-- radioSelector.lua (FIXED - Updated for new core commands)
-- UI client: sends commands to core and displays system state

local RADIO_CHANNEL = 164
local CONTROL_CHANNEL = 165

local modem = peripheral.find("modem")
if not modem then error("Selector: No modem attached") end
modem.open(CONTROL_CHANNEL)

-- ==== CLIENT ID ====
local function gen_client_id(prefix)
  prefix = prefix or "c"
  return prefix .. "_" .. tostring(math.random(1000,9999)) .. "_" .. tostring(os.time() % 100000)
end

local my_id = gen_client_id("sel")

-- ==== STATE ====
local width, height = term.getSize()
local queue = {}
local now_playing = nil
local playing = false
local looping = 0
local volume = 1.0
local server_seq = 0
local waiting_for_input = false

-- ==== UTILITIES ====
local function safeTransmit(channel, reply, message)
  local ok, err = pcall(function()
    modem.transmit(channel, reply, message)
  end)
  if not ok then
    print("Selector: Transmit error:", err)
    return false
  end
  return true
end

local function sendCommand(cmd, payload)
  safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
    type = "command",
    cmd = cmd,
    payload = payload,
    client_id = my_id
  })
end

-- ==== UI FUNCTIONS ====
local function clearScreen()
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
end

local function drawHeader()
  term.setBackgroundColor(colors.gray)
  term.setTextColor(colors.white)
  term.setCursorPos(1, 1)
  term.clearLine()
  term.write(" Radio Selector - " .. my_id:sub(1, 15))
  term.setBackgroundColor(colors.black)
end

local function drawNowPlaying()
  term.setCursorPos(1, 3)
  term.setTextColor(colors.yellow)
  term.write("Now Playing:")
  term.setCursorPos(1, 4)
  term.setTextColor(colors.white)
  
  if now_playing then
    local name = now_playing.name or "(unknown)"
    local artist = now_playing.artist or "(unknown)"
    if #name > width - 2 then
      name = name:sub(1, width - 5) .. "..."
    end
    term.write("  " .. name)
    term.setCursorPos(1, 5)
    term.setTextColor(colors.lightGray)
    term.write("  by " .. artist)
  else
    term.setTextColor(colors.gray)
    term.write("  (nothing playing)")
  end
  
  -- Playing status
  term.setCursorPos(1, 6)
  if playing then
    term.setTextColor(colors.lime)
    term.write("  [PLAYING]")
  else
    term.setTextColor(colors.red)
    term.write("  [STOPPED]")
  end
end

local function drawControls()
  term.setCursorPos(1, 8)
  term.setTextColor(colors.cyan)
  term.write("Controls:")
  
  local y = 9
  
  -- Volume slider
  term.setCursorPos(2, y)
  term.setTextColor(colors.white)
  term.write("Volume: ")
  paintutils.drawBox(11, y, 34, y, colors.gray)
  local width_filled = math.floor(24 * (volume / 3) + 0.5) - 1
  if width_filled >= 0 then
    paintutils.drawBox(11, y, 11 + width_filled, y, colors.white)
  end
  term.setCursorPos(36, y)
  term.setTextColor(colors.white)
  term.write(math.floor(100 * (volume / 3) + 0.5) .. "%")
  
  y = y + 1
  
  -- Looping status
  term.setCursorPos(2, y)
  term.setTextColor(colors.white)
  term.write("Looping: ")
  if looping == 0 then
    term.setTextColor(colors.gray)
    term.write("Off")
  elseif looping == 1 then
    term.setTextColor(colors.lime)
    term.write("Queue")
  else
    term.setTextColor(colors.lime)
    term.write("Song")
  end
end

local function drawQueue()
  local start_y = 12
  term.setCursorPos(1, start_y)
  term.setTextColor(colors.cyan)
  term.write("Queue (" .. #queue .. " songs):")
  
  local max_display = math.min(8, height - start_y - 6)
  for i = 1, math.min(max_display, #queue) do
    term.setCursorPos(1, start_y + i)
    term.setTextColor(colors.white)
    local item = queue[i]
    local name = item.name or "(unknown)"
    if #name > width - 5 then
      name = name:sub(1, width - 8) .. "..."
    end
    term.write(string.format(" %2d) %s", i, name))
  end
  
  if #queue > max_display then
    term.setCursorPos(1, start_y + max_display + 1)
    term.setTextColor(colors.gray)
    term.write("  ... and " .. (#queue - max_display) .. " more")
  end
end

local function drawCommands()
  local cmd_y = height - 5
  term.setCursorPos(1, cmd_y)
  term.setTextColor(colors.lime)
  term.write("Commands:")
  
  term.setCursorPos(1, cmd_y + 1)
  term.setTextColor(colors.white)
  term.write("  [P]lay Now  [A]dd Queue  [N]ext  [S]kip")
  
  term.setCursorPos(1, cmd_y + 2)
  term.write("  [Space]Play/Stop  [L]oop  [V]olume")
  
  term.setCursorPos(1, cmd_y + 3)
  term.write("  [U]pdate Status  [Q]uit")
end

local function drawUI()
  clearScreen()
  drawHeader()
  drawNowPlaying()
  drawControls()
  drawQueue()
  drawCommands()
end

local function promptInput(prompt)
  local cmd_y = height - 5
  term.setCursorPos(1, cmd_y)
  term.setTextColor(colors.black)
  term.setBackgroundColor(colors.yellow)
  term.clearLine()
  term.write(" " .. prompt)
  term.setBackgroundColor(colors.black)
  term.setCursorPos(1, cmd_y + 1)
  term.setTextColor(colors.white)
  term.clearLine()
  term.write(" > ")
  
  waiting_for_input = true
  local input = read()
  waiting_for_input = false
  
  return input
end

local function showMessage(msg, color)
  local cmd_y = height - 5
  term.setCursorPos(1, cmd_y)
  term.setTextColor(color or colors.yellow)
  term.setBackgroundColor(colors.black)
  term.clearLine()
  term.write(" " .. msg)
  sleep(1.5)
  drawUI()
end

-- ==== COMMAND HANDLERS ====
local function handlePlayNow()
  local id = promptInput("Enter song ID to play now:")
  if id and #id > 0 then
    sendCommand("play_now", {
      id = id,
      name = id,
      artist = "(manual)",
      volume = 1.0
    })
    showMessage("Sent play_now command", colors.lime)
  else
    drawUI()
  end
end

local function handleAddToQueue()
  local id = promptInput("Enter song ID to add to queue:")
  if id and #id > 0 then
    sendCommand("add_to_queue", {
      id = id,
      name = id,
      artist = "(manual)",
      volume = 1.0
    })
    showMessage("Added to queue", colors.lime)
  else
    drawUI()
  end
end

local function handlePlayNext()
  local id = promptInput("Enter song ID to play next:")
  if id and #id > 0 then
    sendCommand("play_next", {
      id = id,
      name = id,
      artist = "(manual)",
      volume = 1.0
    })
    showMessage("Added to front of queue", colors.lime)
  else
    drawUI()
  end
end

local function handleSkip()
  sendCommand("skip", nil)
  showMessage("Skipped to next song", colors.lime)
end

local function handlePlayStop()
  if playing then
    sendCommand("stop", nil)
    showMessage("Stopping playback", colors.orange)
  else
    sendCommand("play", nil)
    showMessage("Starting playback", colors.lime)
  end
end

local function handleLoop()
  looping = (looping + 1) % 3
  sendCommand("set_looping", { looping = looping })
  
  local msg = "Looping: "
  if looping == 0 then
    msg = msg .. "Off"
  elseif looping == 1 then
    msg = msg .. "Queue"
  else
    msg = msg .. "Song"
  end
  showMessage(msg, colors.cyan)
end

local function handleVolume()
  local vol_str = promptInput("Enter volume (0.0 - 3.0):")
  local vol = tonumber(vol_str)
  if vol and vol >= 0 and vol <= 3 then
    volume = vol
    sendCommand("set_volume", { volume = vol })
    showMessage("Set volume to " .. vol, colors.lime)
  else
    showMessage("Invalid volume", colors.red)
  end
end

local function handleUpdateStatus()
  sendCommand("request_status", nil)
  showMessage("Requesting status update...", colors.cyan)
end

-- ==== EVENT HANDLERS ====
local function handleModemMessage(channel, msg)
  if channel == CONTROL_CHANNEL and type(msg) == "table" then
    if msg.type == "status_response" then
      queue = msg.queue or {}
      now_playing = msg.now_playing or nil
      playing = msg.playing or false
      looping = msg.looping or 0
      volume = msg.volume or 1.0
      server_seq = msg.server_seq or server_seq
      if not waiting_for_input then
        drawUI()
      end
      
    elseif msg.type == "join_ack" and msg.client_id == my_id then
      queue = msg.queue or {}
      now_playing = msg.now_playing or nil
      playing = msg.playing or false
      looping = msg.looping or 0
      volume = msg.volume or 1.0
      print("Selector: Joined network successfully")
      
    elseif msg.type == "now_playing_update" then
      now_playing = msg.now_playing
      if not waiting_for_input then
        drawUI()
      end
      
    elseif msg.type == "queue_update" then
      queue = msg.queue or {}
      if not waiting_for_input then
        drawUI()
      end
      
    elseif msg.type == "heartbeat" then
      playing = msg.playing or false
      
    elseif msg.type == "network_shutdown" then
      clearScreen()
      term.setTextColor(colors.red)
      print("Network shutdown command received.")
      print("Shutting down...")
      sleep(2)
      os.shutdown()
      
    elseif msg.type == "network_restart" then
      clearScreen()
      term.setTextColor(colors.orange)
      print("Network restart command received.")
      print("Rebooting...")
      sleep(2)
      os.reboot()
    end
  end
end

-- ==== MAIN LOOP ====
local function mainLoop()
  while true do
    local event, p1, p2, p3, p4 = os.pullEvent()
    
    if event == "char" and not waiting_for_input then
      local ch = string.lower(p1)
      
      if ch == "p" then
        handlePlayNow()
      elseif ch == "a" then
        handleAddToQueue()
      elseif ch == "n" then
        handlePlayNext()
      elseif ch == "s" then
        handleSkip()
      elseif ch == " " then
        handlePlayStop()
      elseif ch == "l" then
        handleLoop()
      elseif ch == "v" then
        handleVolume()
      elseif ch == "u" then
        handleUpdateStatus()
      elseif ch == "q" then
        clearScreen()
        term.setCursorPos(1, 1)
        print("Selector: Exiting...")
        return
      end
      
    elseif event == "modem_message" then
      local _, side, channel, reply, msg = event, p1, p2, p3, p4
      handleModemMessage(channel, msg)
    end
  end
end

-- ==== STARTUP ====
print("Selector: Starting...")
print("Selector: ID:", my_id)
print("Selector: Joining network...")

-- Join network
safeTransmit(CONTROL_CHANNEL, CONTROL_CHANNEL, {
  type = "join",
  client_id = my_id,
  client_type = "selector",
  capabilities = { control = true, display = true }
})

-- Wait for join acknowledgment
sleep(0.5)

-- Request initial status
sendCommand("request_status", nil)
sleep(0.5)

-- Start UI
drawUI()
mainLoop()

-- Cleanup
clearScreen()
print("Selector: Goodbye!")