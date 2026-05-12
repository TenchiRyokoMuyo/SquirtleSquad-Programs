-- Foreman Turtle startup.lua
-- TurtleTeamNet v17 full replacement
-- No Ctrl+T lockout. Follows paired miner conservatively and moves aside on request.

local PROTOCOL = "TurtleTeamNet"
local STATE_FILE = "foreman_state.dat"
local ROLE = "foreman"
local ID = os.getComputerID()

local modemSide = nil
local controllerId = nil
local minerTarget = nil
local lastMinerTargetTime = 0

local state = {
  role = ROLE,
  status = "LISTENING",
  job = nil,
  sector = nil,
  gpsStatus = "unknown",
  pos = nil,
  error = nil,
  lastHeartbeat = 0,
  lastControllerSeen = 0,
}

local function save()
  local f = fs.open(STATE_FILE, "w")
  if f then f.write(textutils.serialize(state)); f.close() end
end

local function load()
  if fs.exists(STATE_FILE) then
    local f = fs.open(STATE_FILE, "r")
    if f then
      local s=f.readAll(); f.close()
      local t=textutils.unserialize(s)
      if type(t)=="table" then for k,v in pairs(t) do state[k]=v end end
    end
  end
  state.role = ROLE
  state.status = state.status or "LISTENING"
end

local function findModem()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then return name end
  end
  return nil
end

local function openModem()
  modemSide = findModem()
  if modemSide and not rednet.isOpen(modemSide) then rednet.open(modemSide) end
  return modemSide ~= nil
end

local function gpsTry(timeout)
  local x,y,z = gps.locate(timeout or 1)
  if x then
    state.pos = {x=math.floor(x+0.5), y=math.floor(y+0.5), z=math.floor(z+0.5)}
    state.gpsStatus = "available"
    return state.pos
  end
  state.gpsStatus = "unavailable"
  return nil
end

local function draw(msg)
  term.clear()
  term.setCursorPos(1,1)
  print("Foreman Turtle #"..ID)
  print("Status: "..tostring(state.status))
  print("Controller: "..tostring(controllerId))
  print("GPS: "..tostring(state.gpsStatus))
  if state.job then
    print("Job: "..tostring(state.job.id or state.jobId).." Sector: "..tostring((state.sector and state.sector.id) or state.sectorId))
  end
  if minerTarget and minerTarget.id then print("Following miner: "..tostring(minerTarget.id)) end
  if state.error then print("ERROR: "..tostring(state.error)) end
  if msg then print(msg) end
end

local function send(msg)
  msg.role = msg.role or ROLE
  msg.id = msg.id or ID
  if controllerId then rednet.send(controllerId, msg, PROTOCOL)
  else rednet.broadcast(msg, PROTOCOL) end
end

local function broadcast(msg)
  msg.role = msg.role or ROLE
  msg.id = msg.id or ID
  rednet.broadcast(msg, PROTOCOL)
end

local function register()
  broadcast({
    type="REGISTER",
    role=ROLE,
    id=ID,
    status=state.status,
    gps=gpsTry(1),
    gpsStatus=state.gpsStatus,
    jobId=state.job and state.job.id or state.jobId,
    sectorId=state.sector and state.sector.id or state.sectorId,
  })
end

local function heartbeat()
  send({
    type="HEARTBEAT",
    role=ROLE,
    id=ID,
    status=state.status,
    fuel=turtle.getFuelLevel(),
    gps=gpsTry(0.5),
    gpsStatus=state.gpsStatus,
    jobId=state.job and state.job.id or state.jobId,
    sectorId=state.sector and state.sector.id or state.sectorId,
  })
end

local function assign(msg)
  state.job = msg.job or msg.assignment and msg.assignment.job
  state.sector = msg.sector or msg.assignment and msg.assignment.sector
  state.jobId = state.job and state.job.id or msg.jobId
  state.sectorId = state.sector and state.sector.id or msg.sectorId
  state.status = "WAITING_FOR_MINER"
  state.error = nil
  save()
  send({type="FOREMAN_READY", jobId=state.jobId, sectorId=state.sectorId})
end

local function sameAssignment(msg)
  local jobId = state.jobId or (state.job and state.job.id)
  local sectorId = state.sectorId or (state.sector and state.sector.id)
  return msg.jobId == jobId and msg.sectorId == sectorId
end

local function tryBack()
  return turtle.back()
end

local function trySideStep()
  turtle.turnLeft()
  if turtle.forward() then turtle.turnRight(); return true end
  turtle.turnRight()
  turtle.turnRight()
  if turtle.forward() then turtle.turnLeft(); return true end
  turtle.turnLeft()
  return false
end

local function moveAside()
  state.status = "MOVING_ASIDE"
  draw()
  local ok = false
  if turtle.back() then ok = true
  elseif trySideStep() then ok = true
  elseif turtle.up() then ok = true
  end
  gpsTry(1)
  state.status = "WAITING_FOR_MINER"
  save()
  broadcast({type="FOREMAN_MOVED", id=ID, jobId=state.jobId or (state.job and state.job.id), sectorId=state.sectorId or (state.sector and state.sector.id), ok=ok, pos=state.pos})
  return ok
end

local function followMinerTick()
  if not minerTarget or not minerTarget.pos then return end
  if os.clock() - lastMinerTargetTime > 12 then
    state.status = "WAITING_FOR_MINER"
    return
  end

  local me = gpsTry(0.5)
  if not me then
    state.status = "WAITING_FOR_MINER"
    return
  end

  local dx = minerTarget.pos.x - me.x
  local dy = minerTarget.pos.y - me.y
  local dz = minerTarget.pos.z - me.z
  local dist = math.abs(dx) + math.abs(dy) + math.abs(dz)

  -- close enough, stay put
  if dist <= 3 then
    state.status = "WAITING_FOR_MINER"
    return
  end

  state.status = "FOLLOWING_MINER"
  save()

  -- Very conservative follow: do not path aggressively into miner's work face.
  -- Only move one step every tick, preferring vertical correction or backing/lateral movement.
  if dy > 1 then turtle.up()
  elseif dy < -1 then turtle.down()
  else
    -- If too far, attempt one non-destructive reposition step.
    -- This intentionally does not dig.
    if not turtle.forward() then
      trySideStep()
    end
  end

  gpsTry(1)
  broadcast({type="FOREMAN_READY", id=ID, jobId=state.jobId or (state.job and state.job.id), sectorId=state.sectorId or (state.sector and state.sector.id), status=state.status, pos=state.pos})
end

local function foremanWork()
  while true do
    if state.job then
      if state.status == "ASSIGNED" then
        state.status = "WAITING_FOR_MINER"
        save()
        send({type="FOREMAN_READY", jobId=state.jobId or state.job.id, sectorId=state.sectorId or (state.sector and state.sector.id)})
      elseif state.status == "WAITING_FOR_MINER" or state.status == "FOLLOWING_MINER" then
        followMinerTick()
      end
    end
    sleep(1)
  end
end

local function netLoop()
  register()
  local lastRegister = os.clock()
  while true do
    local sender, msg = rednet.receive(PROTOCOL, 1)
    if type(msg) == "table" then
      if msg.type == "REGISTER_ACK" then
        controllerId = sender
        state.lastControllerSeen = os.clock()
        if state.job then send({type="REQUEST_ASSIGNMENT", role=ROLE, id=ID, jobId=state.jobId, sectorId=state.sectorId}) end
      elseif msg.type == "ROLL_CALL" then
        rednet.send(sender, {type="ROLL_CALL_RESPONSE", role=ROLE, id=ID, status=state.status, fuel=turtle.getFuelLevel(), gps=gpsTry(1), gpsStatus=state.gpsStatus}, PROTOCOL)
      elseif msg.type == "ASSIGN_JOB" or msg.type == "RESTORE_JOB" then
        controllerId = sender
        state.lastControllerSeen = os.clock()
        assign(msg)
      elseif msg.type == "MINER_POSITION" and sameAssignment(msg) then
        minerTarget = msg
        lastMinerTargetTime = os.clock()
      elseif msg.type == "FOREMAN_MOVE_REQUEST" and sameAssignment(msg) then
        moveAside()
      elseif msg.type == "PAUSE_JOB" then
        state.status = "PAUSED"; save()
      elseif msg.type == "RESUME_JOB" then
        if state.job then state.status = "WAITING_FOR_MINER"; save() end
      elseif msg.type == "CANCEL_JOB" then
        state.job=nil; state.sector=nil; state.jobId=nil; state.sectorId=nil; state.status="LISTENING"; state.error=nil; minerTarget=nil; save()
      elseif msg.type == "REQUEST_STATUS" then
        heartbeat()
      end
    end
    if os.clock() - lastRegister > 8 then
      register()
      lastRegister = os.clock()
    end
  end
end

local function heartLoop()
  while true do
    heartbeat()
    draw()
    sleep(5)
  end
end

load()
if not openModem() then
  state.status="ERROR"; state.error="No modem found"; draw()
  while true do sleep(10) end
end
gpsTry(3)
draw("Listening for controller...")
parallel.waitForAny(netLoop, heartLoop, foremanWork)
