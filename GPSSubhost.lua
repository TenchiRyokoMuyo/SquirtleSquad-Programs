-- SquirtleSquad GPSSubhost.lua
-- Persistent GPS anchor. Coordinates reset only by MainController GPS_RESET command.

local PROJECT="SquirtleSquad-Miner"
local ROLE="gps"
local VERSION="v2.0-loadout"
local PROTOCOL="TurtleTeamNet"
local DATA_DIR="SquirtleSquadData/GPSSubhost"
local STATE_FILE=DATA_DIR.."/gps_state.dat"
local HEARTBEAT_INTERVAL=5

local state={version=VERSION,id=os.getComputerID(),status="BOOTING",coords=nil,controllerId=nil,lastReset=nil}
local modemSide=nil
local running=true

local function ensureDir() if not fs.exists("SquirtleSquadData") then fs.makeDir("SquirtleSquadData") end if not fs.exists(DATA_DIR) then fs.makeDir(DATA_DIR) end end
local function copy(t) if type(t)~="table" then return t end local r={} for k,v in pairs(t) do r[k]=copy(v) end return r end
local function saveTable(path,t) ensureDir(); local h=fs.open(path,"w"); if not h then return false end h.write(textutils.serialize(t)); h.close(); return true end
local function loadTable(path) if not fs.exists(path) then return nil end local h=fs.open(path,"r"); if not h then return nil end local s=h.readAll(); h.close(); local ok,t=pcall(textutils.unserialize,s or ""); if ok and type(t)=="table" then return t end return nil end
local function saveState() state.version=VERSION; saveTable(STATE_FILE,state) end
local function loadState() local s=loadTable(STATE_FILE); if type(s)=="table" then for k,v in pairs(s) do state[k]=v end end end
local function now() return os.epoch("utc") end
local function color(c) if term.isColor and term.isColor() then term.setTextColor(c) end end
local function bcolor(c) if term.isColor and term.isColor() then term.setBackgroundColor(c) end end
local function clear() bcolor(colors.black); color(colors.lightGray); term.clear(); term.setCursorPos(1,1) end
local function center(y,text,c) local w=term.getSize(); color(c or colors.lightGray); term.setCursorPos(math.max(1,math.floor((w-#text)/2)+1),y); term.write(text) end
local function header(title) clear(); center(1,"SquirtleSquad GPS Subhost",colors.cyan); center(2,title or VERSION,colors.orange); term.setCursorPos(1,4); color(colors.lightGray) end
local function writeCoord(c) if not c then color(colors.red); term.write("unset"); color(colors.lightGray); return end color(colors.red); term.write("X "..c.x.." "); color(colors.yellow); term.write("Y "..c.y.." "); color(colors.blue); term.write("Z "..c.z); color(colors.lightGray) end
local function promptNumber(label,default) while true do term.write(label..(default and (" ["..default.."]") or "")..": "); local s=read(); if s=="" and default then return tonumber(default) end local n=tonumber(s); if n then return n end print("Enter a number.") end end
local function openModem() for _,n in ipairs(peripheral.getNames()) do if peripheral.getType(n)=="modem" then modemSide=n; if not rednet.isOpen(n) then rednet.open(n) end return true end end return false end
local function safePacket(packet) local p=copy(packet or {}); p.project=PROJECT; p.protocol=PROTOCOL; p.protocolVersion=2; p.senderRole=ROLE; p.senderId=os.getComputerID(); p.timestamp=now(); p.payload=p.payload or {}; if not pcall(textutils.serialize,p) then return nil end return p end
local function send(id,p) local q=safePacket(p); if not q then return false end return rednet.send(id,q,PROTOCOL) end
local function broadcast(p) local q=safePacket(p); if not q then return false end rednet.broadcast(q,PROTOCOL); return true end
local function validPacket(p) return type(p)=="table" and p.project==PROJECT and p.protocol==PROTOCOL and type(p.type)=="string" end
local function heartbeat() local pl={role=ROLE,status=state.status,pos=copy(state.coords),gpsValid=state.coords~=nil,homeValid=true,inventoryValid=true,atHome=true}; if state.controllerId then send(state.controllerId,{type="HEARTBEAT",payload=pl}) else broadcast({type="HEARTBEAT",payload=pl}) end end
local function register() broadcast({type="REGISTER",payload={role=ROLE,status=state.status,pos=copy(state.coords),gpsValid=state.coords~=nil,homeValid=true,inventoryValid=true,atHome=true}}) end
local function coordinateSetup() if state.coords then return end header("Coordinate Setup"); print("Set GPS subhost coordinates once."); print("They will persist until MainController sends reset."); state.coords={x=promptNumber("X"),y=promptNumber("Y"),z=promptNumber("Z")}; state.status="READY"; saveState() end
local function networkLoop() while running do local id,msg=rednet.receive(PROTOCOL,1); if id and validPacket(msg) then if msg.type=="REGISTER_ACK" then state.controllerId=id; saveState() elseif msg.type=="ROLL_CALL" then heartbeat() elseif msg.type=="GPS_RESET" then state.coords=nil; state.status="RESET_REQUIRED"; state.lastReset=now(); saveState(); header("GPS Reset"); print("Controller requested coordinate reset."); sleep(2); coordinateSetup(); register() end end end end
local function heartbeatLoop() while running do heartbeat(); sleep(HEARTBEAT_INTERVAL) end end
local function displayLoop() while running do header("Status"); print("ID: "..os.getComputerID()); print("Modem: "..tostring(modemSide or "missing")); print("Status: "..tostring(state.status)); term.write("Coordinates: "); writeCoord(state.coords); print(""); print("Controller: "..tostring(state.controllerId)); print("Coordinates persist across reboot."); print("Only MainController GPS_RESET clears them."); sleep(2) end end
local function gpsHostLoop() while running do if state.coords then state.status="HOSTING"; saveState(); shell.run("gps","host",tostring(state.coords.x),tostring(state.coords.y),tostring(state.coords.z)) else sleep(1) end end end
local function boot() ensureDir(); loadState(); header("Boot"); if not openModem() then print("No modem found."); return false end coordinateSetup(); state.status="READY"; saveState(); register(); return true end
if boot() then parallel.waitForAny(gpsHostLoop,networkLoop,heartbeatLoop,displayLoop) end
