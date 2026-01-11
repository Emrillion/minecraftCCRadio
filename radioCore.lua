-- radioCore.lua (STABILITY FIXED v2 - Proper event handling)
-- Fixed: Audio loop can now respond to state changes while playing

local RADIO_CHANNEL = 164
local CONTROL_CHANNEL = 165
local api_base_url = "https://ipod-2to6magyna-uc.a.run.app/"
local version = "2.1"
local HEARTBEAT_INTERVAL = 1.0
local CHUNK_SIZE = 16 * 1024 - 4
local CLIENT_TIMEOUT = 120
local MAINTENANCE_INTERVAL = 30

-- PERIPHERALS
local modem = peripheral.find("modem")
if not modem then error("Core: No modem attached") end
modem.open(RADIO_CHANNEL)
modem.open(CONTROL_CHANNEL)

local speakers = { peripheral.find("speaker") }
if #speakers == 0 then
  error("Core: No speakers found! Core needs at least one speaker for timing.")
end

local decoder = require("cc.audio.dfpwm").make_decoder()

-- STATE
local queue = {}
local now_playing = nil
local playing_id = nil
local player_handle = nil
local is_loading = false
local is_error = false
local should_be_playing = false
local actually_playing = false
local chunk_index = 0
local server_seq = 0
local clients = {}
local looping = 0
local volume = 1.0

-- UTIL
local function gen_client_id(prefix)
  prefix = prefix or "c"
  return prefix .. "_" .. tostring(math.random(1000,9999)) .. "_" .. tostring(os.time() % 100000)
end

local function safeTransmit(channel, reply, message)
  local ok, err = pcall(function()
    modem.transmit(channel, reply, message)
  end)
  if not ok then 
    print("Core: Transmit error:", err) 
    return false
  end
  return ok
end

local function broadcastHeartbeat()
  server_seq = server_seq + 1
  safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
    type = "heartbeat",
    song_id = playing_id,
    chunk_index = chunk_index,
    server_seq = server_seq,
    timestamp = os.clock(),
    playing = actually_playing
  })
end

local function broadcastChunk(buffer, vol)
  server_seq = server_seq + 1
  safeTransmit(RADIO_CHANNEL, RADIO_CHANNEL, {
    type = "audio_chunk",
    song_id = playing_id,
    chunk_index = chunk_index,
    seq = server_seq,
    data = buffer,
    volume = vol or volume
  })
  chunk_index = chunk_index + 1
end

local function buildClientsList()
  local clients_flat = {}
  for id, c in pairs(clients) do
    table.insert(clients_flat, {
      client_id = id,
      type = c.type,
      last_seen = c.last_seen,
      region = c.region,
      latency = c.latency,
      volume = c.volume,
      status = c.status
    })
  end
  return clients_flat
end

local function sendStatusResponse(replyChannel, requester)
  safeTransmit(replyChannel, CONTROL_CHANNEL, {
    type = "status_response",
    clients = buildClientsList(),
    queue = queue,
    now_playing = now_playing,
    playing = actually_playing,
    looping = looping,
    volume = volume,
    server_uptime = os.clock()
  })
end

local function pruneStaleClients()
  local now = os.clock()
  local to_remove = {}
  
  for id, c in pairs(clients) do
    local age = now - (c.last_seen or now)
    if age > (CLIENT_TIMEOUT * 2) then
      table.insert(to_remove, id)
    end
  end
  
  for _, id in ipairs(to_remove) do
    clients[id] = nil
  end
  
  if #to_remove > 0 then
    print("Core: Maintenance removed", #to_remove, "stale client(s)")
  end
end

-- Stop everything cleanly
local function stopPlayback()
  print("Core: Stopping playback")
  should_be_playing = false
  actually_playing = false
  
  -- Stop speakers
  for _, speaker in ipairs(speakers) do
    pcall(speaker.stop, speaker)
  end
  
  -- Close handle
  if player_handle then
    pcall(player_handle.close, player_handle)
    player_handle = nil
  end
end

-- QUEUE MANAGEMENT
local function setNowPlaying(item, auto_play)
  print("Core: setNowPlaying called for:", item and item.name or "nil", "auto_play:", auto_play)
  
  -- Stop current playback first
  stopPlayback()
  sleep(0.05)
  
  now_playing = item
  playing_id = item and item.id or nil
  chunk_index = 0
  is_loading = false
  is_error = false
  
  if auto_play == nil then auto_play = true end

  if now_playing and now_playing.id then
    local dl = api_base_url .. "?v=" .. version .. "&id=" .. textutils.urlEncode(now_playing.id)
    print("Core: Requesting download for", now_playing.name)
    is_loading = true
    should_be_playing = auto_play
    http.request({ url = dl, binary = true })
  else
    should_be_playing = false
  end

  server_seq = server_seq + 1
  safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
    type = "now_playing_update",
    now_playing = now_playing,
    playing_id = playing_id,
    chunk_index = chunk_index
  })
  
  safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
    type = "queue_update",
    queue = queue
  })
end

local function playNextInQueue()
  if #queue > 0 then
    if looping == 1 and now_playing then
      table.insert(queue, now_playing)
    end
    
    local next_song = queue[1]
    table.remove(queue, 1)
    setNowPlaying(next_song, true)
  else
    if looping == 2 and now_playing then
      setNowPlaying(now_playing, true)
    else
      setNowPlaying(nil, false)
    end
  end
end

-- CONTROL LOOP
local function controlLoop()
  while true do
    local ev, side, channel, replyChannel, message, distance = os.pullEvent("modem_message")
    
    if channel == CONTROL_CHANNEL and type(message) == "table" then
      message._reply = replyChannel
      
      if message.client_id and clients[message.client_id] then
        clients[message.client_id].last_seen = os.clock()
      end
      
      if message.type == "join" then
        local id = message.client_id or gen_client_id("rx")
        clients[id] = {
          type = message.client_type or "receiver",
          last_seen = os.clock(),
          region = message.region,
          caps = message.capabilities,
          latency = 0,
          volume = (message.volume or 1),
          status = "ok"
        }
        print("Core: Client joined ->", id, "(" .. (message.client_type or "receiver") .. ")")
        
        safeTransmit(message._reply, CONTROL_CHANNEL, {
          type = "join_ack",
          client_id = id,
          song_id = playing_id,
          next_chunk_index = chunk_index,
          server_seq = server_seq,
          queue = queue,
          now_playing = now_playing,
          playing = actually_playing,
          looping = looping,
          volume = volume
        })
        
      elseif message.type == "command" then
        local cmd = message.cmd
        print("Core: Command:", cmd, "from", message.client_id)
        
        if cmd == "add_to_queue" and message.payload then
          if message.payload.type == "playlist" and message.payload.playlist_items then
            for i = 1, #message.payload.playlist_items do
              table.insert(queue, message.payload.playlist_items[i])
            end
          else
            table.insert(queue, message.payload)
          end
          
          safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
            type = "queue_update",
            queue = queue
          })
          
        elseif cmd == "play_now" and message.payload then
          if message.payload.type == "playlist" and message.payload.playlist_items then
            setNowPlaying(message.payload.playlist_items[1], true)
            for i = #message.payload.playlist_items, 2, -1 do
              table.insert(queue, 1, message.payload.playlist_items[i])
            end
          else
            setNowPlaying(message.payload, true)
          end
          
        elseif cmd == "play_next" and message.payload then
          if message.payload.type == "playlist" and message.payload.playlist_items then
            for i = #message.payload.playlist_items, 1, -1 do
              table.insert(queue, 1, message.payload.playlist_items[i])
            end
          else
            table.insert(queue, 1, message.payload)
          end
          
          safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
            type = "queue_update",
            queue = queue
          })
          
        elseif cmd == "skip" then
          playNextInQueue()
          
        elseif cmd == "play" then
          print("Core: Play command - resuming current song")
          if now_playing and player_handle then
            print("Core: Setting should_be_playing = true")
            should_be_playing = true
          elseif now_playing and not player_handle then
            print("Core: Re-downloading current song")
            setNowPlaying(now_playing, true)
          elseif #queue > 0 then
            print("Core: Play command - starting from queue")
            playNextInQueue()
          end
          
        elseif cmd == "stop" then
          print("Core: Stop command")
          stopPlayback()
          
        elseif cmd == "set_volume" and message.payload then
          volume = message.payload.volume
          print("Core: Volume set to", volume)
          
        elseif cmd == "set_looping" and message.payload then
          looping = message.payload.looping
          print("Core: Looping set to", looping)
          
        elseif cmd == "request_status" then
          sendStatusResponse(message._reply, message.client_id)
        end
        
      elseif message.type == "ping" then
        safeTransmit(message._reply, CONTROL_CHANNEL, {
          type = "pong",
          seq = message.seq,
          client_id = message.client_id,
          ts = os.clock()
        })
        
      elseif message.type == "ping_response" then
        if clients[message.client_id] then
          clients[message.client_id].last_seen = os.clock()
          clients[message.client_id].status = "ok"
        end
        
      elseif message.type == "status_request" then
        sendStatusResponse(message._reply, message.client_id)
        
      elseif message.type == "network_command" then
        local cmd = message.cmd
        print("Core: Network command ->", cmd)

        if cmd == "shutdown_network" then
          print("Core: Broadcasting shutdown...")
          for i = 1, 5 do
            safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
              type = "network_shutdown",
              timestamp = os.clock()
            })
            sleep(0.5)
          end
          sleep(1)
          os.shutdown()

        elseif cmd == "restart_network" then
          print("Core: Broadcasting restart...")
          for i = 1, 5 do
            safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
              type = "network_restart",
              timestamp = os.clock()
            })
            sleep(0.5)
          end
          sleep(1)
          os.reboot()

        elseif cmd == "force_refresh" then
          pruneStaleClients()
          safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
            type = "status_response",
            clients = buildClientsList(),
            queue = queue,
            now_playing = now_playing,
            server_uptime = os.clock(),
            refreshed = true
          })
        end
      end
    end
  end
end

-- HTTP LOOP
local function httpLoop()
  while true do
    local ev, url, handle = os.pullEvent()
    
    if ev == "http_success" and url and handle then
      print("Core: Download complete!")
      local start_bytes = handle.read(4)
      player_handle = handle
      chunk_index = 0
      is_loading = false
      is_error = false
      
      print("Core: Handle ready, should_be_playing =", should_be_playing)
      
    elseif ev == "http_failure" then
      print("Core: HTTP failure for", url)
      is_loading = false
      is_error = true
      sleep(2)
      playNextInQueue()
    end
  end
end

-- AUDIO LOOP - Uses parallel.waitForAny to handle speaker events without blocking
local function audioLoop()
  print("Core: Audio loop started")
  
  while true do
    -- Check if we should start or continue playing
    if should_be_playing and player_handle and now_playing then
      local current_song_id = playing_id
      actually_playing = true
      print("Core: Starting playback for", now_playing.name)
      
      -- Play until told to stop or song ends
      local stop_requested = false
      while should_be_playing and player_handle and playing_id == current_song_id and not stop_requested do
        local chunk = player_handle.read(CHUNK_SIZE)
        
        if not chunk then
          -- Song finished
          print("Core: Song finished:", now_playing.name)
          player_handle.close()
          player_handle = nil
          actually_playing = false
          playNextInQueue()
          break
        end
        
        -- Decode and broadcast
        local buffer = decoder(chunk)
        broadcastChunk(buffer, volume)
        
        -- Play on all speakers with non-blocking approach
        local speakers_ready = {}
        for i, speaker in ipairs(speakers) do
          speakers_ready[i] = false
        end
        
        -- Try to queue on all speakers
        for i, speaker in ipairs(speakers) do
          if speaker.playAudio(buffer, volume) then
            speakers_ready[i] = true
          end
        end
        
        -- Wait for any speakers that weren't ready
        while not stop_requested do
          local all_ready = true
          for i = 1, #speakers do
            if not speakers_ready[i] then
              all_ready = false
              break
            end
          end
          if all_ready then break end
          
          -- Use parallel to check both speaker events AND state changes
          parallel.waitForAny(
            function()
              local ev, speaker_name = os.pullEvent("speaker_audio_empty")
              -- Try to queue on the speaker that just emptied
              for i, speaker in ipairs(speakers) do
                if peripheral.getName(speaker) == speaker_name and not speakers_ready[i] then
                  if speaker.playAudio(buffer, volume) then
                    speakers_ready[i] = true
                  end
                end
              end
            end,
            function()
              sleep(0.05)  -- Timeout to check state periodically
            end
          )
          
          -- Check if we should stop
          if not should_be_playing or playing_id ~= current_song_id then
            print("Core: Stop detected during speaker wait")
            actually_playing = false
            stop_requested = true
            break
          end
        end
        
        if stop_requested then break end
        
        -- Now wait for all speakers to finish playing this chunk
        local speakers_done = {}
        for i = 1, #speakers do
          speakers_done[i] = false
        end
        
        while not stop_requested do
          local all_done = true
          for i = 1, #speakers do
            if not speakers_done[i] then
              all_done = false
              break
            end
          end
          if all_done then break end
          
          -- Use parallel to check both speaker events AND state changes
          parallel.waitForAny(
            function()
              local ev, speaker_name = os.pullEvent("speaker_audio_empty")
              for i, speaker in ipairs(speakers) do
                if peripheral.getName(speaker) == speaker_name then
                  speakers_done[i] = true
                end
              end
            end,
            function()
              sleep(0.05)  -- Timeout to check state periodically
            end
          )
          
          -- Check if we should stop
          if not should_be_playing or playing_id ~= current_song_id then
            print("Core: Stop detected during playback sync")
            actually_playing = false
            stop_requested = true
            break
          end
        end
      end
      
      actually_playing = false
    else
      -- Not playing - wait a bit and check again
      actually_playing = false
      sleep(0.1)
    end
  end
end

-- HEARTBEAT LOOP
local function heartbeatLoop()
  while true do
    broadcastHeartbeat()
    sleep(HEARTBEAT_INTERVAL)
  end
end

-- MAINTENANCE LOOP
local function maintenanceLoop()
  while true do
    sleep(MAINTENANCE_INTERVAL)
    pruneStaleClients()
  end
end

-- MAIN
print("Core: Starting radio core server...")
print("Core: Radio channel:", RADIO_CHANNEL)
print("Core: Control channel:", CONTROL_CHANNEL)
print("Core: Speakers:", #speakers)

parallel.waitForAny(controlLoop, httpLoop, audioLoop, heartbeatLoop, maintenanceLoop)