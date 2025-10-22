-- radioReceiver.lua (FIXED - Simple buffered playback)
-- Receives chunks directly from core with minimal buffering

local RADIO_CHANNEL = 164
local CONTROL_CHANNEL = 165

local modem = peripheral.find("modem")
local decoder = require("cc.audio.dfpwm").make_decoder()
local speakers = { peripheral.find("speaker") }

if not modem then error("Receiver: No modem found! Attach a wireless modem.") end
if #speakers == 0 then error("Receiver: No speakers found! Attach at least one speaker.") end

modem.open(RADIO_CHANNEL)
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
local last_heartbeat = os.clock()
local chunk_queue = {}  -- Queue for received chunks
local playing_chunk = false

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

-- Keep-alive function
local function sendKeepAlive()
  safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
    type = "ping",
    client_id = my_id,
    seq = os.clock(),
    timestamp = os.clock()
  })
end

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
          expected_chunk = msg.chunk_index or 0
          chunk_queue = {}
          
          -- Stop speakers to clear old audio
          for _, s in ipairs(speakers) do
            pcall(s.stop, s)
          end
          
          print("Receiver: Song changed, syncing to chunk", expected_chunk)
        end
        
      elseif msg.type == "set_volume" then
        if msg.force then
          local_volume = msg.volume
          saveConfig()
          print("Receiver: Volume set to", local_volume)
        end
        
      elseif msg.type == "now_playing_update" then
        if msg.now_playing then
          print("Receiver: Now playing:", msg.now_playing.name)
        else
          print("Receiver: Playback stopped")
          chunk_queue = {}
          for _, s in ipairs(speakers) do
            pcall(s.stop, s)
          end
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

-- ==== AUDIO RECEIVE LOOP ====
local function handleReceive()
  while true do
    local ev, side, channel, reply, msg, dist = os.pullEvent("modem_message")
    
    if channel == RADIO_CHANNEL and type(msg) == "table" and msg.type == "audio_chunk" then
      
      -- Handle song changes
      if msg.song_id ~= expected_song then
        print("Receiver: New song detected via chunk")
        expected_song = msg.song_id
        expected_chunk = 0
        chunk_queue = {}
        
        for _, s in ipairs(speakers) do
          pcall(s.stop, s)
        end
      end
      
      -- Add chunk to queue if it's in sequence or ahead
      if msg.chunk_index >= expected_chunk then
        table.insert(chunk_queue, {
          chunk_index = msg.chunk_index,
          data = msg.data,
          volume = msg.volume
        })
        
        -- Sort queue by chunk index
        table.sort(chunk_queue, function(a, b) 
          return a.chunk_index < b.chunk_index 
        end)
        
        -- Limit queue size to prevent memory issues
        while #chunk_queue > 10 do
          table.remove(chunk_queue, 1)
          expected_chunk = expected_chunk + 1
        end
        
        -- Signal playback loop that data is available
        if not playing_chunk then
          os.queueEvent("chunk_ready")
        end
      end
    end
  end
end

-- ==== PLAYBACK LOOP ====
local function handlePlayback()
  while true do
    -- Wait for chunks to be available
    if #chunk_queue == 0 or chunk_queue[1].chunk_index > expected_chunk then
      playing_chunk = false
      os.pullEvent("chunk_ready")
    end
    
    -- Process next chunk in sequence
    if #chunk_queue > 0 and chunk_queue[1].chunk_index == expected_chunk then
      playing_chunk = true
      local chunk = table.remove(chunk_queue, 1)
      
      -- Play on all speakers
      local buffer = chunk.data
      local vol = chunk.volume or local_volume
      
      for _, speaker in ipairs(speakers) do
        local name = peripheral.getName(speaker)
        
        -- Try to play, wait if buffer is full
        while not speaker.playAudio(buffer, vol) do
          local ev, speaker_name = os.pullEvent("speaker_audio_empty")
          if speaker_name == name then
            break
          end
        end
      end
      
      expected_chunk = expected_chunk + 1
      
    elseif #chunk_queue > 0 and chunk_queue[1].chunk_index > expected_chunk then
      -- We're behind - skip ahead to catch up
      local skip_count = chunk_queue[1].chunk_index - expected_chunk
      print("Receiver: Skipping", skip_count, "chunk(s) to catch up")
      expected_chunk = chunk_queue[1].chunk_index
    end
  end
end

-- ==== WATCHDOG ====
local function watchdog()
  local keepalive_interval = 30
  local last_keepalive = os.clock()
  
  while true do
    sleep(5)
    
    -- Send keep-alive ping periodically
    if (os.clock() - last_keepalive) > keepalive_interval then
      sendKeepAlive()
      last_keepalive = os.clock()
    end
    
    local time_since_heartbeat = os.clock() - last_heartbeat
    
    if time_since_heartbeat > 20 then
      print("Receiver: No heartbeat for", string.format("%.1f", time_since_heartbeat), "seconds")
      print("Receiver: Attempting to rejoin...")
      
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
print("Receiver: Radio channel:", RADIO_CHANNEL)
print("Receiver: Control channel:", CONTROL_CHANNEL)
print("Receiver: Volume:", local_volume)
print("Receiver: Speakers:", #speakers)

parallel.waitForAny(handleControl, handleReceive, handlePlayback, watchdog)