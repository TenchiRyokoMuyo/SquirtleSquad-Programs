-- SquirtleSquad MinerTurtle.lua
-- Safe GPS-bound industrial miner turtle.

local PROJECT = "SquirtleSquad-Miner"
local ROLE = "miner"
local VERSION = "v2.0-loadout"
local PROTOCOL = "TurtleTeamNet"
local DATA_DIR = "SquirtleSquadData/MinerTurtle"
local STATE_FILE = DATA_DIR .. "/miner_state.dat"
local PROTECTED_FILE = DATA_DIR .. "/protected_cache.dat"
local HEARTBEAT_INTERVAL = 5
local GPS_CHECK_MOVES = 8
local CONTROLLER_TIMEOUT = 10

local VALID_FUEL = { ["minecraft:coal"] = true, ["minecraft:charcoal"] = true }
local VALID_TORCH = { ["minecraft:torch"] = true }
local FILLER_SLOT, FUEL_SLOT, TORCH_SLOT = 2, 1, 16
local WORK_SLOTS_MIN, WORK_SLOTS_MAX = 3, 15
local DIRS = { north={dx=0,dz=-1}, east={dx=1,dz=0}, south={dx=0,dz=1}, west={dx=-1,dz=0} }
local ORDER = {"north","east","south","west"}

local state = {
  version = VERSION,
  id = os.getComputerID(),
  label = os.getComputerLabel(),
  controllerId = nil,
  status = "BOOTING",
  home = nil,
  homeFacing = nil,
  pos = nil,
  facing = nil,
  lastSafePos = nil,
  homeValid = false,
  inventoryValid = false,
  gpsValid = false,
  atHome = false,
  protectedRevision = 0,
  protectedExact = {},
  protectedContains = {},
  assignment = nil,
  job = nil,
  task = nil,
  movesSinceGps = 0,
  rogue = false,
  killMode = false,
  lastProblem = nil,
}

local modemSide = nil
local running = true
local paused = false

local function ensureDir()
  if not fs.exists("SquirtleSquadData") then fs.makeDir("SquirtleSquadData") end
  if not fs.exists(DATA_DIR) then fs.makeDir(DATA_DIR) end
end
local function copy(t) if type(t) ~= "table" then return t end local r = {}; for k,v in pairs(t) do r[k]=copy(v) end return r end
local function saveTable(path, t) ensureDir(); local h=fs.open(path,"w"); if not h then return false end; h.write(textutils.serialize(t)); h.close(); return true end
local function loadTable(path) if not fs.exists(path) then return nil end local h=fs.open(path,"r"); if not h then return nil end local s=h.readAll(); h.close(); local ok,t=pcall(textutils.unserialize,s or ""); if ok and type(t)=="table" then return t end return nil end
local function saveState() state.version=VERSION; state.label=os.getComputerLabel(); saveTable(STATE_FILE,state) end
local function loadState()
  local s = loadTable(STATE_FILE)
  if type(s)=="table" then for k,v in pairs(s) do state[k]=v end end
  local p = loadTable(PROTECTED_FILE)
  if type(p)=="table" then state.protectedExact=p.exact or {}; state.protectedContains=p.contains or {}; state.protectedRevision=p.revision or 0 end
end
local function now() return os.epoch("utc") end

local function color(c) if term.isColor and term.isColor() then term.setTextColor(c) end end
local function bcolor(c) if term.isColor and term.isColor() then term.setBackgroundColor(c) end end
local function clear() bcolor(colors.black); color(colors.lightGray); term.clear(); term.setCursorPos(1,1) end
local function center(y,text,c) local w=term.getSize(); color(c or colors.lightGray); term.setCursorPos(math.max(1,math.floor((w-#text)/2)+1),y); term.write(text) end
local function header(title) clear(); center(1,"SquirtleSquad Miner Turtle",colors.cyan); center(2,title or VERSION,colors.orange); term.setCursorPos(1,4); color(colors.lightGray) end
local function writeCoord(c) if not c then color(colors.red); term.write("unknown"); color(colors.lightGray); return end color(colors.red); term.write("X "..c.x.." "); color(colors.yellow); term.write("Y "..c.y.." "); color(colors.blue); term.write("Z "..c.z); color(colors.lightGray) end

local function openModem()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name)=="modem" then modemSide=name; if not rednet.isOpen(name) then rednet.open(name) end; return true end
  end
  return false
end

local function safePacket(packet)
  if type(packet) ~= "table" then return nil end
  local p = copy(packet)
  p.project=PROJECT; p.protocol=PROTOCOL; p.protocolVersion=2; p.senderRole=ROLE; p.senderId=os.getComputerID(); p.timestamp=now()
  if not p.payload then p.payload={} end
  local ok = pcall(textutils.serialize,p)
  if not ok then return nil end
  return p
end
local function send(id, packet) local p=safePacket(packet); if not p then return false end; return rednet.send(id,p,PROTOCOL) end
local function broadcast(packet) local p=safePacket(packet); if not p then return false end; rednet.broadcast(p,PROTOCOL); return true end
local function validPacket(p) return type(p)=="table" and p.project==PROJECT and p.protocol==PROTOCOL and type(p.type)=="string" end

local function heartbeat()
  local payload = { role=ROLE, status=state.status, pos=copy(state.pos), home=copy(state.home), homeValid=state.homeValid, inventoryValid=state.inventoryValid, gpsValid=state.gpsValid, atHome=state.atHome, protectedRevision=state.protectedRevision, rogue=state.rogue }
  if state.controllerId then send(state.controllerId,{type="HEARTBEAT",payload=payload}) else broadcast({type="HEARTBEAT",payload=payload}) end
end
local function register()
  broadcast({type="REGISTER", payload={ role=ROLE, label=os.getComputerLabel(), status=state.status, pos=copy(state.pos), home=copy(state.home), homeValid=state.homeValid, inventoryValid=state.inventoryValid, gpsValid=state.gpsValid, atHome=state.atHome, protectedRevision=state.protectedRevision }})
end

local function locate(timeout)
  local x,y,z = gps.locate(timeout or 2)
  if x then return {x=math.floor(x+0.5), y=math.floor(y+0.5), z=math.floor(z+0.5)} end
  return nil
end

local function requestAnchors()
  if state.controllerId then send(state.controllerId,{type="ANCHOR_REQUEST",payload={}}) else broadcast({type="ANCHOR_REQUEST",payload={}}) end
  local deadline = os.clock() + CONTROLLER_TIMEOUT
  while os.clock() < deadline do
    local id,msg = rednet.receive(PROTOCOL,1)
    if id and validPacket(msg) then
      if msg.type == "ANCHOR_STATUS" then state.controllerId=id; return msg.payload end
      if msg.type == "REGISTER_ACK" then state.controllerId=id; if msg.payload and msg.payload.anchors then return msg.payload.anchors end end
    end
  end
  return nil
end

local function gpsQuorum()
  local p = locate(2)
  state.gpsValid = false
  if not p then return false, "gps.locate failed" end
  local anchors = requestAnchors()
  if not anchors or not anchors.ok or (anchors.gpsSubhosts or 0) < 3 then return false, "4 GPS anchors unavailable" end
  state.pos = p; state.gpsValid = true; state.lastSafePos = copy(p); saveState(); return true
end

local function samePos(a,b) return a and b and a.x==b.x and a.y==b.y and a.z==b.z end
local function isAtHome() return state.home and samePos(state.pos,state.home) end
local function faceIndex(f) for i,v in ipairs(ORDER) do if v==f then return i end end return 1 end
local function turnLeft() turtle.turnLeft(); state.facing=ORDER[((faceIndex(state.facing)-2)%4)+1]; saveState() end
local function turnRight() turtle.turnRight(); state.facing=ORDER[(faceIndex(state.facing)%4)+1]; saveState() end
local function face(f) while state.facing ~= f do local ci,ti=faceIndex(state.facing),faceIndex(f); if ((ti-ci)%4)==1 then turnRight() else turnLeft() end end end
local function forwardTarget() local d=DIRS[state.facing]; return {x=state.pos.x+d.dx,y=state.pos.y,z=state.pos.z+d.dz} end
local function upTarget() return {x=state.pos.x,y=state.pos.y+1,z=state.pos.z} end
local function downTarget() return {x=state.pos.x,y=state.pos.y-1,z=state.pos.z} end

local function insideBounds(b,p) return b and p and p.x>=b.minX and p.x<=b.maxX and p.y>=b.minY and p.y<=b.maxY and p.z>=b.minZ and p.z<=b.maxZ end
local function dist2LineXZ(px,pz,ax,az,bx,bz)
  local vx,vz=bx-ax,bz-az; local wx,wz=px-ax,pz-az; local c1=wx*vx+wz*vz; if c1<=0 then local dx, dz=px-ax,pz-az; return math.sqrt(dx*dx+dz*dz) end
  local c2=vx*vx+vz*vz; if c2<=c1 then local dx,dz=px-bx,pz-bz; return math.sqrt(dx*dx+dz*dz) end
  local t=c1/c2; local qx,qz=ax+t*vx,az+t*vz; local dx,dz=px-qx,pz-qz; return math.sqrt(dx*dx+dz*dz)
end
local function insideShape(job,p)
  if not job or not p or not insideBounds(job.fullBounds,p) then return false end
  local h=(job.layerHeight or 1); local dy=p.y-job.origin.y
  if job.shape=="cuboid_center" or job.shape=="cuboid_coords" then return true end
  if job.shape=="cylinder" then local dx,dz=p.x-job.origin.x,p.z-job.origin.z; return dx*dx+dz*dz <= job.radius*job.radius end
  if job.shape=="cone" then local r=math.max(0, job.radius * (1 - dy / math.max(1,h))); local dx,dz=p.x-job.origin.x,p.z-job.origin.z; return dx*dx+dz*dz <= r*r end
  if job.shape=="dome" then local r=job.radius; local dx,dz=p.x-job.origin.x,p.z-job.origin.z; return dx*dx+dz*dz+dy*dy <= r*r end
  if job.shape=="pyramid" then local step=job.step or 1; local shrink=math.floor(dy / step); local ax=math.max(0, math.floor((job.sideA or 1)/2)-shrink); local bz=math.max(0, math.floor((job.sideB or 1)/2)-shrink); return math.abs(p.x-job.origin.x)<=ax and math.abs(p.z-job.origin.z)<=bz end
  if job.shape=="stretched_cylinder" then return dist2LineXZ(p.x,p.z,job.origin.x,job.origin.z,job.origin2.x,job.origin2.z) <= job.radius end
  if job.shape=="tunnel_spline" then return dist2LineXZ(p.x,p.z,job.origin.x,job.origin.z,job.dest.x,job.dest.z) <= math.max(1,math.floor((job.width or 3)/2)) end
  return true
end

local phase = "idle"
local function allowedTarget(p, reason)
  if state.rogue then return false, "rogue lock" end
  if phase == "to_home" or phase == "to_origin" or reason == "service" or reason == "emergency_return" then return true end
  if state.job and state.job.fullBounds and insideShape(state.job,p) then return true end
  return false, "outside permitted job volume"
end

local function isProtectedName(name)
  if not name then return false end
  local n=string.lower(name)
  if state.protectedExact[n] then return true end
  for _, sub in ipairs(state.protectedContains or {}) do if n:find(sub,1,true) then return true end end
  return false
end
local function loadProtected(payload)
  if not payload then return end
  state.protectedExact={}; state.protectedContains={}
  for _,v in ipairs(payload.exact or {}) do state.protectedExact[string.lower(v)]=true end
  for _,v in ipairs(payload.contains or {}) do table.insert(state.protectedContains,string.lower(v)) end
  state.protectedRevision=payload.revision or state.protectedRevision
  saveTable(PROTECTED_FILE,{exact=state.protectedExact,contains=state.protectedContains,revision=state.protectedRevision})
  saveState()
end

local function blockName(dir)
  local ok, data
  if dir=="forward" then ok,data=turtle.inspect() elseif dir=="up" then ok,data=turtle.inspectUp() else ok,data=turtle.inspectDown() end
  if ok and data then return data.name, data end
  return nil,nil
end
local function isTorchName(n) return n and VALID_TORCH[n] end
local function selectSlot(s) turtle.select(s) end
local function itemName(slot) local d=turtle.getItemDetail(slot); return d and d.name or nil, d and d.count or 0 end
local function hasFiller() local n,c=itemName(FILLER_SLOT); return c>0 and n and not VALID_FUEL[n] and not VALID_TORCH[n] end
local function placeDir(dir)
  if dir=="forward" then return turtle.place() elseif dir=="up" then return turtle.placeUp() else return turtle.placeDown() end
end
local function digDirRaw(dir)
  if dir=="forward" then return turtle.dig() elseif dir=="up" then return turtle.digUp() else return turtle.digDown() end
end
local function targetForDir(dir) if dir=="forward" then return forwardTarget() elseif dir=="up" then return upTarget() else return downTarget() end end

local function reportProblem(reason, extra)
  state.status="PROBLEM"; state.lastProblem=reason; saveState()
  if state.controllerId then send(state.controllerId,{type="TASK_PROBLEM",payload={reason=reason, extra=extra, pos=copy(state.pos), taskId=state.task and state.task.id}}) end
end

local function markRogue(reason)
  state.rogue=true; state.status="ROGUE"; state.lastProblem=reason; saveState()
  pcall(os.setComputerLabel, "ROGUE-" .. tostring(os.getComputerID()))
  if state.controllerId then send(state.controllerId,{type="ROGUE",payload={reason=reason,pos=copy(state.pos)}}) else broadcast({type="ROGUE",payload={reason=reason,pos=copy(state.pos)}}) end
  header("ROGUE LOCK")
  color(colors.red); print("This turtle is Rogue."); color(colors.lightGray)
  print("Reason: " .. tostring(reason))
  print("Place it back at its saved home and reboot.")
  error("ROGUE: " .. tostring(reason), 0)
end

local function handleLava(dir, target)
  local n = blockName(dir)
  if n ~= "minecraft:lava" and n ~= "minecraft:flowing_lava" then return true end
  if not hasFiller() then reportProblem("Lava found but no filler", {dir=dir,target=target}); return false end
  selectSlot(FILLER_SLOT)
  if not placeDir(dir) then reportProblem("Failed to place filler into lava", {dir=dir,target=target}); return false end
  if state.job and insideShape(state.job,target) then digDirRaw(dir) end
  return true
end

local function safeDig(dir, reason)
  local target = targetForDir(dir)
  local n = blockName(dir)
  if not n then return true end
  if isProtectedName(n) then reportProblem("Protected block encountered: "..n, {dir=dir,target=target}); return false end
  if isTorchName(n) then
    local mode = state.job and state.job.torchMode or "ignored"
    if mode == "ignored" then reportProblem("Torch blocks path and torch mode is ignored", {dir=dir,target=target}); return false end
  end
  if n == "minecraft:lava" or n == "minecraft:flowing_lava" then return handleLava(dir,target) end
  if not allowedTarget(target, reason) then reportProblem("Refused to dig outside permitted volume", {dir=dir,target=target}); return false end
  local ok = digDirRaw(dir)
  if not ok then reportProblem("Dig failed", {dir=dir,target=target,name=n}); return false end
  return true
end

local function gpsCheck(force)
  if not force and state.movesSinceGps < GPS_CHECK_MOVES then return true end
  local ok, why = gpsQuorum()
  state.movesSinceGps = 0
  if not ok then reportProblem("GPS_LOST: " .. tostring(why)); return false end
  return true
end

local function moveChecked(dir, reason)
  if not gpsCheck(false) then return false end
  local target = targetForDir(dir)
  local ok, why = allowedTarget(target, reason)
  if not ok then reportProblem(why, {target=target, reason=reason}); return false end
  if not handleLava(dir,target) then return false end
  local moved = false
  if dir=="forward" then
    if turtle.detect() and not safeDig("forward",reason) then return false end
    moved = turtle.forward()
  elseif dir=="up" then
    if turtle.detectUp() and not safeDig("up",reason) then return false end
    moved = turtle.up()
  else
    if turtle.detectDown() and not safeDig("down",reason) then return false end
    moved = turtle.down()
  end
  if not moved then reportProblem("Move failed "..dir, {target=target}); return false end
  state.pos = target; state.lastSafePos=copy(target); state.movesSinceGps=(state.movesSinceGps or 0)+1; saveState()
  return gpsCheck(false)
end

local function goY(y, reason) while state.pos.y < y do if not moveChecked("up",reason) then return false end end while state.pos.y > y do if not moveChecked("down",reason) then return false end end return true end
local function goX(x, reason) while state.pos.x < x do face("east"); if not moveChecked("forward",reason) then return false end end while state.pos.x > x do face("west"); if not moveChecked("forward",reason) then return false end end return true end
local function goZ(z, reason) while state.pos.z < z do face("south"); if not moveChecked("forward",reason) then return false end end while state.pos.z > z do face("north"); if not moveChecked("forward",reason) then return false end end return true end
local function goTo(pos, reason)
  if not gpsCheck(true) then return false end
  if not goY(pos.y,reason) then return false end
  if not goX(pos.x,reason) then return false end
  if not goZ(pos.z,reason) then return false end
  return gpsCheck(true)
end

local function promptFacing()
  while true do
    header("Home Facing")
    print("Set the direction this turtle is currently facing at home:")
    print("1. north")
    print("2. east")
    print("3. south")
    print("4. west")
    local s=read()
    local n=tonumber(s)
    if n and ORDER[n] then return ORDER[n] end
  end
end

local function inspectChest(dir)
  local n
  if dir=="up" then n=blockName("up") else n=blockName("down") end
  if not n then return false end
  return n:find("chest",1,true) or n:find("barrel",1,true) or n:find("shulker",1,true)
end

local function setupHome()
  local ok, why = gpsQuorum()
  if not ok then header("GPS Failed"); print(why); sleep(2); return false end
  if not inspectChest("down") then header("Home Setup"); print("Deposit chest/barrel/shulker must be below turtle."); return false end
  if not inspectChest("up") then header("Home Setup"); print("Fuel/Torch/Filler chest must be above turtle."); return false end
  state.home=copy(state.pos); state.homeFacing=state.homeFacing or promptFacing(); state.facing=state.homeFacing
  state.homeValid=true; state.atHome=true; state.status="AT_HOME"; saveState(); return true
end

local function dumpSlotDown(slot)
  turtle.select(slot)
  local d=turtle.getItemDetail(slot)
  if d then turtle.dropDown() end
end
local function moveReservedMisplacedUp()
  for s=WORK_SLOTS_MIN,WORK_SLOTS_MAX do
    local d=turtle.getItemDetail(s)
    if d and (VALID_FUEL[d.name] or VALID_TORCH[d.name]) then turtle.select(s); turtle.dropUp() end
  end
end
local function normalizeReservedSlots()
  for s=1,16 do
    local d=turtle.getItemDetail(s)
    if d then
      if s ~= FUEL_SLOT and VALID_FUEL[d.name] then turtle.select(s); turtle.dropUp() end
      if s ~= TORCH_SLOT and VALID_TORCH[d.name] then turtle.select(s); turtle.dropUp() end
    end
  end
end
local function pullSlot(slot, validSet, maxCount)
  turtle.select(slot)
  local d=turtle.getItemDetail(slot)
  if d and (not validSet[d.name] or d.count > maxCount) then turtle.dropUp() end
  d=turtle.getItemDetail(slot)
  if not d or d.count < maxCount then turtle.suckUp(maxCount - (d and d.count or 0)) end
end
local function serviceInventory()
  phase = "to_home"
  state.status="SERVICING"; saveState()
  if not goTo(state.home,"service") then markRogue("Unable to return home for service") end
  gpsCheck(true)
  if not isAtHome() then markRogue("GPS says turtle is not at home during service") end
  face(state.homeFacing)
  for s=WORK_SLOTS_MIN,WORK_SLOTS_MAX do dumpSlotDown(s) end
  moveReservedMisplacedUp(); normalizeReservedSlots()
  pullSlot(FUEL_SLOT, VALID_FUEL, 64)
  turtle.select(FILLER_SLOT); local d=turtle.getItemDetail(FILLER_SLOT); if not d or d.count < 64 then turtle.suckUp(64 - (d and d.count or 0)) end
  pullSlot(TORCH_SLOT, VALID_TORCH, 64)
  local f,fc=itemName(FUEL_SLOT); local fi,fic=itemName(FILLER_SLOT); local to,tc=itemName(TORCH_SLOT)
  state.inventoryValid = VALID_FUEL[f] and fc>=8 and fi and fic>=2 and (not state.job or state.job.torchMode ~= "replaced" or (VALID_TORCH[to] and tc>=2))
  state.atHome=true; state.status=state.inventoryValid and "AT_HOME" or "NEEDS_SUPPLIES"; saveState(); heartbeat()
  phase="idle"
  return state.inventoryValid
end

local function needsService()
  local f,fc=itemName(FUEL_SLOT); if not VALID_FUEL[f] or fc < 8 then return true end
  local fi,fic=itemName(FILLER_SLOT); if not fi or fic < 2 then return true end
  if state.job and state.job.torchMode=="replaced" then local t,tc=itemName(TORCH_SLOT); if not VALID_TORCH[t] or tc < 2 then return true end end
  local full=true; for s=WORK_SLOTS_MIN,WORK_SLOTS_MAX do if turtle.getItemCount(s)==0 then full=false break end end
  return full
end

local function fuelIfNeeded()
  if turtle.getFuelLevel and turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < 100 then
    local n,c=itemName(FUEL_SLOT); if VALID_FUEL[n] and c>0 then turtle.select(FUEL_SLOT); turtle.refuel(1) end
  end
end

local function placeTorchIfNeeded(x,z)
  if not state.job or state.job.torchMode ~= "replaced" then return end
  if state.task.passIndex ~= 1 then return end
  local spacing = state.job.torchSpacing or 8
  if ((x - state.job.origin.x) % spacing ~= 0) or ((z - state.job.origin.z) % spacing ~= 0) then return end
  local n,c=itemName(TORCH_SLOT); if not VALID_TORCH[n] or c<=0 then return end
  turtle.select(TORCH_SLOT); turtle.placeDown()
end

local function mineColumnAt(x,z)
  local b=state.task.bounds
  for y=b.minY,b.maxY do
    local p={x=x,y=y,z=z}
    if insideShape(state.job,p) and y ~= state.pos.y then
      if y > state.pos.y then while state.pos.y < y do if not moveChecked("up","work") then return false end end
      else while state.pos.y > y do if not moveChecked("down","work") then return false end end end
    end
  end
  if not goY(state.task.travelY,"work") then return false end
  -- Clear one block above/below travel lane if part of this 3-layer pass.
  if b.maxY > state.pos.y then if not safeDig("up","work") then return false end end
  if b.minY < state.pos.y then if not safeDig("down","work") then return false end end
  placeTorchIfNeeded(x,z)
  return true
end

local function taskOrigin()
  return {x=state.job.origin.x,y=state.task.travelY,z=state.job.origin.z}
end

local function returnToOrigin()
  phase="to_origin"
  local o = taskOrigin()
  local ok = goTo(o,"to_origin")
  phase="idle"
  if ok and state.controllerId then send(state.controllerId,{type="AT_ORIGIN",payload={pos=copy(state.pos),taskId=state.task and state.task.id}}) end
  return ok
end

local function workTask()
  state.status="MOVING_TO_ORIGIN"; saveState(); heartbeat()
  phase="to_origin"
  if not goTo(taskOrigin(),"to_origin") then reportProblem("Could not reach origin"); return false end
  if state.controllerId then send(state.controllerId,{type="AT_ORIGIN",payload={pos=copy(state.pos),taskId=state.task.id}}) end
  phase="work"
  state.status="WORKING"; saveState(); heartbeat()
  local b=state.task.bounds
  for z=b.minZ,b.maxZ do
    local xStart,xEnd,xStep = b.minX,b.maxX,1
    if (z-b.minZ)%2==1 then xStart,xEnd,xStep=b.maxX,b.minX,-1 end
    local x=xStart
    while (xStep==1 and x<=xEnd) or (xStep==-1 and x>=xEnd) do
      fuelIfNeeded()
      if needsService() then
        local resume={x=x,y=state.task.travelY,z=z}; returnToOrigin(); if not serviceInventory() then reportProblem("Supplies unavailable"); return false end; phase="to_origin"; if not goTo(taskOrigin(),"to_origin") then return false end; phase="work"; if not goTo(resume,"work") then return false end
      else
        if insideShape(state.job,{x=x,y=state.task.travelY,z=z}) then
          if not goTo({x=x,y=state.task.travelY,z=z},"work") then return false end
          if not mineColumnAt(x,z) then return false end
        end
        x=x+xStep
      end
    end
  end
  phase="to_origin"; returnToOrigin(); phase="to_home"; serviceInventory(); phase="idle"
  state.status="IDLE"; state.assignment=nil; local taskId=state.task.id; state.task=nil; state.job=nil; saveState()
  if state.controllerId then send(state.controllerId,{type="TASK_COMPLETE",payload={taskId=taskId,pos=copy(state.pos)}}) end
  return true
end

local function receiveProtectedOrAck(id,msg)
  if msg.type=="REGISTER_ACK" then
    state.controllerId=id
    if msg.payload and msg.payload.protectedRevision and msg.payload.protectedRevision > state.protectedRevision then send(id,{type="PROTECTED_REQUEST",payload={}}) end
  elseif msg.type=="PROTECTED_LIST" then loadProtected(msg.payload)
  end
end

local function emergencyReturn(reason)
  state.killMode=true; state.status="EMERGENCY_RETURN"; saveState(); heartbeat()
  paused=false
  if state.task and state.job then pcall(returnToOrigin) end
  phase="to_home"
  local ok=false
  if state.home then ok=goTo(state.home,"emergency_return") end
  local gpsOk=gpsCheck(true)
  if not ok or not gpsOk or not isAtHome() then markRogue(reason or "Kill switch return failed") end
  serviceInventory()
  state.status="AT_HOME"; state.killMode=false; state.assignment=nil; state.task=nil; state.job=nil; saveState(); heartbeat()
end

local function handlePacket(id,msg)
  if not validPacket(msg) then return end
  if msg.type=="REGISTER_ACK" or msg.type=="PROTECTED_LIST" then receiveProtectedOrAck(id,msg)
  elseif msg.type=="TASK_ASSIGN" then
    if state.rogue then return end
    local pl=msg.payload or {}; state.controllerId=id; state.job=pl.job; state.task=pl.task; state.assignment={jobId=pl.job and pl.job.id, taskId=pl.task and pl.task.id}; state.status="ASSIGNED"; saveState(); heartbeat(); workTask()
  elseif msg.type=="GO_HOME" then emergencyReturn("Controller ordered return home")
  elseif msg.type=="EMERGENCY_STOP_RETURN" then emergencyReturn("Controller kill switch")
  elseif msg.type=="KILL_SWITCH_CLEAR" then state.killMode=false; saveState()
  elseif msg.type=="PAUSE_JOB" then if state.job and msg.payload and msg.payload.jobId==state.job.id then paused=true; state.status="PAUSED"; saveState() end
  elseif msg.type=="RESUME_JOB" then paused=false; if state.status=="PAUSED" then state.status="WORKING" end; saveState()
  elseif msg.type=="CANCEL_JOB" then if state.job and msg.payload and msg.payload.jobId==state.job.id then emergencyReturn("Job cancelled") end
  elseif msg.type=="ROLL_CALL" then heartbeat()
  end
end

local function networkLoop()
  while running do
    local id,msg=rednet.receive(PROTOCOL,1)
    if id then handlePacket(id,msg) end
  end
end
local function heartbeatLoop()
  while running do heartbeat(); sleep(HEARTBEAT_INTERVAL) end
end
local function displayLoop()
  while running do
    header("Status")
    print("ID: "..os.getComputerID().." "..tostring(os.getComputerLabel() or ""))
    print("Status: "..tostring(state.status))
    term.write("Pos: "); writeCoord(state.pos); print("")
    term.write("Home: "); writeCoord(state.home); print("")
    print("GPS: "..tostring(state.gpsValid).." Controller: "..tostring(state.controllerId))
    print("Protected rev: "..tostring(state.protectedRevision))
    if state.task then print("Task: "..tostring(state.task.id).." P"..tostring(state.task.passIndex).." Q"..tostring(state.task.quadrantIndex)) end
    if state.rogue then color(colors.red); print("ROGUE LOCK ACTIVE"); color(colors.lightGray) end
    sleep(2)
  end
end

local function rogueBootCheck()
  if not state.rogue then return true end
  header("ROGUE LOCK")
  print("This turtle was previously labeled Rogue.")
  print("Checking if it has been placed back home...")
  local ok = gpsQuorum()
  if ok and state.home and isAtHome() then
    state.rogue=false; state.status="AT_HOME"; state.lastProblem=nil; pcall(os.setComputerLabel,"Miner-"..os.getComputerID()); saveState(); print("Home confirmed. Rogue lock cleared."); sleep(2); return true
  end
  print("Not at saved home or GPS invalid.")
  print("Place turtle at:")
  writeCoord(state.home); print("")
  print("Then reboot.")
  return false
end

local function boot()
  ensureDir(); loadState(); header("Boot")
  if not openModem() then print("No modem found."); return false end
  print("Modem: "..modemSide)
  if not rogueBootCheck() then return false end
  if not state.homeValid or not state.home then
    if not setupHome() then print("Home invalid. Fix chest/GPS setup and reboot."); return false end
  else
    local ok,why=gpsQuorum(); if not ok then print("GPS invalid: "..tostring(why)); return false end
    state.atHome=isAtHome(); if state.atHome then state.status="AT_HOME" else state.status="IDLE" end
  end
  register(); serviceInventory(); register(); saveState(); return true
end

if boot() then parallel.waitForAny(networkLoop, heartbeatLoop, displayLoop) end
