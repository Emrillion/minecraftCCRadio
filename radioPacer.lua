-- radioPacer.lua
-- Buffers audio chunks from core and rebroadcasts at proper playback rate
-- This prevents the "fast-forward" issue by throttling chunk distribution

local CORE_CHANNEL = 164  -- Receives from core on this channel
local CONTROL_CHANNEL = 165  -- Control/management channel
local RECEIVER_CHANNEL = 166  -- Rebroadcasts to receivers on this channel

-- PERIPHERALS
local modem = peripheral.find("modem")
if not modem then error("Pacer: No modem attached") end

modem.open(CORE_CHANNEL)
modem.open(CONTROL_CHANNEL)

-- Optional local speaker for monitoring
local speakers = { peripheral.find("speaker") }
local has_local_speaker = (#speakers > 0)

-- Optional monitor for display
local monitor = peripheral.find("monitor")
local has_monitor = (monitor ~= nil)
if has_monitor then
  monitor.setTextScale(0.5)
  monitor.setBackgroundColor(colors.black)
  monitor.clear()
end

-- STATE
local chunk_buffer = {}
local current_song_id = nil
local current_song_name = "(none)"
local playing = false
local buffer_size = 0
local chunks_received = 0
local chunks_sent = 0
local last_chunk_sent = 0

-- CLIENT ID
local function gen_client_id(prefix)
  prefix = prefix or "c"
  return prefix .. "_" .. tostring(math.random(1000,9999)) .. "_" .. tostring(os.time() % 100000)
end

local my_id = gen_client_id("pacer")

-- UTILITIES
local function safeTransmit(channel, reply, message)
  local ok, err = pcall(function()
    modem.transmit(channel, reply, message)
  end)
  if not ok then
    print("Pacer: Transmit error:", err)
    return false
  end
  return true
end

local function clearBuffer()
  chunk_buffer = {}
  buffer_size = 0
  print("Pacer: Buffer cleared")
end

-- MONITOR DISPLAY
local function drawMonitor()
  if not has_monitor then return end
  
  local w, h = monitor.getSize()
  monitor.setBackgroundColor(colors.black)
  monitor.clear()
  
  -- Header
  monitor.setTextColor(colors.yellow)
  monitor.setCursorPos(1, 1)
  local header = "=== AUDIO PACER ==="
  monitor.write(string.rep("=", w))
  monitor.setCursorPos(math.floor((w - #header) / 2) + 1, 1)
  monitor.write(header)
  
  -- Status
  monitor.setCursorPos(2, 3)
  monitor.setTextColor(colors.cyan)
  monitor.write("Status: ")
  if playing then
    monitor.setTextColor(colors.lime)
    monitor.write("PLAYING")
  else
    monitor.setTextColor(colors.orange)
    monitor.write("BUFFERING")
  end
  
  -- Current song
  monitor.setCursorPos(2, 4)
  monitor.setTextColor(colors.cyan)
  monitor.write("Now Playing:")
  monitor.setCursorPos(2, 5)
  monitor.setTextColor(colors.white)
  local song_display = current_song_name
  if #song_display > w - 3 then
    song_display = song_display:sub(1, w - 6) .. "..."
  end
  monitor.write("  " .. song_display)
  
  -- Statistics
  monitor.setCursorPos(2, 7)
  monitor.setTextColor(colors.lightGray)
  monitor.write(string.format("Received: %d chunks", chunks_received))
  
  monitor.setCursorPos(2, 8)
  monitor.write(string.format("Sent: %d chunks", chunks_sent))
  
  monitor.setCursorPos(2, 9)
  monitor.write(string.format("Buffer: %d chunks", buffer_size))
  
  -- Buffer visualization
  monitor.setCursorPos(2, 11)
  monitor.setTextColor(colors.yellow)
  monitor.write("Buffer Contents:")
  
  local max_display = math.min(10, h - 13)
  for i = 1, math.min(max_display, #chunk_buffer) do
    local chunk = chunk_buffer[i]
    monitor.setCursorPos(2, 11 + i)
    
    if i == 1 then
      monitor.setTextColor(colors.lime)
      monitor.write("> ")
    else
      monitor.setTextColor(colors.white)
      monitor.write("  ")
    end
    
    monitor.write(string.format("Chunk #%d", chunk.chunk_index))
    
    -- Show data size
    local size_kb = math.floor(#chunk.data / 1024 * 10) / 10
    monitor.setCursorPos(w - 10, 11 + i)
    monitor.setTextColor(colors.gray)
    monitor.write(string.format("%.1fKB", size_kb))
  end
  
  if #chunk_buffer > max_display then
    monitor.setCursorPos(2, 11 + max_display + 1)
    monitor.setTextColor(colors.gray)
    monitor.write(string.format("  ... and %d more", #chunk_buffer - max_display))
  end
  
  -- Last sent chunk
  monitor.setCursorPos(2, h - 2)
  monitor.setTextColor(colors.cyan)
  monitor.write(string.format("Last sent: Chunk #%d", last_chunk_sent))
  
  -- Footer with timing info
  monitor.setCursorPos(2, h)
  monitor.setTextColor(colors.gray)
  if has_local_speaker then
    monitor.write("Timing: Speaker-based (accurate)")
  else
    monitor.write("Timing: Fixed delay (approx)")
  end
end

-- JOIN NETWORK
print("Pacer: Joining network as", my_id)
safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
  type = "join",
  client_id = my_id,
  client_type = "pacer",
  capabilities = { buffer = true, relay = true }
})

-- RECEIVE CHUNKS FROM CORE
local function receiveLoop()
  while true do
    local ev, side, channel, reply, msg, dist = os.pullEvent("modem_message")
    
    if channel == CORE_CHANNEL and type(msg) == "table" then
      if msg.type == "audio_chunk" then
        -- Check for song change
        if msg.song_id ~= current_song_id then
          print("Pacer: New song detected:", msg.song_id)
          clearBuffer()
          current_song_id = msg.song_id
          chunks_received = 0
          chunks_sent = 0
          last_chunk_sent = 0
        end
        
        -- Buffer the chunk
        table.insert(chunk_buffer, {
          chunk_index = msg.chunk_index,
          data = msg.data,
          volume = msg.volume,
          song_id = msg.song_id,
          seq = msg.seq
        })
        
        buffer_size = #chunk_buffer
        chunks_received = chunks_received + 1
        
        -- Start playing once we have a few chunks buffered
        if not playing and buffer_size >= 3 then
          print("Pacer: Buffer filled, starting playback")
          playing = true
          os.queueEvent("pacer_start_playback")
        end
        
        -- Update display every 5 chunks to reduce overhead
        if has_monitor and (chunks_received % 5 == 0 or buffer_size <= 3) then
          drawMonitor()
        end
        
      end
      
    elseif channel == CONTROL_CHANNEL and type(msg) == "table" then
      if msg.type == "join_ack" and msg.client_id == my_id then
        print("Pacer: Joined network successfully")
        current_song_id = msg.song_id
        if msg.now_playing then
          current_song_name = msg.now_playing.name or "(unknown)"
        end
        drawMonitor()
        
      elseif msg.type == "heartbeat" then
        -- Detect song changes from heartbeat
        if msg.song_id ~= current_song_id then
          print("Pacer: Song change via heartbeat")
          clearBuffer()
          current_song_id = msg.song_id
          playing = false
          chunks_received = 0
          chunks_sent = 0
          last_chunk_sent = 0
          drawMonitor()
        end
        
      elseif msg.type == "now_playing_update" then
        if msg.now_playing then
          print("Pacer: Now playing:", msg.now_playing.name)
          current_song_name = msg.now_playing.name or "(unknown)"
        else
          print("Pacer: Playback stopped")
          clearBuffer()
          playing = false
          current_song_id = nil
          current_song_name = "(none)"
        end
        drawMonitor()
        
      elseif msg.type == "network_shutdown" then
        print("Pacer: Shutdown command received")
        sleep(1)
        os.shutdown()
        
      elseif msg.type == "network_restart" then
        print("Pacer: Restart command received")
        sleep(1)
        os.reboot()
      end
    end
  end
end

-- PLAYBACK LOOP - Sends chunks at proper rate
local function playbackLoop()
  while true do
    if playing and #chunk_buffer > 0 then
      local chunk_data = table.remove(chunk_buffer, 1)
      buffer_size = #chunk_buffer
      
      -- Rebroadcast to receivers on dedicated channel
      safeTransmit(RECEIVER_CHANNEL, RECEIVER_CHANNEL, {
        type = "audio_chunk",
        song_id = chunk_data.song_id,
        chunk_index = chunk_data.chunk_index,
        data = chunk_data.data,
        volume = chunk_data.volume,
        seq = chunk_data.seq
      })
      
      chunks_sent = chunks_sent + 1
      last_chunk_sent = chunk_data.chunk_index
      
      -- Update display after sending
      if has_monitor then
        drawMonitor()
      end
      
      -- Optional: Play locally for monitoring
      if has_local_speaker then
        for _, speaker in ipairs(speakers) do
          pcall(speaker.playAudio, speaker, chunk_data.data, chunk_data.volume)
        end
      end
      
      -- CRITICAL: Wait for audio to play before sending next chunk
      -- Each chunk is ~6KB of DFPWM audio at 48kHz = ~1 second of audio
      -- We wait for speaker_audio_empty to know when to send next chunk
      if has_local_speaker then
        local timeout = os.startTimer(2)
        while true do
          local event, param = os.pullEvent()
          if event == "speaker_audio_empty" then
            os.cancelTimer(timeout)
            break
          elseif event == "timer" and param == timeout then
            -- Timeout fallback - continue anyway
            break
          elseif event == "pacer_stop_playback" then
            os.cancelTimer(timeout)
            return
          end
        end
      else
        -- No local speaker - use fixed delay (less accurate but works)
        -- DFPWM at 48kHz: 6KB = 48000/8 = 6000 samples = 0.125 seconds
        -- 16KB chunk = ~0.33 seconds, but add buffer time
        sleep(0.3)
      end
      
      -- Check if we're running low on buffer AND still receiving
      if buffer_size < 2 and playing then
        -- Check if we've received all chunks (no new chunks for a bit means song is done sending)
        local last_received = chunks_received
        sleep(1)
        
        if last_received == chunks_received and buffer_size == 0 then
          -- No new chunks came in and buffer is empty - song playback complete!
          print("Pacer: Playback complete for song", current_song_id)
          
          -- Notify core that this song finished playing
          safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
            type = "playback_complete",
            song_id = current_song_id,
            chunks_played = chunks_sent,
            client_id = my_id
          })
          
          playing = false
          current_song_id = nil
          current_song_name = "(none)"
          chunks_received = 0
          chunks_sent = 0
          last_chunk_sent = 0
          drawMonitor()
        elseif buffer_size < 2 then
          print("Pacer: Buffer low (" .. buffer_size .. "), waiting for more chunks...")
          playing = false
          drawMonitor()
        end
      end
      
    else
      -- Wait for signal to start playing
      local event = os.pullEvent()
      if event == "pacer_start_playback" then
        playing = true
        drawMonitor()
      end
    end
  end
end

-- STATUS DISPLAY (console)
local function statusLoop()
  while true do
    sleep(5)
    if current_song_id then
      print(string.format("Pacer: Buffer=%d | Rcv=%d | Sent=%d | Playing=%s", 
        buffer_size, chunks_received, chunks_sent, tostring(playing)))
    end
  end
end

-- MAIN
print("Pacer: Starting audio pacer...")
print("Pacer: Core channel:", CORE_CHANNEL)
print("Pacer: Receiver channel:", RECEIVER_CHANNEL)
print("Pacer: Control channel:", CONTROL_CHANNEL)
if has_local_speaker then
  print("Pacer: Local speaker detected - using for timing")
else
  print("Pacer: No local speaker - using fixed timing")
end
if has_monitor then
  print("Pacer: Monitor detected - visual display enabled")
  drawMonitor()
else
  print("Pacer: No monitor - console only")
end

parallel.waitForAny(receiveLoop, playbackLoop, statusLoop)