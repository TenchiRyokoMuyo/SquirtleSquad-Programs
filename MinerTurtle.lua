-- SquirtleSquad MinerTurtle.lua
-- Full safety-first fleet miner. Root-level role program.
-- Implements: GPS quorum, home validation, controller protected list, origin movement lock,
-- protected-block bypass with rollback, torch modes, lava filler handling, emergency return,
-- rogue lockout, persistent crash recovery, and shape-bounded excavation.

local PROJECT = "SquirtleSquad-Miner"
local ROLE = "miner"
local VERSION = "v2.1-fullpass-refuel-origin-horizontal"
local PROTOCOL = "TurtleTeamNet"
local DATA_DIR = "SquirtleSquadData/MinerTurtle"
local STATE_FILE = DATA_DIR .. "/miner_state.dat"
local PROTECTED_FILE = DATA_DIR .. "/protected_cache.dat"
local HEARTBEAT_INTERVAL = 5
local GPS_CHECK_MOVES = 8
local CONTROLLER_TIMEOUT = 10
local ORIGIN_LOCK_TIMEOUT = 60
local BYPASS_LIMIT = 5

local VALID_FUEL = { ["minecraft:coal"] = true, ["minecraft:charcoal"] = true }
local VALID_TORCH = { ["minecraft:torch"] = true }
local FUEL_SLOT, FILLER_SLOT, TORCH_SLOT = 1, 2, 16
local WORK_SLOTS_MIN, WORK_SLOTS_MAX = 3, 15
local DIRS = { north={dx=0,dz=-1}, east={dx=1,dz=0}, south={dx=0,dz=1}, west={dx=-1,dz=0} }
local ORDER = {"north","east","south","west"}

local state = {
  version = VERSION, id = os.getComputerID(), label = os.getComputerLabel(), controllerId = nil,
  status = "BOOTING", home = nil, homeFacing = nil, pos = nil, facing = nil,
  lastSafePos = nil, homeValid = false, inventoryValid = false, gpsValid = false, atHome = false,
  protectedRevision = 0, protectedExact = {}, protectedContains = {},
  assignment = nil, job = nil, task = nil, movesSinceGps = 0,
  routePhase = "idle", originLockHeld = false, rogue = false, killMode = false,
  lastProblem = nil, lastProblemPos = nil, stats = { mined=0, bypasses=0, rollbacks=0, serviced=0 },
}

local modemSide, running, paused = nil, true, false

-- ---------- storage / utility ----------
local function ensureDir() if not fs.exists("SquirtleSquadData") then fs.makeDir("SquirtleSquadData") end if not fs.exists(DATA_DIR) then fs.makeDir(DATA_DIR) end end
local function copy(t) if type(t) ~= "table" then return t end local r = {}; for k,v in pairs(t) do r[k] = copy(v) end return r end
local function saveTable(path, t) ensureDir(); local h=fs.open(path,"w"); if not h then return false end h.write(textutils.serialize(t)); h.close(); return true end
local function loadTable(path) if not fs.exists(path) then return nil end local h=fs.open(path,"r"); if not h then return nil end local s=h.readAll(); h.close(); local ok,t=pcall(textutils.unserialize,s or ""); if ok and type(t)=="table" then return t end return nil end
local function now() return os.epoch("utc") end
local function saveState() state.version=VERSION; state.label=os.getComputerLabel(); saveTable(STATE_FILE,state) end
local function loadState() local s=loadTable(STATE_FILE); if type(s)=="table" then for k,v in pairs(s) do state[k]=v end end; local p=loadTable(PROTECTED_FILE); if type(p)=="table" then state.protectedExact=p.exact or {}; state.protectedContains=p.contains or {}; state.protectedRevision=p.revision or 0 end; state.stats=state.stats or {mined=0,bypasses=0,rollbacks=0,serviced=0} end
local function samePos(a,b) return a and b and a.x==b.x and a.y==b.y and a.z==b.z end
local function distXZ(a,b) local dx,dz=a.x-b.x,a.z-b.z; return math.sqrt(dx*dx+dz*dz) end
local function clamp(n,a,b) return math.max(a, math.min(b,n)) end

-- ---------- UI ----------
local function color(c) if term.isColor and term.isColor() then term.setTextColor(c) end end
local function bcolor(c) if term.isColor and term.isColor() then term.setBackgroundColor(c) end end
local function clear() bcolor(colors.black); color(colors.lightGray); term.clear(); term.setCursorPos(1,1) end
local function center(y,text,c) local w=term.getSize(); color(c or colors.lightGray); term.setCursorPos(math.max(1,math.floor((w-#text)/2)+1),y); term.write(text) end
local function header(title) clear(); center(1,"SquirtleSquad Miner Turtle",colors.cyan); center(2,title or VERSION,colors.orange); term.setCursorPos(1,4); color(colors.lightGray) end
local function writeCoord(c) if not c then color(colors.red); term.write("unknown"); color(colors.lightGray); return end color(colors.red); term.write("X "..tostring(c.x).." "); color(colors.yellow); term.write("Y "..tostring(c.y).." "); color(colors.blue); term.write("Z "..tostring(c.z)); color(colors.lightGray) end

-- ---------- network ----------
local function openModem() for _,n in ipairs(peripheral.getNames()) do if peripheral.getType(n)=="modem" then modemSide=n; if not rednet.isOpen(n) then rednet.open(n) end; return true end end return false end
local function safePacket(packet) if type(packet)~="table" then return nil end local p=copy(packet); p.project=PROJECT; p.protocol=PROTOCOL; p.protocolVersion=2; p.senderRole=ROLE; p.senderId=os.getComputerID(); p.timestamp=now(); p.payload=p.payload or {}; if not pcall(textutils.serialize,p) then return nil end return p end
local function send(id,p) local q=safePacket(p); if not q then return false end return rednet.send(id,q,PROTOCOL) end
local function broadcast(p) local q=safePacket(p); if not q then return false end rednet.broadcast(q,PROTOCOL); return true end
local function validPacket(p) return type(p)=="table" and p.project==PROJECT and p.protocol==PROTOCOL and type(p.type)=="string" end
local function heartbeat() local pl={role=ROLE,status=state.status,pos=copy(state.pos),home=copy(state.home),homeValid=state.homeValid,inventoryValid=state.inventoryValid,gpsValid=state.gpsValid,atHome=state.atHome,protectedRevision=state.protectedRevision,rogue=state.rogue,originLockHeld=state.originLockHeld,lastProblem=state.lastProblem}; if state.controllerId then send(state.controllerId,{type="HEARTBEAT",payload=pl}) else broadcast({type="HEARTBEAT",payload=pl}) end end
local function register() broadcast({type="REGISTER",payload={role=ROLE,label=os.getComputerLabel(),status=state.status,pos=copy(state.pos),home=copy(state.home),homeValid=state.homeValid,inventoryValid=state.inventoryValid,gpsValid=state.gpsValid,atHome=state.atHome,protectedRevision=state.protectedRevision,rogue=state.rogue}}) end
local function report(typeName, payload) if state.controllerId then send(state.controllerId,{type=typeName,payload=payload or {}}) else broadcast({type=typeName,payload=payload or {}}) end end
local function requestReturnHome(reason) returnRequested=true; returnReason=reason or "Return requested"; state.status="RETURN_REQUESTED"; saveState(); heartbeat() end
local function shouldInterruptMovement() return returnRequested or state.rogue end

-- ---------- GPS quorum ----------
local function locate(timeout) local x,y,z = gps.locate(timeout or 2); if x then return {x=math.floor(x+0.5),y=math.floor(y+0.5),z=math.floor(z+0.5)} end return nil end
local function requestAnchors() if state.controllerId then send(state.controllerId,{type="ANCHOR_REQUEST",payload={}}) else broadcast({type="ANCHOR_REQUEST",payload={}}) end local deadline=os.clock()+CONTROLLER_TIMEOUT while os.clock()<deadline do local id,msg=rednet.receive(PROTOCOL,1); if id and validPacket(msg) then if msg.type=="ANCHOR_STATUS" then state.controllerId=id; saveState(); return msg.payload elseif msg.type=="REGISTER_ACK" then state.controllerId=id; if msg.payload and msg.payload.protectedRevision and msg.payload.protectedRevision > state.protectedRevision then send(id,{type="PROTECTED_REQUEST",payload={}}) end; saveState(); return msg.payload and msg.payload.anchors elseif msg.type=="PROTECTED_LIST" then -- do not lose useful packet while waiting
        local pl=msg.payload or {}; state.protectedExact={}; state.protectedContains={}; for _,v in ipairs(pl.exact or {}) do state.protectedExact[string.lower(v)]=true end; for _,v in ipairs(pl.contains or {}) do table.insert(state.protectedContains,string.lower(v)) end; state.protectedRevision=pl.revision or state.protectedRevision; saveTable(PROTECTED_FILE,{exact=state.protectedExact,contains=state.protectedContains,revision=state.protectedRevision})
      end end end return nil end
local function gpsQuorum() local p=locate(2); state.gpsValid=false; if not p then saveState(); return false,"gps.locate failed" end local a=requestAnchors(); if not a or not a.ok or (a.gpsSubhosts or 0)<3 then state.pos=p; saveState(); return false,"4 GPS anchors unavailable" end state.pos=p; state.lastSafePos=copy(p); state.gpsValid=true; state.atHome=samePos(state.pos,state.home); saveState(); return true end
local function gpsCheck(force) if not force and (state.movesSinceGps or 0) < GPS_CHECK_MOVES then return true end state.movesSinceGps=0; local ok,why=gpsQuorum(); if not ok then report("GPS_LOST",{reason=why,pos=copy(state.pos),lastSafePos=copy(state.lastSafePos)}); state.status="GPS_LOST"; saveState(); return false end return true end

-- ---------- protected block / block utility ----------
local function blockName(dir) local ok,d if dir=="up" then ok,d=turtle.inspectUp() elseif dir=="down" then ok,d=turtle.inspectDown() else ok,d=turtle.inspect() end if ok and d and d.name then return string.lower(d.name),d end return nil,nil end
local function isTorchName(n) return n and VALID_TORCH[n] end
local function isProtectedName(n) if not n then return false end n=string.lower(n); if state.protectedExact[n] then return true end for _,sub in ipairs(state.protectedContains or {}) do if n:find(sub,1,true) then return true end end return false end
local function loadProtected(pl) if type(pl)~="table" then return end state.protectedExact={}; state.protectedContains={}; for _,v in ipairs(pl.exact or {}) do state.protectedExact[string.lower(v)]=true end for _,v in ipairs(pl.contains or {}) do table.insert(state.protectedContains,string.lower(v)) end state.protectedRevision=pl.revision or state.protectedRevision; saveTable(PROTECTED_FILE,{exact=state.protectedExact,contains=state.protectedContains,revision=state.protectedRevision}); saveState() end

-- ---------- facing / coordinate math ----------
local function faceIndex(f) for i,v in ipairs(ORDER) do if v==f then return i end end return 1 end
local function turnLeft() turtle.turnLeft(); state.facing=ORDER[((faceIndex(state.facing)-2)%4)+1]; saveState() end
local function turnRight() turtle.turnRight(); state.facing=ORDER[(faceIndex(state.facing)%4)+1]; saveState() end
local function turnAround() turnRight(); turnRight() end
local function face(f) while state.facing~=f do local ci,ti=faceIndex(state.facing),faceIndex(f); if ((ti-ci)%4)==1 then turnRight() elseif ((ci-ti)%4)==1 then turnLeft() else turnRight() end end end
local function targetForDir(dir) if dir=="up" then return {x=state.pos.x,y=state.pos.y+1,z=state.pos.z} end if dir=="down" then return {x=state.pos.x,y=state.pos.y-1,z=state.pos.z} end local d=DIRS[state.facing]; return {x=state.pos.x+d.dx,y=state.pos.y,z=state.pos.z+d.dz} end
local function inverseMove(move) if move=="forward" then return "back" elseif move=="up" then return "down" elseif move=="down" then return "up" end return nil end

-- ---------- shape/bounds ----------
local function inBox(b,p) return b and p and p.x>=b.minX and p.x<=b.maxX and p.y>=b.minY and p.y<=b.maxY and p.z>=b.minZ and p.z<=b.maxZ end
local function lineDistanceXZ(a,b,p) local vx,vz=b.x-a.x,b.z-a.z; local wx,wz=p.x-a.x,p.z-a.z; local len2=vx*vx+vz*vz; if len2==0 then return distXZ(a,p) end local t=clamp((wx*vx+wz*vz)/len2,0,1); local px,pz=a.x+t*vx,a.z+t*vz; local dx,dz=p.x-px,p.z-pz; return math.sqrt(dx*dx+dz*dz) end
local function insideShape(job,p)
  if not job or not p then return false end
  if not inBox(job.fullBounds,p) then return false end
  local h = math.max(1, tonumber(job.layerHeight) or ((job.fullBounds.maxY-job.fullBounds.minY)+1))
  local yOff = p.y - job.origin.y
  if yOff < 0 or yOff >= h then return false end
  if job.shape=="cuboid_center" or job.shape=="cuboid_coords" then return true end
  if job.shape=="cylinder" then return distXZ(job.origin,p) <= (job.radius or 0) + 0.01 end
  if job.shape=="cone" then local r=(job.radius or 0)*(1-(yOff/math.max(1,h))); return distXZ(job.origin,p) <= r+0.5 end
  if job.shape=="dome" then local r=job.radius or 0; local dx,dz=p.x-job.origin.x,p.z-job.origin.z; return dx*dx+dz*dz+yOff*yOff <= r*r+0.5 end
  if job.shape=="pyramid" then local step=math.max(1,tonumber(job.step) or 1); local shrink=math.floor(yOff/step); local ax=math.max(0,math.floor((job.sideA or 1)/2)-shrink); local bz=math.max(0,math.floor((job.sideB or 1)/2)-shrink); return math.abs(p.x-job.origin.x)<=ax and math.abs(p.z-job.origin.z)<=bz end
  if job.shape=="stretched_cylinder" then return lineDistanceXZ(job.origin,{x=job.origin2.x,y=job.origin.y,z=job.origin2.z},p) <= (job.radius or 0)+0.01 end
  if job.shape=="tunnel_spline" then local r=math.max(1,math.floor((job.width or 3)/2)); return lineDistanceXZ(job.origin,job.dest,p) <= r+0.01 end
  return false
end
local function corridorBetween(a,b,p,pad) if not a or not b or not p then return false end pad=pad or 1; local c={minX=math.min(a.x,b.x)-pad,maxX=math.max(a.x,b.x)+pad,minY=math.min(a.y,b.y)-pad,maxY=math.max(a.y,b.y)+pad,minZ=math.min(a.z,b.z)-pad,maxZ=math.max(a.z,b.z)+pad}; return inBox(c,p) end
local function originPos() if not state.job or not state.task then return nil end return {x=state.job.origin.x,y=state.task.travelY,z=state.job.origin.z} end
local function allowedTarget(p, reason)
  if not p then return false,"nil target" end
  if state.rogue then return false,"rogue lock active" end
  if reason=="home" or state.routePhase=="to_home" then local o=originPos(); if samePos(p,state.home) or corridorBetween(o or state.pos,state.home,p,2) then return true end return false,"outside origin-home corridor" end
  if reason=="origin" or state.routePhase=="to_origin" then local o=originPos(); if o and (samePos(p,o) or corridorBetween(state.home or o,o,p,2) or insideShape(state.job,p)) then return true end return false,"outside origin corridor" end
  if reason=="bypass" then if insideShape(state.job,p) then return true end return false,"bypass would leave work volume" end
  if state.job then if insideShape(state.job,p) then return true end return false,"movement would leave job volume" end
  if state.home and corridorBetween(state.home,state.pos,p,2) then return true end
  return false,"no active job corridor allows target"
end

-- ---------- problem / rogue ----------
local function clearLocalTaskAfterProblem()
  state.assignment=nil
  state.task=nil
  state.job=nil
  state.originLockHeld=false
  state.routePhase="idle"
  paused=false
end
local function reportProblem(reason, extra)
  local taskId = state.task and state.task.id
  state.status="PROBLEM"
  state.lastProblem=reason
  state.lastProblemPos=copy(state.pos)
  saveState()
  report("TASK_PROBLEM",{reason=reason,pos=copy(state.pos),taskId=taskId,extra=extra})
  if taskId then clearLocalTaskAfterProblem(); saveState(); heartbeat() end
  return false
end
local function problemKey(name)
  local t = state.task and state.task.id or "no_task"
  local p = state.pos or {x=0,y=0,z=0}
  return table.concat({t,tostring(name),tostring(p.x),tostring(p.y),tostring(p.z)},"|")
end
local function bumpProblemRetry(name)
  state.problemRetries = state.problemRetries or {}
  local k=problemKey(name)
  state.problemRetries[k]=(state.problemRetries[k] or 0)+1
  saveState()
  return state.problemRetries[k],k
end
local function markRogue(reason) state.rogue=true; state.status="ROGUE"; state.lastProblem=reason; state.lastProblemPos=copy(state.pos); saveState(); pcall(os.setComputerLabel,"ROGUE-Miner-"..os.getComputerID()); report("ROGUE",{reason=reason,pos=copy(state.pos),home=copy(state.home),taskId=state.task and state.task.id}); error("ROGUE: "..tostring(reason),0) end

-- ---------- inventory / service ----------
local function itemName(slot) local d=turtle.getItemDetail(slot); if d then return d.name,d.count,d end return nil,0,nil end
local function hasFiller() local n,c=itemName(FILLER_SLOT); return n and c and c>0 end
local function validFuelSlot() local n,c=itemName(FUEL_SLOT); return VALID_FUEL[n] and c>=8 end
local function validTorchSlot(needed) if not needed then return true end local n,c=itemName(TORCH_SLOT); return VALID_TORCH[n] and c>=2 end
local function normalizeReservedSlots() for s=1,16 do local n,c=itemName(s); if n then if s~=FUEL_SLOT and VALID_FUEL[n] then turtle.select(s); turtle.dropUp() end if s~=TORCH_SLOT and VALID_TORCH[n] then turtle.select(s); turtle.dropUp() end end end end
local function pullSlot(slot, validSet, want) turtle.select(slot); local n,c=itemName(slot); if n and validSet and not validSet[n] then turtle.dropUp(); n,c=itemName(slot) end if not n or c<want then turtle.suckUp(want-(c or 0)) end end
local function serviceInventory()
  if not state.home then return reportProblem("No saved home for service") end
  state.status="SERVICING"; state.routePhase="to_home"; saveState(); heartbeat()
  if not goTo(state.home,"home") then markRogue("Unable to return home for service") end
  if not gpsCheck(true) or not samePos(state.pos,state.home) then markRogue("GPS did not confirm home during service") end
  face(state.homeFacing)
  for s=WORK_SLOTS_MIN,WORK_SLOTS_MAX do turtle.select(s); if turtle.getItemCount(s)>0 then turtle.dropDown() end end
  normalizeReservedSlots()
  pullSlot(FUEL_SLOT,VALID_FUEL,64)
  turtle.select(FILLER_SLOT); local fn,fc=itemName(FILLER_SLOT); if not fn or fc<64 then turtle.suckUp(64-(fc or 0)) end
  pullSlot(TORCH_SLOT,VALID_TORCH,64)
  state.inventoryValid = validFuelSlot() and hasFiller() and validTorchSlot(state.job and state.job.torchMode=="replaced")
  state.atHome=true; state.status=state.inventoryValid and "AT_HOME" or "NEEDS_SUPPLIES"; state.routePhase="idle"; state.stats.serviced=(state.stats.serviced or 0)+1; saveState(); heartbeat(); report("AT_HOME",{pos=copy(state.pos),inventoryValid=state.inventoryValid})
  return state.inventoryValid
end
local function needsService() if not validFuelSlot() then return true,"fuel" end if not hasFiller() then return true,"filler" end if state.job and state.job.torchMode=="replaced" and not validTorchSlot(true) then return true,"torches" end local full=true; for s=WORK_SLOTS_MIN,WORK_SLOTS_MAX do if turtle.getItemCount(s)==0 then full=false break end end if full then return true,"inventory full" end return false,nil end
local function fuelIfNeeded() if turtle.getFuelLevel and turtle.getFuelLevel()~="unlimited" and turtle.getFuelLevel()<100 then local n,c=itemName(FUEL_SLOT); if VALID_FUEL[n] and c>0 then turtle.select(FUEL_SLOT); turtle.refuel(1) end end end

local function ensureFuelForMove()
  if not turtle.getFuelLevel then return true end
  local lvl = turtle.getFuelLevel()
  if lvl == "unlimited" or lvl > 0 then return true end
  local n,c = itemName(FUEL_SLOT)
  if not VALID_FUEL[n] or c <= 0 then return false end
  local previous = turtle.getSelectedSlot()
  turtle.select(FUEL_SLOT)
  local ok = turtle.refuel(1)
  turtle.select(previous)
  if not ok then return false end
  lvl = turtle.getFuelLevel()
  return lvl == "unlimited" or lvl > 0
end

-- ---------- raw movement, lava, dig ----------
local function inspectForDir(dir) if dir=="up" then return blockName("up") elseif dir=="down" then return blockName("down") else return blockName("forward") end end
local function turtleMove(dir)
  if not ensureFuelForMove() then return false end
  if dir=="up" then return turtle.up() elseif dir=="down" then return turtle.down() else return turtle.forward() end
end
local function turtleBack()
  if not ensureFuelForMove() then return false end
  return turtle.back()
end
local function rawMove(dir, reason, allowDig, allowBypass)
  if shouldInterruptMovement() then return false end
  if not gpsCheck(false) then return false end
  local target=targetForDir(dir); local ok,why=allowedTarget(target,reason); if not ok then return reportProblem(why,{target=target,reason=reason}) end
  local n=inspectForDir(dir)
  if n then
    if isProtectedName(n) or (isTorchName(n) and state.job and state.job.torchMode=="ignored") then
      if allowBypass and dir=="forward" then return attemptBypassProtected(n, reason) end
      return reportProblem("Blocked by protected/ignored block: "..n,{target=target,name=n})
    end
    if isTorchName(n) and state.job and state.job.torchMode=="replaced" and state.task and state.task.passIndex>1 then
      if allowBypass and dir=="forward" then return attemptBypassProtected(n, reason) end
      return reportProblem("Refusing to break preserved torch after first pass",{target=target})
    end
    if n=="minecraft:lava" or n=="minecraft:flowing_lava" then if not handleLava(dir,target) then return false end else
      if allowDig then if dir=="up" then if not turtle.digUp() then return reportProblem("Dig up failed",{target=target,name=n}) end elseif dir=="down" then if not turtle.digDown() then return reportProblem("Dig down failed",{target=target,name=n}) end else if not turtle.dig() then return reportProblem("Dig forward failed",{target=target,name=n}) end end; state.stats.mined=(state.stats.mined or 0)+1 else return reportProblem("Path blocked and digging disabled: "..n,{target=target}) end
    end
  end
  if not ensureFuelForMove() then return reportProblem("No fuel for movement",{target=target}) end
  if not turtleMove(dir) then return reportProblem("Move failed "..dir,{target=target}) end
  state.pos=target; state.lastSafePos=copy(target); state.movesSinceGps=(state.movesSinceGps or 0)+1; saveState(); return gpsCheck(false)
end
function handleLava(dir,target)
  if not hasFiller() then return reportProblem("Lava found but no filler",{target=target}) end
  turtle.select(FILLER_SLOT)
  local placed=false
  if dir=="up" then placed=turtle.placeUp() elseif dir=="down" then placed=turtle.placeDown() else placed=turtle.place() end
  if not placed then return reportProblem("Failed to place filler into lava",{target=target}) end
  local inside=state.job and insideShape(state.job,target)
  if inside then if dir=="up" then turtle.digUp() elseif dir=="down" then turtle.digDown() else turtle.dig() end end
  return true
end

local returnToOrigin

-- ---------- bypass and rollback ----------
local function appendInverse(rollback, action)
  if action=="L" then table.insert(rollback,"R") elseif action=="R" then table.insert(rollback,"L") elseif action=="F" then table.insert(rollback,"B") elseif action=="U" then table.insert(rollback,"D") elseif action=="D" then table.insert(rollback,"U") end
end
local function runAction(action, rollback, reason)
  if shouldInterruptMovement() then return false end
  if action=="L" then turnLeft(); appendInverse(rollback,"L"); return true end
  if action=="R" then turnRight(); appendInverse(rollback,"R"); return true end
  if action=="F" then if rawMove("forward",reason,true,false) then appendInverse(rollback,"F"); return true end; return false end
  if action=="U" then if rawMove("up",reason,true,false) then appendInverse(rollback,"U"); return true end; return false end
  if action=="D" then if rawMove("down",reason,true,false) then appendInverse(rollback,"D"); return true end; return false end
  return false
end
local function rollbackPath(rollback)
  state.status="ROLLING_BACK"; saveState(); state.stats.rollbacks=(state.stats.rollbacks or 0)+1
  for i=#rollback,1,-1 do local a=rollback[i]; if a=="L" then turnLeft() elseif a=="R" then turnRight() elseif a=="U" then rawMove("up","rollback",false,false) elseif a=="D" then rawMove("down","rollback",false,false) elseif a=="B" then if turtleBack() then local d=DIRS[state.facing]; state.pos={x=state.pos.x-d.dx,y=state.pos.y,z=state.pos.z-d.dz}; saveState() else return false end end end
  return gpsCheck(true)
end
local function tryBypassPath(actions, label)
  local start=copy(state.pos); local sf=state.facing; local rb={}; state.status="BYPASS_"..label; saveState()
  for _,a in ipairs(actions) do if not runAction(a,rb,"bypass") then rollbackPath(rb); face(sf); if not samePos(state.pos,start) then gpsCheck(true) end; return false end end
  if not gpsCheck(true) then rollbackPath(rb); face(sf); return false end
  state.stats.bypasses=(state.stats.bypasses or 0)+1; state.status="WORKING"; saveState(); return true
end
function attemptBypassProtected(name, reason)
  if shouldInterruptMovement() then return false end
  report("BYPASS_ATTEMPT",{name=name,pos=copy(state.pos),taskId=state.task and state.task.id})
  local h=state.job and state.job.layerHeight or 1

  local function repeatAction(action, count)
    local t={}
    for i=1,count do table.insert(t,action) end
    return t
  end
  local function join(...)
    local out={}
    for _,part in ipairs({...}) do
      for _,a in ipairs(part) do table.insert(out,a) end
    end
    return out
  end

  -- Height 2: try under-routes with increasing forward clearance.
  -- The turtle goes down, moves forward far enough to clear the protected block,
  -- then comes back up only after it is past the obstruction.
  if h==2 then
    for forwardDist=2,BYPASS_LIMIT do
      if shouldInterruptMovement() then return false end
      if tryBypassPath(join({"D"},repeatAction("F",forwardDist),{"U"}),"UNDER_"..forwardDist) then return true end
    end
  end

  -- Height >=3: try over-routes with increasing forward clearance.
  -- It must move over AND past the protected block before descending.
  if h>=3 then
    for forwardDist=2,BYPASS_LIMIT do
      if shouldInterruptMovement() then return false end
      if tryBypassPath(join({"U"},repeatAction("F",forwardDist),{"D"}),"OVER_"..forwardDist) then return true end
    end
  end

  -- Side bypasses expand outward and forward from the problem point.
  -- Pattern: sidestep N, move forward M, return to the original line, then continue.
  -- This fixes the monitor/chest case where a 1-wide sidestep or 2-forward jog is not enough.
  for sideDist=1,BYPASS_LIMIT do
    for forwardDist=2,BYPASS_LIMIT do
      if shouldInterruptMovement() then return false end
      local leftPath = join({"L"},repeatAction("F",sideDist),{"R"},repeatAction("F",forwardDist),{"R"},repeatAction("F",sideDist),{"L"})
      if tryBypassPath(leftPath,"LEFT_"..sideDist.."_"..forwardDist) then return true end
      if shouldInterruptMovement() then return false end
      local rightPath = join({"R"},repeatAction("F",sideDist),{"L"},repeatAction("F",forwardDist),{"L"},repeatAction("F",sideDist),{"R"})
      if tryBypassPath(rightPath,"RIGHT_"..sideDist.."_"..forwardDist) then return true end
    end
  end

  local tries = bumpProblemRetry(name)
  report("BYPASS_RETRY",{name=name,pos=copy(state.pos),taskId=state.task and state.task.id,attempt=tries,limit=3})

  -- First two failures on the same obstruction return to origin and retry the same path.
  -- Third failure marks the task/quadrant as Problem so the controller can skip it and assign the next task.
  if tries < 3 and state.job and state.task then
    pcall(function() returnToOrigin() end)
    return false
  end

  return reportProblem("Unable to bypass protected/ignored block after 3 origin retries: "..tostring(name),{name=name,limit=BYPASS_LIMIT,attempts=tries})
end
local function moveChecked(dir, reason) return rawMove(dir, reason, true, true) end

-- Plan an X/Z route that stays inside the active job volume.
-- This is used whenever straight-line X-then-Z or Z-then-X travel would clip
-- outside a cylinder/dome/cone/stretched shape. It does not allow the miner to
-- leave the work area; every planned step must pass insideShape(job, pos).
local function keyXZ(x,z) return tostring(x)..","..tostring(z) end
local function planPathInsideJob(target)
  if not state.job or not target or not state.pos then return nil,"no active job" end
  if state.pos.y ~= target.y then return nil,"path planner requires same Y" end
  local y = state.pos.y
  local start = {x=state.pos.x,y=y,z=state.pos.z}
  local goal = {x=target.x,y=y,z=target.z}
  if samePos(start, goal) then return {} end
  if not insideShape(state.job,start) then return nil,"current position is outside job volume" end
  if not insideShape(state.job,goal) then return nil,"target is outside job volume" end

  local b = state.job.fullBounds
  if not b then return nil,"job has no full bounds" end

  local q = {{x=start.x,z=start.z}}
  local qi = 1
  local startKey = keyXZ(start.x,start.z)
  local goalKey = keyXZ(goal.x,goal.z)
  local came = {[startKey] = false}
  local cameDir = {}
  local nodes = 0
  local maxNodes = 50000
  local dirs = {
    {name="east",  dx= 1, dz= 0},
    {name="west",  dx=-1, dz= 0},
    {name="south", dx= 0, dz= 1},
    {name="north", dx= 0, dz=-1},
  }

  while qi <= #q do
    local cur = q[qi]; qi = qi + 1
    nodes = nodes + 1
    if nodes > maxNodes then return nil,"path search exceeded safety limit" end

    for _,d in ipairs(dirs) do
      local nx,nz = cur.x + d.dx, cur.z + d.dz
      if nx >= b.minX and nx <= b.maxX and nz >= b.minZ and nz <= b.maxZ then
        local np = {x=nx,y=y,z=nz}
        if insideShape(state.job,np) then
          local k = keyXZ(nx,nz)
          if came[k] == nil then
            came[k] = keyXZ(cur.x,cur.z)
            cameDir[k] = d.name
            if k == goalKey then
              local out = {}
              local walk = k
              while walk ~= startKey do
                table.insert(out,1,cameDir[walk])
                walk = came[walk]
              end
              return out
            end
            q[#q+1] = {x=nx,z=nz}
          end
        end
      end
    end
  end
  return nil,"no in-volume path to target"
end

local function routeInsideJob(target, reason)
  local path, why = planPathInsideJob(target)
  if not path then return reportProblem("No valid in-volume route: "..tostring(why),{target=target}) end
  state.status="PATHING"; saveState(); heartbeat()
  for _,f in ipairs(path) do
    if shouldInterruptMovement() then return false end
    face(f)
    if not moveChecked("forward", reason or "work") then return false end
  end
  return gpsCheck(false)
end

-- ---------- routing ----------
function goY(y, reason)
  while state.pos.y<y do if shouldInterruptMovement() then return false end; if not moveChecked("up",reason) then return false end end
  while state.pos.y>y do if shouldInterruptMovement() then return false end; if not moveChecked("down",reason) then return false end end
  return true
end
function goX(x, reason)
  while state.pos.x<x do if shouldInterruptMovement() then return false end; face("east"); if not moveChecked("forward",reason) then return false end end
  while state.pos.x>x do if shouldInterruptMovement() then return false end; face("west"); if not moveChecked("forward",reason) then return false end end
  return true
end
function goZ(z, reason)
  while state.pos.z<z do if shouldInterruptMovement() then return false end; face("south"); if not moveChecked("forward",reason) then return false end end
  while state.pos.z>z do if shouldInterruptMovement() then return false end; face("north"); if not moveChecked("forward",reason) then return false end end
  return true
end
function goTo(p, reason)
  if not gpsCheck(true) then return false end
  if not p then return false end

  -- Home -> origin special case:
  -- A miner sits on layer 2 with the deposit chest directly below it.
  -- When later passes use a lower travelY, changing Y first makes the turtle
  -- try to move down into its own protected deposit chest.
  -- While physically at home and heading to origin, leave the rack horizontally
  -- at the current home Y first, then change Y only after reaching origin X/Z.
  if reason == "origin" and state.home and samePos(state.pos, state.home) and p.y ~= state.pos.y then
    if not goX(p.x, reason) then return false end
    if not goZ(p.z, reason) then return false end
    if not goY(p.y, reason) then return false end
    return gpsCheck(true)
  end

  -- Work/origin travel inside shaped jobs must not use blind X-then-Z routing.
  -- For circles, domes, cones, stretched cylinders, etc., a straight axis route can
  -- briefly step outside the shape even though another legal route exists. Plan the
  -- horizontal route inside the work volume instead.
  if state.job and state.pos and p.y == state.pos.y and insideShape(state.job,p) and (reason=="work" or reason=="bypass" or reason=="origin") then
    return routeInsideJob(p, reason)
  end

  -- If vertical movement is needed, change Y first only when each vertical step is
  -- still legal. After reaching the target Y, use the in-volume router when possible.
  if not goY(p.y,reason) then return false end
  if state.job and state.pos and p.y == state.pos.y and insideShape(state.job,p) and (reason=="work" or reason=="bypass" or reason=="origin") then
    return routeInsideJob(p, reason)
  end

  -- Non-work routes, such as explicit home corridors, keep the older corridor logic.
  if not goX(p.x,reason) then return false end
  if not goZ(p.z,reason) then return false end
  return gpsCheck(true)
end

-- ---------- home setup ----------
local function promptFacing() while true do header("Home Facing"); print("Set the direction this turtle is facing at home:"); print("1 north\n2 east\n3 south\n4 west"); local n=tonumber(read()); if n and ORDER[n] then return ORDER[n] end end end
local function inspectChest(dir) local n=blockName(dir); return n and (n:find("chest",1,true) or n:find("barrel",1,true) or n:find("shulker",1,true)) end
local function setupHome() local ok,why=gpsQuorum(); if not ok then header("GPS Failed"); print(why); sleep(2); return false end if not inspectChest("down") then header("Home Setup"); print("Deposit chest/barrel/shulker must be below turtle."); return false end if not inspectChest("up") then header("Home Setup"); print("Fuel/Torch/Filler chest must be above turtle."); return false end state.home=copy(state.pos); state.homeFacing=state.homeFacing or promptFacing(); state.facing=state.homeFacing; state.homeValid=true; state.atHome=true; state.status="AT_HOME"; saveState(); return true end
local function isAtHome() return state.home and samePos(state.pos,state.home) end

-- ---------- origin lock ----------
local function claimOriginLock()
  if not state.controllerId then return false,"no controller" end
  local lockId = tostring(os.getComputerID())..":"..tostring(state.task and state.task.id or "none")
  send(state.controllerId,{type="ORIGIN_LOCK_REQUEST",payload={jobId=state.job.id,taskId=state.task.id,lockId=lockId,pos=copy(state.pos)}})
  local deadline=os.clock()+ORIGIN_LOCK_TIMEOUT
  while os.clock()<deadline do local id,msg=rednet.receive(PROTOCOL,1); if id and validPacket(msg) then handlePacket(id,msg); if msg.type=="ORIGIN_LOCK_GRANTED" and msg.payload and msg.payload.lockId==lockId then state.originLockHeld=true; saveState(); return true end if msg.type=="ORIGIN_LOCK_DENIED" and msg.payload and msg.payload.lockId==lockId then sleep(1) end end end
  return false,"origin lock timeout"
end
local function releaseOriginLock() if state.originLockHeld and state.controllerId then send(state.controllerId,{type="ORIGIN_LOCK_RELEASE",payload={jobId=state.job and state.job.id,taskId=state.task and state.task.id}}) end state.originLockHeld=false; saveState() end

-- ---------- torch placement ----------
local function placeTorchIfNeeded(x,z)
  if not state.job or state.job.torchMode~="replaced" then return end
  if not state.task or state.task.passIndex~=1 then return end
  local spacing=state.job.torchSpacing or 8
  if ((x-state.job.origin.x)%spacing~=0) or ((z-state.job.origin.z)%spacing~=0) then return end
  local n,c=itemName(TORCH_SLOT); if not VALID_TORCH[n] or c<=0 then return end
  turtle.select(TORCH_SLOT); turtle.placeDown()
end

-- ---------- mining ----------
local function shouldPreserveColumnBlock(n)
  if not n then return false end
  if isProtectedName(n) then return true end
  if isTorchName(n) and state.job then
    if state.job.torchMode == "ignored" then return true end
    if state.job.torchMode == "replaced" and state.task and state.task.passIndex > 1 then return true end
  end
  return false
end

local function skipProtectedColumnBlock(dir, name)
  state.stats.protectedSkips = (state.stats.protectedSkips or 0) + 1
  state.lastProblem = "Skipped protected block " .. tostring(name) .. " " .. tostring(dir)
  saveState()
  report("PROTECTED_SKIPPED", {
    direction = dir,
    name = name,
    pos = copy(state.pos),
    taskId = state.task and state.task.id,
    jobId = state.job and state.job.id
  })
  return true
end

local function digVerticalIfAllowed(dir)
  local n = blockName(dir)
  if not n then return true end

  -- Protected blocks inside a column are not job-ending.
  -- The miner is allowed to leave that single block in place, then continue the route.
  -- This is what should happen for chests/monitors/computers hanging above the pass.
  if shouldPreserveColumnBlock(n) then
    return skipProtectedColumnBlock(dir, n)
  end

  if dir == "up" then
    if not rawMove("up", "work", true, false) then return false end
    return rawMove("down", "work", true, false)
  elseif dir == "down" then
    if not rawMove("down", "work", true, false) then return false end
    return rawMove("up", "work", true, false)
  end
  return true
end

local function digColumnAroundTravel()
  local b = state.task.bounds
  if b.maxY > state.pos.y then
    if not digVerticalIfAllowed("up") then return false end
  end
  if b.minY < state.pos.y then
    if not digVerticalIfAllowed("down") then return false end
  end
  return true
end
local function mineColumnAt(x,z)
  if not insideShape(state.job,{x=x,y=state.task.travelY,z=z}) then return true end
  if not goTo({x=x,y=state.task.travelY,z=z},"work") then return false end
  if not digColumnAroundTravel() then return false end
  placeTorchIfNeeded(x,z); return true
end
returnToOrigin = function()
  local o=originPos(); if not o then return false end
  state.routePhase="to_origin"; state.status="MOVING_TO_ORIGIN"; saveState(); local ok=goTo(o,"origin"); state.routePhase="idle"; if ok then report("AT_ORIGIN",{pos=copy(state.pos),taskId=state.task and state.task.id}) end return ok
end
local function workTask()
  if returnRequested then return false end
  if not state.job or not state.task then return false end
  if (state.protectedRevision or 0) < (state.assignment and state.assignment.protectedRevision or 0) then report("PROTECTED_REQUEST",{}); sleep(1) end
  state.status="CLAIMING_ORIGIN"; heartbeat(); local ok,why=claimOriginLock(); if not ok then return reportProblem("Could not claim origin movement lock: "..tostring(why)) end
  if not returnToOrigin() then releaseOriginLock(); return reportProblem("Could not reach origin") end
  releaseOriginLock()
  state.status="WORKING"; state.routePhase="work"; saveState(); heartbeat()
  local b=state.task.bounds
  for z=b.minZ,b.maxZ do if shouldInterruptMovement() then return false end; local xStart,xEnd,xStep=b.minX,b.maxX,1; if (z-b.minZ)%2==1 then xStart,xEnd,xStep=b.maxX,b.minX,-1 end; local x=xStart; while (xStep==1 and x<=xEnd) or (xStep==-1 and x>=xEnd) do if shouldInterruptMovement() then return false end; fuelIfNeeded(); local svc,whySvc=needsService(); if svc then local resume={x=x,y=state.task.travelY,z=z}; if not returnToOrigin() then return false end; if not serviceInventory() then return reportProblem("Supplies unavailable: "..tostring(whySvc)) end; if not returnToOrigin() then return false end; state.routePhase="work"; if not goTo(resume,"work") then return false end else if not mineColumnAt(x,z) then return false end; x=x+xStep end end end
  state.routePhase="to_origin"; returnToOrigin(); state.routePhase="to_home"; serviceInventory(); state.routePhase="idle"
  local taskId=state.task.id; state.status="IDLE"; state.assignment=nil; state.task=nil; state.job=nil; paused=false; saveState(); report("TASK_COMPLETE",{taskId=taskId,pos=copy(state.pos)}); return true
end

-- ---------- emergency / command handling ----------
local function emergencyReturn(reason)
  returnRequested=false; returnReason=nil
  state.killMode=true; state.status="EMERGENCY_RETURN"; saveState(); heartbeat(); paused=false
  if state.job and state.task then pcall(returnToOrigin) end
  state.routePhase="to_home"
  local ok = state.home and pcall(function() return goTo(state.home,"home") end)
  local at = false; if ok then gpsCheck(true); at=isAtHome() end
  if not at then markRogue(reason or "Emergency return failed") end
  state.status="AT_HOME"; state.killMode=false; state.routePhase="idle"; saveState(); heartbeat(); report("AT_HOME",{emergency=true,pos=copy(state.pos)})
end
function handlePacket(id,msg)
  if not validPacket(msg) then return end
  if msg.type=="REGISTER_ACK" then state.controllerId=id; if msg.payload and msg.payload.killSwitch and msg.payload.killSwitch.active then emergencyReturn("Controller kill switch active on register") end; if msg.payload and msg.payload.protectedRevision and msg.payload.protectedRevision>state.protectedRevision then send(id,{type="PROTECTED_REQUEST",payload={}}) end; saveState()
  elseif msg.type=="PROTECTED_LIST" then state.controllerId=id; loadProtected(msg.payload)
  elseif msg.type=="ROLL_CALL" then heartbeat()
  elseif msg.type=="PAUSE_JOB" then paused=true; state.status="PAUSED"; saveState(); heartbeat()
  elseif msg.type=="RESUME_JOB" then paused=false; state.status="IDLE"; saveState(); heartbeat()
  elseif msg.type=="GO_HOME" then requestReturnHome("Controller ordered home")
  elseif msg.type=="CANCEL_JOB" then if (not state.job) or (msg.payload and msg.payload.jobId==state.job.id) then requestReturnHome("Job cancelled") end
  elseif msg.type=="EMERGENCY_STOP_RETURN" then requestReturnHome("Controller kill switch")
  elseif msg.type=="KILL_SWITCH_CLEAR" then if state.rogue and isAtHome() then state.rogue=false; state.status="AT_HOME"; pcall(os.setComputerLabel,"Miner-"..os.getComputerID()); saveState() end
  elseif msg.type=="TASK_ASSIGN" then if state.rogue then report("ROGUE",{reason="Rogue turtle refused task",pos=copy(state.pos)}); return end; state.controllerId=id; state.assignment=copy(msg.payload); state.job=copy(msg.payload.job); state.task=copy(msg.payload.task); state.assignment.protectedRevision=msg.payload.protectedRevision or 0; state.status="ASSIGNED"; saveState(); heartbeat()
  end
end

-- ---------- loops ----------
local function networkLoop() while running do local id,msg=rednet.receive(PROTOCOL,1); if id then handlePacket(id,msg) end end end
local function heartbeatLoop() while running do heartbeat(); sleep(HEARTBEAT_INTERVAL) end end
local function workLoop() while running do if state.rogue then sleep(2) elseif returnRequested then emergencyReturn(returnReason or "Return requested") elseif state.job and state.task and not paused then workTask() else sleep(1) end end end
local function displayLoop() while running do header("Status"); print("ID: "..os.getComputerID()); print("Status: "..tostring(state.status)); term.write("Pos: "); writeCoord(state.pos); print(""); term.write("Home: "); writeCoord(state.home); print(""); print("Facing: "..tostring(state.facing)); print("GPS: "..tostring(state.gpsValid).."  Home valid: "..tostring(state.homeValid)); print("Inventory valid: "..tostring(state.inventoryValid)); print("Protected rev: "..tostring(state.protectedRevision)); print("Task: "..tostring(state.task and state.task.id or "none")); if turtle.getFuelLevel then print("Fuel level: "..tostring(turtle.getFuelLevel())) end; if state.rogue then color(colors.red); print("ROGUE LOCK: place turtle at saved home and reboot."); color(colors.lightGray) end if state.lastProblem then color(colors.red); print("Problem: "..tostring(state.lastProblem)); color(colors.lightGray) end sleep(2) end end

-- ---------- boot ----------
local function boot()
  ensureDir(); loadState(); header("Boot"); if not openModem() then print("No modem found."); return false end
  local ok,why=gpsQuorum(); if not ok then print("GPS invalid: "..tostring(why)); sleep(2); return false end
  if state.rogue then if state.home and samePos(state.pos,state.home) then state.rogue=false; state.status="AT_HOME"; pcall(os.setComputerLabel,"Miner-"..os.getComputerID()); saveState() else header("ROGUE LOCK"); print("This turtle was marked Rogue."); print("Saved home:"); writeCoord(state.home); print(""); print("Current GPS:"); writeCoord(state.pos); print(""); print("Place it back at saved home and reboot."); return false end end
  if not state.homeValid or not state.home then if not setupHome() then return false end else state.atHome=samePos(state.pos,state.home); if not state.atHome then header("Not At Home"); print("Saved home:"); writeCoord(state.home); print(""); print("Current:"); writeCoord(state.pos); print(""); print("Move turtle back home or clear data."); return false end end
  if not serviceInventory() then header("Inventory"); print("Could not validate fuel/filler/torches from upper chest."); sleep(2) end
  state.status=state.inventoryValid and "AT_HOME" or "NEEDS_SUPPLIES"; saveState(); register(); return true
end
if boot() then parallel.waitForAny(networkLoop,heartbeatLoop,workLoop,displayLoop) end
