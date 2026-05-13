-- SquirtleSquad-Miner v1
-- ForemanTurtle/startup.lua
-- Support unit. Hard-leashed to assigned miner, stays inside mineable area, never mines.

local PROTOCOL="TurtleTeamNet"
local PROJECT="SquirtleSquad-Miner"
local VERSION="v1"
local DATA_DIR="SquirtleSquadData"
local STATE_FILE=DATA_DIR.."/foreman_state.dat"

local LEASH_MAX=6
local LEASH_TARGET=3
local MINER_POS_TIMEOUT=15000

local state={
  role="foreman",
  label="Foreman-"..os.getComputerID(),
  controllerId=nil,
  agentId=nil,
  status="BOOTING",
  teamId=nil,
  minerId=nil,
  minerNet=nil,
  jobId=nil,
  job=nil,
  sector=nil,
  deployHold=true,
  pos=nil,
  facing="north",
  calibrated=false,
  paused=false
}
local running=true
local modemSide=nil
local lastMinerPos=nil
local lastMinerFacing="north"
local lastMinerUpdate=0

local DIRS={
  north={x=0,z=-1,left="west",right="east",back="south"},
  east={x=1,z=0,left="north",right="south",back="west"},
  south={x=0,z=1,left="east",right="west",back="north"},
  west={x=-1,z=0,left="south",right="north",back="east"}
}

local function ensureDir() if not fs.exists(DATA_DIR) then fs.makeDir(DATA_DIR) end end
local function save() ensureDir(); local h=fs.open(STATE_FILE,"w"); if h then h.write(textutils.serialize(state)); h.close() end end
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
    if peripheral.getType(side)=="modem" then
      modemSide=side
      if not rednet.isOpen(side) then rednet.open(side) end
      return true
    end
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
  print("Foreman Turtle: "..state.label)
  print("Status: "..tostring(state.status))
  print("Team: "..tostring(state.teamId or "none"))
  print("MinerNet: "..tostring(state.minerNet or "none"))
  if state.pos then print("Pos: "..state.pos.x..","..state.pos.y..","..state.pos.z.." facing "..tostring(state.facing)) end
  if lastMinerPos then
    print("Miner: "..lastMinerPos.x..","..lastMinerPos.y..","..lastMinerPos.z.." age "..math.floor((os.epoch("utc")-lastMinerUpdate)/1000).."s")
  end
  print("")
end

local function clonePos(p) if not p then return nil end return {x=p.x,y=p.y,z=p.z} end
local function manhattan(a,b) if not a or not b then return 999999 end return math.abs(a.x-b.x)+math.abs(a.y-b.y)+math.abs(a.z-b.z) end

local function boundsAllowed(p)
  if not p then return false end
  local b=nil
  if state.sector then b=state.sector.fullBounds or state.sector.bounds end
  if not b then return true end
  return p.x>=b.minX and p.x<=b.maxX and p.y>=b.minY and p.y<=b.maxY and p.z>=b.minZ and p.z<=b.maxZ
end

local function insideShape(p)
  local job=state.job
  if not job or not p then return true end

  if job.shape=="cylinder" then
    if not job.origin or not job.radius or not job.height then return boundsAllowed(p) end
    if p.y < job.origin.y or p.y > job.origin.y + job.height - 1 then return false end
    local dx=p.x-job.origin.x
    local dz=p.z-job.origin.z
    return dx*dx + dz*dz <= job.radius*job.radius
  elseif job.shape=="dome" then
    if not job.origin or not job.radius then return boundsAllowed(p) end
    if p.y < job.origin.y or p.y > job.origin.y + job.radius then return false end
    local dx=p.x-job.origin.x
    local dy=p.y-job.origin.y
    local dz=p.z-job.origin.z
    return dx*dx + dy*dy + dz*dz <= job.radius*job.radius
  elseif job.shape=="cone" then
    if not job.origin or not job.radius or not job.height then return boundsAllowed(p) end
    if p.y < job.origin.y or p.y > job.origin.y + job.height - 1 then return false end
    local level=p.y-job.origin.y
    local remaining=math.max(0, job.height-1-level)
    local r=(job.radius*remaining)/math.max(1,job.height-1)
    local dx=p.x-job.origin.x
    local dz=p.z-job.origin.z
    return dx*dx + dz*dz <= r*r
  elseif job.shape=="pyramid" then
    if not job.origin or not job.radius or not job.height then return boundsAllowed(p) end
    if p.y < job.origin.y or p.y > job.origin.y + job.height - 1 then return false end
    local level=p.y-job.origin.y
    local r=math.floor((job.radius*math.max(0, job.height-1-level))/math.max(1,job.height-1))
    return math.abs(p.x-job.origin.x)<=r and math.abs(p.z-job.origin.z)<=r
  elseif job.shape=="rect" then
    return boundsAllowed(p)
  end

  return boundsAllowed(p)
end

local function areaAllowed(p)
  return boundsAllowed(p) and insideShape(p)
end

local function nextForwardPos()
  local d=DIRS[state.facing]
  return {x=state.pos.x+d.x,y=state.pos.y,z=state.pos.z+d.z}
end
local function nextBackPos()
  local d=DIRS[state.facing]
  return {x=state.pos.x-d.x,y=state.pos.y,z=state.pos.z-d.z}
end

local function isTorchName(name)
  return name=="minecraft:torch" or name=="minecraft:wall_torch" or name=="minecraft:soul_torch" or name=="minecraft:soul_wall_torch"
end

local function refuelIfNeeded()
  if turtle.getFuelLevel()=="unlimited" then return true end
  if turtle.getFuelLevel()>200 then return true end
  turtle.select(1)
  if turtle.getItemCount(1)>0 then turtle.refuel(math.min(8,turtle.getItemCount(1))) end
  return turtle.getFuelLevel()=="unlimited" or turtle.getFuelLevel()>50
end

local function turnLeft() turtle.turnLeft(); state.facing=DIRS[state.facing].left; save() end
local function turnRight() turtle.turnRight(); state.facing=DIRS[state.facing].right; save() end
local function turnTo(dir)
  local guard=0
  while state.facing~=dir and guard<4 do
    turnRight()
    guard=guard+1
  end
end

local function updateForward() local d=DIRS[state.facing]; state.pos.x=state.pos.x+d.x; state.pos.z=state.pos.z+d.z end
local function updateBack() local d=DIRS[state.facing]; state.pos.x=state.pos.x-d.x; state.pos.z=state.pos.z-d.z end

local function rawForward()
  if turtle.forward() then updateForward(); save(); return true end
  return false
end

local function safeForward()
  if not state.pos then return false end
  refuelIfNeeded()
  local np=nextForwardPos()
  if not areaAllowed(np) then return false end

  if rawForward() then return true end

  local ok,data=turtle.inspect()
  if ok and data and isTorchName(data.name) then
    local upPos={x=state.pos.x,y=state.pos.y+1,z=state.pos.z}
    local overPos={x=np.x,y=np.y+1,z=np.z}
    if areaAllowed(upPos) and areaAllowed(overPos) then
      if turtle.up() then
        state.pos.y=state.pos.y+1; save()
        if rawForward() then
          local downPos={x=state.pos.x,y=state.pos.y-1,z=state.pos.z}
          if areaAllowed(downPos) and not turtle.detectDown() and turtle.down() then
            state.pos.y=state.pos.y-1; save()
          end
          return true
        end
        turtle.down(); state.pos.y=state.pos.y-1; save()
      end
    end
  end

  return false
end

local function safeBack()
  if not state.pos then return false end
  refuelIfNeeded()
  local np=nextBackPos()
  if not areaAllowed(np) then return false end
  for i=1,2 do
    if turtle.back() then updateBack(); save(); return true end
    sleep(0.25)
  end
  return false
end

local function safeUp()
  if not state.pos then return false end
  refuelIfNeeded()
  local np={x=state.pos.x,y=state.pos.y+1,z=state.pos.z}
  if not areaAllowed(np) then return false end
  if turtle.up() then state.pos.y=state.pos.y+1; save(); return true end
  return false
end

local function safeDown()
  if not state.pos then return false end
  refuelIfNeeded()
  local np={x=state.pos.x,y=state.pos.y-1,z=state.pos.z}
  if not areaAllowed(np) then return false end
  if turtle.down() then state.pos.y=state.pos.y-1; save(); return true end
  return false
end

local function calibrateFacing()
  if not state.pos then return false end
  local x1,y1,z1=gps.locate(5)
  if not x1 then return false end
  if turtle.forward() then
    local x2,y2,z2=gps.locate(5)
    turtle.back()
    if x2 then
      local dx=math.floor(x2+0.5)-math.floor(x1+0.5)
      local dz=math.floor(z2+0.5)-math.floor(z1+0.5)
      if dx==1 then state.facing="east"
      elseif dx==-1 then state.facing="west"
      elseif dz==1 then state.facing="south"
      elseif dz==-1 then state.facing="north" end
      save()
      return true
    end
  end
  return false
end

local function calibrate()
  status("WAITING_FOR_GPS")
  while not state.calibrated do
    local x,y,z=gps.locate(10)
    if x and y and z then
      state.pos={x=math.floor(x+0.5),y=math.floor(y+0.5),z=math.floor(z+0.5)}
      state.facing=state.facing or "north"
      state.calibrated=true
      save()
      calibrateFacing()
      status("CALIBRATED")
      return true
    end
    if state.pos then state.calibrated=true; status("RECOVERED_DEAD_RECKONING"); return true end
    sleep(3)
  end
end

local function stepToward(target)
  if not target or not state.pos then return false end

  local dx=target.x-state.pos.x
  local dy=target.y-state.pos.y
  local dz=target.z-state.pos.z

  if math.abs(dx)>=math.abs(dz) and dx~=0 then
    turnTo(dx>0 and "east" or "west")
    if safeForward() then return true end
  end
  if dz~=0 then
    turnTo(dz>0 and "south" or "north")
    if safeForward() then return true end
  end
  if dx~=0 then
    turnTo(dx>0 and "east" or "west")
    if safeForward() then return true end
  end
  if dy>0 then if safeUp() then return true end end
  if dy<0 then if safeDown() then return true end end

  return false
end

local function sideOfMiner(minerPos, minerFacing)
  local f=minerFacing or "north"
  local side=DIRS[f].right
  local d=DIRS[side]
  return {x=minerPos.x+d.x, y=minerPos.y, z=minerPos.z+d.z}
end

local function nearestAllowedAround(base)
  if not base then return nil end
  if areaAllowed(base) then return base end

  local best=nil
  local bestDist=999999
  for r=1,LEASH_MAX do
    for dx=-r,r do
      for dz=-r,r do
        for dy=-1,1 do
          local p={x=base.x+dx,y=base.y+dy,z=base.z+dz}
          if areaAllowed(p) then
            local d=manhattan(p,base)
            if d<bestDist then best=p; bestDist=d end
          end
        end
      end
    end
    if best then return best end
  end
  return nil
end

local function desiredFollowPos()
  if not lastMinerPos then return nil end
  local desired=sideOfMiner(lastMinerPos,lastMinerFacing)
  return nearestAllowedAround(desired) or nearestAllowedAround(lastMinerPos)
end

local function maintainLeash()
  if not state.teamId or state.deployHold then return end
  if not lastMinerPos or not state.pos then
    status("WAITING_FOR_MINER_POSITION")
    return
  end

  local age=os.epoch("utc")-lastMinerUpdate
  if age>MINER_POS_TIMEOUT then
    status("WAITING_FOR_MINER_POSITION")
    return
  end

  local distToMiner=manhattan(state.pos,lastMinerPos)
  local target=desiredFollowPos()
  if not target then
    status("NO_VALID_FOREMAN_POSITION")
    return
  end

  if distToMiner>LEASH_MAX then
    status("RETURNING_TO_MINER")
    for i=1,4 do
      if manhattan(state.pos,lastMinerPos)<=LEASH_TARGET then break end
      if not stepToward(target) and not stepToward(lastMinerPos) then
        status("FOREMAN_LEASH_BLOCKED")
        send({type="FOREMAN_LEASH_BLOCKED",teamId=state.teamId,minerNet=state.minerNet,x=state.pos.x,y=state.pos.y,z=state.pos.z})
        return
      end
    end
  elseif manhattan(state.pos,target)>2 then
    status("FOLLOWING")
    stepToward(target)
  else
    status("PARKED_NEAR_MINER")
  end
end

local function moveAside()
  status("MOVING_ASIDE")
  if safeBack() then sendTo(state.minerNet,{type="FOREMAN_MOVED",teamId=state.teamId}); status("FOLLOWING"); return true end
  turnRight()
  if safeForward() then turnLeft(); sendTo(state.minerNet,{type="FOREMAN_MOVED",teamId=state.teamId}); status("FOLLOWING"); return true end
  turnLeft()
  if safeUp() then sendTo(state.minerNet,{type="FOREMAN_MOVED",teamId=state.teamId}); status("FOLLOWING"); return true end
  sendTo(state.minerNet,{type="FOREMAN_MOVED",teamId=state.teamId,failed=true})
  status("FOLLOWING")
  return false
end

local function networkLoop()
  while running do
    local sender,msg,proto=rednet.receive(PROTOCOL,1)
    if type(msg)=="table" then
      if msg.type=="REGISTER_ACK" then
        state.controllerId=sender; state.agentId=msg.agentId; save()
      elseif msg.type=="ASSIGN_FOREMAN" then
        state.controllerId=sender
        state.teamId=msg.teamId
        state.minerId=msg.minerId
        state.minerNet=msg.minerNet
        state.jobId=msg.jobId
        state.job=msg.job or state.job
        state.sector=msg.sector
        state.deployHold=true
        save()
        status("ASSIGNED")
      elseif msg.type=="DEPLOY_NOW" and (not msg.teamId or msg.teamId==state.teamId) then
        state.deployHold=false; save(); status("DEPLOY_RELEASED")
      elseif msg.type=="MINER_POSITION" or msg.type=="MINER_MOVED_FORWARD" or msg.type=="MINER_MOVED_UP" or msg.type=="MINER_MOVED_DOWN" or msg.type=="MINER_TURNED_LEFT" or msg.type=="MINER_TURNED_RIGHT" then
        if msg.pos then
          lastMinerPos=clonePos(msg.pos)
          lastMinerFacing=msg.facing or lastMinerFacing
          lastMinerUpdate=os.epoch("utc")
          maintainLeash()
        end
      elseif msg.type=="FOREMAN_MOVE_REQUEST" then
        lastMinerPos=clonePos(msg.pos) or lastMinerPos
        lastMinerFacing=msg.facing or lastMinerFacing
        lastMinerUpdate=os.epoch("utc")
        moveAside()
      elseif msg.type=="SERVICE_RETURN" then
        status("RETURNING_WITH_MINER")
      elseif msg.type=="PAUSE_JOB" then
        state.paused=true; save(); status("PAUSED")
      elseif msg.type=="RESUME_JOB" then
        state.paused=false; save(); status("FOLLOWING")
      elseif msg.type=="CANCEL_JOB" then
        state.teamId=nil; state.minerNet=nil; state.jobId=nil; state.job=nil; state.sector=nil; save(); status("CANCELLED")
      elseif msg.type=="ROLL_CALL" then
        send({type="ROLL_CALL_RESPONSE",role="foreman",status=state.status,x=state.pos and state.pos.x,y=state.pos and state.pos.y,z=state.pos and state.pos.z})
      end
    end
  end
end

local function heartbeatLoop()
  while running do
    send({type="REGISTER",role="foreman",label=state.label,status=state.status})
    send({type="HEARTBEAT",role="foreman",label=state.label,status=state.status,teamId=state.teamId,minerNet=state.minerNet,x=state.pos and state.pos.x,y=state.pos and state.pos.y,z=state.pos and state.pos.z})
    sleep(10)
  end
end

local function displayLoop() while running do header(); sleep(2) end end

local function workLoop()
  calibrate()
  while running do
    if state.teamId and state.deployHold then
      status("WAITING_DEPLOY")
      sleep(1)
    elseif state.teamId then
      if not state.paused then maintainLeash() end
      sleep(5)
    else
      status("LISTENING")
      sleep(3)
    end
  end
end

ensureDir()
load()
openModem()
save()
parallel.waitForAny(networkLoop,heartbeatLoop,displayLoop,workLoop)
