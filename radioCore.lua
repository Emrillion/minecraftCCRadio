-- radioCore.lua (UPDATED for Pacer system)
-- Core now sends chunks as fast as possible to the pacer
-- Pacer handles throttling to proper playback speed

local RADIO_CHANNEL = 164  -- Send to pacer on this channel
local CONTROL_CHANNEL = 165  -- Control/management channel
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

-- No local speakers needed - pacer handles playback
local decoder = require("cc.audio.dfpwm").make_decoder()

-- STATE
local queue = {}
local now_playing = nil
local playing_id = nil
local player_handle = nil
local is_loading = false
local is_error = false
local chunk_index = 0
local server_seq = 0
local clients = {}

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
  return true
end

local function broadcastHeartbeat()
  server_seq = server_seq + 1
  local hb = {
    type = "heartbeat",
    song_id = playing_id,
    chunk_index = chunk_index,
    server_seq = server_seq,
    timestamp = os.clock()
  }
  safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, hb)
end

local function broadcastChunk(buffer, volume)
  server_seq = server_seq + 1
  local msg = {
    type = "audio_chunk",
    song_id = playing_id,
    chunk_index = chunk_index,
    seq = server_seq,
    data = buffer,
    volume = volume or 1
  }
  safeTransmit(RADIO_CHANNEL, RADIO_CHANNEL, msg)
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
      print("Core: Client", id, "hasn't been seen for", string.format("%.1f", age), "s - pinging...")
      
      safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
        type = "ping_request",
        client_id = id,
        seq = now,
        timestamp = now
      })
      
      c.status = "unresponsive"
    end
  end
  
  print("Core: Maintenance check - examined", checked, "clients")
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
end

local function playNextInQueue()
  if #queue > 0 then
    now_playing = queue[1]
    table.remove(queue, 1)
    setNowPlaying(now_playing)
  else
    now_playing = nil
    playing_id = nil
    is_loading = false
    is_error = false
    player_handle = nil
    safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
      type = "now_playing_update",
      now_playing = nil
    })
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
          now_playing = now_playing
        })
        
      elseif message.type == "playback_complete" then
        -- Pacer finished playing the current song
        print("Core: Pacer reports playback complete for", message.song_id)
        if message.song_id == playing_id then
          print("Core: Moving to next song in queue")
          -- Don't need to close player_handle - already closed by audioLoop
          playNextInQueue()
        end
        
      elseif message.type == "command" then
        local cmd = message.cmd
        print("Core: Command received:", cmd, "from", message.client_id)
        
        if cmd == "add_to_queue" and message.payload then
          table.insert(queue, message.payload)
          safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
            type = "queue_update",
            queue = queue
          })
          
        elseif cmd == "play_now" and message.payload then
          setNowPlaying(message.payload)
          
        elseif cmd == "skip" then
          playNextInQueue()
          
        elseif cmd == "force_set_volume" and message.payload then
          local vol = message.payload.volume
          safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
            type = "set_volume",
            volume = vol,
            force = true
          })
          
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
          print("Core: Client", message.client_id, "responded to ping")
        end
        
      elseif message.type == "resync_request" then
        safeTransmit(message._reply, CONTROL_CHANNEL, {
          type = "resync_response",
          client_id = message.client_id,
          song_id = playing_id,
          next_chunk_index = chunk_index
        })
        
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
          print("Core: Force refresh - pinging all clients...")
          
          local ping_seq = os.clock()
          local client_count = 0
          for id, c in pairs(clients) do
            client_count = client_count + 1
            safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
              type = "ping_request",
              client_id = id,
              seq = ping_seq,
              timestamp = os.clock()
            })
          end
          
          print("Core: Pinged", client_count, "clients, waiting for responses...")
          sleep(3)
          
          local now = os.clock()
          local removed = 0
          for id, c in pairs(clients) do
            local age = now - (c.last_seen or now)
            if c.status == "unresponsive" or age > 180 then
              print("Core: Removing unresponsive client:", id)
              clients[id] = nil
              removed = removed + 1
            end
          end
          
          print("Core: Force refresh removed", removed, "unresponsive client(s)")
          
          safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
            type = "status_response",
            clients = buildClientsList(),
            queue = queue,
            now_playing = now_playing,
            server_uptime = os.clock(),
            refreshed = true
          })
          
          print("Core: Force refresh complete. Active clients:", #buildClientsList())
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
      local start = handle.read(4)
      chunk_index = 0
      is_loading = false
      is_error = false
      print("Core: Download ready for", now_playing and now_playing.name or "unknown")
      print("Core: Starting high-speed chunk transmission to pacer...")
      
    elseif ev == "http_failure" then
      print("Core: HTTP failure for", url)
      is_loading = false
      is_error = true
      sleep(2)
      playNextInQueue()
    end
  end
end

-- AUDIO LOOP - Sends chunks as fast as possible, pacer notifies when done
local function audioLoop()
  local chunks_sent = 0
  local start_time = nil
  
  while true do
    if player_handle and now_playing then
      if chunks_sent == 0 then
        start_time = os.clock()
        print("Core: Beginning chunk transmission...")
      end
      
      local chunk = player_handle.read(CHUNK_SIZE)
      if not chunk then
        local elapsed = os.clock() - start_time
        print(string.format("Core: Transmission complete - sent %d chunks in %.2fs", chunks_sent, elapsed))
        print("Core: Waiting for pacer to finish playback...")
        
        -- Close the handle, but DON'T move to next song yet
        -- Wait for pacer to send "playback_complete" message
        player_handle.close()
        player_handle = nil
        chunks_sent = 0
        
        -- Just wait - the controlLoop will handle playback_complete
        sleep(0.5)
      else
        local buffer = decoder(chunk)
        broadcastChunk(buffer, now_playing.volume or 1)
        chunks_sent = chunks_sent + 1
        
        -- No delay - send as fast as possible!
        os.sleep(0)
      end
    else
      sleep(0.5)
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
print("Core: Radio channel:", RADIO_CHANNEL, "(to pacer)")
print("Core: Control channel:", CONTROL_CHANNEL)
print("Core: NOTE: Requires pacer on channel", RADIO_CHANNEL)

parallel.waitForAny(controlLoop, httpLoop, audioLoop, heartbeatLoop, maintenanceLoop)