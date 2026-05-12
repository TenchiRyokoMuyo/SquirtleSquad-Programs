-- Miner Turtle startup.lua v11
-- No Ctrl+T lockout. GPS is diagnostic/correction only; failure does not abort listening.
local PROTOCOL="TurtleTeamNet"; local STATE_FILE="miner_state.dat"; local role="miner"; local id=os.getComputerID()
local modemSide,controllerId
local state={role=role,status="IDLE",job=nil,sector=nil,currentIndex=1,progress=0,lastKnownGPS=nil,gpsStatus="untested",error=nil,facing=nil,pos=nil}
local function save() local f=fs.open(STATE_FILE,"w"); if f then f.write(textutils.serialize(state)); f.close() end end
local function load() if fs.exists(STATE_FILE) then local f=fs.open(STATE_FILE,"r"); local s=f.readAll(); f.close(); local t=textutils.unserialize(s); if type(t)=="table" then for k,v in pairs(t) do state[k]=v end end end end
local function findModem() for _,side in ipairs(peripheral.getNames()) do if peripheral.getType(side)=="modem" then return side end end end
local function gpsTry(timeout) local x,y,z=gps.locate(timeout or 3); if x then state.lastKnownGPS={x=math.floor(x+0.5),y=math.floor(y+0.5),z=math.floor(z+0.5)}; state.pos={x=state.lastKnownGPS.x,y=state.lastKnownGPS.y,z=state.lastKnownGPS.z}; state.gpsStatus="ok"; save(); return state.lastKnownGPS end state.gpsStatus="unavailable"; save(); return nil end
local function draw(msg) term.clear(); term.setCursorPos(1,1); print("Miner Turtle #"..id); print("Status: "..tostring(state.status)); print("Controller: "..tostring(controllerId)); if state.job then print("Job: "..state.job.id.." Sector: "..(state.sector and state.sector.id or "?")); print("Index: "..state.currentIndex.." Progress: "..state.progress.."%") end; print("GPS: "..tostring(state.gpsStatus)); if msg then print(msg) end; if state.error then print("ERROR: "..state.error) end end
local function send(msg) if controllerId then rednet.send(controllerId,msg,PROTOCOL) else rednet.broadcast(msg,PROTOCOL) end end
local function register() rednet.broadcast({type="REGISTER",role=role,id=id,status=state.status,gps=state.lastKnownGPS,gpsStatus=state.gpsStatus},PROTOCOL) end
local function heartbeat() send({type="HEARTBEAT",role=role,id=id,status=state.status,fuel=turtle.getFuelLevel(),gps=state.lastKnownGPS,gpsStatus=state.gpsStatus,jobId=state.job and state.job.id,sectorId=state.sector and state.sector.id,currentIndex=state.currentIndex,progress=state.progress}) end
local protectedSubstrings={"chest","barrel","shulker","drawer","computer","turtle","modem","scaffold","create:"}
local function isProtected(name) if not name then return false end; for _,s in ipairs(protectedSubstrings) do if name:lower():find(s,1,true) then return true end end; return false end
local function inspectForward() local ok,d=turtle.inspect(); return ok,d end
local function safeDigForward() local ok,d=inspectForward(); if ok then local n=d.name or ""; if isProtected(n) then state.status="ERROR"; state.error="Protected block ahead: "..n; save(); send({type="ERROR",role=role,id=id,error=state.error}); return false end; turtle.dig() end; return true end
local function safeDigUp() local ok,d=turtle.inspectUp(); if ok then local n=d.name or ""; if isProtected(n) then state.status="ERROR"; state.error="Protected block above: "..n; save(); send({type="ERROR",role=role,id=id,error=state.error}); return false end; turtle.digUp() end; return true end
local function safeDigDown() if state.job and state.job.origin and state.pos and state.pos.y <= state.job.origin.y then return true end; local ok,d=turtle.inspectDown(); if ok then local n=d.name or ""; if isProtected(n) then state.status="ERROR"; state.error="Protected block below: "..n; save(); send({type="ERROR",role=role,id=id,error=state.error}); return false end; turtle.digDown() end; return true end
local dirs={{x=0,z=-1,name="N"},{x=1,z=0,name="E"},{x=0,z=1,name="S"},{x=-1,z=0,name="W"}}
local function turnLeft() turtle.turnLeft(); if state.facing then state.facing=((state.facing+2)%4)+1 end end
local function turnRight() turtle.turnRight(); if state.facing then state.facing=(state.facing%4)+1 end end
local function face(idx) if not state.facing then state.facing=1 end; while state.facing~=idx do turnRight() end end
local function forward() if not safeDigForward() then return false end; if turtle.forward() then if state.pos and state.facing then local d=dirs[state.facing]; state.pos.x=state.pos.x+d.x; state.pos.z=state.pos.z+d.z end; save(); return true end; return false end
local function up() if not safeDigUp() then return false end; if turtle.up() then if state.pos then state.pos.y=state.pos.y+1 end; save(); return true end; return false end
local function down() if state.job and state.job.origin and state.pos and state.pos.y <= state.job.origin.y then return false end; if not safeDigDown() then return false end; if turtle.down() then if state.pos then state.pos.y=state.pos.y-1 end; save(); return true end; return false end
local function moveAxisX(tx) while state.pos and state.pos.x~=tx do face(tx>state.pos.x and 2 or 4); if not forward() then return false end end; return true end
local function moveAxisZ(tz) while state.pos and state.pos.z~=tz do face(tz>state.pos.z and 3 or 1); if not forward() then return false end end; return true end
local function moveAxisY(ty) while state.pos and state.pos.y~=ty do if ty>state.pos.y then if not up() then return false end else if not down() then return false end end end; return true end
local function gotoPoint(p) if not state.pos then state.pos={x=p.x,y=p.y,z=p.z} end; return moveAxisY(p.y) and moveAxisX(p.x) and moveAxisZ(p.z) end
local function organizeInventory() -- best effort: slot 16 torches, slot 1 fuel, slot 2 filler
  for i=1,16 do local d=turtle.getItemDetail(i); if d and d.name and d.name:find("torch") and i~=16 then turtle.select(i); turtle.transferTo(16) end end
  turtle.select(1)
end
local function assign(msg) state.job=msg.job; state.sector=msg.sector; state.currentIndex=state.currentIndex or 1; state.status="MINING"; state.error=nil; save(); send({type="MINER_SAFE",jobId=state.job.id,sectorId=state.sector.id}); end
local function mineLoop()
  while true do
    if state.status=="MINING" and state.sector and state.sector.path then
      organizeInventory()
      if not state.pos then gpsTry(2); local first=state.sector.path[state.currentIndex or 1]; if first and not state.pos then state.pos={x=first.x,y=first.y,z=first.z} end end
      for i=state.currentIndex or 1, #state.sector.path do
        state.currentIndex=i; local p=state.sector.path[i]
        if state.job and state.job.origin and p.y < state.job.origin.y then state.currentIndex=i+1; save() else
          if not gotoPoint(p) then state.status="ERROR"; state.error=state.error or "Unable to move to path point"; save(); send({type="ERROR",role=role,id=id,error=state.error}); break end
          if i%20==0 then gpsTry(0.5) end
          state.progress=math.floor((i/#state.sector.path)*100); save(); draw()
        end
      end
      if state.status=="MINING" then state.status="IDLE"; state.progress=100; save(); send({type="SECTOR_COMPLETE",jobId=state.job.id,sectorId=state.sector.id}); state.job=nil; state.sector=nil; state.currentIndex=1; save() end
    end
    sleep(0.5)
  end
end
local function netLoop() register(); local lastReg=os.clock(); while true do local sender,msg=rednet.receive(PROTOCOL,1); if type(msg)=="table" then if msg.type=="REGISTER_ACK" then controllerId=sender elseif msg.type=="ROLL_CALL" then rednet.send(sender,{type="ROLL_CALL_RESPONSE",role=role,id=id,status=state.status,fuel=turtle.getFuelLevel(),gps=state.lastKnownGPS,gpsStatus=state.gpsStatus},PROTOCOL) elseif msg.type=="ASSIGN_JOB" or msg.type=="RESTORE_JOB" then controllerId=sender; assign(msg) elseif msg.type=="PAUSE_JOB" then state.status="IDLE"; save() elseif msg.type=="RESUME_JOB" and state.job then state.status="MINING"; save() elseif msg.type=="CANCEL_JOB" then state={role=role,status="IDLE",currentIndex=1,progress=0,gpsStatus=state.gpsStatus,lastKnownGPS=state.lastKnownGPS,pos=state.pos,facing=state.facing}; save() end end; if os.clock()-lastReg>10 then register(); lastReg=os.clock() end end end
local function heartLoop() while true do heartbeat(); draw(); sleep(5) end end
load(); modemSide=findModem(); gpsTry(5); draw("Boot GPS test complete."); if not modemSide then draw("ERROR: No modem."); while true do sleep(5) end end; rednet.open(modemSide); register(); send({type="REQUEST_ASSIGNMENT",role=role,id=id}); parallel.waitForAny(netLoop,heartLoop,mineLoop)
