-- radioCore.lua
-- Core authoritative server: maintains queue, downloads audio, decodes, and broadcasts chunks.
-- Place this on your designated server machine. Can run headless (no local speaker required).

-- CONFIG
local RADIO_CHANNEL = 164
local CONTROL_CHANNEL = RADIO_CHANNEL + 1
local api_base_url = "https://ipod-2to6_MAGYNA-uc.a.run.app/" -- your original API; keep updated
local version = "2.1"
local HEARTBEAT_INTERVAL = 1.0 -- seconds
local CHUNK_SIZE = 16 * 1024 - 4 -- match original broadcaster chunk size

-- PERIPHERALS
local modem = peripheral.find("modem")
if not modem then error("Core: No modem attached") end
modem.open(RADIO_CHANNEL)
modem.open(CONTROL_CHANNEL)

-- Optional local speaker to preview (core may be headless)
local speakers = { peripheral.find("speaker") }
local has_local_speakers = (#speakers > 0)

-- AUDIO/HTTP
local http = http
local decoder = require("cc.audio.dfpwm").make_decoder()

-- STATE
local queue = {} -- { { id=..., name=..., artist=..., url=..., volume=..., type=..., ... }, ... }
local now_playing = nil -- metadata table or nil
local playing_id = nil
local player_handle = nil
local is_loading = false
local is_error = false

local chunk_index = 0 -- increments each emitted chunk for current song
local server_seq = 0 -- heartbeat/seq counter
local clients = {} -- client_id -> {type, last_seen, region, caps, latency, volume, status}
local client_ids = {} -- useful list order

-- UTIL
local function gen_client_id(prefix)
  prefix = prefix or "c"
  return prefix .. "_" .. tostring(math.random(1000,9999)) .. "_" .. tostring(os.time() % 100000)
end

local function safeTransmit(channel, reply, message)
  -- pcall transmit to avoid crashes when modem can't send
  local ok, err = pcall(function()
    modem.transmit(channel, reply, message)
  end)
  if not ok then print("Transmit error:", err) end
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
  -- send on control channel (so selectors/dashboards get state without audio)
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
  -- Broadcast raw audio on RADIO_CHANNEL
  safeTransmit(RADIO_CHANNEL, RADIO_CHANNEL, msg)
  chunk_index = chunk_index + 1
end

local function sendStatusResponse(replyChannel, requester)
  local clients_flat = {}
  for id, c in pairs(clients) do
    table.insert(clients_flat, {client_id = id, type = c.type, last_seen = c.last_seen, region = c.region, latency = c.latency, volume = c.volume, status = c.status})
  end
  safeTransmit(replyChannel, CONTROL_CHANNEL, {
    type = "status_response",
    clients = clients_flat,
    queue = queue,
    now_playing = now_playing,
    server_uptime = os.clock()
  })
end

-- QUEUE MANAGEMENT
local function setNowPlaying(item)
  now_playing = item
  playing_id = item and item.id or nil
  chunk_index = 0
  -- close any existing handle
  if player_handle then
    pcall(player_handle.close, player_handle)
    player_handle = nil
  end
  is_loading = true
  is_error = false
  server_seq = server_seq + 1

  if now_playing and now_playing.id then
    local dl = api_base_url .. "?v=" .. version .. "&id=" .. textutils.urlEncode(now_playing.id)
    print("Core: requesting ", dl)
    http.request({ url = dl, binary = true })
  else
    is_loading = false
  end

  -- notify selectors via control channel of new now playing
  safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, { type = "now_playing_update", now_playing = now_playing, playing_id = playing_id, chunk_index = chunk_index })
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
    safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, { type = "now_playing_update", now_playing = nil })
  end
end

-- CONTROL LOOP: handle join/command/ping
local function controlLoop()
  while true do
    local ev, side, channel, replyChannel, message, distance = os.pullEvent("modem_message")
    if channel == CONTROL_CHANNEL and type(message) == "table" then
      message._reply = replyChannel
      if message.type == "join" then
        local id = message.client_id or gen_client_id("rx")
        clients[id] = { type = message.client_type or "receiver", last_seen = os.time(), region = message.region, caps = message.capabilities, latency = 0, volume = (message.volume or 1), status = "ok" }
        clients[id].last_ping = os.clock()
        print("Core: client join ->", id, message.client_type)
        -- reply join_ack
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
        print("Core: received command", cmd, "from", message.client_id)
        if cmd == "add_to_queue" and message.payload then
          table.insert(queue, message.payload)
          safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, { type = "queue_update", queue = queue })
        elseif cmd == "play_now" and message.payload then
          setNowPlaying(message.payload)
        elseif cmd == "skip" then
          playNextInQueue()
        elseif cmd == "set_loop" then
          -- loop handling could be implemented by storing loop state; omitted for brevity
        elseif cmd == "force_set_volume" and message.payload then
          local vol = message.payload.volume
          safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, { type = "set_volume", volume = vol, force = true })
        elseif cmd == "request_status" then
          sendStatusResponse(message._reply, message.client_id)
        end
      elseif message.type == "ping" then
        -- reply with pong for latency
        safeTransmit(message._reply, CONTROL_CHANNEL, { type = "pong", seq = message.seq, client_id = message.client_id, ts = os.clock() })
      elseif message.type == "resync_request" then
        -- a client missed chunks; reply with authoritative next chunk info
        safeTransmit(message._reply, CONTROL_CHANNEL, { type = "resync_response", client_id = message.client_id, song_id = playing_id, next_chunk_index = chunk_index })
      elseif message.type == "status_request" then
        sendStatusResponse(message._reply, message.client_id)
      end
    end
  end
end

-- HTTP handler: reacts to http_success/failure (mirrors original broadcaster logic)
local function httpLoop()
  while true do
    local ev, url, handle = os.pullEvent("http_success")
    if url and handle then
      -- if it's the playing download url, set player_handle
      -- We can't inspect URL reliably here; assume the last requested now_playing corresponds.
      player_handle = handle
      -- read initial 4 bytes
      local start = handle.read(4)
      chunk_index = 0
      is_loading = false
      is_error = false
      print("Core: download ready")
    end
    -- handle failures
    local ev2, failurl = os.pullEvent("http_failure")
    if ev2 and failurl then
      print("Core: http failure", failurl)
      is_loading = false
      is_error = true
    end
  end
end

-- AUDIO LOOP: read from player_handle, decode, broadcast
local function audioLoop()
  while true do
    if player_handle and now_playing then
      -- read chunks
      local chunk = player_handle.read(CHUNK_SIZE)
      if not chunk then
        -- end of file
        player_handle.close()
        player_handle = nil
        playNextInQueue()
      else
        local buffer = decoder(chunk)
        -- Broadcast the buffer
        broadcastChunk(buffer, now_playing.volume or 1)

        -- Optionally play locally
        if has_local_speakers then
          for _, s in ipairs(speakers) do
            -- best-effort local playback without blocking the core loop
            pcall(s.playAudio, s, buffer, now_playing.volume or 1)
          end
        end

        -- sleep a small amount if necessary; the rate is determined by how quickly speakers consume audio
        -- we can let speaker events pace in more complex implementation; keep small yield to avoid lock
        os.sleep(0)
      end
    else
      os.pullEvent("audio_request") -- idle until new audio ready
    end
  end
end

-- Heartbeat loop
local function heartbeatLoop()
  while true do
    broadcastHeartbeat()
    os.sleep(HEARTBEAT_INTERVAL)
  end
end

-- Driver: wait for http events and run loops in parallel
parallel.waitForAny(controlLoop, httpLoop, audioLoop, heartbeatLoop)
