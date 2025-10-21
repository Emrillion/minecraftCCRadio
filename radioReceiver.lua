-- radioReceiver.lua (UPDATED for Pacer system)
-- Now receives from pacer on channel 166 instead of directly from core

local RECEIVER_CHANNEL = 166  -- Changed! Receive from pacer on this channel
local CONTROL_CHANNEL = 165  -- Still talk to core on control channel

local modem = peripheral.find("modem")
local decoder = require("cc.audio.dfpwm").make_decoder()
local speakers = { peripheral.find("speaker") }

if not modem then error("Receiver: No modem found! Attach a wireless modem.") end
if #speakers == 0 then error("Receiver: No speakers found! Attach at least one speaker.") end

modem.open(RECEIVER_CHANNEL)
modem.open(CONTROL_CHANNEL)

-- ==== CLIENT ID ====
local function gen_client_id(prefix)
  prefix = prefix or "c"
  return prefix .. "_" .. tostring(math.random(1000,9999)) .. "_" .. tostring(os.time() % 100000)
end

local my_id = gen_client_id("rx")

-- ==== STATE ====
local expected_song = nil
local expected_chunk = 0
local local_volume = 1.0
local accept_global_force = true
local last_heartbeat = os.clock()
local chunk_buffer = {}  -- Small local buffer
local BUFFER_SIZE = 2  -- Keep 2 chunks buffered

-- ==== UTILITIES ====
local function safeTransmit(channel, reply, message)
  local ok, err = pcall(function()
    modem.transmit(channel, reply, message)
  end)
  if not ok then
    print("Receiver: Transmit error:", err)
    return false
  end
  return true
end

-- Persist volume
local function saveConfig()
  local ok, err = pcall(function()
    local f = fs.open("radio_config.txt", "w")
    f.write(textutils.serialize({ volume = local_volume }))
    f.close()
  end)
  if not ok then
    print("Receiver: Config save error:", err)
  end
end

local function loadConfig()
  if fs.exists("radio_config.txt") then
    local ok, err = pcall(function()
      local f = fs.open("radio_config.txt", "r")
      local raw = f.readAll()
      f.close()
      local t = textutils.unserialize(raw)
      if t and t.volume then
        local_volume = t.volume
        print("Receiver: Loaded volume:", local_volume)
      end
    end)
    if not ok then
      print("Receiver: Config load error:", err)
    end
  end
end

loadConfig()

-- ==== JOIN NETWORK ====
print("Receiver: Joining network as", my_id)
safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
  type = "join",
  client_id = my_id,
  client_type = "receiver",
  capabilities = { play = true, control = false, noisy = true },
  volume = local_volume
})

-- ==== CONTROL LOOP ====
local function handleControl()
  while true do
    local ev, side, channel, reply, msg, dist = os.pullEvent("modem_message")
    
    if channel == CONTROL_CHANNEL and type(msg) == "table" then
      if msg.type == "join_ack" and msg.client_id == my_id then
        expected_song = msg.song_id
        expected_chunk = msg.next_chunk_index or 0
        print("Receiver: Joined! Starting at chunk", expected_chunk)
        
      elseif msg.type == "heartbeat" then
        last_heartbeat = os.clock()
        
        -- Detect song changes
        if msg.song_id ~= expected_song then
          expected_song = msg.song_id
          expected_chunk = msg.chunk_index
          
          -- Stop local playback to avoid mismatch
          for _, s in ipairs(speakers) do
            pcall(s.stop, s)
          end
          
          print("Receiver: Song changed, expecting chunk", expected_chunk)
        end
        
      elseif msg.type == "ping_request" and msg.client_id == my_id then
        -- Respond to ping during force refresh
        safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
          type = "ping_response",
          client_id = my_id,
          seq = msg.seq,
          timestamp = os.clock()
        })
        
      elseif msg.type == "set_volume" then
        if msg.force or accept_global_force then
          local_volume = msg.volume
          saveConfig()
          print("Receiver: Volume set to", local_volume)
        end
        
      elseif msg.type == "resync_response" and msg.client_id == my_id then
        expected_song = msg.song_id
        expected_chunk = msg.next_chunk_index
        print("Receiver: Resynced to chunk", expected_chunk)
        
      elseif msg.type == "now_playing_update" then
        -- Core notified of song change
        if msg.now_playing then
          print("Receiver: Now playing:", msg.now_playing.name)
        else
          print("Receiver: Playback stopped")
        end
        
      elseif msg.type == "network_shutdown" then
        print("Receiver: Shutdown command received")
        for _, s in ipairs(speakers) do
          pcall(s.stop, s)
        end
        sleep(1)
        os.shutdown()
        
      elseif msg.type == "network_restart" then
        print("Receiver: Restart command received")
        for _, s in ipairs(speakers) do
          pcall(s.stop, s)
        end
        sleep(1)
        os.reboot()
      end
    end
  end
end

-- ==== AUDIO LOOP ====
local function handleAudio()
  while true do
    local ev, side, channel, reply, msg, dist = os.pullEvent("modem_message")
    
    -- NOW listening on RECEIVER_CHANNEL (166) from pacer
    if channel == RECEIVER_CHANNEL and type(msg) == "table" and msg.type == "audio_chunk" then
      
      -- Handle song changes
      if msg.song_id ~= expected_song then
        print("Receiver: New song detected")
        expected_song = msg.song_id
        expected_chunk = 0
        chunk_buffer = {}
        
        -- Stop current playback
        for _, s in ipairs(speakers) do
          pcall(s.stop, s)
        end
      end
      
      -- Buffer incoming chunks
      if msg.chunk_index >= expected_chunk then
        table.insert(chunk_buffer, {
          chunk_index = msg.chunk_index,
          data = msg.data
        })
        
        -- Sort buffer by chunk_index (in case packets arrive out of order)
        table.sort(chunk_buffer, function(a, b) return a.chunk_index < b.chunk_index end)
        
        -- Trim buffer if it gets too large
        while #chunk_buffer > 5 do
          table.remove(chunk_buffer, 1)
          expected_chunk = expected_chunk + 1
        end
      end
    end
  end
end

-- ==== PLAYBACK LOOP ====
local function handlePlayback()
  while true do
    -- Check if we have buffered chunks ready to play
    if #chunk_buffer > 0 and chunk_buffer[1].chunk_index == expected_chunk then
      local chunk = table.remove(chunk_buffer, 1)
      expected_chunk = expected_chunk + 1
      
      -- Play the chunk
      local buffer = chunk.data
      for _, speaker in ipairs(speakers) do
        while not speaker.playAudio(buffer, local_volume) do
          os.pullEvent("speaker_audio_empty")
        end
      end
      
    elseif #chunk_buffer > 0 and chunk_buffer[1].chunk_index > expected_chunk then
      -- We're behind - skip ahead
      local missed = chunk_buffer[1].chunk_index - expected_chunk
      if missed > 0 then
        print("Receiver: Skipping", missed, "chunk(s) to catch up")
        expected_chunk = chunk_buffer[1].chunk_index
      end
      
    else
      -- No chunks ready - wait a bit
      sleep(0.05)
    end
  end
end

-- ==== WATCHDOG ====
local function watchdog()
  while true do
    sleep(10)
    local time_since_heartbeat = os.clock() - last_heartbeat
    
    if time_since_heartbeat > 15 then
      print("Receiver: No heartbeat for", string.format("%.1f", time_since_heartbeat), "seconds")
      print("Receiver: Connection may be lost")
      
      -- Try to rejoin
      safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
        type = "join",
        client_id = my_id,
        client_type = "receiver",
        capabilities = { play = true, control = false, noisy = true },
        volume = local_volume
      })
    end
  end
end

-- ==== MAIN ====
print("Receiver: Starting audio receiver")
print("Receiver: Listening on channel:", RECEIVER_CHANNEL, "(from pacer)")
print("Receiver: Control channel:", CONTROL_CHANNEL)
print("Receiver: Volume:", local_volume)
print("Receiver: Speakers:", #speakers)
print("Receiver: Buffer size:", BUFFER_SIZE, "chunks")

parallel.waitForAny(handleControl, handleAudio, handlePlayback, watchdog)