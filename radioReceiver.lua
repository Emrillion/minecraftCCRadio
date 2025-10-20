-- radioReceiver.lua (updated)
-- Sync-aware receiver that defers to core for authoritative state. Keeps local volume and optional acceptance of forced volume.

local RADIO_CHANNEL = 164
local CONTROL_CHANNEL = RADIO_CHANNEL + 1
local modem = peripheral.find("modem")
local decoder = require("cc.audio.dfpwm").make_decoder()
local speakers = { peripheral.find("speaker") }
if not modem then error("Receiver: No modem found! Attach a wireless modem.") end
if #speakers == 0 then error("Receiver: No speakers found! Attach at least one speaker.") end

modem.open(RADIO_CHANNEL)
modem.open(CONTROL_CHANNEL)

local function gen_client_id(prefix)
  prefix = prefix or "c"
  return prefix .. "_" .. tostring(math.random(1000,9999)) .. "_" .. tostring(os.time() % 100000)
end

local my_id = gen_client_id("rx")
local expected_song = nil
local expected_chunk = 0
local local_volume = 1.0
local accept_global_force = true

-- Utility helpers (add near the top)
local function safeTransmit(channel, reply, message)
  local ok, err = pcall(function()
    modem.transmit(channel, reply, message)
  end)
  if not ok then
    print("Transmit error:", err)
  end
end

-- persist volume (optional)
local function saveConfig()
  local ok, err = pcall(function()
    local f = fs.open("radio_config.txt", "w")
    f.write(textutils.serialize({ volume = local_volume }))
    f.close()
  end)
end
local function loadConfig()
  if fs.exists("radio_config.txt") then
    local f = fs.open("radio_config.txt", "r")
    local raw = f.readAll(); f.close()
    local t = textutils.unserialize(raw)
    if t and t.volume then local_volume = t.volume end
  end
end
loadConfig()

-- join
safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, { type = "join", client_id = my_id, client_type = "receiver", capabilities = { play = true, control = false, noisy = true }, volume = local_volume })

local function handleControl()
  while true do
    local ev, side, channel, reply, msg, dist = os.pullEvent("modem_message")
    if channel == CONTROL_CHANNEL and type(msg) == "table" then
      if msg.type == "join_ack" and msg.client_id == my_id then
        expected_song = msg.song_id
        expected_chunk = msg.next_chunk_index or 0
        print("Receiver: join ack, will start at chunk", expected_chunk)
      elseif msg.type == "heartbeat" then
        if msg.song_id ~= expected_song then
          expected_song = msg.song_id
          expected_chunk = msg.chunk_index
          -- stop local playback to avoid mismatch
          for _, s in ipairs(speakers) do pcall(s.stop, s) end
          print("Receiver: heartbeat - song changed, now expecting chunk", expected_chunk)
        end
      elseif msg.type == "set_volume" then
        if msg.force or accept_global_force then
          local_volume = msg.volume
          saveConfig()
        end
      elseif msg.type == "resync_response" and msg.client_id == my_id then
        expected_song = msg.song_id
        expected_chunk = msg.next_chunk_index
      end
    end
  end
end

local function handleAudio()
  while true do
    local ev, side, channel, reply, msg, dist = os.pullEvent("modem_message")
    if channel == RADIO_CHANNEL and type(msg) == "table" and msg.type == "audio_chunk" then
      if msg.song_id == expected_song and msg.chunk_index == expected_chunk then
        expected_chunk = expected_chunk + 1
        local buffer = msg.data
        for _, speaker in ipairs(speakers) do
          while not speaker.playAudio(buffer, local_volume) do
            os.pullEvent("speaker_audio_empty")
          end
        end
      else
        -- missed chunks? request resync but don't play out-of-order
        if msg.song_id == expected_song and msg.chunk_index > expected_chunk then
          safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, { type = "resync_request", client_id = my_id, missing_from = expected_chunk })
        elseif msg.song_id ~= expected_song and msg.chunk_index == 0 then
          -- server started a new song, we can jump to it on chunk 0
          expected_song = msg.song_id
          expected_chunk = 1
          local buffer = msg.data
          for _, speaker in ipairs(speakers) do
            while not speaker.playAudio(buffer, local_volume) do
              os.pullEvent("speaker_audio_empty")
            end
          end
        end
      end
    end
  end
end

parallel.waitForAny(handleControl, handleAudio)