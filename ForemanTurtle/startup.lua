-- SquirtleSquad-Miner v1.1
-- ForemanTurtle/startup.lua
-- Patch focus:
--   * Avoid endless spin-panic by limiting follow attempts and waiting when blocked.
--   * Track a home position on first calibration and obey GO_HOME.
--   * Preserve no-dig support behavior.

local PROTOCOL="TurtleTeamNet"
local PROJECT="SquirtleSquad-Miner"
local VERSION="v1.1"
local DATA_DIR="SquirtleSquadData"
local STATE_FILE=DATA_DIR.."/foreman_state.dat"

local state={
  role="foreman", label="Foreman-"..os.getComputerID(), controllerId=nil, agentId=nil,
  status="BOOTING", teamId=nil, minerId=nil, minerNet=nil, jobId=nil, sector=nil,
  deployHold=true, pos=nil, facing="north", calibrated=false, paused=false,
  home=nil, homeFacing=nil, forceHome=false
}

local running=true
local modemSide=nil
local lastMinerPos=nil
local lastMinerFacing="north"

local DIRS={
  north={x=0,z=-1,left="west",right="east",back="south"},
  east ={x=1,z=0,left="north",right="south",back="west"},
  south={x=0,z=1,left="east",right="west",back="north"},
  west ={x=-1,z=0,left="south",right="north",back="east"},
}

local function ensureDir() if not fs.exists(DATA_DIR) then fs.makeDir(DATA_DIR) end end
local function save() ensureDir(); local h=fs.open(STATE_FILE,"w"); if h then h.write(textutils.serialize(state)); h.close() end end
local function load()
  if fs.exists(STATE_FILE) then
    local h=fs.open(STATE_FILE,"r")
    if h then local txt=h.readAll(); h.close(); local ok,t=pcall(textutils.unserialize,txt); if ok and type(t)=="table" then for k,v in pairs(t) do state[k]=v end end end
  end
end
local function clonePos(p) if not p then return nil end return {x=p.x,y=p.y,z=p.z} end
local function openModem()
  for _,side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side)=="modem" then modemSide=side; if not rednet.isOpen(side) then rednet.open(side) end; return true end
  end
  return false
end
local function send(msg) if not modemSide then return end msg.project=PROJECT; msg.version=VERSION; if state.controllerId then rednet.send(state.controllerId,msg,PROTOCOL) else rednet.broadcast(msg,PROTOCOL) end end
local function sendTo(id,msg) if id then msg.project=PROJECT; msg.version=VERSION; rednet.send(id,msg,PROTOCOL) end end
local function status(s) state.status=s; save() end

local function header()
  term.clear(); term.setCursorPos(1,1)
  if term.isColor() then term.setTextColor(colors.cyan) end
  print(" "..PROJECT.." "..VERSION.." ")
  if term.isColor() then term.setTextColor(colors.white) end
  print("Foreman Turtle: "..tostring(state.label))
  print("Status: "..tostring(state.status))
  print("Team: "..tostring(state.teamId or "none"))
  print("MinerNet: "..tostring(state.minerNet or "none"))
  if state.pos then print("Pos: "..state.pos.x..","..state.pos.y..","..state.pos.z.." facing "..tostring(state.facing)) end
  if lastMinerPos then print("Miner: "..lastMinerPos.x..","..lastMinerPos.y..","..lastMinerPos.z.." facing "..tostring(lastMinerFacing)) end
  if state.home then print("Home: "..state.home.x..","..state.home.y..","..state.home.z) end
  print("")
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
  if not dir then return end
  local g=0
  while state.facing~=dir and g<4 do turnRight(); g=g+1 end
end
local function updateForward() local d=DIRS[state.facing]; state.pos.x=state.pos.x+d.x; state.pos.z=state.pos.z+d.z end
local function updateBack() local d=DIRS[state.facing]; state.pos.x=state.pos.x-d.x; state.pos.z=state.pos.z-d.z end

local function safeForward()
  refuelIfNeeded()
  for _=1,2 do if turtle.forward() then updateForward(); save(); return true end sleep(0.25) end
  return false
end
local function safeBack()
  refuelIfNeeded()
  for _=1,2 do if turtle.back() then updateBack(); save(); return true end sleep(0.25) end
  return false
end
local function safeUp() refuelIfNeeded(); if turtle.up() then state.pos.y=state.pos.y+1; save(); return true end return false end
local function safeDown() refuelIfNeeded(); if turtle.down() then state.pos.y=state.pos.y-1; save(); return true end return false end

local function calibrate()
  status("WAITING_FOR_GPS")
  while not state.calibrated do
    local x,y,z=gps.locate(10)
    if x and y and z then
      state.pos={x=math.floor(x+0.5),y=math.floor(y+0.5),z=math.floor(z+0.5)}
      state.facing=state.facing or "north"
      state.calibrated=true
      if not state.home then state.home=clonePos(state.pos); state.homeFacing=state.facing end
      save(); status("CALIBRATED"); return true
    end
    if state.pos then
      state.calibrated=true
      if not state.home then state.home=clonePos(state.pos); state.homeFacing=state.facing end
      save(); status("RECOVERED_DEAD_RECKONING"); return true
    end
    sleep(3)
  end
end

local function goY(y)
  while state.pos.y<y do if not safeUp() then return false end end
  while state.pos.y>y do if not safeDown() then return false end end
  return true
end
local function goX(x)
  if state.pos.x<x then turnTo("east"); while state.pos.x<x do if not safeForward() then return false end end
  elseif state.pos.x>x then turnTo("west"); while state.pos.x>x do if not safeForward() then return false end end end
  return true
end
local function goZ(z)
  if state.pos.z<z then turnTo("south"); while state.pos.z<z do if not safeForward() then return false end end
  elseif state.pos.z>z then turnTo("north"); while state.pos.z>z do if not safeForward() then return false end end end
  return true
end
local function gotoXYZ(p)
  if not p or not state.pos then return false end
  local travelY=math.max(state.pos.y,p.y)
  if not goY(travelY) then return false end
  if not goX(p.x) then return false end
  if not goZ(p.z) then return false end
  if not goY(p.y) then return false end
  return true
end

local function manhattan(a,b) return math.abs(a.x-b.x)+math.abs(a.y-b.y)+math.abs(a.z-b.z) end
local function sideOfMiner(minerPos, minerFacing)
  local f=minerFacing or "north"
  local side=DIRS[f].right
  local d=DIRS[side]
  return {x=minerPos.x+d.x, y=minerPos.y, z=minerPos.z+d.z}
end

local function trySingleStepToward(target)
  if not target or not state.pos then return false end
  local dx,dy,dz=target.x-state.pos.x,target.y-state.pos.y,target.z-state.pos.z
  if math.abs(dy)>0 and math.abs(dy)>=math.abs(dx) and math.abs(dy)>=math.abs(dz) then
    if dy>0 then return safeUp() else return safeDown() end
  end
  if math.abs(dx)>=math.abs(dz) and dx~=0 then
    turnTo(dx>0 and "east" or "west")
    return safeForward()
  elseif dz~=0 then
    turnTo(dz>0 and "south" or "north")
    return safeForward()
  end
  return true
end

local function maintainSide()
  if not lastMinerPos or not state.pos then return end
  local target=sideOfMiner(lastMinerPos,lastMinerFacing)
  local dist=manhattan(state.pos,target)
  if dist<=2 then status("FOLLOWING"); return end

  status("RETURNING_TO_MINER")
  -- Bounded follow: no endless spin. Try a few direct steps, then wait for the miner to move/clear path.
  for _=1,6 do
    if manhattan(state.pos,target)<=2 then status("FOLLOWING"); return true end
    if not trySingleStepToward(target) then
      status("WAITING_NEAR_MINER")
      return false
    end
  end
  status("WAITING_NEAR_MINER")
  return false
end

local function moveAside()
  status("MOVING_ASIDE")
  if safeBack() then sendTo(state.minerNet,{type="FOREMAN_MOVED",teamId=state.teamId}); status("FOLLOWING"); return true end
  turnRight()
  if safeForward() then turnLeft(); sendTo(state.minerNet,{type="FOREMAN_MOVED",teamId=state.teamId}); status("FOLLOWING"); return true end
  turnLeft()
  if safeUp() then sendTo(state.minerNet,{type="FOREMAN_MOVED",teamId=state.teamId}); status("FOLLOWING"); return true end
  sendTo(state.minerNet,{type="FOREMAN_MOVED",teamId=state.teamId,failed=true})
  status("WAITING_NEAR_MINER")
  return false
end

local function goHome()
  if not state.home then status("NO_HOME_SET"); return false end
  status("GOING_HOME")
  local ok=gotoXYZ(state.home)
  if ok then turnTo(state.homeFacing or state.facing); status("AT_HOME") else status("HOME_PATH_FAILED") end
  return ok
end

local function networkLoop()
  while running do
    local sender,msg,proto=rednet.receive(PROTOCOL,1)
    if type(msg)=="table" then
      if msg.type=="REGISTER_ACK" then state.controllerId=sender; state.agentId=msg.agentId; save()
      elseif msg.type=="ASSIGN_FOREMAN" then
        state.controllerId=sender; state.teamId=msg.teamId; state.minerId=msg.minerId; state.minerNet=msg.minerNet; state.jobId=msg.jobId; state.sector=msg.sector; state.deployHold=true; state.forceHome=false; save(); status("ASSIGNED")
      elseif msg.type=="DEPLOY_NOW" and (not msg.teamId or msg.teamId==state.teamId) then state.deployHold=false; save(); status("DEPLOY_RELEASED")
      elseif msg.type=="MINER_POSITION" or msg.type=="MINER_MOVED_FORWARD" or msg.type=="MINER_MOVED_UP" or msg.type=="MINER_MOVED_DOWN" then if msg.pos then lastMinerPos=msg.pos; lastMinerFacing=msg.facing or lastMinerFacing; maintainSide() end
      elseif msg.type=="MINER_TURNED_LEFT" or msg.type=="MINER_TURNED_RIGHT" then if msg.pos then lastMinerPos=msg.pos; lastMinerFacing=msg.facing or lastMinerFacing end
      elseif msg.type=="FOREMAN_MOVE_REQUEST" then lastMinerPos=msg.pos or lastMinerPos; lastMinerFacing=msg.facing or lastMinerFacing; moveAside()
      elseif msg.type=="SERVICE_RETURN" then status("RETURNING_WITH_MINER")
      elseif msg.type=="GO_HOME" then state.forceHome=true; save(); status("GO_HOME_REQUESTED")
      elseif msg.type=="PAUSE_JOB" then state.paused=true; save(); status("PAUSED")
      elseif msg.type=="RESUME_JOB" then state.paused=false; save(); status("FOLLOWING")
      elseif msg.type=="CANCEL_JOB" then state.teamId=nil; state.minerNet=nil; state.jobId=nil; state.sector=nil; state.forceHome=true; save(); status("CANCELLED_GOING_HOME")
      elseif msg.type=="ROLL_CALL" then send({type="ROLL_CALL_RESPONSE",role="foreman",status=state.status,x=state.pos and state.pos.x,y=state.pos and state.pos.y,z=state.pos and state.pos.z})
      end
    end
  end
end

local function heartbeatLoop()
  while running do
    send({type="REGISTER",role="foreman",label=state.label,status=state.status,x=state.pos and state.pos.x,y=state.pos and state.pos.y,z=state.pos and state.pos.z})
    send({type="HEARTBEAT",role="foreman",label=state.label,status=state.status,x=state.pos and state.pos.x,y=state.pos and state.pos.y,z=state.pos and state.pos.z,facing=state.facing})
    sleep(10)
  end
end
local function displayLoop() while running do header(); sleep(2) end end
local function workLoop()
  calibrate()
  while running do
    if state.forceHome then state.forceHome=false; save(); goHome()
    elseif state.teamId and state.deployHold then status("WAITING_DEPLOY"); sleep(1)
    elseif state.teamId then maintainSide(); sleep(2)
    else status("LISTENING"); sleep(3) end
  end
end

ensureDir(); load(); openModem(); save()
parallel.waitForAny(networkLoop,heartbeatLoop,displayLoop,workLoop)
