-- SquirtleSquad-Miner v1
-- GPSSubhost/startup.lua
-- Lightweight GPS host and heartbeat node. Uses shell.run("gps", "host", x, y, z).

local PROTOCOL = "TurtleTeamNet"
local PROJECT = "SquirtleSquad-Miner"
local VERSION = "v1"
local DATA_DIR = "SquirtleSquadData"
local STATE_FILE = DATA_DIR .. "/gps_subhost_state.dat"

local state = { x=nil, y=nil, z=nil, label=nil, controllerId=nil }
local running = true
local modemSide = nil

local function ensureDir() if not fs.exists(DATA_DIR) then fs.makeDir(DATA_DIR) end end
local function save()
  ensureDir()
  local h=fs.open(STATE_FILE,"w")
  if h then h.write(textutils.serialize(state)); h.close() end
end
local function load()
  if fs.exists(STATE_FILE) then
    local h=fs.open(STATE_FILE,"r")
    if h then
      local txt=h.readAll(); h.close()
      local ok,t=pcall(textutils.unserialize,txt)
      if ok and type(t)=="table" then
        for k,v in pairs(t) do state[k]=v end
      end
    end
  end
end

local function openModem()
  for _,side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side)=="modem" then
      modemSide=side
      if not rednet.isOpen(side) then rednet.open(side) end
      return true
    end
  end
  return false
end

local function center(text,y,col)
  local w,h=term.getSize()
  term.setCursorPos(math.max(1,math.floor((w-#text)/2)+1),y)
  if term.isColor() and col then term.setTextColor(col) end
  term.write(text)
end

local function header()
  if term.isColor() then term.setBackgroundColor(colors.black); term.setTextColor(colors.cyan) end
  term.clear()
  center("🐢 " .. PROJECT .. " " .. VERSION .. " 🐢",1,colors.cyan)
  center("GPS Subhost",2,colors.lightBlue)
  if term.isColor() then term.setTextColor(colors.white) end
  term.setCursorPos(1,4)
end

local function promptNumber(label, default)
  term.write(label .. (default and (" ["..default.."]") or "") .. ": ")
  local s=read()
  if s=="" and default~=nil then return tonumber(default) end
  return tonumber(s)
end

local function setup()
  header()
  print("This host runs: shell.run(\"gps\", \"host\", x, y, z)")
  print("")
  if state.x and state.y and state.z then
    print("Saved coords: "..state.x..","..state.y..","..state.z)
    print("Press Enter to keep, or type reset.")
    term.write("> ")
    local s=read()
    if s~="reset" and s~="RESET" then return end
  end
  state.label = state.label or ("GPS-" .. os.getComputerID())
  term.write("Label ["..state.label.."]: ")
  local l=read()
  if l~="" then state.label=l end
  state.x=promptNumber("X")
  state.y=promptNumber("Y")
  state.z=promptNumber("Z")
  save()
end

local function heartbeatLoop()
  while running do
    if modemSide then
      rednet.broadcast({type="REGISTER",role="gps",label=state.label,x=state.x,y=state.y,z=state.z,project=PROJECT,version=VERSION},PROTOCOL)
      rednet.broadcast({type="HEARTBEAT",role="gps",label=state.label,x=state.x,y=state.y,z=state.z,status="HOSTING"},PROTOCOL)
    end
    sleep(10)
  end
end

local function receiveLoop()
  while running do
    local sender,msg=rednet.receive(PROTOCOL,2)
    if type(msg)=="table" then
      if msg.type=="REGISTER_ACK" then state.controllerId=sender; save()
      elseif msg.type=="ROLL_CALL" then rednet.send(sender,{type="ROLL_CALL_RESPONSE",role="gps",label=state.label,x=state.x,y=state.y,z=state.z},PROTOCOL)
      end
    end
  end
end

local function displayLoop()
  while running do
    header()
    print("Label: "..tostring(state.label))
    print("ID: "..os.getComputerID())
    print("Coords: "..tostring(state.x)..","..tostring(state.y)..","..tostring(state.z))
    print("Modem: "..tostring(modemSide or "missing"))
    print("Controller: "..tostring(state.controllerId or "unknown"))
    print("")
    print("Hosting GPS. Ctrl+T allowed during development.")
    sleep(5)
  end
end

local function gpsHostLoop()
  while running do
    if state.x and state.y and state.z then
      local old = term.current()
      local win = window.create(old,1,1,1,1,false)
      local prior = term.redirect(win)
      pcall(function()
        shell.run("gps","host",tostring(state.x),tostring(state.y),tostring(state.z))
      end)
      term.redirect(prior)
    else
      sleep(2)
    end
  end
end

ensureDir()
load()
openModem()
setup()
save()
parallel.waitForAny(gpsHostLoop, heartbeatLoop, receiveLoop, displayLoop)

