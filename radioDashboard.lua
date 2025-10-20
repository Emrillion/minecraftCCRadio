-- radioDashboard.lua
-- Displays radio core status on an external monitor with a cleaner UI.

local RADIO_CHANNEL = 164
local CONTROL_CHANNEL = RADIO_CHANNEL + 1

local modem = peripheral.find("modem")
if not modem then error("Dashboard: No modem attached") end
modem.open(CONTROL_CHANNEL)

local monitor = peripheral.find("monitor")
if not monitor then error("Dashboard: No monitor attached") end

-- Set monitor text scale for readability
monitor.setTextScale(0.5)
local mon = monitor

-- Generate unique client ID
local function gen_client_id(prefix)
  prefix = prefix or "c"
  return prefix .. "_" .. tostring(math.random(1000,9999)) .. "_" .. tostring(os.time() % 100000)
end
local my_id = gen_client_id("dash")

-- Utility: safe transmit
local function safeTransmit(channel, reply, message)
  local ok, err = pcall(function()
    modem.transmit(channel, reply, message)
  end)
  if not ok then
    print("Transmit error:", err)
  end
end

-- Request status from the core
local function requestStatus()
  safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, { type = "status_request", client_id = my_id })
  local timeout = os.startTimer(2)
  while true do
    local ev, side, channel, reply, msg = os.pullEvent()
    if ev == "modem_message" and channel == CONTROL_CHANNEL and type(msg) == "table" then
      if msg.type == "status_response" then
        return msg
      elseif msg.type == "network_shutdown" then
        print("Core requested shutdown. Shutting down...")
        os.shutdown()
      elseif msg.type == "network_restart" then
        print("Core requested restart. Rebooting...")
        os.reboot()
      end
    elseif ev == "timer" and reply == timeout then
      return nil, "timeout"
    end
  end
end

-- Utility: pretty centered print
local function centerText(y, text, color)
  local w, h = mon.getSize()
  local x = math.floor((w - #text) / 2) + 1
  if color then mon.setTextColor(color) end
  mon.setCursorPos(x, y)
  mon.write(text)
end

-- Draw a bordered box
local function drawBox(title)
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.white)
  mon.clear()
  local w, h = mon.getSize()
  local line = string.rep("-", w)
  mon.setCursorPos(1, 1)
  mon.write(line)
  centerText(1, title, colors.yellow)
  mon.setCursorPos(1, h)
  mon.write(line)
end

-- Draw the radio status
local function drawStatus(s)
  drawBox(" RADIO DASHBOARD ")
  if not s then
    centerText(5, "No response from core", colors.red)
    return
  end

  local y = 3
  mon.setCursorPos(2, y)
  mon.setTextColor(colors.lightBlue)
  mon.write("Connected clients: " .. tostring(#s.clients))
  y = y + 1
  mon.setCursorPos(2, y)
  mon.write("Now playing: " .. (s.now_playing and s.now_playing.name or "(none)"))
  y = y + 1
  mon.setCursorPos(2, y)
  mon.write("Queue length: " .. tostring(#s.queue))
  y = y + 2

  mon.setTextColor(colors.orange)
  mon.setCursorPos(2, y)
  mon.write("CLIENT ID      TYPE     LAT(ms)  VOL")
  y = y + 1
  mon.setTextColor(colors.gray)
  mon.setCursorPos(2, y)
  mon.write(string.rep("-", 40))
  y = y + 1

  mon.setTextColor(colors.white)
  for i = 1, #s.clients do
    local c = s.clients[i]
    if y >= select(2, mon.getSize()) - 1 then break end -- prevent overflow
    mon.setCursorPos(2, y)
    mon.write(string.format("%-13s %-8s %-8s %-4s",
      c.client_id:sub(1, 12),
      c.type or "?",
      tostring(c.latency or "?"),
      tostring(c.volume or "?")))
    y = y + 1
  end
end

-- Main loop
while true do
  local status, err = requestStatus()
  drawStatus(status)
  sleep(2)
end