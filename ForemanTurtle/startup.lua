-- TurtleTeamNet Foreman Turtle startup.lua v15
-- No Ctrl+T lockout. Listens for miner path-clear requests and moves out of the way.

local PROTOCOL = "TurtleTeamNet"
local STATE_FILE = "foreman_state.dat"
local role = "foreman"
local id = os.getComputerID()

local controllerId = nil
local modemSide = nil
local state = {role=role,status="LISTENING",job=nil,sector=nil,gpsStatus="unknown",lastGPS=nil,error=nil}
local lastMoveAside = nil

local function save()
  local f = fs.open(STATE_FILE,"w")
  if f then f.write(textutils.serialize(state)); f.close() end
end

local function load()
  if fs.exists(STATE_FILE) then
    local f=fs.open(STATE_FILE,"r"); local s=f.readAll(); f.close()
    local t=textutils.unserialize(s)
    if type(t)=="table" then for k,v in pairs(t) do state[k]=v end end
  end
  state.role=role; state.status=state.status or "LISTENING"
end

local function findModem()
  for _,side in ipairs(peripheral.getNames()) do if peripheral.getType(side)=="modem" then return side end end
end

local function gpsTry(timeout)
  local x,y,z=gps.locate(timeout or 2)
  if x then
    state.gpsStatus="ok"
    state.lastGPS={x=math.floor(x+0.5),y=math.floor(y+0.5),z=math.floor(z+0.5)}
    return state.lastGPS
  end
  state.gpsStatus="unavailable"
  return nil
end

local function send(msg)
  if controllerId then rednet.send(controllerId,msg,PROTOCOL) else rednet.broadcast(msg,PROTOCOL) end
end

local function broadcast(msg) rednet.broadcast(msg, PROTOCOL) end

local function status(msg)
  term.clear(); term.setCursorPos(1,1)
  print("Foreman Turtle #"..id)
  print("Status: "..tostring(state.status))
  print("Controller: "..tostring(controllerId))
  print("GPS: "..tostring(state.gpsStatus))
  if state.job then print("Job: "..tostring(state.job.id).." Sector: "..tostring(state.sector and state.sector.id or "?")) end
  if state.error then print("ERROR: "..tostring(state.error)) end
  if msg then print(msg) end
end

local function register()
  send({type="REGISTER",role=role,id=id,status=state.status,gps=gpsTry(1),gpsStatus=state.gpsStatus})
end

local function heartbeat()
  send({type="HEARTBEAT",role=role,id=id,status=state.status,fuel=turtle.getFuelLevel(),gps=state.lastGPS,gpsStatus=state.gpsStatus,jobId=state.job and state.job.id,sectorId=state.sector and state.sector.id})
end

local protectedSubstrings = {"chest","barrel","shulker","drawer","computer","turtle","modem","monitor","disk_drive","spawner"}
local function protected(name)
  if not name then return false end
  for _,s in ipairs(protectedSubstrings) do if name:find(s) then return true end end
  return false
end

local function canMoveForward()
  local ok,d=turtle.inspect()
  if ok and d and protected(d.name) then return false end
  return true
end
local function tryForward()
  if canMoveForward() and turtle.forward() then return true end
  return false
end
local function tryBack()
  if turtle.back() then return true end
  return false
end
local function tryUp()
  local ok,d=turtle.inspectUp(); if ok and d and protected(d.name) then return false end
  return turtle.up()
end
local function tryDown()
  local ok,d=turtle.inspectDown(); if ok and d and protected(d.name) then return false end
  return turtle.down()
end

local function moveAside(req)
  local oldStatus = state.status
  state.status = "CLEARING_MINER_PATH"
  state.error = nil
  save(); status("Miner #"..tostring(req.minerId).." requested clear.")

  -- Prefer backing away because it keeps the foreman near the miner without stepping into the excavation face.
  local moved = false
  if tryBack() then moved=true; lastMoveAside="back"
  else
    turtle.turnLeft()
    if tryForward() then moved=true; lastMoveAside="left"
    else
      turtle.turnRight(); turtle.turnRight()
      if tryForward() then moved=true; lastMoveAside="right"
      else
        turtle.turnLeft()
        if tryUp() then moved=true; lastMoveAside="up"
        elseif tryDown() then moved=true; lastMoveAside="down" end
      end
    end
  end

  if moved then
    state.status = oldStatus == "CLEARING_MINER_PATH" and "WAITING_FOR_MINER" or oldStatus
    save(); status("Moved aside: "..tostring(lastMoveAside))
    local reply = {type="FOREMAN_MOVED", role=role, id=id, minerId=req.minerId, jobId=req.jobId, sectorId=req.sectorId, moved=lastMoveAside}
    broadcast(reply); send(reply)
  else
    state.status = oldStatus
    state.error = "Unable to clear miner path"
    save(); status(state.error)
    local reply = {type="TEAM_ERROR", role=role, id=id, minerId=req.minerId, jobId=req.jobId, sectorId=req.sectorId, error=state.error}
    broadcast(reply); send(reply)
  end
end

local function assign(msg)
  state.job=msg.job; state.sector=msg.sector; state.status="ANCHORING"; state.error=nil; save()
  send({type="FOREMAN_READY",role=role,id=id,jobId=state.job.id,sectorId=state.sector.id})
  sleep(1)
  send({type="CHUNK_ANCHORED",role=role,id=id,jobId=state.job.id,sectorId=state.sector.id})
  state.status="WAITING_FOR_MINER"; save()
end

local function shouldHonorMoveRequest(msg)
  if msg.type ~= "FOREMAN_MOVE_REQUEST" then return false end
  if msg.jobId and state.job and msg.jobId ~= state.job.id then return false end
  if msg.sectorId and state.sector and msg.sectorId ~= state.sector.id then return false end
  -- If this foreman is not assigned yet, still move if it is physically blocking a miner.
  return true
end

local function netLoop()
  register()
  local lastReg=os.clock()
  while true do
    local sender,msg=rednet.receive(PROTOCOL,1)
    if type(msg)=="table" then
      if msg.type=="REGISTER_ACK" then controllerId=sender
      elseif msg.type=="ROLL_CALL" then rednet.send(sender,{type="ROLL_CALL_RESPONSE",role=role,id=id,status=state.status,gps=state.lastGPS,gpsStatus=state.gpsStatus,fuel=turtle.getFuelLevel()},PROTOCOL)
      elseif msg.type=="ASSIGN_JOB" or msg.type=="RESTORE_JOB" then controllerId=sender; assign(msg)
      elseif msg.type=="PAUSE_JOB" then state.status="LISTENING"; save()
      elseif msg.type=="RESUME_JOB" then if state.job then state.status="WAITING_FOR_MINER"; save() end
      elseif msg.type=="CANCEL_JOB" then state={role=role,status="LISTENING",gpsStatus=state.gpsStatus,lastGPS=state.lastGPS}; save()
      elseif msg.type=="MINER_SAFE" then send({type="MINER_SAFE",role=role,id=id,jobId=state.job and state.job.id,sectorId=state.sector and state.sector.id})
      elseif shouldHonorMoveRequest(msg) then moveAside(msg)
      end
    end
    if os.clock()-lastReg>10 then register(); lastReg=os.clock() end
  end
end

local function heartLoop()
  while true do heartbeat(); status(); sleep(5) end
end

load()
modemSide=findModem()
if not modemSide then status("ERROR: No modem. Attach modem and reboot."); return end
rednet.open(modemSide)
gpsTry(5)
parallel.waitForAny(netLoop, heartLoop)
