-- SquirtleSquad-Miner v1
-- ForemanTurtle/startup.lua
-- Support unit. Follows miner broadcasts, stays near side of stack, moves aside on request. Does not mine.

local PROTOCOL="TurtleTeamNet"
local PROJECT="SquirtleSquad-Miner"
local VERSION="v1"
local DATA_DIR="SquirtleSquadData"
local STATE_FILE=DATA_DIR.."/foreman_state.dat"

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
  sector=nil,
  deployHold=true,
  pos=nil,
  facing="north",
  calibrated=false,
  paused=false
}
local running=true
local modemSide=nil
local DIRS={
  north={x=0,z=-1,left="west",right="east",back="south"},
  east={x=1,z=0,left="north",right="south",back="west"},
  south={x=0,z=1,left="east",right="west",back="north"},
  west={x=-1,z=0,left="south",right="north",back="east"}
}

local function ensureDir() if not fs.exists(DATA_DIR) then fs.makeDir(DATA_DIR) end end
local function save() ensureDir(); local h=fs.open(STATE_FILE,"w"); if h then h.write(textutils.serialize(state)); h.close() end end
local function load()
  if fs.exists(STATE_FILE) then local h=fs.open(STATE_FILE,"r"); if h then local txt=h.readAll(); h.close(); local ok,t=pcall(textutils.unserialize,txt); if ok and type(t)=="table" then for k,v in pairs(t) do state[k]=v end end end end
end
local function openModem() for _,side in ipairs(peripheral.getNames()) do if peripheral.getType(side)=="modem" then modemSide=side; if not rednet.isOpen(side) then rednet.open(side) end; return true end end return false end
local function send(msg) if not modemSide then return end msg.project=PROJECT; msg.version=VERSION; if state.controllerId then rednet.send(state.controllerId,msg,PROTOCOL) else rednet.broadcast(msg,PROTOCOL) end end
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
local function turnTo(dir) local g=0; while state.facing~=dir and g<4 do turnRight(); g=g+1 end end
local function updateForward() local d=DIRS[state.facing]; state.pos.x=state.pos.x+d.x; state.pos.z=state.pos.z+d.z end
local function updateBack() local d=DIRS[state.facing]; state.pos.x=state.pos.x-d.x; state.pos.z=state.pos.z-d.z end

local function safeForward()
  refuelIfNeeded()
  for i=1,2 do
    if turtle.forward() then updateForward(); save(); return true end
    -- Foreman never digs. Try waiting for path to clear.
    sleep(0.4)
  end
  return false
end
local function safeBack()
  refuelIfNeeded()
  for i=1,2 do
    if turtle.back() then updateBack(); save(); return true end
    sleep(0.4)
  end
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
      save(); status("CALIBRATED"); return true
    end
    if state.pos then state.calibrated=true; status("RECOVERED_DEAD_RECKONING"); return true end
    sleep(3)
  end
end

local function goY(y) while state.pos.y<y do if not safeUp() then return false end end while state.pos.y>y do if not safeDown() then return false end end return true end
local function goX(x) if state.pos.x<x then turnTo("east"); while state.pos.x<x do if not safeForward() then return false end end elseif state.pos.x>x then turnTo("west"); while state.pos.x>x do if not safeForward() then return false end end end return true end
local function goZ(z) if state.pos.z<z then turnTo("south"); while state.pos.z<z do if not safeForward() then return false end end elseif state.pos.z>z then turnTo("north"); while state.pos.z>z do if not safeForward() then return false end end end return true end
local function gotoXYZ(p)
  local travelY=math.max(state.pos.y,p.y)
  if not goY(travelY) then return false end
  if not goX(p.x) then return false end
  if not goZ(p.z) then return false end
  if not goY(p.y) then return false end
  return true
end

local function sideOfMiner(minerPos, minerFacing)
  local f=minerFacing or "north"
  local side=DIRS[f].right
  local d=DIRS[side]
  return {x=minerPos.x+d.x, y=minerPos.y, z=minerPos.z+d.z}
end

local lastMinerPos=nil
local lastMinerFacing="north"

local function maintainSide()
  if not lastMinerPos or not state.pos then return end
  local target=sideOfMiner(lastMinerPos,lastMinerFacing)
  if math.abs(state.pos.x-target.x)+math.abs(state.pos.y-target.y)+math.abs(state.pos.z-target.z) > 3 then
    gotoXYZ(target)
  end
end

local function moveAside()
  status("MOVING_ASIDE")
  -- Prefer backward, then right side-step, then up. Never mine.
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
      if msg.type=="REGISTER_ACK" then state.controllerId=sender; state.agentId=msg.agentId; save()
      elseif msg.type=="ASSIGN_FOREMAN" then
        state.controllerId=sender; state.teamId=msg.teamId; state.minerId=msg.minerId; state.minerNet=msg.minerNet; state.jobId=msg.jobId; state.sector=msg.sector; state.deployHold=true; save(); status("ASSIGNED")
      elseif msg.type=="DEPLOY_NOW" and (not msg.teamId or msg.teamId==state.teamId) then state.deployHold=false; save(); status("DEPLOY_RELEASED")
      elseif msg.type=="MINER_POSITION" or msg.type=="MINER_MOVED_FORWARD" or msg.type=="MINER_MOVED_UP" or msg.type=="MINER_MOVED_DOWN" then
        if msg.pos then lastMinerPos=msg.pos; lastMinerFacing=msg.facing or lastMinerFacing; maintainSide() end
      elseif msg.type=="MINER_TURNED_LEFT" or msg.type=="MINER_TURNED_RIGHT" then
        if msg.pos then lastMinerPos=msg.pos; lastMinerFacing=msg.facing or lastMinerFacing; maintainSide() end
      elseif msg.type=="FOREMAN_MOVE_REQUEST" then
        lastMinerPos=msg.pos or lastMinerPos; lastMinerFacing=msg.facing or lastMinerFacing; moveAside()
      elseif msg.type=="SERVICE_RETURN" then status("RETURNING_WITH_MINER")
      elseif msg.type=="PAUSE_JOB" then state.paused=true; save(); status("PAUSED")
      elseif msg.type=="RESUME_JOB" then state.paused=false; save(); status("FOLLOWING")
      elseif msg.type=="CANCEL_JOB" then state.teamId=nil; state.minerNet=nil; state.jobId=nil; state.sector=nil; save(); status("CANCELLED")
      elseif msg.type=="ROLL_CALL" then send({type="ROLL_CALL_RESPONSE",role="foreman",status=state.status,x=state.pos and state.pos.x,y=state.pos and state.pos.y,z=state.pos and state.pos.z})
      end
    end
  end
end

local function heartbeatLoop()
  while running do
    send({type="REGISTER",role="foreman",label=state.label,status=state.status})
    send({type="HEARTBEAT",role="foreman",label=state.label,status=state.status,x=state.pos and state.pos.x,y=state.pos and state.pos.y,z=state.pos and state.pos.z})
    sleep(10)
  end
end

local function displayLoop() while running do header(); sleep(2) end end

local function workLoop()
  calibrate()
  while running do
    if state.teamId and state.deployHold then status("WAITING_DEPLOY"); sleep(1)
    elseif state.teamId then status("FOLLOWING"); maintainSide(); sleep(2)
    else status("LISTENING"); sleep(3) end
  end
end

ensureDir()
load()
openModem()
save()
parallel.waitForAny(networkLoop,heartbeatLoop,displayLoop,workLoop)
