-- radioSelector.lua
-- UI client: adapt your existing musicBroadcaster UI into a selector that sends commands to core.
-- This script retains the original UI, but sends commands and receives state updates from the core.

-- CONFIG
local RADIO_CHANNEL = 164
local CONTROL_CHANNEL = RADIO_CHANNEL + 1
local modem = peripheral.find("modem")
if not modem then error("Selector: No modem attached") end
modem.open(CONTROL_CHANNEL)

local function gen_client_id(prefix)
  prefix = prefix or "c"
  return prefix .. "_" .. tostring(math.random(1000,9999)) .. "_" .. tostring(os.time() % 100000)
end

local my_id = gen_client_id("sel")
local width, height = term.getSize()
local tab = 1
local waiting_for_input = false

-- UI state mirrored from core
local queue = {}
local now_playing = nil
local server_seq = 0
local last_search = nil
local search_results = nil
local in_search_result = false
local clicked_result = nil
local is_loading = false
local is_error = false

-- Utility helpers (add near the top)
local function safeTransmit(channel, reply, message)
  local ok, err = pcall(function()
    modem.transmit(channel, reply, message)
  end)
  if not ok then
    print("Transmit error:", err)
  end
end

local function gen_client_id(prefix)
  prefix = prefix or "c"
  return prefix .. "_" .. tostring(math.random(1000,9999)) .. "_" .. tostring(os.time() % 100000)
end

-- Minimal API usage: when user searches we still use original http-search (selector can directly hit API)
-- But playback control is sent to core via commands

local function sendCommand(cmd, payload)
  safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, { type = "command", cmd = cmd, payload = payload, client_id = my_id })
end

-- When selector starts, send join so core knows the UI exists (optional)
safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, { type = "join", client_id = my_id, client_type = "selector", capabilities = { control = true }})

-- Simplified: draw small UI that mimics the original; full UI can be ported by copying your existing musicBroadcaster UI functions
local function drawBasicUI()
  term.clear()
  term.setCursorPos(1,1)
  print("Radio Selector - connected as: " .. my_id)
  print("Now Playing: " .. (now_playing and now_playing.name or "(none)"))
  print("Queue:")
  for i=1, math.min(8, #queue) do
    print(i .. ") " .. (queue[i].name or "(item)"))
  end
  print("\nCommands: p=play now, a=add to queue, s=skip, v=force volume, u=status")
end

local function handleInput()
  while true do
    drawBasicUI()
    local e = os.pullEvent()
    if e == "key" then
      local _, code = os.pullEvent("key")
    end
    local event, p1 = os.pullEvent()
    if event == "char" then
      local ch = p1
      if ch == "p" then
        -- quick test: ask for a query then send play_now
        term.write("Enter item id to play now: ")
        local id = read()
        if id and #id > 0 then
          sendCommand("play_now", { id = id, name = id, artist = "(remote)" })
        end
      elseif ch == "a" then
        term.write("Enter item id to add: ")
        local id = read()
        if id and #id > 0 then
          sendCommand("add_to_queue", { id = id, name = id, artist = "(remote)" })
        end
      elseif ch == "s" then
        sendCommand("skip", nil)
      elseif ch == "v" then
        term.write("Force volume (0.0-3.0): ")
        local v = tonumber(read())
        if v then sendCommand("force_set_volume", { volume = v }) end
      elseif ch == "u" then
        sendCommand("request_status", nil)
      end
    elseif event == "modem_message" then
      local _, side, channel, replyChannel, message, distance = os.pullEvent("modem_message")
      -- handle message here later
    end
  end
end

-- Initial status request
sendCommand("request_status", nil)

-- Start a lightweight input loop (UI porting is left for you to replace entire musicBroadcaster UI)
parallel.waitForAny(handleInput)