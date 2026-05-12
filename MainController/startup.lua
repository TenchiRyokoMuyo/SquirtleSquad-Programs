-- TurtleTeam Main Controller startup.lua v11
-- GPS subhosts are locked/unchanged. Controller no longer blocks jobs because gps.locate fails on itself.
-- Requires: controller_gps.dat, shared_storage.dat optional existing files.

local PROTOCOL = "TurtleTeamNet"
local STATE_FILE = "controller_state.dat"
local GPS_FILE = "controller_gps.dat"
local STORAGE_FILE = "shared_storage.dat"
local HOSTNAME = "MainController"

local state = {
  jobs = {}, miners = {}, foremen = {}, gpsHosts = {}, logs = {},
  nextJobId = 1, hiddenGpsStarted = false, gpsHostStatus = "waiting"
}
local storage = { fuelTorchesChest = nil, depositChest = nil }
local controllerGPS = nil
local modemSide, mon
local running = true
local terminal = term.current()

local function now() return os.clock() end
local function log(s)
  table.insert(state.logs, 1, textutils.formatTime(os.time(), true).." "..tostring(s))
  while #state.logs > 100 do table.remove(state.logs) end
end
local function safeSerialize(t) return textutils.serialize(t) end
local function readTable(path, fallback)
  if not fs.exists(path) then return fallback end
  local f = fs.open(path, "r"); if not f then return fallback end
  local s = f.readAll(); f.close()
  local ok, t = pcall(textutils.unserialize, s)
  if ok and type(t) == "table" then return t end
  return fallback
end
local function writeTable(path, t)
  local f = fs.open(path, "w"); if not f then return false end
  f.write(safeSerialize(t)); f.close(); return true
end
local function normalizeState()
  state.jobs = state.jobs or {}
  state.miners = state.miners or {}
  state.foremen = state.foremen or {}
  state.gpsHosts = state.gpsHosts or {}
  state.logs = state.logs or {}
  state.nextJobId = state.nextJobId or 1
  state.gpsHostStatus = state.gpsHostStatus or "waiting"
end
local function saveState() normalizeState(); writeTable(STATE_FILE, state) end
local function saveStorage() writeTable(STORAGE_FILE, storage) end
local function loadAll()
  state = readTable(STATE_FILE, state); normalizeState()
  storage = readTable(STORAGE_FILE, storage) or storage
  if storage.fuelChest and not storage.fuelTorchesChest then storage.fuelTorchesChest = storage.fuelChest; storage.fuelChest = nil end
  controllerGPS = readTable(GPS_FILE, nil)
end
local function detectMonitor()
  mon = nil
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then
      mon = peripheral.wrap(name)
      mon.setTextScale(0.5)
      break
    end
  end
end
local function detectModem()
  modemSide = nil
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then modemSide = name; break end
  end
end
local function drawLine(target, y, text)
  local w,h = target.getSize()
  if y < 1 or y > h then return end
  target.setCursorPos(1,y); target.clearLine(); target.write(tostring(text):sub(1,w))
end
local function bootLine(s)
  term.redirect(terminal); print(s)
  if mon then local _,h=mon.getSize(); local y=select(2,mon.getCursorPos()); if y>h then mon.clear(); mon.setCursorPos(1,1); y=1 end; mon.write(s:sub(1,select(1,mon.getSize()))); mon.setCursorPos(1,y+1) end
end
local function cleanList(tbl, ttl)
  local c = 0
  for id, t in pairs(tbl or {}) do
    if type(t) == "table" and t.lastSeen and now() - t.lastSeen <= ttl then c = c + 1 end
  end
  return c
end
local function minerCount() return cleanList(state.miners, 45) end
local function foremanCount() return cleanList(state.foremen, 45) end
local function gpsSubhostCount() return cleanList(state.gpsHosts, 90) end
local function drawDashboard(target)
  if not target then return end
  target.clear(); target.setCursorPos(1,1)
  local y = 1
  drawLine(target,y,"TurtleTeam Dashboard v11"); y=y+1
  drawLine(target,y,string.rep("-",40)); y=y+1
  local gpsText = controllerGPS and (controllerGPS.x..","..controllerGPS.y..","..controllerGPS.z) or "not set"
  drawLine(target,y,"GPS host coords: "..gpsText); y=y+1
  drawLine(target,y,"GPS subhosts: "..gpsSubhostCount().." active"); y=y+1
  drawLine(target,y,"GPS constellation: "..(gpsSubhostCount()+1).." total hosts"); y=y+1
  drawLine(target,y,"Client GPS: use miner reports"); y=y+1
  drawLine(target,y,"Miners: "..minerCount().."  Foremen: "..foremanCount()); y=y+1
  drawLine(target,y,"Fuel/Torches: "..tostring(storage.fuelTorchesChest or "not set")); y=y+1
  drawLine(target,y,"Deposit: "..tostring(storage.depositChest or "not set")); y=y+1
  y=y+1; drawLine(target,y,"Jobs:"); y=y+1
  local any=false
  for _,j in pairs(state.jobs) do
    any=true
    drawLine(target,y,"#"..j.id.." "..j.shape.." "..j.status.." "..(j.progress or 0).."%"); y=y+1
  end
  if not any then drawLine(target,y,"No jobs created.") end
end
local function drawAllDash() detectMonitor(); if mon then drawDashboard(mon) end end
local function promptNumber(label, default)
  term.redirect(terminal); write(label..(default and " ["..default.."]" or "")..": ")
  local s=read(); if s=="" and default then return default end
  return tonumber(s)
end
local function promptText(label, default)
  term.redirect(terminal); write(label..(default and " ["..default.."]" or "")..": ")
  local s=read(); if s=="" and default then return default end
  return s
end
local function getGpsCoords()
  if controllerGPS and controllerGPS.x then return end
  term.redirect(terminal); term.clear(); term.setCursorPos(1,1)
  print("Controller GPS coordinates missing.")
  controllerGPS = { x=promptNumber("X"), y=promptNumber("Y"), z=promptNumber("Z") }
  writeTable(GPS_FILE, controllerGPS)
end
local function startGpsHost()
  if not controllerGPS then return end
  state.gpsHostStatus = "starting"
  local args = {"gps", "host", tostring(controllerGPS.x), tostring(controllerGPS.y), tostring(controllerGPS.z)}
  if multishell then
    local id = multishell.launch({}, table.unpack(args))
    if id then multishell.setTitle(id, "GPS Host"); state.gpsHostStatus = "running in tab" else state.gpsHostStatus = "failed" end
  else
    parallel.waitForAny(function() shell.run(table.unpack(args)) end, function() sleep(0.1) end)
    state.gpsHostStatus = "started"
  end
end
local function sendPacket(id,msg) rednet.send(id,msg,PROTOCOL) end
local function broadcast(msg) rednet.broadcast(msg,PROTOCOL) end
local function safeJobCopy(j)
  return {id=j.id, shape=j.shape, status=j.status, origin=j.origin, params=j.params, torchSpacing=j.torchSpacing, created=j.created}
end
local function safeSectorCopy(s)
  return {id=s.id, index=s.index, bounds=s.bounds, path=s.path, torchPlan=s.torchPlan or {}, status=s.status}
end
local function buildAssignPacket(j,s,team)
  return {
    type="ASSIGN_JOB", job=safeJobCopy(j), sector=safeSectorCopy(s),
    team={minerId=team and team.minerId, foremanId=team and team.foremanId},
    sharedStorage={fuelTorchesChest=storage.fuelTorchesChest, depositChest=storage.depositChest},
    inventoryPolicy={fuelSlot=1,fillerSlot=2,lootStart=3,lootEnd=15,torchSlot=16},
    torchPolicy={wallFirst=true,floorSecond=true,spacing=j.torchSpacing or 8},
    fillerPolicy={enabled=true,fillOvercutSidewalls=true,fillCeiling=true,doNotFillInsideShape=true},
    controllerGPS=controllerGPS
  }
end
local function menu(title, items)
  term.redirect(terminal); local sel,top=1,1
  while true do
    term.clear(); term.setCursorPos(1,1)
    print(title); print(string.rep("-", math.min(#title, 40)))
    local w,h=term.getSize(); local visible=h-5
    if sel<top then top=sel end; if sel>top+visible-1 then top=sel-visible+1 end
    for i=top, math.min(#items, top+visible-1) do
      print((i==sel and "> " or "  ")..items[i].label)
    end
    term.setCursorPos(1,h-1); write("Up/Down Enter Q/Esc")
    term.setCursorPos(1,h); write("Item "..sel.."/"..#items)
    local e,k=os.pullEvent("key")
    if k==keys.up then sel=math.max(1,sel-1)
    elseif k==keys.down then sel=math.min(#items,sel+1)
    elseif k==keys.enter then return items[sel]
    elseif k==keys.q or k==keys.escape then return nil end
  end
end
local function infoScreen(title, lines)
  term.redirect(terminal); local top=1
  while true do
    term.clear(); term.setCursorPos(1,1); print(title); print(string.rep("-", math.min(#title,40)))
    local _,h=term.getSize(); local visible=h-4
    for i=top, math.min(#lines, top+visible-1) do print(lines[i]) end
    term.setCursorPos(1,h); write("Up/Down scroll, Q back")
    local _,k=os.pullEvent("key")
    if k==keys.up then top=math.max(1,top-1)
    elseif k==keys.down then top=math.min(math.max(1,#lines-visible+1),top+1)
    elseif k==keys.q or k==keys.escape or k==keys.enter then return end
  end
end
local function configureStorage()
  term.redirect(terminal); term.clear(); term.setCursorPos(1,1)
  storage.fuelTorchesChest = promptText("Fuel/Torches chest label", storage.fuelTorchesChest or "Fuel/Torches")
  storage.depositChest = promptText("Deposit chest label", storage.depositChest or "Community Deposit")
  saveStorage(); log("Storage configured")
end
local function hasStorage() return storage.fuelTorchesChest and storage.depositChest end
local function generatePath(shape, origin, params)
  local path = {}
  local ox,oy,oz=origin.x,origin.y,origin.z
  local function add(x,y,z) table.insert(path,{x=x,y=y,z=z}) end
  if shape=="rect_prism" then
    local a,b,h=params.sideA,params.sideB,params.height
    for y=0,h-1 do for z=0,b-1 do for x=0,a-1 do add(ox+x,oy+y,oz+z) end end end
  elseif shape=="cylinder" then
    local r,h=params.radius,params.height
    for y=0,h-1 do for z=-r,r do for x=-r,r do if x*x+z*z<=r*r then add(ox+x,oy+y,oz+z) end end end end
  elseif shape=="dome" then
    local r=params.radius
    for y=0,r do local rr=math.floor(math.sqrt(math.max(0,r*r-y*y))) for z=-rr,rr do for x=-rr,rr do if x*x+z*z<=rr*rr then add(ox+x,oy+y,oz+z) end end end end
  elseif shape=="cone" then
    local r,h=params.radius,params.height
    for y=0,h-1 do local rr=math.max(0,math.floor(r*(1-y/math.max(1,h-1)))) for z=-rr,rr do for x=-rr,rr do if x*x+z*z<=rr*rr then add(ox+x,oy+y,oz+z) end end end end
  elseif shape=="pyramid" then
    local a,b,h=params.sideA,params.sideB,params.height
    for y=0,h-1 do local sx=math.max(1,math.floor(a*(1-y/math.max(1,h)))) local sz=math.max(1,math.floor(b*(1-y/math.max(1,h)))) for z=0,sz-1 do for x=0,sx-1 do add(ox+x,oy+y,oz+z) end end end
  elseif shape=="tunnel" or shape=="tunnel_spline" then
    local dx,dy,dz=params.x2-ox,params.y2-oy,params.z2-oz; local steps=math.max(math.abs(dx),math.abs(dy),math.abs(dz),1); local w=params.width or 3; local rad=math.floor(w/2)
    for i=0,steps do local x=math.floor(ox+dx*i/steps+0.5); local y=math.floor(oy+dy*i/steps+0.5); local z=math.floor(oz+dz*i/steps+0.5); for yy=-rad,rad do for zz=-rad,rad do for xx=-rad,rad do if xx*xx+yy*yy+zz*zz<=rad*rad then add(x+xx,y+yy,z+zz) end end end end end
  elseif shape=="stretched_cylinder" then
    local x2,y2,z2=params.x2,params.y2,params.z2; local r=params.radius; local dx,dy,dz=x2-ox,y2-oy,z2-oz; local steps=math.max(math.abs(dx),math.abs(dy),math.abs(dz),1)
    for i=0,steps do local cx=math.floor(ox+dx*i/steps+0.5); local cy=math.floor(oy+dy*i/steps+0.5); local cz=math.floor(oz+dz*i/steps+0.5); for yy=-r,r do for zz=-r,r do for xx=-r,r do if xx*xx+yy*yy+zz*zz<=r*r then add(cx+xx,cy+yy,cz+zz) end end end end end
  end
  return path
end
local function createJob()
  if not hasStorage() then infoScreen("Storage required", {"Configure Fuel/Torches and Deposit chests before creating jobs."}); return end
  local shapeItem = menu("Choose Shape", {
    {label="Rectangular Prism",shape="rect_prism"},{label="Cylinder",shape="cylinder"},{label="Dome",shape="dome"},{label="Stretched Cylinder",shape="stretched_cylinder"},{label="Pyramid",shape="pyramid"},{label="Cone",shape="cone"},{label="Tunnel",shape="tunnel"},{label="Tunnel Spline",shape="tunnel_spline"}
  })
  if not shapeItem then return end
  term.redirect(terminal); term.clear(); term.setCursorPos(1,1)
  local origin={x=promptNumber("Origin X"), y=promptNumber("Origin Y"), z=promptNumber("Origin Z")}
  local p={}
  if shapeItem.shape=="rect_prism" or shapeItem.shape=="pyramid" then p.sideA=promptNumber("Side A"); p.sideB=promptNumber("Side B"); p.height=promptNumber("Height")
  elseif shapeItem.shape=="cylinder" or shapeItem.shape=="cone" then p.radius=promptNumber("Radius"); p.height=promptNumber("Height")
  elseif shapeItem.shape=="dome" then p.radius=promptNumber("Radius")
  elseif shapeItem.shape=="stretched_cylinder" then p.x2=promptNumber("Point B X"); p.y2=promptNumber("Point B Y"); p.z2=promptNumber("Point B Z"); p.radius=promptNumber("Radius")
  elseif shapeItem.shape=="tunnel" or shapeItem.shape=="tunnel_spline" then p.x2=promptNumber("Destination X"); p.y2=promptNumber("Destination Y"); p.z2=promptNumber("Destination Z"); p.width=promptNumber("Width",3) end
  local spacing=promptNumber("Torch spacing",8)
  local path=generatePath(shapeItem.shape, origin, p)
  local jid=state.nextJobId; state.nextJobId=jid+1
  local job={id=jid,shape=shapeItem.shape,status="waiting",origin=origin,params=p,torchSpacing=spacing,progress=0,created=now(),sectors={}}
  job.sectors[1]={id=1,index=1,status="waiting",bounds={minY=origin.y},path=path,torchPlan={}}
  state.jobs[jid]=job; saveState(); log("Created job #"..jid)
  broadcast({type="REQUEST_ASSIGNMENT",controller=HOSTNAME})
end
local function assignWaiting()
  for _,job in pairs(state.jobs) do
    if job.status=="waiting" then
      local minerId, foremanId
      for id,m in pairs(state.miners) do if now()-(m.lastSeen or 9999)<45 and not m.jobId then minerId=id; break end end
      for id,f in pairs(state.foremen) do if now()-(f.lastSeen or 9999)<45 and not f.jobId then foremanId=id; break end end
      if minerId then
        local sector=job.sectors[1]
        local packet=buildAssignPacket(job,sector,{minerId=minerId,foremanId=foremanId})
        sendPacket(minerId,packet); if foremanId then sendPacket(foremanId,packet) end
        job.status="active"; sector.status="active"; job.assignedMiner=minerId; job.assignedForeman=foremanId; state.miners[minerId].jobId=job.id; if foremanId then state.foremen[foremanId].jobId=job.id end
        saveState(); log("Assigned job #"..job.id.." to miner "..minerId)
      end
    end
  end
end
local function diagnostics()
  broadcast({type="GPS_PING",from=HOSTNAME})
  sleep(1)
  local lines={}
  table.insert(lines,"Controller coords: "..(controllerGPS and (controllerGPS.x..","..controllerGPS.y..","..controllerGPS.z) or "not set"))
  table.insert(lines,"Controller GPS host: "..tostring(state.gpsHostStatus))
  table.insert(lines,"Subhost PONG results:")
  for id,h in pairs(state.gpsHosts) do table.insert(lines,"ID "..id.."  "..h.x..","..h.y..","..h.z.."  "..((now()-(h.lastSeen or 0)<90) and "active" or "stale")) end
  table.insert(lines,"")
  table.insert(lines,"Constellation count: "..(gpsSubhostCount()+1).." total including controller")
  table.insert(lines,"Controller gps.locate is informational only and does not block jobs.")
  table.insert(lines,"Miner GPS reports are the real client test.")
  infoScreen("GPS Diagnostics", lines)
end
local function viewLogs() infoScreen("Logs", state.logs) end
local function networkLoop()
  while running do
    local sender,msg=rednet.receive(PROTOCOL,0.5)
    if type(msg)=="table" then
      if msg.type=="REGISTER" then
        if msg.role=="miner" then state.miners[sender]={id=sender,role="miner",status=msg.status,gps=msg.gps,gpsStatus=msg.gpsStatus,lastSeen=now()} end
        if msg.role=="foreman" then state.foremen[sender]={id=sender,role="foreman",status=msg.status,gps=msg.gps,gpsStatus=msg.gpsStatus,lastSeen=now()} end
        rednet.send(sender,{type="REGISTER_ACK",controller=HOSTNAME},PROTOCOL)
      elseif msg.type=="ROLL_CALL_RESPONSE" or msg.type=="HEARTBEAT" then
        local t = msg.role=="miner" and state.miners or state.foremen
        if t then t[sender]=t[sender] or {id=sender}; for k,v in pairs(msg) do t[sender][k]=v end; t[sender].lastSeen=now() end
      elseif msg.type=="GPS_PONG" then
        state.gpsHosts[sender]={id=sender,role=msg.role or "gps_subcontroller",x=msg.x,y=msg.y,z=msg.z,lastSeen=now()}
      elseif msg.type=="REQUEST_ASSIGNMENT" then assignWaiting()
      elseif msg.type=="SECTOR_COMPLETE" then
        for _,j in pairs(state.jobs) do if j.id==msg.jobId then j.status="complete"; j.progress=100; if state.miners[sender] then state.miners[sender].jobId=nil end; saveState() end end
      elseif msg.type=="ERROR" then log("ERROR from "..sender..": "..tostring(msg.error or msg.message)) end
    end
  end
end
local function dashboardLoop() while running do drawAllDash(); sleep(2) end end
local function menuLoop()
  while running do
    local item=menu("TurtleTeam Main Controller Menu",{
      {label="Create Job",fn=createJob},{label="Run GPS Diagnostics",fn=diagnostics},{label="Configure Shared Storage",fn=configureStorage},{label="View Dashboard",fn=function() drawDashboard(terminal); os.pullEvent("key") end},{label="View Logs",fn=viewLogs},{label="Save State",fn=saveState},{label="Exit Menu / keep server running",fn=function() running=false end}
    })
    if item and item.fn then item.fn() end
  end
end

detectMonitor(); if mon then mon.clear(); mon.setCursorPos(1,1) end
bootLine("TurtleTeam Main Controller v11")
bootLine("Monitor detected before boot: "..(mon and "yes" or "no"))
bootLine("Loading state..."); loadAll()
bootLine("Detecting modem..."); detectModem()
if not modemSide then bootLine("No modem found. Continue after attaching modem and reboot."); sleep(3) else rednet.open(modemSide) end
getGpsCoords()
bootLine("Starting hidden GPS host..."); startGpsHost()
bootLine("Running startup diagnostics...")
if modemSide then broadcast({type="ROLL_CALL"}); broadcast({type="GPS_PING",from=HOSTNAME}) end
sleep(2)
saveState(); drawAllDash()
parallel.waitForAny(networkLoop,dashboardLoop,menuLoop)
