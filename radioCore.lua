-- radioCore.lua (FIXED - Direct transmission with speaker timing)
-- Core sends chunks directly to receivers using speaker-based pacing

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

-- Core needs at least one speaker for timing synchronization
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
local playing = false
local chunk_index = 0
local server_seq = 0
local clients = {}
local looping = 0  -- 0=off, 1=queue, 2=song
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
    playing = playing
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
    playing = playing,
    looping = looping,
    volume = volume,
    server_uptime = os.clock()
  })
end

local function pruneStaleClients()
  local now = os.clock()
  local checked = 0
  
  for id, c in pairs(clients) do
    checked = checked + 1
    local age = now - (c.last_seen or now)
    
    if age > CLIENT_TIMEOUT then
      print("Core: Client", id, "hasn't been seen for", string.format("%.1f", age), "s - removing")
      clients[id] = nil
    end
  end
  
  if checked > 0 then
    print("Core: Maintenance check - examined", checked, "clients")
  end
end

-- QUEUE MANAGEMENT
local function setNowPlaying(item)
  now_playing = item
  playing_id = item and item.id or nil
  chunk_index = 0
  
  if player_handle then
    pcall(player_handle.close, player_handle)
    player_handle = nil
  end
  
  is_loading = true
  is_error = false
  playing = false
  server_seq = server_seq + 1

  if now_playing and now_playing.id then
    local dl = api_base_url .. "?v=" .. version .. "&id=" .. textutils.urlEncode(now_playing.id)
    print("Core: Requesting", now_playing.name)
    http.request({ url = dl, binary = true })
  else
    is_loading = false
  end

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
      -- Loop queue mode - add current song to end
      table.insert(queue, now_playing)
    end
    
    now_playing = queue[1]
    table.remove(queue, 1)
    setNowPlaying(now_playing)
  else
    if looping == 2 and now_playing then
      -- Loop song mode - replay current song
      setNowPlaying(now_playing)
    else
      -- Stop playing
      now_playing = nil
      playing_id = nil
      is_loading = false
      is_error = false
      playing = false
      player_handle = nil
      
      safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
        type = "now_playing_update",
        now_playing = nil
      })
      
      safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
        type = "queue_update",
        queue = queue
      })
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
          playing = playing,
          looping = looping,
          volume = volume
        })
        
      elseif message.type == "command" then
        local cmd = message.cmd
        print("Core: Command received:", cmd, "from", message.client_id)
        
        if cmd == "add_to_queue" and message.payload then
          if message.payload.type == "playlist" and message.payload.playlist_items then
            -- Add all playlist items
            for i = 1, #message.payload.playlist_items do
              table.insert(queue, message.payload.playlist_items[i])
            end
          else
            -- Add single song
            table.insert(queue, message.payload)
          end
          
          safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
            type = "queue_update",
            queue = queue
          })
          
        elseif cmd == "play_now" and message.payload then
          -- Stop current playback
          if playing then
            for _, speaker in ipairs(speakers) do
              pcall(speaker.stop, speaker)
            end
            playing = false
          end
          
          -- Handle playlist or single song
          if message.payload.type == "playlist" and message.payload.playlist_items then
            setNowPlaying(message.payload.playlist_items[1])
            -- Add remaining songs to front of queue
            for i = #message.payload.playlist_items, 2, -1 do
              table.insert(queue, 1, message.payload.playlist_items[i])
            end
          else
            setNowPlaying(message.payload)
          end
          
        elseif cmd == "play_next" and message.payload then
          -- Handle playlist or single song
          if message.payload.type == "playlist" and message.payload.playlist_items then
            -- Insert playlist items at beginning of queue
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
          if playing then
            for _, speaker in ipairs(speakers) do
              pcall(speaker.stop, speaker)
            end
          end
          playNextInQueue()
          
        elseif cmd == "play" then
          if now_playing and not playing then
            playing = true
            os.queueEvent("audio_update")
          elseif #queue > 0 and not now_playing then
            playNextInQueue()
            playing = true
          end
          
        elseif cmd == "stop" then
          playing = false
          for _, speaker in ipairs(speakers) do
            pcall(speaker.stop, speaker)
          end
          
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
          print("Core: Broadcasting shutdown to all devices...")
          for i = 1, 5 do
            safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
              type = "network_shutdown",
              timestamp = os.clock()
            })
            sleep(0.5)
          end
          print("Core: Shutdown broadcast complete. Shutting down...")
          sleep(1)
          os.shutdown()

        elseif cmd == "restart_network" then
          print("Core: Broadcasting restart to all devices...")
          for i = 1, 5 do
            safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
              type = "network_restart",
              timestamp = os.clock()
            })
            sleep(0.5)
          end
          print("Core: Restart broadcast complete. Rebooting...")
          sleep(1)
          os.reboot()

        elseif cmd == "force_refresh" then
          print("Core: Force refresh - clearing stale clients...")
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
      player_handle = handle
      local start_bytes = handle.read(4)
      chunk_index = 0
      is_loading = false
      is_error = false
      playing = true
      print("Core: Download ready for", now_playing and now_playing.name or "unknown")
      os.queueEvent("audio_update")
      
    elseif ev == "http_failure" then
      print("Core: HTTP failure for", url)
      is_loading = false
      is_error = true
      sleep(2)
      playNextInQueue()
    end
  end
end

-- AUDIO LOOP - Uses speaker timing like original system
local function audioLoop()
  while true do
    if playing and player_handle and now_playing then
      local this_song_id = playing_id
      
      while true do
        local chunk = player_handle.read(CHUNK_SIZE)
        
        if not chunk then
          -- Song finished
          print("Core: Song finished:", now_playing.name)
          player_handle.close()
          player_handle = nil
          playNextInQueue()
          break
        end
        
        -- Decode chunk
        local buffer = decoder(chunk)
        
        -- Broadcast to all receivers
        broadcastChunk(buffer, volume)
        
        -- Play locally on core's speakers for timing synchronization
        -- This is the KEY to proper timing - we wait for the speaker to be ready
        local playback_functions = {}
        for i, speaker in ipairs(speakers) do
          playback_functions[i] = function()
            local name = peripheral.getName(speaker)
            while not speaker.playAudio(buffer, volume) do
              local ev, speaker_name = os.pullEvent("speaker_audio_empty")
              if speaker_name == name then
                break
              end
            end
            
            -- Wait for this speaker to finish playing this chunk
            repeat
              local ev, speaker_name = os.pullEvent("speaker_audio_empty")
            until speaker_name == name
          end
        end
        
        -- Wait for all speakers to finish
        parallel.waitForAll(table.unpack(playback_functions))
        
        -- Check if we should stop
        if not playing or playing_id ~= this_song_id then
          if player_handle then
            player_handle.close()
            player_handle = nil
          end
          break
        end
      end
    end
    
    os.pullEvent("audio_update")
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