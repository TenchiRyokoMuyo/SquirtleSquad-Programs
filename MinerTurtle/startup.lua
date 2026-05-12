-- TurtleTeamNet Miner Turtle startup.lua v12 Compact Jobs
-- No Ctrl+T lockout. Computes shape positions on demand; no huge point tables.

local PROTOCOL="TurtleTeamNet"
local STATE_FILE="miner_state.dat"
local role="miner"
local id=os.getComputerID()
local modemSide=nil
local controllerId=nil
local state={role=role,status="LISTENING",job=nil,sector=nil,currentIndex=1,gpsStatus="unknown",lastGPS=nil,error=nil}
local facing=0 -- 0 north(-z),1 east(+x),2 south(+z),3 west(-x)
local pos=nil

local function save() local f=fs.open(STATE_FILE,"w"); if f then f.write(textutils.serialize(state)); f.close() end end
local function load() if fs.exists(STATE_FILE) then local f=fs.open(STATE_FILE,"r"); local s=f.readAll(); f.close(); local t=textutils.unserialize(s); if type(t)=="table" then for k,v in pairs(t) do state[k]=v end end end end
local function findModem() for _,side in ipairs(peripheral.getNames()) do if peripheral.getType(side)=="modem" then return side end end end
local function gpsTry(timeout) local x,y,z=gps.locate(timeout or 2); if x then state.gpsStatus="ok"; state.lastGPS={x=math.floor(x+0.5),y=math.floor(y+0.5),z=math.floor(z+0.5)}; pos={x=state.lastGPS.x,y=state.lastGPS.y,z=state.lastGPS.z}; return pos end state.gpsStatus="unavailable"; return nil end
local function send(msg) if controllerId then rednet.send(controllerId,msg,PROTOCOL) else rednet.broadcast(msg,PROTOCOL) end end
local function status(extra) term.clear(); term.setCursorPos(1,1); print("Miner Turtle #"..id); print("Status: "..tostring(state.status)); print("Controller: "..tostring(controllerId)); print("GPS: "..tostring(state.gpsStatus)); if state.job then print("Job: "..state.job.id.." "..state.job.shape); print("Sector: "..(state.sector and state.sector.id or "?")); print("Index: "..tostring(state.currentIndex).." / "..tostring(state.sector and state.sector.totalEstimate or state.job.totalEstimate or "?")) end; if state.error then print("ERROR: "..state.error) end; if extra then print(extra) end end
local function register() send({type="REGISTER",role=role,id=id,status=state.status,gps=gpsTry(1),gpsStatus=state.gpsStatus}) end
local function heartbeat() send({type="HEARTBEAT",role=role,id=id,status=state.status,fuel=turtle.getFuelLevel(),gps=state.lastGPS,gpsStatus=state.gpsStatus,jobId=state.job and state.job.id,sectorId=state.sector and state.sector.id,currentIndex=state.currentIndex}) end

local fuelNames={ ["minecraft:coal"]=true,["minecraft:charcoal"]=true,["minecraft:coal_block"]=true,["minecraft:lava_bucket"]=true }
local function organizeInventory()
  for i=1,16 do local d=turtle.getItemDetail(i); if d and fuelNames[d.name] and i~=1 then turtle.select(i); turtle.transferTo(1) end end
  for i=1,16 do local d=turtle.getItemDetail(i); if d and d.name:find("torch") and i~=16 then turtle.select(i); turtle.transferTo(16) end end
  if turtle.getItemCount(2)==0 then for i=3,15 do local d=turtle.getItemDetail(i); if d and not fuelNames[d.name] and not d.name:find("torch") then turtle.select(i); turtle.transferTo(2); break end end end
  turtle.select(1); if turtle.getFuelLevel() < 200 and turtle.getItemCount(1)>0 then turtle.refuel(math.min(16,turtle.getItemCount(1))) end
end
local protectedSubstrings={"chest","barrel","shulker","drawer","computer","turtle","modem","monitor","disk_drive","scaffold","scaffolding","spawner","create:"}
local function protected(name) if not name then return false end; for _,s in ipairs(protectedSubstrings) do if name:find(s) then return true end end; return false end
local function inspectDir(dir) if dir=="up" then return turtle.inspectUp() elseif dir=="down" then return turtle.inspectDown() else return turtle.inspect() end end
local function digDir(dir)
  local ok,d=inspectDir(dir); if ok and d and protected(d.name) then state.status="ERROR"; state.error="Protected block: "..d.name; save(); send({type="ERROR",role=role,id=id,error=state.error}); return false end
  if dir=="up" then return turtle.digUp() elseif dir=="down" then return turtle.digDown() else return turtle.dig() end
end
local function updateForward() if not pos then return end; if facing==0 then pos.z=pos.z-1 elseif facing==1 then pos.x=pos.x+1 elseif facing==2 then pos.z=pos.z+1 else pos.x=pos.x-1 end end
local function turnLeft() turtle.turnLeft(); facing=(facing+3)%4 end
local function turnRight() turtle.turnRight(); facing=(facing+1)%4 end
local function face(f) while facing~=f do turnRight() end end
local function forward()
  for i=1,3 do if turtle.forward() then updateForward(); return true end; if not digDir("forward") then return false end; sleep(0.2) end
  return false
end
local function up() for i=1,3 do if turtle.up() then if pos then pos.y=pos.y+1 end; return true end; if not digDir("up") then return false end; sleep(0.2) end; return false end
local function down(minY) if pos and pos.y<=minY then return false end; for i=1,3 do if turtle.down() then if pos then pos.y=pos.y-1 end; return true end; if not digDir("down") then return false end; sleep(0.2) end; return false end
local function gotoXYZ(target)
  local minY=state.job.origin.y
  if not pos then pos={x=target.x,y=target.y,z=target.z}; return true end
  while pos.y < target.y do if not up() then return false end end
  while pos.x ~= target.x do face(pos.x < target.x and 1 or 3); if not forward() then return false end end
  while pos.z ~= target.z do face(pos.z < target.z and 2 or 0); if not forward() then return false end end
  while pos.y > target.y do if not down(minY) then return false end end
  return true
end

local function inside(shape,p,x,y,z)
  if shape=="rectangular_prism" then return x>=0 and x<p.sideA and z>=0 and z<p.sideB and y>=0 and y<p.height end
  if shape=="cylinder" then return y>=0 and y<p.height and x*x+z*z <= p.radius*p.radius end
  if shape=="dome" then return y>=0 and y<=p.radius and x*x+z*z+y*y <= p.radius*p.radius end
  if shape=="pyramid" then if y<0 or y>=p.height then return false end; local k=1-y/p.height; return math.abs(x)<=p.sideA*k/2 and math.abs(z)<=p.sideB*k/2 end
  if shape=="cone" then if y<0 or y>=p.height then return false end; local r=p.radius*(1-y/p.height); return x*x+z*z<=r*r end
  return true
end
local function indexToPoint(job, sector, idx)
  local p=job.params or {}; local o=job.origin
  local y0=sector.yStart or 0; local y1=sector.yEnd or ((p.height or p.radius or 1)-1)
  local count=0
  if job.shape=="rectangular_prism" then
    for y=y0,y1 do for z=0,(p.sideB or 1)-1 do for x=0,(p.sideA or 1)-1 do count=count+1; if count==idx then return {x=o.x+x,y=o.y+y,z=o.z+z} end end end end
  elseif job.shape=="cylinder" or job.shape=="dome" or job.shape=="cone" or job.shape=="pyramid" then
    local r=math.max(p.radius or p.sideA or 1, p.sideB or p.radius or 1)
    for y=y0,y1 do for z=-r,r do for x=-r,r do if inside(job.shape,p,x,y,z) then count=count+1; if count==idx then return {x=o.x+x,y=o.y+y,z=o.z+z} end end end end end
  elseif job.shape=="tunnel" or job.shape=="tunnel_spline" or job.shape=="stretched_cylinder" then
    local x2,y2,z2=p.x2 or o.x,p.y2 or o.y,p.z2 or o.z; local len=math.max(1,p.length or 1); local width=p.width or (p.radius and p.radius*2+1) or 3; local rad=math.floor(width/2)
    for step=0,len do local t=step/len; local cx=math.floor(o.x+(x2-o.x)*t+0.5); local cy=math.floor(o.y+(y2-o.y)*t+0.5); local cz=math.floor(o.z+(z2-o.z)*t+0.5); for yy=-rad,rad do for zz=-rad,rad do for xx=-rad,rad do if xx*xx+yy*yy+zz*zz<=rad*rad then count=count+1; if count==idx then return {x=cx+xx,y=cy+yy,z=cz+zz} end end end end end end
  end
  return nil
end
local function shouldPlaceTorch(pt) local sp=(state.job and state.job.torchSpacing) or 8; return sp>0 and ((math.abs(pt.x)+math.abs(pt.z)) % sp == 0) and pt.y==state.job.origin.y end
local function placeTorch() if turtle.getItemCount(16)<=0 then return end; turtle.select(16); turtle.placeDown() end
local function mineLoop()
  if not state.job or not state.sector then return end
  state.status="MINING"; state.error=nil; save(); organizeInventory(); gpsTry(2)
  while state.job and state.sector and state.status=="MINING" do
    local pt=indexToPoint(state.job,state.sector,state.currentIndex)
    if not pt then state.status="IDLE"; send({type="SECTOR_COMPLETE",role=role,id=id,jobId=state.job.id,sectorId=state.sector.id}); state.job=nil; state.sector=nil; state.currentIndex=1; save(); return end
    status("Moving to "..pt.x..","..pt.y..","..pt.z)
    if not gotoXYZ(pt) then state.status="ERROR"; state.error=state.error or "Unable to path"; save(); send({type="ERROR",role=role,id=id,error=state.error}); return end
    digDir("up") -- ceiling of current cell only, never below origin
    if shouldPlaceTorch(pt) then placeTorch() end
    state.currentIndex=state.currentIndex+1; if state.currentIndex%10==0 then save(); heartbeat() end
    if turtle.getFuelLevel()~= "unlimited" and turtle.getFuelLevel()<50 then state.status="ERROR"; state.error="Low fuel"; save(); send({type="ERROR",role=role,id=id,error=state.error}); return end
  end
end
local function assign(msg) state.job=msg.job; state.sector=msg.sector; state.currentIndex=(msg.sector and msg.sector.currentIndex) or 1; state.status="MINING"; state.error=nil; controllerId=msg.controllerId or controllerId; save(); send({type="MINER_SAFE",role=role,id=id,jobId=state.job.id,sectorId=state.sector.id}); mineLoop() end
local function netLoop()
  register(); local lastReg=os.clock(); while true do local sender,msg=rednet.receive(PROTOCOL,1); if type(msg)=="table" then if msg.type=="REGISTER_ACK" then controllerId=sender elseif msg.type=="ROLL_CALL" then rednet.send(sender,{type="ROLL_CALL_RESPONSE",role=role,id=id,status=state.status,gps=state.lastGPS,gpsStatus=state.gpsStatus,fuel=turtle.getFuelLevel()},PROTOCOL) elseif msg.type=="ASSIGN_JOB" or msg.type=="RESTORE_JOB" then controllerId=sender; assign(msg) elseif msg.type=="PAUSE_JOB" then state.status="LISTENING"; save() elseif msg.type=="RESUME_JOB" then if state.job then state.status="MINING"; save(); mineLoop() end elseif msg.type=="CANCEL_JOB" then state={role=role,status="LISTENING",currentIndex=1,gpsStatus=state.gpsStatus,lastGPS=state.lastGPS}; save() end end; if os.clock()-lastReg>10 then register(); lastReg=os.clock() end end
end
local function heartLoop() while true do heartbeat(); status(); sleep(5) end end
load(); modemSide=findModem(); if not modemSide then status("ERROR: No modem. Attach modem and reboot."); return end; rednet.open(modemSide); gpsTry(5); organizeInventory(); parallel.waitForAny(netLoop, heartLoop)
