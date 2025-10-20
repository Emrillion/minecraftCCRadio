-- radioDashboard.lua
-- Displays radio core status on an external monitor with a cleaner UI.

local RADIO_CHANNEL = 164
local CONTROL_CHANNEL = RADIO_CHANNEL + 1

local modem = peripheral.find("modem")
if not modem then error("Dashboard: No modem attached") end
modem.open(CONTROL_CHANNEL)

local monitor = peripheral.find("monitor")
if not monitor then error("Dashboard: No monitor attached") end

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
    print("Dashboard: Transmit error:", err)
  end
  return ok
end

-- Announce ourselves to core
local function joinNetwork()
  safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
    type = "join",
    client_id = my_id,
    client_type = "dashboard",
    capabilities = { display = true, control = false }
  })
end

-- Request status from the core
local function requestStatus()
  safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
    type = "status_request",
    client_id = my_id
  })
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
    centerText(5, "Waiting for core response...", colors.orange)
    centerText(7, "ID: " .. my_id, colors.gray)
    return
  end

  local y = 3
  mon.setCursorPos(2, y)
  mon.setTextColor(colors.lightBlue)
  mon.write("Connected clients: " .. tostring(#s.clients))
  
  y = y + 1
  mon.setCursorPos(2, y)
  local np_text = "Now playing: " .. (s.now_playing and s.now_playing.name or "(none)")
  if #np_text > select(1, mon.getSize()) - 2 then
    np_text = np_text:sub(1, select(1, mon.getSize()) - 5) .. "..."
  end
  mon.write(np_text)
  
  y = y + 1
  mon.setCursorPos(2, y)
  mon.write("Queue length: " .. tostring(#s.queue))
  
  y = y + 1
  mon.setCursorPos(2, y)
  mon.setTextColor(colors.gray)
  mon.write("Uptime: " .. string.format("%.1fs", s.server_uptime or 0))
  
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
  local max_y = select(2, mon.getSize()) - 1
  for i = 1, #s.clients do
    local c = s.clients[i]
    if y >= max_y then break end
    mon.setCursorPos(2, y)
    mon.write(string.format("%-13s %-8s %-8s %-4s",
      c.client_id:sub(1, 12),
      (c.type or "?"):sub(1, 8),
      tostring(c.latency or "?"),
      tostring(c.volume or "?")))
    y = y + 1
  end
  
  -- Show last update time
  mon.setCursorPos(2, max_y)
  mon.setTextColor(colors.gray)
  mon.write("Last update: " .. os.date("%H:%M:%S"))
end

-- Main loop with proper event handling
local function mainLoop()
  local last_status = nil
  local waiting_for_response = false
  local request_timer = nil
  local last_update_time = os.clock()
  local REFRESH_INTERVAL = 3
  local TIMEOUT = 5
  
  -- Initial join and request
  joinNetwork()
  sleep(0.5)
  requestStatus()
  waiting_for_response = true
  request_timer = os.startTimer(TIMEOUT)
  
  -- Draw initial UI
  drawStatus(nil, last_update_time)
  
  while true do
    local event, p1, p2, p3, p4 = os.pullEvent()
    
    if event == "modem_message" then
      local _, side, channel, reply, msg = event, p1, p2, p3, p4
      
      if channel == CONTROL_CHANNEL and type(msg) == "table" then
        if msg.type == "status_response" then
          last_status = msg
          last_update_time = os.clock()
          waiting_for_response = false
          if request_timer then
            os.cancelTimer(request_timer)
          end
          drawStatus(last_status, last_update_time)
          -- Schedule next refresh
          request_timer = os.startTimer(REFRESH_INTERVAL)
          
        elseif msg.type == "join_ack" and msg.client_id == my_id then
          print("Dashboard: Joined network successfully")
          
        elseif msg.type == "heartbeat" then
          -- Update timestamp without full redraw
          -- (optional: could update a small section of screen)
          
        elseif msg.type == "now_playing_update" then
          -- Update now playing without waiting for full status
          if last_status then
            last_status.now_playing = msg.now_playing
            last_update_time = os.clock()
            drawStatus(last_status, last_update_time)
          end
          
        elseif msg.type == "queue_update" then
          -- Update queue without waiting for full status
          if last_status then
            last_status.queue = msg.queue
            last_update_time = os.clock()
            drawStatus(last_status, last_update_time)
          end
          
        elseif msg.type == "network_shutdown" then
          mon.setBackgroundColor(colors.red)
          mon.clear()
          centerText(math.floor(select(2, mon.getSize()) / 2), "SYSTEM SHUTDOWN", colors.white)
          sleep(2)
          os.shutdown()
          
        elseif msg.type == "network_restart" then
          mon.setBackgroundColor(colors.orange)
          mon.clear()
          centerText(math.floor(select(2, mon.getSize()) / 2), "SYSTEM RESTART", colors.white)
          sleep(2)
          os.reboot()
        end
      end
      
    elseif event == "timer" and p1 == request_timer then
      -- Time to refresh or timeout occurred
      if waiting_for_response then
        -- Timeout - no response received
        print("Dashboard: Status request timeout")
        drawStatus(nil, last_update_time)
        waiting_for_response = false
      end
      
      -- Redraw with updated "seconds ago" even if no new data
      if last_status and not waiting_for_response then
        drawStatus(last_status, last_update_time)
      end
      
      -- Request new status
      requestStatus()
      waiting_for_response = true
      request_timer = os.startTimer(TIMEOUT)
    end
  end
end

-- Start
print("Dashboard: Starting...")
print("Dashboard: ID:", my_id)
mainLoop()