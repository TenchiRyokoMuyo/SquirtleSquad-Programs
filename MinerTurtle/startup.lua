-- Miner Turtle startup.lua
-- TurtleTeamNet v17 full replacement
-- No Ctrl+T lockout. Designed for development/testing.

local PROTOCOL = "TurtleTeamNet"
local STATE_FILE = "miner_state.dat"
local ROLE = "miner"
local ID = os.getComputerID()

local modemSide = nil
local controllerId = nil

local state = {
  role = ROLE,
  status = "LISTENING",
  job = nil,
  sector = nil,
  currentIndex = 1,
  progress = 0,
  pos = nil,
  facing = nil,
  gpsStatus = "unknown",
  error = nil,
  lastHeartbeat = 0,
  lastControllerSeen = 0,
}

local function shallowCopy(t)
  local out = {}
  if type(t) ~= "table" then return out end
  for k,v in pairs(t) do out[k] = v end
  return out
end

local function save()
  local f = fs.open(STATE_FILE, "w")
  if f then
    f.write(textutils.serialize(state))
    f.close()
  end
end

local function load()
  if fs.exists(STATE_FILE) then
    local f = fs.open(STATE_FILE, "r")
    if f then
      local s = f.readAll()
      f.close()
      local t = textutils.unserialize(s)
      if type(t) == "table" then
        for k,v in pairs(t) do state[k] = v end
      end
    end
  end
  state.role = ROLE
  state.status = state.status or "LISTENING"
  state.currentIndex = state.currentIndex or 1
  state.progress = state.progress or 0
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
    state.pos = { x = math.floor(x + 0.5), y = math.floor(y + 0.5), z = math.floor(z + 0.5) }
    state.gpsStatus = "available"
    return state.pos
  end
  state.gpsStatus = "unavailable"
  return nil
end

local function draw(msg)
  term.clear()
  term.setCursorPos(1,1)
  print("Miner Turtle #"..ID)
  print("Status: "..tostring(state.status))
  print("Controller: "..tostring(controllerId))
  print("GPS: "..tostring(state.gpsStatus))
  if state.job then
    local jid = state.job.id or state.jobId or "?"
    local sid = state.sector and state.sector.id or state.sectorId or "?"
    print("Job: "..tostring(jid).." Sector: "..tostring(sid))
    print("Index: "..tostring(state.currentIndex).." Progress: "..tostring(math.floor((state.progress or 0) * 100)).."%")
  end
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
    type = "REGISTER",
    role = ROLE,
    id = ID,
    status = state.status,
    gps = gpsTry(1),
    gpsStatus = state.gpsStatus,
    jobId = state.job and state.job.id or state.jobId,
    sectorId = state.sector and state.sector.id or state.sectorId,
  })
end

local function broadcastMinerPosition()
  gpsTry(0.5)
  broadcast({
    type = "MINER_POSITION",
    role = ROLE,
    id = ID,
    jobId = state.job and state.job.id or state.jobId,
    sectorId = state.sector and state.sector.id or state.sectorId,
    status = state.status,
    pos = state.pos,
    facing = state.facing,
    currentIndex = state.currentIndex,
    progress = state.progress,
  })
end

local function heartbeat()
  send({
    type = "HEARTBEAT",
    role = ROLE,
    id = ID,
    status = state.status,
    fuel = turtle.getFuelLevel(),
    gps = gpsTry(0.5),
    gpsStatus = state.gpsStatus,
    jobId = state.job and state.job.id or state.jobId,
    sectorId = state.sector and state.sector.id or state.sectorId,
    currentIndex = state.currentIndex,
    progress = state.progress,
  })
  broadcastMinerPosition()
end

local function itemName(slot)
  local d = turtle.getItemDetail(slot)
  return d and d.name or nil
end

local function isFuelName(name)
  if not name then return false end
  return name:find("coal") or name:find("charcoal") or name:find("lava_bucket") or name:find("blaze_rod")
end

local function isTorchName(name)
  if not name then return false end
  return name == "minecraft:torch" or name:find(":torch") ~= nil
end

local function isLikelyFiller(name)
  if not name then return false end
  if isFuelName(name) or isTorchName(name) then return false end
  if name:find("chest") or name:find("barrel") or name:find("shulker") then return false end
  if name:find("modem") or name:find("computer") or name:find("turtle") then return false end
  return true
end

local function moveSlotTo(from, to)
  if from == to or turtle.getItemCount(from) == 0 then return true end
  turtle.select(from)
  if turtle.getItemCount(to) == 0 then
    return turtle.transferTo(to)
  end
  return false
end

local function organizeInventory()
  for i=1,16 do
    local n = itemName(i)
    if isFuelName(n) and i ~= 1 and turtle.getItemCount(1) == 0 then moveSlotTo(i,1) end
  end
  for i=1,16 do
    local n = itemName(i)
    if isLikelyFiller(n) and i ~= 2 and turtle.getItemCount(2) == 0 then moveSlotTo(i,2) end
  end
  for i=1,16 do
    local n = itemName(i)
    if isTorchName(n) and i ~= 16 and turtle.getItemCount(16) == 0 then moveSlotTo(i,16) end
  end
  turtle.select(1)
  if turtle.getItemCount(1) > 0 and turtle.getFuelLevel() < 500 then turtle.refuel(1) end
end

local protectedSubstrings = {
  "chest","barrel","shulker","drawer","crate","storage",
  "computer","turtle","modem","monitor","disk_drive","display_link",
  "scaffold","scaffolding","spawner"
}

local function isProtected(name)
  if not name then return false end
  for _, s in ipairs(protectedSubstrings) do
    if name:find(s) then return true end
  end
  return false
end

local function inspectDir(dir)
  if dir == "up" then return turtle.inspectUp()
  elseif dir == "down" then return turtle.inspectDown()
  else return turtle.inspect() end
end

local function digDir(dir)
  local ok, data = inspectDir(dir)
  if ok and data and isProtected(data.name) then
    return false, "Protected block: "..tostring(data.name)
  end
  if not ok then return true end
  if dir == "up" then return turtle.digUp()
  elseif dir == "down" then return turtle.digDown()
  else return turtle.dig() end
end

local function requestForemanMove(reason)
  broadcast({
    type = "FOREMAN_MOVE_REQUEST",
    role = ROLE,
    id = ID,
    jobId = state.job and state.job.id or state.jobId,
    sectorId = state.sector and state.sector.id or state.sectorId,
    reason = reason or "miner path blocked",
    pos = state.pos,
    facing = state.facing,
  })
  local deadline = os.clock() + 4
  while os.clock() < deadline do
    local sender, msg = rednet.receive(PROTOCOL, 0.5)
    if type(msg) == "table" and msg.type == "FOREMAN_MOVED" then return true end
  end
  return false
end

local function safeDigForward()
  local ok, data = turtle.inspect()
  if ok and data and isProtected(data.name) then
    local n = data.name or ""
    if n:find("turtle") or n:find("computer") or n:find("modem") then
      if requestForemanMove("blocked by "..n) then
        sleep(0.5)
        return safeDigForward()
      end
    end
    return false, "Cannot break protected block: "..n
  end
  if ok then return turtle.dig() end
  return true
end

local function forward()
  safeDigForward()
  if turtle.forward() then
    broadcastMinerPosition()
    return true
  end
  local ok, err = safeDigForward()
  if not ok then
    state.error = err
    state.status = "ERROR"
    save()
    send({type="ERROR", message=err, jobId=state.job and state.job.id, sectorId=state.sector and state.sector.id})
    return false
  end
  if turtle.forward() then
    broadcastMinerPosition()
    return true
  end
  if requestForemanMove("movement blocked") then
    sleep(0.5)
    if turtle.forward() then broadcastMinerPosition(); return true end
  end
  return false
end

local function up()
  local ok, err = digDir("up")
  if not ok then state.error=err; state.status="ERROR"; save(); send({type="ERROR",message=err}); return false end
  if turtle.up() then broadcastMinerPosition(); return true end
  return false
end

local function down()
  local floorY = state.job and state.job.origin and state.job.origin.y
  if floorY and state.pos and state.pos.y <= floorY then return false end
  local ok, err = digDir("down")
  if not ok then state.error=err; state.status="ERROR"; save(); send({type="ERROR",message=err}); return false end
  if turtle.down() then broadcastMinerPosition(); return true end
  return false
end

local function turnLeft()
  turtle.turnLeft()
  if state.facing then
    local order = {"north","west","south","east"}
    local map = {north=1, west=2, south=3, east=4}
    local i = map[state.facing] or 1
    state.facing = order[(i % 4) + 1]
  end
end

local function turnRight()
  turtle.turnRight()
  if state.facing then
    local order = {"north","east","south","west"}
    local map = {north=1, east=2, south=3, west=4}
    local i = map[state.facing] or 1
    state.facing = order[(i % 4) + 1]
  end
end

local function assign(msg)
  state.job = msg.job or msg.assignment and msg.assignment.job
  state.sector = msg.sector or msg.assignment and msg.assignment.sector
  state.jobId = state.job and state.job.id or msg.jobId
  state.sectorId = state.sector and state.sector.id or msg.sectorId
  state.status = "MINING"
  state.error = nil
  state.currentIndex = state.currentIndex or 1
  save()
  send({type="MINER_SAFE", jobId=state.jobId, sectorId=state.sectorId})
  broadcastMinerPosition()
end

local function totalEstimate(job, sector)
  if not job then return 0 end
  local shape = job.shape or job.type
  if shape == "cylinder" then
    local r = tonumber(job.radius or 1) or 1
    local h = tonumber(job.height or 1) or 1
    return math.max(1, math.floor((2*r+1)*(2*r+1)*h))
  elseif shape == "rectangular_prism" or shape == "room" then
    return math.max(1, (tonumber(job.sideA or job.width or 1) or 1) * (tonumber(job.sideB or job.depth or 1) or 1) * (tonumber(job.height or 1) or 1))
  else
    return 1000
  end
end

local function miningLoop()
  while true do
    if state.status == "MINING" and state.job then
      organizeInventory()
      local total = totalEstimate(state.job, state.sector)
      if state.currentIndex > total then
        state.status = "COMPLETE"
        save()
        send({type="SECTOR_COMPLETE", jobId=state.jobId or state.job.id, sectorId=state.sectorId or (state.sector and state.sector.id)})
      else
        -- Conservative compact-job worker:
        -- each tick clears forward/up as needed and steps forward.
        -- Shape-specific sweeping is handled by compact index in later refinements.
        state.progress = math.min(1, state.currentIndex / total)
        draw()
        forward()
        if state.status ~= "ERROR" then
          state.currentIndex = state.currentIndex + 1
          save()
          broadcastMinerPosition()
        end
        sleep(0.1)
      end
    else
      sleep(0.25)
    end
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
      elseif msg.type == "PAUSE_JOB" then
        state.status = "PAUSED"; save()
      elseif msg.type == "RESUME_JOB" then
        if state.job then state.status = "MINING"; save() end
      elseif msg.type == "CANCEL_JOB" then
        state.job=nil; state.sector=nil; state.jobId=nil; state.sectorId=nil; state.currentIndex=1; state.progress=0; state.status="LISTENING"; state.error=nil; save()
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
  state.status = "ERROR"; state.error = "No modem found"; draw()
  while true do sleep(10) end
end
gpsTry(3)
organizeInventory()
draw("Listening for controller...")
parallel.waitForAny(netLoop, heartLoop, miningLoop)
