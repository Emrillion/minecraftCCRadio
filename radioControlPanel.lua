-- networkControlPanel.lua
-- External monitor UI for restarting/shutting down the network + force refresh
-- Self-registers with core and shows core online status

local RADIO_CHANNEL = 164
local CONTROL_CHANNEL = RADIO_CHANNEL + 1

-- ==== PERIPHERALS ====
local modem = peripheral.find("modem")
if not modem then error("No modem attached!") end
modem.open(CONTROL_CHANNEL)

local monitor = peripheral.find("monitor")
if not monitor then error("No monitor attached!") end
monitor.setTextScale(0.5)
monitor.setBackgroundColor(colors.black)
monitor.setTextColor(colors.white)
monitor.clear()

local w, h = monitor.getSize()

-- ==== CLIENT ID ====
local function gen_client_id(prefix)
  prefix = prefix or "c"
  return prefix .. "_" .. tostring(math.random(1000,9999)) .. "_" .. tostring(os.time() % 100000)
end

local my_id = gen_client_id("ctrl")

-- ==== STATE ====
local core_online = false
local status_interval = 3
local status_timer = nil

-- ==== BUTTONS ====
local buttons = {
  restart =  { x = math.floor(w/2) - 12, y = math.floor(h/2) - 5, w = 24, h = 3, label = "RESTART NETWORK", color = colors.green },
  shutdown = { x = math.floor(w/2) - 12, y = math.floor(h/2),     w = 24, h = 3, label = "SHUTDOWN NETWORK", color = colors.red },
  refresh =  { x = math.floor(w/2) - 12, y = math.floor(h/2) + 5, w = 24, h = 3, label = "FORCE REFRESH", color = colors.blue },
}

-- ==== HELPERS ====
local function drawButton(btn, active)
  local bg = active and colors.gray or btn.color
  monitor.setBackgroundColor(bg)
  for y = 0, btn.h - 1 do
    monitor.setCursorPos(btn.x, btn.y + y)
    monitor.write(string.rep(" ", btn.w))
  end
  local labelX = btn.x + math.floor((btn.w - #btn.label) / 2)
  local labelY = btn.y + math.floor(btn.h / 2)
  monitor.setCursorPos(labelX, labelY)
  monitor.setTextColor(colors.white)
  monitor.write(btn.label)
  monitor.setBackgroundColor(colors.black)
end

local function safeTransmit(channel, reply, message)
  local ok, err = pcall(function()
    modem.transmit(channel, reply, message)
  end)
  if not ok then print("Transmit error:", err) end
end

local function announceSelf()
  safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
    type = "join",
    client_id = my_id,
    client_type = "control_panel"
  })
end

local function sendNetworkCommand(cmd)
  safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
    type = "network_command",
    cmd = cmd,
    sender = my_id,
    timestamp = os.clock()
  })
  monitor.setCursorPos(1, h)
  monitor.setBackgroundColor(colors.black)
  monitor.setTextColor(colors.yellow)
  monitor.clearLine()
  monitor.write("Sent: " .. cmd)
  sleep(2)
  monitor.setCursorPos(1, h)
  monitor.clearLine()
  monitor.setTextColor(colors.lightGray)
  monitor.write("Touch a button to send command.")
end

local function requestStatus()
  safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
    type = "status_request",
    client_id = my_id
  })
end

-- ==== DRAWING ====
local function drawUI()
  monitor.setBackgroundColor(colors.black)
  monitor.clear()
  monitor.setTextColor(colors.cyan)
  local title = "=== Network Control Panel ==="
  monitor.setCursorPos(math.floor((w - #title) / 2), 2)
  monitor.write(title)

  -- Status indicator
  monitor.setCursorPos(3, 2)
  if core_online then
    monitor.setBackgroundColor(colors.green)
    monitor.write("   ")
  else
    monitor.setBackgroundColor(colors.red)
    monitor.write("   ")
  end
  monitor.setBackgroundColor(colors.black)
  monitor.setTextColor(colors.white)

  for _, b in pairs(buttons) do
    drawButton(b)
  end

  monitor.setCursorPos(1, h)
  monitor.setTextColor(colors.lightGray)
  monitor.write("Touch a button to send command.")
end

local function inButton(btn, x, y)
  return x >= btn.x and x < btn.x + btn.w and y >= btn.y and y < btn.y + btn.h
end

-- ==== MAIN ====
announceSelf()
drawUI()
status_timer = os.startTimer(status_interval)

while true do
  local event, p1, p2, p3, p4, p5 = os.pullEvent()
  if event == "monitor_touch" then
    local _, side, x, y = event, p1, p2, p3
    for name, btn in pairs(buttons) do
      if inButton(btn, x, y) then
        drawButton(btn, true)
        sleep(0.15)
        drawButton(btn, false)
        if name == "restart" then
          sendNetworkCommand("restart_network")
        elseif name == "shutdown" then
          sendNetworkCommand("shutdown_network")
        elseif name == "refresh" then
          sendNetworkCommand("force_refresh")
        end
      end
    end

  elseif event == "modem_message" then
    local _, side, channel, reply, msg = event, p1, p2, p3, p4
    if channel == CONTROL_CHANNEL and type(msg) == "table" then
      if msg.type == "status_response" then
        core_online = true
        drawUI()
      end
    end

  elseif event == "timer" then
    if p1 == status_timer then
      requestStatus()
      core_online = false
      drawUI()
      status_timer = os.startTimer(status_interval)
    end
  end
end
