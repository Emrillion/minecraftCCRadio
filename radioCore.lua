-- radioCore.lua
-- Core authoritative server: maintains queue, downloads audio, decodes, and broadcasts chunks.
-- Place this on your designated server machine. Can run headless (no local speaker required).

-- CONFIG
local RADIO_CHANNEL = 164
local CONTROL_CHANNEL = RADIO_CHANNEL + 1
local api_base_url = "https://ipod-2to6_MAGYNA-uc.a.run.app/"
local version = "2.1"
local HEARTBEAT_INTERVAL = 1.0
local CHUNK_SIZE = 16 * 1024 - 4
local CLIENT_TIMEOUT = 120 -- seconds before considering a client stale (2 minutes)
local MAINTENANCE_INTERVAL = 30 -- how often to check for stale clients (30 seconds)

-- PERIPHERALS
local modem = peripheral.find("modem")
if not modem then error("Core: No modem attached") end
modem.open(RADIO_CHANNEL)
modem.open(CONTROL_CHANNEL)

-- Optional local speaker to preview
local speakers = { peripheral.find("speaker") }
local has_local_speakers = (#speakers > 0)

-- AUDIO/HTTP
local http = http
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
local shutdown_requested = false
local restart_requested = false

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
  local removed = 0
  local checked = 0
  
  for id, c in pairs(clients) do
    checked = checked + 1
    local age = now - (c.last_seen or now)
    
    if age > CLIENT_TIMEOUT then
      -- Client hasn't been seen in a while - try pinging first
      print("Core: Client", id, "hasn't been seen for", string.format("%.1f", age), "s - pinging...")
      
      safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
        type = "ping_request",
        client_id = id,
        seq = now,
        timestamp = now
      })
      
      -- Mark as potentially stale, but don't remove yet
      -- Force refresh will do the actual removal
      c.status = "unresponsive"
    end
  end
  
  print("Core: Maintenance check - examined", checked, "clients")
  return removed
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
      
      -- Update client last_seen timestamp
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
        -- Client responded to our ping during maintenance or force refresh
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
          -- Broadcast multiple times to ensure delivery
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
          -- Broadcast multiple times to ensure delivery
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
          print("Core: Force refresh - pinging all clients and removing unresponsive ones...")
          
          -- Ping all clients
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
          
          -- Wait for responses
          sleep(3)
          
          -- Now remove clients that are marked unresponsive or very old
          local now = os.clock()
          local removed = 0
          for id, c in pairs(clients) do
            local age = now - (c.last_seen or now)
            -- Remove if status is unresponsive OR if it's been over 3 minutes
            if c.status == "unresponsive" or age > 180 then
              print("Core: Removing unresponsive client:", id, "(last seen", string.format("%.1f", age), "s ago)")
              clients[id] = nil
              removed = removed + 1
            end
          end
          
          print("Core: Force refresh removed", removed, "unresponsive client(s)")
          
          -- Broadcast updated status
          print("Core: Broadcasting refreshed status...")
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
      
    elseif ev == "http_failure" then
      print("Core: HTTP failure for", url)
      is_loading = false
      is_error = true
      -- Auto-skip on error
      sleep(2)
      playNextInQueue()
    end
  end
end

-- AUDIO LOOP
local function audioLoop()
  while true do
    if player_handle and now_playing then
      local chunk = player_handle.read(CHUNK_SIZE)
      if not chunk then
        print("Core: Song ended:", now_playing.name)
        player_handle.close()
        player_handle = nil
        playNextInQueue()
      else
        local buffer = decoder(chunk)
        broadcastChunk(buffer, now_playing.volume or 1)

        if has_local_speakers then
          for _, s in ipairs(speakers) do
            pcall(s.playAudio, s, buffer, now_playing.volume or 1)
          end
        end

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
print("Core: Radio channel:", RADIO_CHANNEL)
print("Core: Control channel:", CONTROL_CHANNEL)

parallel.waitForAny(controlLoop, httpLoop, audioLoop, heartbeatLoop, maintenanceLoop)