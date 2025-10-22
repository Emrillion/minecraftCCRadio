-- radioSelectorGUI.lua
-- Full GUI selector with search functionality (like original musicBroadcaster)

local CONTROL_CHANNEL = 165
local api_base_url = "https://ipod-2to6magyna-uc.a.run.app/"
local version = "2.1"

local width, height = term.getSize()
local tab = 1  -- 1=Now Playing, 2=Search

local waiting_for_input = false
local last_search = nil
local last_search_url = nil
local search_results = nil
local search_error = false
local in_search_result = false
local clicked_result = nil

local playing = false
local queue = {}
local now_playing = nil
local looping = 0
local volume = 1.5

local modem = peripheral.find("modem")
if not modem then error("Selector: No modem attached") end
modem.open(CONTROL_CHANNEL)

-- ==== CLIENT ID ====
local function gen_client_id(prefix)
  prefix = prefix or "c"
  return prefix .. "_" .. tostring(math.random(1000,9999)) .. "_" .. tostring(os.clock() % 100000)
end

local my_id = gen_client_id("sel")

-- ==== NETWORK ====
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

-- ==== UI DRAWING ====
function redrawScreen()
  if waiting_for_input then
    return
  end

  term.setCursorBlink(false)
  term.setBackgroundColor(colors.black)
  term.clear()

  -- Draw the tabs
  term.setCursorPos(1,1)
  term.setBackgroundColor(colors.gray)
  term.clearLine()
  
  local tabs = {" Now Playing ", " Search "}
  
  for i=1,#tabs,1 do
    if tab == i then
      term.setTextColor(colors.black)
      term.setBackgroundColor(colors.white)
    else
      term.setTextColor(colors.white)
      term.setBackgroundColor(colors.gray)
    end
    
    term.setCursorPos((math.floor((width/#tabs)*(i-0.5)))-math.ceil(#tabs[i]/2)+1, 1)
    term.write(tabs[i])
  end

  if tab == 1 then
    drawNowPlaying()
  elseif tab == 2 then
    drawSearch()
  end
end

function drawNowPlaying()
  if now_playing ~= nil then
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.setCursorPos(2,3)
    term.write(now_playing.name)
    term.setTextColor(colors.lightGray)
    term.setCursorPos(2,4)
    term.write(now_playing.artist)
  else
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.setCursorPos(2,3)
    term.write("Not playing")
  end

  -- Status indicator
  term.setTextColor(colors.gray)
  term.setBackgroundColor(colors.black)
  term.setCursorPos(2,5)
  if playing then
    term.setTextColor(colors.lime)
    term.write("[PLAYING]")
  else
    term.setTextColor(colors.red)
    term.write("[STOPPED]")
  end

  -- Buttons
  term.setTextColor(colors.white)
  term.setBackgroundColor(colors.gray)

  if playing then
    term.setCursorPos(2, 6)
    term.write(" Stop ")
  else
    if now_playing ~= nil or #queue > 0 then
      term.setTextColor(colors.white)
      term.setBackgroundColor(colors.gray)
    else
      term.setTextColor(colors.lightGray)
      term.setBackgroundColor(colors.gray)
    end
    term.setCursorPos(2, 6)
    term.write(" Play ")
  end

  if now_playing ~= nil or #queue > 0 then
    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.gray)
  else
    term.setTextColor(colors.lightGray)
    term.setBackgroundColor(colors.gray)
  end
  term.setCursorPos(2 + 7, 6)
  term.write(" Skip ")

  if looping ~= 0 then
    term.setTextColor(colors.black)
    term.setBackgroundColor(colors.white)
  else
    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.gray)
  end
  term.setCursorPos(2 + 7 + 7, 6)
  if looping == 0 then
    term.write(" Loop Off ")
  elseif looping == 1 then
    term.write(" Loop Queue ")
  else
    term.write(" Loop Song ")
  end

  -- Volume slider
  term.setCursorPos(2,8)
  paintutils.drawBox(2,8,25,8,colors.gray)
  local vol_width = math.floor(24 * (volume / 3) + 0.5)-1
  if not (vol_width == -1) then
    paintutils.drawBox(2,8,2+vol_width,8,colors.white)
  end
  if volume < 0.6 then
    term.setCursorPos(2+vol_width+2,8)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
  else
    term.setCursorPos(2+vol_width-3-(volume == 3 and 1 or 0),8)
    term.setBackgroundColor(colors.white)
    term.setTextColor(colors.black)
  end
  term.write(math.floor(100 * (volume / 3) + 0.5) .. "%")

  -- Queue
  if #queue > 0 then
    term.setBackgroundColor(colors.black)
    for i=1,math.min(#queue, 5) do
      term.setTextColor(colors.white)
      term.setCursorPos(2,10 + (i-1)*2)
      term.write(queue[i].name)
      term.setTextColor(colors.lightGray)
      term.setCursorPos(2,11 + (i-1)*2)
      term.write(queue[i].artist)
    end
  end
end

function drawSearch()
  -- Search bar
  paintutils.drawFilledBox(2,3,width-1,5,colors.lightGray)
  term.setBackgroundColor(colors.lightGray)
  term.setCursorPos(3,4)
  term.setTextColor(colors.black)
  term.write(last_search or "Search...")

  -- Search results
  if search_results ~= nil then
    term.setBackgroundColor(colors.black)
    for i=1,math.min(#search_results, 5) do
      term.setTextColor(colors.white)
      term.setCursorPos(2,7 + (i-1)*2)
      term.write(search_results[i].name)
      term.setTextColor(colors.lightGray)
      term.setCursorPos(2,8 + (i-1)*2)
      term.write(search_results[i].artist)
    end
  else
    term.setCursorPos(2,7)
    term.setBackgroundColor(colors.black)
    if search_error == true then
      term.setTextColor(colors.red)
      term.write("Network error")
    elseif last_search_url ~= nil then
      term.setTextColor(colors.lightGray)
      term.write("Searching...")
    else
      term.setCursorPos(1,7)
      term.setTextColor(colors.lightGray)
      print("Tip: You can paste YouTube video or playlist links.")
    end
  end

  -- Fullscreen song options
  if in_search_result == true then
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(2,2)
    term.setTextColor(colors.white)
    term.write(search_results[clicked_result].name)
    term.setCursorPos(2,3)
    term.setTextColor(colors.lightGray)
    term.write(search_results[clicked_result].artist)

    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)

    term.setCursorPos(2,6)
    term.clearLine()
    term.write("Play now")

    term.setCursorPos(2,8)
    term.clearLine()
    term.write("Play next")

    term.setCursorPos(2,10)
    term.clearLine()
    term.write("Add to queue")

    term.setCursorPos(2,13)
    term.clearLine()
    term.write("Cancel")
  end
end

-- ==== UI LOOP ====
function uiLoop()
  redrawScreen()

  while true do
    if waiting_for_input then
      parallel.waitForAny(
        function()
          term.setCursorPos(3,4)
          term.setBackgroundColor(colors.white)
          term.setTextColor(colors.black)
          local input = read()

          if string.len(input) > 0 then
            last_search = input
            last_search_url = api_base_url .. "?v=" .. version .. "&search=" .. textutils.urlEncode(input)
            http.request(last_search_url)
            search_results = nil
            search_error = false
          else
            last_search = nil
            last_search_url = nil
            search_results = nil
            search_error = false
          end

          waiting_for_input = false
          os.queueEvent("redraw_screen")
        end,
        function()
          while waiting_for_input do
            local event, button, x, y = os.pullEvent("mouse_click")
            if y < 3 or y > 5 or x < 2 or x > width-1 then
              waiting_for_input = false
              os.queueEvent("redraw_screen")
              break
            end
          end
        end
      )
    else
      parallel.waitForAny(
        function()
          local event, button, x, y = os.pullEvent("mouse_click")

          if button == 1 then
            -- Tabs
            if in_search_result == false then
              if y == 1 then
                if x < width/2 then
                  tab = 1
                else
                  tab = 2
                end
                redrawScreen()
              end
            end
            
            if tab == 2 and in_search_result == false then
              -- Search box click
              if y >= 3 and y <= 5 and x >= 1 and x <= width-1 then
                paintutils.drawFilledBox(2,3,width-1,5,colors.white)
                term.setBackgroundColor(colors.white)
                waiting_for_input = true
              end
  
              -- Search result click
              if search_results then
                for i=1,math.min(#search_results, 5) do
                  if y == 7 + (i-1)*2 or y == 8 + (i-1)*2 then
                    term.setBackgroundColor(colors.white)
                    term.setTextColor(colors.black)
                    term.setCursorPos(2,7 + (i-1)*2)
                    term.clearLine()
                    term.write(search_results[i].name)
                    term.setTextColor(colors.gray)
                    term.setCursorPos(2,8 + (i-1)*2)
                    term.clearLine()
                    term.write(search_results[i].artist)
                    sleep(0.2)
                    in_search_result = true
                    clicked_result = i
                    redrawScreen()
                  end
                end
              end
            elseif tab == 2 and in_search_result == true then
              -- Search result menu clicks
  
              term.setBackgroundColor(colors.white)
              term.setTextColor(colors.black)
  
              if y == 6 then
                term.setCursorPos(2,6)
                term.clearLine()
                term.write("Play now")
                sleep(0.2)
                in_search_result = false
                
                if search_results[clicked_result].type == "playlist" then
                  sendCommand("play_now", search_results[clicked_result])
                else
                  sendCommand("play_now", search_results[clicked_result])
                end
                os.queueEvent("audio_update")
              end
  
              if y == 8 then
                term.setCursorPos(2,8)
                term.clearLine()
                term.write("Play next")
                sleep(0.2)
                in_search_result = false
                
                sendCommand("play_next", search_results[clicked_result])
                os.queueEvent("audio_update")
              end
  
              if y == 10 then
                term.setCursorPos(2,10)
                term.clearLine()
                term.write("Add to queue")
                sleep(0.2)
                in_search_result = false
                
                sendCommand("add_to_queue", search_results[clicked_result])
                os.queueEvent("audio_update")
              end
  
              if y == 13 then
                term.setCursorPos(2,13)
                term.clearLine()
                term.write("Cancel")
                sleep(0.2)
                in_search_result = false
              end
  
              redrawScreen()
            elseif tab == 1 and in_search_result == false then
              -- Now playing tab clicks
  
              if y == 6 then
                -- Play/stop button
                if x >= 2 and x < 2 + 6 then
                  if playing or now_playing ~= nil or #queue > 0 then
                    term.setBackgroundColor(colors.white)
                    term.setTextColor(colors.black)
                    term.setCursorPos(2, 6)
                    if playing then
                      term.write(" Stop ")
                    else 
                      term.write(" Play ")
                    end
                    sleep(0.2)
                  end
                  if playing then
                    sendCommand("stop", nil)
                    os.queueEvent("audio_update")
                  elseif now_playing ~= nil then
                    sendCommand("play", nil)
                    os.queueEvent("audio_update")
                  elseif #queue > 0 then
                    sendCommand("play", nil)
                    os.queueEvent("audio_update")
                  end
                end
  
                -- Skip button
                if x >= 2 + 7 and x < 2 + 7 + 6 then
                  if now_playing ~= nil or #queue > 0 then
                    term.setBackgroundColor(colors.white)
                    term.setTextColor(colors.black)
                    term.setCursorPos(2 + 7, 6)
                    term.write(" Skip ")
                    sleep(0.2)
  
                    sendCommand("skip", nil)
                    os.queueEvent("audio_update")
                  end
                end
  
                -- Loop button
                if x >= 2 + 7 + 7 and x < 2 + 7 + 7 + 12 then
                  looping = (looping + 1) % 3
                  sendCommand("set_looping", { looping = looping })
                end
              end

              if y == 8 then
                -- Volume slider
                if x >= 1 and x < 2 + 24 then
                  volume = (x - 1) / 24 * 3
                  sendCommand("set_volume", { volume = volume })
                end
              end

              redrawScreen()
            end
          end
        end,
        function()
          local event, button, x, y = os.pullEvent("mouse_drag")

          if button == 1 then
            if tab == 1 and in_search_result == false then
              if y >= 7 and y <= 9 then
                -- Volume slider
                if x >= 1 and x < 2 + 24 then
                  volume = (x - 1) / 24 * 3
                  sendCommand("set_volume", { volume = volume })
                end
              end

              redrawScreen()
            end
          end
        end,
        function()
          local event = os.pullEvent("redraw_screen")
          redrawScreen()
        end
      )
    end
  end
end

-- ==== HTTP LOOP ====
function httpLoop()
  while true do
    parallel.waitForAny(
      function()
        local event, url, handle = os.pullEvent("http_success")

        if url == last_search_url then
          search_results = textutils.unserialiseJSON(handle.readAll())
          os.queueEvent("redraw_screen")
        end
      end,
      function()
        local event, url = os.pullEvent("http_failure")	

        if url == last_search_url then
          search_error = true
          os.queueEvent("redraw_screen")
        end
      end
    )
  end
end

-- ==== MODEM LOOP ====
function modemLoop()
  while true do
    local event, side, channel, reply, msg = os.pullEvent("modem_message")
    
    if channel == CONTROL_CHANNEL and type(msg) == "table" then
      if msg.type == "status_response" then
        queue = msg.queue or {}
        now_playing = msg.now_playing or nil
        playing = msg.playing or false
        looping = msg.looping or 0
        volume = msg.volume or 1.0
        if not waiting_for_input then
          os.queueEvent("redraw_screen")
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
          os.queueEvent("redraw_screen")
        end
        
      elseif msg.type == "queue_update" then
        queue = msg.queue or {}
        if not waiting_for_input then
          os.queueEvent("redraw_screen")
        end
        
      elseif msg.type == "heartbeat" then
        playing = msg.playing or false
        
      elseif msg.type == "network_shutdown" then
        term.setBackgroundColor(colors.black)
        term.clear()
        term.setCursorPos(1,1)
        term.setTextColor(colors.red)
        print("Network shutdown command received.")
        print("Shutting down...")
        sleep(2)
        os.shutdown()
        
      elseif msg.type == "network_restart" then
        term.setBackgroundColor(colors.black)
        term.clear()
        term.setCursorPos(1,1)
        term.setTextColor(colors.orange)
        print("Network restart command received.")
        print("Rebooting...")
        sleep(2)
        os.reboot()
      end
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

-- Start loops
parallel.waitForAny(uiLoop, httpLoop, modemLoop)