-- SquirtleSquad-Miner v1
-- MinerTurtle/startup.lua
-- Miner lead unit. Compact state, dead reckoning, formula-generated excavation.

local PROTOCOL = "TurtleTeamNet"
local PROJECT = "SquirtleSquad-Miner"
local VERSION = "v1"
local DATA_DIR = "SquirtleSquadData"
local STATE_FILE = DATA_DIR .. "/miner_state.dat"

local state = {
  role="miner",
  label="Miner-"..os.getComputerID(),
  controllerId=nil,
  agentId=nil,
  status="BOOTING",
  paused=false,
  teamId=nil,
  foremanNet=nil,
  job=nil,
  sector=nil,
  storage=nil,
  deployHold=true,
  pos=nil,
  facing=nil,
  calibrated=false,
  progress=0,
  complete=false,
  originReached=false
}

local running=true
local modemSide=nil
local lastHeartbeat=0

local DIRS = {
  north={x=0,z=-1,left="west",right="east",back="south"},
  east={x=1,z=0,left="north",right="south",back="west"},
  south={x=0,z=1,left="east",right="west",back="north"},
  west={x=-1,z=0,left="south",right="north",back="east"}
}

local protectedNeedles = {
  "chest","barrel","shulker","turtle","computer","modem","monitor","drive",
  "display_link","scaffold","scaffolding","create:display_link"
}

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
      if ok and type(t)=="table" then for k,v in pairs(t) do state[k]=v end end
    end
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
local function sendTo(id,msg) if id then msg.project=PROJECT; msg.version=VERSION; rednet.send(id,msg,PROTOCOL) end end
local function status(s) state.status=s; save() end

local function header()
  term.clear(); term.setCursorPos(1,1)
  if term.isColor() then term.setTextColor(colors.cyan) end
  print("🐢 "..PROJECT.." "..VERSION.." 🐢")
  if term.isColor() then term.setTextColor(colors.white) end
  print("Miner Turtle: "..state.label)
  print("Status: "..tostring(state.status))
  print("Team: "..tostring(state.teamId or "none"))
  if state.pos then print("Pos: "..state.pos.x..","..state.pos.y..","..state.pos.z.." facing "..tostring(state.facing)) end
  print("")
end

local function inspectIsProtected(inspector)
  local ok,data=inspector()
  if not ok or not data or not data.name then return false,nil end
  local name=string.lower(data.name)
  if name:find("torch") then return false,data end
  for _,n in ipairs(protectedNeedles) do if name:find(n,1,true) then return true,data end end
  return false,data
end

local function isTorch(data) return data and data.name and string.lower(data.name):find("torch") ~= nil end

local function refuelIfNeeded()
  if turtle.getFuelLevel()=="unlimited" then return true end
  if turtle.getFuelLevel() > 200 then return true end
  turtle.select(1)
  if turtle.getItemCount(1)>0 then turtle.refuel(math.min(8,turtle.getItemCount(1))) end
  return turtle.getFuelLevel()=="unlimited" or turtle.getFuelLevel()>50
end

local function mergeFiller()
  local detail=turtle.getItemDetail(2)
  if not detail then return end
  for i=3,15 do
    local d=turtle.getItemDetail(i)
    if d and d.name==detail.name then turtle.select(i); turtle.transferTo(2) end
  end
  turtle.select(1)
end

local function turnLeft()
  turtle.turnLeft()
  if state.facing then state.facing=DIRS[state.facing].left end
  save()
  sendTo(state.foremanNet,{type="MINER_TURNED_LEFT",teamId=state.teamId,pos=state.pos,facing=state.facing})
end
local function turnRight()
  turtle.turnRight()
  if state.facing then state.facing=DIRS[state.facing].right end
  save()
  sendTo(state.foremanNet,{type="MINER_TURNED_RIGHT",teamId=state.teamId,pos=state.pos,facing=state.facing})
end
local function turnTo(dir)
  if not state.facing then state.facing=dir return end
  local guard=0
  while state.facing~=dir and guard<4 do
    turnRight(); guard=guard+1
  end
end

local function updateForward()
  local d=DIRS[state.facing or "north"]
  state.pos.x=state.pos.x+d.x; state.pos.z=state.pos.z+d.z
end
local function updateBack()
  local d=DIRS[state.facing or "north"]
  state.pos.x=state.pos.x-d.x; state.pos.z=state.pos.z-d.z
end

local function requestForemanMove()
  if state.foremanNet then
    sendTo(state.foremanNet,{type="FOREMAN_MOVE_REQUEST",teamId=state.teamId,pos=state.pos,facing=state.facing})
    local timer=os.startTimer(4)
    while true do
      local ev,a,b,c = os.pullEvent()
      if ev=="rednet_message" then
        local sender,msg,proto=a,b,c
        if proto==PROTOCOL and sender==state.foremanNet and type(msg)=="table" and msg.type=="FOREMAN_MOVED" then return true end
      elseif ev=="timer" and a==timer then return false end
    end
  end
  return false
end

local function digForwardIfSafe()
  local prot,data=inspectIsProtected(turtle.inspect)
  if prot then
    requestForemanMove()
    prot,data=inspectIsProtected(turtle.inspect)
    if prot then return false,"protected" end
  end
  if data then turtle.dig() end
  return true
end
local function digUpIfSafe()
  local prot,data=inspectIsProtected(turtle.inspectUp)
  if prot then return false,"protected" end
  if data then turtle.digUp() end
  return true
end
local function digDownIfSafe()
  local prot,data=inspectIsProtected(turtle.inspectDown)
  if prot then return false,"protected" end
  if data then turtle.digDown() end
  return true
end

local function moveForwardRaw()
  refuelIfNeeded()
  for i=1,3 do
    if turtle.forward() then updateForward(); save(); sendTo(state.foremanNet,{type="MINER_MOVED_FORWARD",teamId=state.teamId,pos=state.pos,facing=state.facing}); return true end
    local ok,why=digForwardIfSafe()
    if not ok and why=="protected" then return false,"protected" end
    sleep(0.2)
  end
  return false,"blocked"
end
local function moveUpRaw()
  refuelIfNeeded()
  for i=1,3 do
    if turtle.up() then state.pos.y=state.pos.y+1; save(); sendTo(state.foremanNet,{type="MINER_MOVED_UP",teamId=state.teamId,pos=state.pos,facing=state.facing}); return true end
    local ok,why=digUpIfSafe()
    if not ok then return false,why end
    sleep(0.2)
  end
  return false,"blocked"
end
local function moveDownRaw()
  refuelIfNeeded()
  for i=1,3 do
    if turtle.down() then state.pos.y=state.pos.y-1; save(); sendTo(state.foremanNet,{type="MINER_MOVED_DOWN",teamId=state.teamId,pos=state.pos,facing=state.facing}); return true end
    local ok,why=digDownIfSafe()
    if not ok then return false,why end
    sleep(0.2)
  end
  return false,"blocked"
end

local function moveAroundProtected()
  -- Try up/side/down detours up to 10 moves. If impossible, caller returns to origin and retries later.
  local start={x=state.pos.x,y=state.pos.y,z=state.pos.z,f=state.facing}
  for lift=1,10 do
    local moved={}
    local ok=true
    for i=1,lift do local a,b=moveUpRaw(); if not a then ok=false; break end; table.insert(moved,"up") end
    if ok then
      local a,b=moveForwardRaw()
      if a then return true end
    end
    -- Return approximate to start height
    while state.pos.y>start.y do moveDownRaw() end
    turnRight()
    local sideOk=moveForwardRaw()
    turnLeft()
    if sideOk then
      local a=moveForwardRaw()
      if a then
        turnLeft(); moveForwardRaw(); turnRight()
        return true
      end
    end
    -- best effort back
    turnTo(start.f)
  end
  return false
end

local function safeForward()
  local ok,why=moveForwardRaw()
  if ok then return true end
  if why=="protected" then return moveAroundProtected() end
  return false
end

local function goY(y)
  while state.pos.y < y do if not moveUpRaw() then return false end end
  while state.pos.y > y do if not moveDownRaw() then return false end end
  return true
end
local function goX(x)
  if state.pos.x < x then turnTo("east") while state.pos.x<x do if not safeForward() then return false end end
  elseif state.pos.x > x then turnTo("west") while state.pos.x>x do if not safeForward() then return false end end end
  return true
end
local function goZ(z)
  if state.pos.z < z then turnTo("south") while state.pos.z<z do if not safeForward() then return false end end
  elseif state.pos.z > z then turnTo("north") while state.pos.z>z do if not safeForward() then return false end end end
  return true
end
local function gotoXYZ(p)
  -- Move vertically above floor first for safer travel, then horizontal, then exact Y.
  local travelY=math.max(state.pos.y, p.y)
  if not goY(travelY) then return false end
  if not goX(p.x) then return false end
  if not goZ(p.z) then return false end
  if not goY(p.y) then return false end
  return true
end

local function faceForTask(p)
  local b=state.sector and state.sector.fullBounds or state.sector.bounds
  if not b then return "north" end
  local cx=(b.minX+b.maxX)/2; local cz=(b.minZ+b.maxZ)/2
  local dx=p.x-cx; local dz=p.z-cz
  if math.abs(dx)>math.abs(dz) then return dx>=0 and "west" or "east" else return dz>=0 and "north" or "south" end
end

local function pointLineDistanceSquared(px,py,pz, ax,ay,az, bx,by,bz)
  local vx,vy,vz=bx-ax,by-ay,bz-az
  local wx,wy,wz=px-ax,py-ay,pz-az
  local c1=wx*vx+wy*vy+wz*vz
  local c2=vx*vx+vy*vy+vz*vz
  local t=0
  if c2>0 then t=math.max(0,math.min(1,c1/c2)) end
  local qx,qy,qz=ax+t*vx,ay+t*vy,az+t*vz
  local dx,dy,dz=px-qx,py-qy,pz-qz
  return dx*dx+dy*dy+dz*dz
end

local function splinePoint(job,t)
  -- Shallow quadratic Bezier: control at midpoint, y biased to average to avoid steep peaks/dips.
  local ax,ay,az=job.a.x,job.a.y,job.a.z
  local bx,by,bz=job.b.x,job.b.y,job.b.z
  local cx=(ax+bx)/2
  local cy=(ay+by)/2
  local cz=(az+bz)/2
  local u=1-t
  return {
    x=u*u*ax+2*u*t*cx+t*t*bx,
    y=u*u*ay+2*u*t*cy+t*t*by,
    z=u*u*az+2*u*t*cz+t*t*bz
  }
end

local function pointSplineDistanceSquared(px,py,pz,job)
  local best=1e9
  local prev=splinePoint(job,0)
  for i=1,32 do
    local cur=splinePoint(job,i/32)
    local d=pointLineDistanceSquared(px,py,pz,prev.x,prev.y,prev.z,cur.x,cur.y,cur.z)
    if d<best then best=d end
    prev=cur
  end
  return best
end

local function inside(job,x,y,z)
  if not job then return false end
  if job.shape=="rect" then
    local minX,maxX=math.min(job.a.x,job.b.x),math.max(job.a.x,job.b.x)
    local minY,maxY=math.min(job.a.y,job.b.y),math.max(job.a.y,job.b.y)
    local minZ,maxZ=math.min(job.a.z,job.b.z),math.max(job.a.z,job.b.z)
    return x>=minX and x<=maxX and y>=minY and y<=maxY and z>=minZ and z<=maxZ
  elseif job.shape=="cylinder" then
    if y<job.origin.y or y>job.origin.y+job.height-1 then return false end
    local dx,dz=x-job.origin.x,z-job.origin.z
    return dx*dx+dz*dz <= job.radius*job.radius
  elseif job.shape=="dome" then
    if y<job.origin.y or y>job.origin.y+job.radius then return false end
    local dx,dy,dz=x-job.origin.x,y-job.origin.y,z-job.origin.z
    return dx*dx+dy*dy+dz*dz <= job.radius*job.radius
  elseif job.shape=="stretched_cylinder" then
    return pointLineDistanceSquared(x,y,z,job.a.x,job.a.y,job.a.z,job.b.x,job.b.y,job.b.z) <= job.radius*job.radius
  elseif job.shape=="pyramid" then
    if y<job.origin.y or y>job.origin.y+job.height-1 then return false end
    local level=y-job.origin.y
    local r=math.max(0, job.radius*(1-level/math.max(1,job.height)))
    return math.abs(x-job.origin.x)<=r and math.abs(z-job.origin.z)<=r
  elseif job.shape=="cone" then
    if y<job.origin.y or y>job.origin.y+job.height-1 then return false end
    local level=y-job.origin.y
    local r=math.max(0, job.radius*(1-level/math.max(1,job.height)))
    local dx,dz=x-job.origin.x,z-job.origin.z
    return dx*dx+dz*dz <= r*r
  elseif job.shape=="tunnel" then
    local r=math.max(job.width or 3,job.height or job.width or 3)/2
    return pointLineDistanceSquared(x,y,z,job.a.x,job.a.y,job.a.z,job.b.x,job.b.y,job.b.z) <= r*r
  elseif job.shape=="tunnel_spline" then
    local r=math.max(job.width or 3,job.height or job.width or 3)/2
    return pointSplineDistanceSquared(x,y,z,job) <= r*r
  end
  return false
end

local function sectorPointFromIndex(idx)
  local b=state.sector.bounds
  local widthX=b.maxX-b.minX+1
  local widthZ=b.maxZ-b.minZ+1
  local layerSize=widthX*widthZ
  local y=b.minY+math.floor(idx/layerSize)
  if y>b.maxY then return nil end
  local rem=idx%layerSize
  local zOff=math.floor(rem/widthX)
  local xOff=rem%widthX
  if zOff%2==1 then xOff=widthX-1-xOff end
  return {x=b.minX+xOff,y=y,z=b.minZ+zOff}
end

local function nextExcavationPoint()
  local b=state.sector.bounds
  local maxCount=(b.maxX-b.minX+1)*(b.maxY-b.minY+1)*(b.maxZ-b.minZ+1)
  while state.progress < maxCount do
    local p=sectorPointFromIndex(state.progress)
    state.progress=state.progress+1
    if p and inside(state.job,p.x,p.y,p.z) then save(); return p end
  end
  return nil
end

local function placeTorchIfNeeded(p)
  if not state.job or not p then return end
  local spacing=state.job.torchSpacing or 8
  if p.y == (state.sector.fullBounds and state.sector.fullBounds.minY or state.sector.bounds.minY) and ((math.abs(p.x)+math.abs(p.z)) % spacing == 0) then
    turtle.select(16)
    if turtle.getItemCount(16)>0 then turtle.placeDown() end
  end
  turtle.select(1)
end

local function fillOvercutsNear(p)
  -- conservative repair: if block below is outside intended shape and empty, place filler.
  if p and p.y > (state.sector.fullBounds and state.sector.fullBounds.minY or state.sector.bounds.minY) then
    local belowInside=inside(state.job,p.x,p.y-1,p.z)
    local ok,data=turtle.inspectDown()
    if not belowInside and not ok and turtle.getItemCount(2)>0 then turtle.select(2); turtle.placeDown(); turtle.select(1) end
  end
end

local function needsService()
  if turtle.getItemCount(16)<8 then return true end
  if turtle.getItemCount(2)<16 then return true end
  for i=3,15 do if turtle.getItemCount(i)==0 then return false end end
  return true
end

local function dumpAndRestock()
  if not state.storage or not state.storage.dump or not state.storage.supply then return false end
  status("SERVICE_RETURN")
  local returnPos={x=state.pos.x,y=state.pos.y,z=state.pos.z,f=state.facing}
  sendTo(state.foremanNet,{type="SERVICE_RETURN",teamId=state.teamId})
  gotoXYZ(state.storage.dump)
  for i=3,15 do turtle.select(i); turtle.drop() end
  gotoXYZ(state.storage.supply)
  -- Slot 1 fuel
  turtle.select(1); turtle.suck(64-turtle.getItemCount(1))
  -- Slot 2 filler
  turtle.select(2); turtle.suck(64-turtle.getItemCount(2))
  -- Slot 16 torches
  turtle.select(16); turtle.suck(64-turtle.getItemCount(16))
  turtle.select(1)
  mergeFiller()
  gotoXYZ(returnPos)
  turnTo(returnPos.f)
  status("MINING")
  return true
end

local function calibrate()
  status("WAITING_FOR_GPS")
  while not state.calibrated do
    local x,y,z=gps.locate(10)
    if x and y and z then
      state.pos={x=math.floor(x+0.5),y=math.floor(y+0.5),z=math.floor(z+0.5)}
      -- Facing cannot be read from GPS. Use current forward movement probe if possible.
      state.facing=state.facing or "north"
      state.calibrated=true
      save()
      status("CALIBRATED")
      return true
    end
    if state.pos and state.facing then
      state.calibrated=true
      status("RECOVERED_DEAD_RECKONING")
      return true
    end
    sleep(3)
  end
  return true
end

local function originForJob()
  local job=state.job
  if job.origin then return {x=job.origin.x,y=job.origin.y,z=job.origin.z} end
  if job.a then return {x=job.a.x,y=job.a.y,z=job.a.z} end
  return {x=state.sector.bounds.minX,y=state.sector.bounds.minY,z=state.sector.bounds.minZ}
end

local function waitForDeploy()
  status("ASSIGNED_WAITING_DEPLOY")
  while state.deployHold do sleep(1) end
end

local function mineLoop()
  if not state.job or not state.sector then status("LISTENING"); return end
  calibrate()
  waitForDeploy()
  status("MOVE_TO_ORIGIN")
  local origin=originForJob()
  gotoXYZ({x=origin.x,y=origin.y+1,z=origin.z})
  state.originReached=true; save()
  send({type="TEAM_READY_AT_ORIGIN",teamId=state.teamId,jobId=state.job.id})
  status("MINING")
  while running and not state.complete do
    if state.paused then status("PAUSED") repeat sleep(1) until not state.paused end
    mergeFiller()
    if needsService() then dumpAndRestock() end
    local p=nextExcavationPoint()
    if not p then
      state.complete=true; status("COMPLETE"); save()
      send({type="SECTOR_COMPLETE",teamId=state.teamId,jobId=state.job.id})
      return
    end
    local target={x=p.x,y=p.y+1,z=p.z}
    local ok=gotoXYZ(target)
    if not ok then
      send({type="ERROR",teamId=state.teamId,message="Could not path around protected/blocked object; returning to origin and retrying."})
      gotoXYZ({x=origin.x,y=origin.y+1,z=origin.z})
      sleep(3)
    else
      turnTo(faceForTask(p))
      digDownIfSafe()
      digForwardIfSafe()
      digUpIfSafe()
      fillOvercutsNear(p)
      placeTorchIfNeeded(p)
    end
  end
end

local function networkLoop()
  while running do
    local sender,msg,proto=rednet.receive(PROTOCOL,1)
    if type(msg)=="table" then
      if msg.type=="REGISTER_ACK" then state.controllerId=sender; state.agentId=msg.agentId; save()
      elseif msg.type=="ASSIGN_JOB" then
        state.controllerId=sender
        state.teamId=msg.teamId
        state.foremanNet=msg.foremanNet
        state.job=msg.job
        state.sector=msg.sector
        state.storage=msg.storage
        state.deployHold=msg.deployHold ~= false
        state.progress=state.progress or 0
        state.complete=false
        save()
        status("ASSIGNED")
      elseif msg.type=="DEPLOY_NOW" and (not msg.teamId or msg.teamId==state.teamId) then
        state.deployHold=false; save(); status("DEPLOY_RELEASED")
      elseif msg.type=="PAUSE_JOB" then state.paused=true; save()
      elseif msg.type=="RESUME_JOB" then state.paused=false; save()
      elseif msg.type=="CANCEL_JOB" then state.job=nil; state.sector=nil; state.complete=false; state.progress=0; save(); status("CANCELLED")
      elseif msg.type=="ROLL_CALL" then send({type="ROLL_CALL_RESPONSE",role="miner",status=state.status,x=state.pos and state.pos.x,y=state.pos and state.pos.y,z=state.pos and state.pos.z})
      end
    end
  end
end

local function heartbeatLoop()
  while running do
    send({type="REGISTER",role="miner",label=state.label,status=state.status})
    send({type="HEARTBEAT",role="miner",label=state.label,status=state.status,x=state.pos and state.pos.x,y=state.pos and state.pos.y,z=state.pos and state.pos.z})
    sleep(10)
  end
end

local function displayLoop()
  while running do header(); sleep(2) end
end

local function workLoop()
  while running do
    if state.job and state.sector and not state.complete then
      mineLoop()
    else
      status("LISTENING")
      send({type="REQUEST_ASSIGNMENT",role="miner",label=state.label})
      sleep(5)
    end
  end
end

ensureDir()
load()
openModem()
save()
parallel.waitForAny(networkLoop, heartbeatLoop, displayLoop, workLoop)
