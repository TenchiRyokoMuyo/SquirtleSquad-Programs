-- SquirtleSquad-Miner v1.1
-- GPSSubHost/startup.lua
-- Patch focus:
--   * Saved coordinates auto-load without pressing Enter.
--   * Main controller can send RESET_GPS_COORDS to clear and re-enter coordinates.

local PROTOCOL="TurtleTeamNet"
local PROJECT="SquirtleSquad-Miner"
local VERSION="v1.1"
local DATA_DIR="SquirtleSquadData"
local STATE_FILE=DATA_DIR.."/gps_subhost_state.dat"

local state={role="gps",label="GPSSubHost-"..os.getComputerID(),controllerId=nil,x=nil,y=nil,z=nil,status="BOOTING"}
local modemSide=nil
local running=true

local function ensureDir() if not fs.exists(DATA_DIR) then fs.makeDir(DATA_DIR) end end
local function save() ensureDir(); local h=fs.open(STATE_FILE,"w"); if h then h.write(textutils.serialize(state)); h.close() end end
local function load()
  if fs.exists(STATE_FILE) then
    local h=fs.open(STATE_FILE,"r")
    if h then local txt=h.readAll(); h.close(); local ok,t=pcall(textutils.unserialize,txt); if ok and type(t)=="table" then for k,v in pairs(t) do state[k]=v end end end
  end
end
local function openModem()
  for _,side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side)=="modem" then modemSide=side; if not rednet.isOpen(side) then rednet.open(side) end; return true end
  end
  return false
end
local function send(msg)
  if not modemSide then return end
  msg.project=PROJECT; msg.version=VERSION
  if state.controllerId then rednet.send(state.controllerId,msg,PROTOCOL) else rednet.broadcast(msg,PROTOCOL) end
end
local function status(s) state.status=s; save() end
local function promptNumber(label,default)
  term.write(label..(default~=nil and (" ["..default.."]") or "")..": ")
  local s=read()
  if s=="" and default~=nil then return tonumber(default) end
  return tonumber(s)
end
local function header()
  term.clear(); term.setCursorPos(1,1)
  if term.isColor() then term.setTextColor(colors.cyan) end
  print(" "..PROJECT.." GPS Subhost "..VERSION.." ")
  if term.isColor() then term.setTextColor(colors.white) end
  print("Computer ID: "..os.getComputerID())
  print("Status: "..tostring(state.status))
  print("Coords: "..tostring(state.x)..", "..tostring(state.y)..", "..tostring(state.z))
  print("")
end
local function coordinatesSet() return state.x~=nil and state.y~=nil and state.z~=nil end
local function promptCoordinates()
  status("AWAITING_COORDS")
  while running do
    header()
    print("Enter this GPS subhost's fixed coordinates.")
    print("These will be retained automatically on future boots.")
    print("")
    local x=promptNumber("X",state.x)
    local y=promptNumber("Y",state.y)
    local z=promptNumber("Z",state.z)
    if x and y and z then state.x,state.y,state.z=x,y,z; status("COORDS_SAVED"); save(); return true end
    print("Invalid coordinates. Try again."); sleep(1.5)
  end
  return false
end
local function resetCoordinates()
  state.x,state.y,state.z=nil,nil,nil
  save(); status("COORDS_RESET")
end
local function networkLoop()
  while running do
    local sender,msg,proto=rednet.receive(PROTOCOL,1)
    if type(msg)=="table" then
      if msg.type=="REGISTER_ACK" then state.controllerId=sender; save()
      elseif msg.type=="RESET_GPS_COORDS" then resetCoordinates(); promptCoordinates()
      elseif msg.type=="ROLL_CALL" then send({type="ROLL_CALL_RESPONSE",role="gps",status=state.status,x=state.x,y=state.y,z=state.z}) end
    end
  end
end
local function heartbeatLoop()
  while running do
    send({type="REGISTER",role="gps",label=state.label,status=state.status,x=state.x,y=state.y,z=state.z})
    send({type="HEARTBEAT",role="gps",label=state.label,status=state.status,x=state.x,y=state.y,z=state.z})
    sleep(10)
  end
end
local function gpsHostLoop()
  while running do
    if coordinatesSet() then
      status("HOSTING_GPS")
      local old=term.current(); local win=window.create(old,1,1,1,1,false); local prior=term.redirect(win)
      pcall(function() shell.run("gps","host",tostring(state.x),tostring(state.y),tostring(state.z)) end)
      term.redirect(prior)
      sleep(1)
    else
      promptCoordinates()
    end
  end
end
local function displayLoop() while running do header(); sleep(2) end end

ensureDir(); load(); openModem(); save()
if not coordinatesSet() then promptCoordinates() else status("HOSTING_GPS") end
parallel.waitForAny(networkLoop,heartbeatLoop,gpsHostLoop,displayLoop)
