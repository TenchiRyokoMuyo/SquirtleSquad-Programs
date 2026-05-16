-- SquirtleSquad ForemanTurtle.lua
-- Optional support turtle. Foremen are never required for mining.
-- v2.1: GPS quorum, rogue lockout, safe home return, follow assignment scaffold.

local PROJECT="SquirtleSquad-Miner"
local ROLE="foreman"
local VERSION="v2.1-fullpass"
local PROTOCOL="TurtleTeamNet"
local DATA_DIR="SquirtleSquadData/ForemanTurtle"
local STATE_FILE=DATA_DIR.."/foreman_state.dat"
local HEARTBEAT_INTERVAL=5
local DIRS={north={dx=0,dz=-1},east={dx=1,dz=0},south={dx=0,dz=1},west={dx=-1,dz=0}}
local ORDER={"north","east","south","west"}
local state={version=VERSION,id=os.getComputerID(),label=os.getComputerLabel(),controllerId=nil,status="BOOTING",home=nil,homeFacing=nil,pos=nil,facing=nil,gpsValid=false,atHome=false,assignedMiner=nil,minerPos=nil,job=nil,rogue=false,lastProblem=nil}
local modemSide=nil
local running=true
local phase="idle"
local function ensureDir() if not fs.exists("SquirtleSquadData") then fs.makeDir("SquirtleSquadData") end if not fs.exists(DATA_DIR) then fs.makeDir(DATA_DIR) end end
local function copy(t) if type(t)~="table" then return t end local r={} for k,v in pairs(t) do r[k]=copy(v) end return r end
local function saveTable(p,t) ensureDir(); local h=fs.open(p,"w"); if not h then return false end h.write(textutils.serialize(t)); h.close(); return true end
local function loadTable(p) if not fs.exists(p) then return nil end local h=fs.open(p,"r"); if not h then return nil end local s=h.readAll(); h.close(); local ok,t=pcall(textutils.unserialize,s or ""); if ok and type(t)=="table" then return t end return nil end
local function saveState() state.version=VERSION; state.label=os.getComputerLabel(); saveTable(STATE_FILE,state) end
local function loadState() local s=loadTable(STATE_FILE); if type(s)=="table" then for k,v in pairs(s) do state[k]=v end end end
local function now() return os.epoch("utc") end
local function samePos(a,b) return a and b and a.x==b.x and a.y==b.y and a.z==b.z end
local function color(c) if term.isColor and term.isColor() then term.setTextColor(c) end end
local function bcolor(c) if term.isColor and term.isColor() then term.setBackgroundColor(c) end end
local function clear() bcolor(colors.black); color(colors.lightGray); term.clear(); term.setCursorPos(1,1) end
local function center(y,t,c) local w=term.getSize(); color(c or colors.lightGray); term.setCursorPos(math.max(1,math.floor((w-#t)/2)+1),y); term.write(t) end
local function header(t) clear(); center(1,"SquirtleSquad Foreman",colors.cyan); center(2,t or VERSION,colors.orange); term.setCursorPos(1,4); color(colors.lightGray) end
local function writeCoord(c) if not c then color(colors.red); term.write("unknown"); color(colors.lightGray); return end color(colors.red); term.write("X "..c.x.." "); color(colors.yellow); term.write("Y "..c.y.." "); color(colors.blue); term.write("Z "..c.z); color(colors.lightGray) end
local function openModem() for _,n in ipairs(peripheral.getNames()) do if peripheral.getType(n)=="modem" then modemSide=n; if not rednet.isOpen(n) then rednet.open(n) end return true end end return false end
local function safePacket(p) if type(p)~="table" then return nil end local q=copy(p); q.project=PROJECT; q.protocol=PROTOCOL; q.protocolVersion=2; q.senderRole=ROLE; q.senderId=os.getComputerID(); q.timestamp=now(); q.payload=q.payload or {}; if not pcall(textutils.serialize,q) then return nil end return q end
local function send(id,p) local q=safePacket(p); if not q then return false end return rednet.send(id,q,PROTOCOL) end
local function broadcast(p) local q=safePacket(p); if not q then return false end rednet.broadcast(q,PROTOCOL); return true end
local function validPacket(p) return type(p)=="table" and p.project==PROJECT and p.protocol==PROTOCOL and type(p.type)=="string" end
local function locate(timeout) local x,y,z=gps.locate(timeout or 2); if x then return {x=math.floor(x+0.5),y=math.floor(y+0.5),z=math.floor(z+0.5)} end return nil end
local function requestAnchors() if state.controllerId then send(state.controllerId,{type="ANCHOR_REQUEST",payload={}}) else broadcast({type="ANCHOR_REQUEST",payload={}}) end local deadline=os.clock()+8 while os.clock()<deadline do local id,msg=rednet.receive(PROTOCOL,1); if id and validPacket(msg) then if msg.type=="ANCHOR_STATUS" then state.controllerId=id; return msg.payload elseif msg.type=="REGISTER_ACK" then state.controllerId=id; return msg.payload and msg.payload.anchors end end end return nil end
local function gpsQuorum() local p=locate(2); state.gpsValid=false; if not p then saveState(); return false,"gps.locate failed" end local a=requestAnchors(); if not a or not a.ok or (a.gpsSubhosts or 0)<3 then state.pos=p; saveState(); return false,"4 GPS anchors unavailable" end state.pos=p; state.gpsValid=true; state.atHome=samePos(state.pos,state.home); saveState(); return true end
local function faceIndex(f) for i,v in ipairs(ORDER) do if v==f then return i end end return 1 end
local function turnLeft() turtle.turnLeft(); state.facing=ORDER[((faceIndex(state.facing)-2)%4)+1]; saveState() end
local function turnRight() turtle.turnRight(); state.facing=ORDER[(faceIndex(state.facing)%4)+1]; saveState() end
local function face(f) while state.facing~=f do local ci,ti=faceIndex(state.facing),faceIndex(f); if ((ti-ci)%4)==1 then turnRight() else turnLeft() end end end
local function targetForward() local d=DIRS[state.facing]; return {x=state.pos.x+d.dx,y=state.pos.y,z=state.pos.z+d.dz} end
local function promptFacing() while true do header("Home Facing"); print("1 north\n2 east\n3 south\n4 west"); local n=tonumber(read()); if n and ORDER[n] then return ORDER[n] end end end
local function heartbeat() local pl={role=ROLE,status=state.status,pos=copy(state.pos),home=copy(state.home),homeValid=state.home~=nil,inventoryValid=true,gpsValid=state.gpsValid,atHome=samePos(state.pos,state.home),assignedMiner=state.assignedMiner,rogue=state.rogue}; if state.controllerId then send(state.controllerId,{type="HEARTBEAT",payload=pl}) else broadcast({type="HEARTBEAT",payload=pl}) end end
local function register() broadcast({type="REGISTER",payload={role=ROLE,label=os.getComputerLabel(),status=state.status,pos=copy(state.pos),home=copy(state.home),homeValid=state.home~=nil,inventoryValid=true,gpsValid=state.gpsValid,atHome=samePos(state.pos,state.home),rogue=state.rogue}}) end
local function markRogue(reason) state.rogue=true; state.status="ROGUE"; state.lastProblem=reason; saveState(); pcall(os.setComputerLabel,"ROGUE-Foreman-"..os.getComputerID()); if state.controllerId then send(state.controllerId,{type="ROGUE",payload={reason=reason,pos=copy(state.pos)}}) else broadcast({type="ROGUE",payload={reason=reason,pos=copy(state.pos)}}) end error("ROGUE: "..tostring(reason),0) end
local function moveForward() if not gpsQuorum() then return false end if turtle.detect() then return false end local t=targetForward(); if turtle.forward() then state.pos=t; saveState(); return true end return false end
local function moveUp() if not gpsQuorum() then return false end if turtle.detectUp() then return false end if turtle.up() then state.pos={x=state.pos.x,y=state.pos.y+1,z=state.pos.z}; saveState(); return true end return false end
local function moveDown() if not gpsQuorum() then return false end if turtle.detectDown() then return false end if turtle.down() then state.pos={x=state.pos.x,y=state.pos.y-1,z=state.pos.z}; saveState(); return true end return false end
local function goY(y) while state.pos.y<y do if not moveUp() then return false end end while state.pos.y>y do if not moveDown() then return false end end return true end
local function goX(x) while state.pos.x<x do face("east"); if not moveForward() then return false end end while state.pos.x>x do face("west"); if not moveForward() then return false end end return true end
local function goZ(z) while state.pos.z<z do face("south"); if not moveForward() then return false end end while state.pos.z>z do face("north"); if not moveForward() then return false end end return true end
local function goTo(p) if not gpsQuorum() then return false end if not goY(p.y) then return false end if not goX(p.x) then return false end if not goZ(p.z) then return false end return gpsQuorum() end
local function returnHome(reason) state.status="RETURNING"; phase="to_home"; saveState(); if not state.home or not goTo(state.home) or not samePos(state.pos,state.home) then markRogue(reason or "Unable to return home") end face(state.homeFacing); state.status="AT_HOME"; phase="idle"; saveState(); heartbeat() end
local function followTick() if not state.job or not state.minerPos then return end local target={x=state.minerPos.x,y=state.job.origin.y,z=state.minerPos.z}; if math.abs((state.pos.x or 0)-target.x)<=3 and math.abs((state.pos.z or 0)-target.z)<=3 and state.pos.y==target.y then return end state.status="FOLLOWING"; goY(target.y); if math.abs(state.pos.x-target.x)>3 then goX(target.x + (state.pos.x<target.x and -3 or 3)) end; if math.abs(state.pos.z-target.z)>3 then goZ(target.z + (state.pos.z<target.z and -3 or 3)) end; saveState() end
local function handlePacket(id,msg) if not validPacket(msg) then return end if msg.type=="REGISTER_ACK" then state.controllerId=id; saveState() elseif msg.type=="ROLL_CALL" then heartbeat() elseif msg.type=="GO_HOME" then returnHome("Controller ordered home") elseif msg.type=="EMERGENCY_STOP_RETURN" then returnHome("Controller kill switch") elseif msg.type=="KILL_SWITCH_CLEAR" then if state.rogue and samePos(state.pos,state.home) then state.rogue=false; state.status="AT_HOME"; pcall(os.setComputerLabel,"Foreman-"..os.getComputerID()); saveState() end elseif msg.type=="FOREMAN_ASSIGN" then state.controllerId=id; state.assignedMiner=msg.payload and msg.payload.minerId; state.job=msg.payload and msg.payload.job; state.status="ASSIGNED"; saveState(); heartbeat() elseif msg.type=="MINER_POSITION" then if msg.payload and msg.payload.minerId==state.assignedMiner then state.minerPos=msg.payload.pos end end end
local function networkLoop() while running do local id,msg=rednet.receive(PROTOCOL,1); if id then handlePacket(id,msg) end end end
local function heartbeatLoop() while running do heartbeat(); sleep(HEARTBEAT_INTERVAL) end end
local function followLoop() while running do if state.rogue then sleep(2) elseif state.assignedMiner and state.job then followTick(); sleep(1) else sleep(1) end end end
local function displayLoop() while running do header("Status"); print("ID: "..os.getComputerID()); print("Status: "..tostring(state.status)); term.write("Pos: "); writeCoord(state.pos); print(""); term.write("Home: "); writeCoord(state.home); print(""); print("Assigned miner: "..tostring(state.assignedMiner)); print("GPS: "..tostring(state.gpsValid)); if state.rogue then color(colors.red); print("ROGUE LOCK: place at saved home and reboot."); color(colors.lightGray) end sleep(2) end end
local function boot() ensureDir(); loadState(); header("Boot"); if not openModem() then print("No modem found."); return false end local ok,why=gpsQuorum(); if not ok then print("GPS invalid: "..tostring(why)); return false end if state.rogue then if state.home and samePos(state.pos,state.home) then state.rogue=false; state.status="AT_HOME"; pcall(os.setComputerLabel,"Foreman-"..os.getComputerID()); saveState() else print("Rogue lock. Place at home and reboot."); return false end end if not state.home then state.home=copy(state.pos); state.homeFacing=promptFacing(); state.facing=state.homeFacing end state.status=samePos(state.pos,state.home) and "AT_HOME" or "WAITING"; saveState(); register(); return true end
if boot() then parallel.waitForAny(networkLoop,heartbeatLoop,followLoop,displayLoop) end
