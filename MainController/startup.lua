-- TurtleTeamNet Main Controller startup.lua v12 Compact Jobs
-- Compact job storage: never prebuild/save block lists or torch tables.

local PROTOCOL = "TurtleTeamNet"
local HOSTNAME = "MainController"
local STATE_FILE = "controller_state.dat"
local GPS_FILE = "controller_gps.dat"
local STORAGE_FILE = "shared_storage.dat"
local VERSION = "v12 compact-jobs"

local state = { jobs={}, miners={}, foremen={}, gpsHosts={}, logs={}, nextJobId=1, assignments={} }
local gpsCoords = nil
local storage = { fuelTorchesChest=nil, depositChest=nil }
local modemSide = nil
local monitor = nil
local running = true
local gpsHostStarted = false

local nativeTerm = term.current()

local function safeSerialize(t) return textutils.serialize(t, { allow_repetitions = false }) end
local function log(s) table.insert(state.logs, 1, os.date("%H:%M:%S").." "..tostring(s)); while #state.logs > 80 do table.remove(state.logs) end end
local function readTable(path, fallback)
  if not fs.exists(path) then return fallback end
  local f = fs.open(path, "r"); if not f then return fallback end
  local s = f.readAll(); f.close()
  local ok, t = pcall(textutils.unserialize, s)
  if ok and type(t)=="table" then return t end
  return fallback
end
local function writeTable(path, t)
  local f = fs.open(path, "w")
  if not f then print("Could not open "..path.." for write"); return false end
  f.write(safeSerialize(t)); f.close(); return true
end
local function normalizeState()
  state.jobs = state.jobs or {}
  state.miners = state.miners or {}
  state.foremen = state.foremen or {}
  state.gpsHosts = state.gpsHosts or {}
  state.logs = state.logs or {}
  state.assignments = state.assignments or {}
  state.nextJobId = state.nextJobId or 1
end
local function saveAll() normalizeState(); writeTable(STATE_FILE, state); writeTable(STORAGE_FILE, storage); if gpsCoords then writeTable(GPS_FILE, gpsCoords) end end
local function loadAll()
  state = readTable(STATE_FILE, state); normalizeState()
  storage = readTable(STORAGE_FILE, storage) or storage
  if storage.fuelChest and not storage.fuelTorchesChest then storage.fuelTorchesChest = storage.fuelChest; storage.fuelChest = nil end
  gpsCoords = readTable(GPS_FILE, nil)
end

local function findMonitor()
  for _,n in ipairs(peripheral.getNames()) do if peripheral.getType(n)=="monitor" then monitor=peripheral.wrap(n); pcall(function() monitor.setTextScale(0.5) end); return true end end
  monitor=nil; return false
end
local function findModem()
  for _,n in ipairs(peripheral.getNames()) do if peripheral.getType(n)=="modem" then return n end end
end
local function writeLine(t, y, text)
  local w,h = t.getSize(); if y<1 or y>h then return end
  t.setCursorPos(1,y); t.clearLine(); t.write(tostring(text):sub(1,w))
end
local function screen(t, lines)
  t.clear(); for i,l in ipairs(lines) do writeLine(t,i,l) end
end
local function bootLine(s)
  term.redirect(nativeTerm); print(s)
  if monitor then local _,h=monitor.getSize(); monitor.scroll(1); monitor.setCursorPos(1,h); monitor.clearLine(); monitor.write(s:sub(1,monitor.getSize())) end
end

local function startGpsHost()
  if gpsHostStarted or not gpsCoords then return end
  gpsHostStarted = true
  if multishell then
    local id = multishell.launch({}, "gps", "host", tostring(gpsCoords.x), tostring(gpsCoords.y), tostring(gpsCoords.z))
    if id then multishell.setTitle(id, "GPS Host") end
  else
    parallel.waitForAny(function() shell.run("gps", "host", tostring(gpsCoords.x), tostring(gpsCoords.y), tostring(gpsCoords.z)) end, function() sleep(0.1) end)
  end
end

local function promptNumber(label, default)
  while true do
    term.redirect(nativeTerm); term.write(label..(default and (" ["..default.."]") or "")..": ")
    local s=read(); if s=="" and default then return default end
    local n=tonumber(s); if n then return n end
    print("Enter a number.")
  end
end
local function promptText(label, default)
  term.redirect(nativeTerm); term.write(label..(default and (" ["..default.."]") or "")..": ")
  local s=read(); if s=="" and default then return default end; return s
end
local function ensureGpsCoords()
  if gpsCoords and gpsCoords.x then return true end
  print("Controller GPS coords missing.")
  gpsCoords={x=promptNumber("Controller X"),y=promptNumber("Controller Y"),z=promptNumber("Controller Z")}
  writeTable(GPS_FILE,gpsCoords); return true
end
local function storageConfigured() return storage.fuelTorchesChest and storage.depositChest end
local function configureStorage()
  storage.fuelTorchesChest = promptText("Fuel/Torches chest label", storage.fuelTorchesChest or "Fuel/Torches")
  storage.depositChest = promptText("Deposit chest label", storage.depositChest or "Community Deposit")
  writeTable(STORAGE_FILE, storage)
end

local function totalMinersActive()
  local n=0; local now=os.clock(); for _,m in pairs(state.miners) do if now-(m.lastSeen or 0)<45 then n=n+1 end end; return n end
local function totalForemenActive()
  local n=0; local now=os.clock(); for _,m in pairs(state.foremen) do if now-(m.lastSeen or 0)<45 then n=n+1 end end; return n end
local function gpsSubhostsActive()
  local n=0; local now=os.clock(); for _,g in pairs(state.gpsHosts) do if now-(g.lastSeen or 0)<120 then n=n+1 end end; return n end

local function compactJobForSend(job)
  return {
    id=job.id, shape=job.shape, origin=job.origin, params=job.params,
    torchSpacing=job.torchSpacing, status=job.status, created=job.created,
    totalEstimate=job.totalEstimate
  }
end
local function compactSectorForSend(sec)
  return { id=sec.id, yStart=sec.yStart, yEnd=sec.yEnd, indexStart=sec.indexStart or 1, indexEnd=sec.indexEnd or sec.totalEstimate, currentIndex=sec.currentIndex or 1, totalEstimate=sec.totalEstimate or 0 }
end
local function estimateTotal(shape, p)
  if shape=="rectangular_prism" then return math.max(1, math.floor((p.sideA or 1)*(p.sideB or 1)*(p.height or 1))) end
  if shape=="cylinder" then return math.max(1, math.floor(math.pi*(p.radius or 1)*(p.radius or 1)*(p.height or 1))) end
  if shape=="dome" then return math.max(1, math.floor((2/3)*math.pi*(p.radius or 1)^3)) end
  if shape=="stretched_cylinder" then return math.max(1, math.floor(math.pi*(p.radius or 1)^2*(p.length or 1))) end
  if shape=="pyramid" then return math.max(1, math.floor((p.sideA or 1)*(p.sideB or 1)*(p.height or 1)/3)) end
  if shape=="cone" then return math.max(1, math.floor(math.pi*(p.radius or 1)^2*(p.height or 1)/3)) end
  if shape=="tunnel" or shape=="tunnel_spline" then return math.max(1, math.floor((p.length or 1)*(p.width or 3)*(p.width or 3))) end
  return 1
end
local function makeSectors(job)
  local miners = math.max(1,totalMinersActive())
  local h = job.params.height or job.params.radius or 1
  local sectors={}
  for i=1,miners do
    local y0 = math.floor((i-1)*h/miners)
    local y1 = math.floor(i*h/miners)-1
    if i==miners then y1=h-1 end
    sectors[i]={id=i,yStart=y0,yEnd=y1,currentIndex=1,totalEstimate=math.max(1, math.floor(job.totalEstimate/miners))}
  end
  return sectors
end
local function sendTo(id,msg) rednet.send(tonumber(id), msg, PROTOCOL) end
local function assignJobs()
  local miners, foremen = {}, {}
  local now=os.clock()
  for id,m in pairs(state.miners) do if now-(m.lastSeen or 0)<45 and (m.status=="IDLE" or m.status=="LISTENING" or m.status=="ERROR") then table.insert(miners, tonumber(id)) end end
  for id,m in pairs(state.foremen) do if now-(m.lastSeen or 0)<45 and (m.status=="IDLE" or m.status=="LISTENING" or m.status=="ERROR") then table.insert(foremen, tonumber(id)) end end
  table.sort(miners); table.sort(foremen)
  for _,job in ipairs(state.jobs) do
    if job.status=="waiting" and #miners>0 then
      job.sectors = job.sectors or makeSectors(job)
      for i,sec in ipairs(job.sectors) do
        local miner = table.remove(miners,1); if not miner then break end
        local foreman = table.remove(foremen,1)
        local packet = { type="ASSIGN_JOB", job=compactJobForSend(job), sector=compactSectorForSend(sec), team={miner=miner,foreman=foreman}, sharedStorage=storage, inventoryPolicy={fuel=1,filler=2,torches=16,lootStart=3,lootEnd=15}, fillerPolicy={enabled=true,fillSidewalls=true,fillCeiling=true,neverFillBelowOrigin=true}, torchPolicy={spacing=job.torchSpacing or 8,wallFirst=true,floorSecond=true}, controllerGPS=gpsCoords }
        sendTo(miner, packet); if foreman then sendTo(foreman, packet) end
        state.assignments[tostring(miner)]={jobId=job.id,sectorId=sec.id}
        if foreman then state.assignments[tostring(foreman)]={jobId=job.id,sectorId=sec.id} end
        sec.miner=miner; sec.foreman=foreman; sec.status="assigned"
      end
      job.status="active"; log("Assigned job #"..job.id)
    end
  end
  saveAll()
end

local function dashboard()
  findMonitor(); if not monitor then return end
  local lines={}
  table.insert(lines,"TurtleTeam Dashboard "..VERSION)
  table.insert(lines,string.rep("-",34))
  table.insert(lines,"GPS: "..(gpsCoords and (gpsCoords.x..","..gpsCoords.y..","..gpsCoords.z) or "not set"))
  table.insert(lines,"GPS subhosts: "..gpsSubhostsActive().." active")
  table.insert(lines,"Miners: "..totalMinersActive().."  Foremen: "..totalForemenActive())
  table.insert(lines,"Fuel/Torches: "..tostring(storage.fuelTorchesChest or "not set"))
  table.insert(lines,"Deposit: "..tostring(storage.depositChest or "not set"))
  table.insert(lines,"Jobs:")
  for _,j in ipairs(state.jobs) do table.insert(lines,"#"..j.id.." "..j.shape.." "..j.status.." est:"..tostring(j.totalEstimate or 0)) end
  screen(monitor, lines)
end

local function drawMenu(items, selected, title)
  term.redirect(nativeTerm); term.clear(); term.setCursorPos(1,1)
  print(title or ("TurtleTeam Main Controller "..VERSION)); print(string.rep("-",40))
  print("Miners "..totalMinersActive().." | Foremen "..totalForemenActive().." | GPS Subhosts "..gpsSubhostsActive())
  print("Storage: "..(storageConfigured() and "configured" or "missing")); print("")
  local w,h=term.getSize(); local visible=h-8; local start=math.max(1, selected-visible+1)
  for i=start, math.min(#items,start+visible-1) do print((i==selected and "> " or "  ")..items[i]) end
  print(""); print("Up/Down Enter  Q quit")
end
local function choose(items,title)
  local sel=1
  while true do
    dashboard(); drawMenu(items,sel,title)
    local e,k=os.pullEvent("key")
    if k==keys.up then sel=math.max(1,sel-1) elseif k==keys.down then sel=math.min(#items,sel+1) elseif k==keys.enter then return sel elseif k==keys.q or k==keys.escape then return nil end
  end
end

local shapes = {"rectangular_prism","cylinder","dome","stretched_cylinder","pyramid","cone","tunnel","tunnel_spline"}
local function createJob()
  if not storageConfigured() then print("Storage must be configured first."); sleep(2); return end
  local sidx=choose(shapes,"Select Shape"); if not sidx then return end
  local shape=shapes[sidx]
  term.clear(); term.setCursorPos(1,1); print("Create "..shape)
  local ox=promptNumber("Origin X", gpsCoords and gpsCoords.x or 0)
  local oy=promptNumber("Origin Y", gpsCoords and gpsCoords.y or 0)
  local oz=promptNumber("Origin Z", gpsCoords and gpsCoords.z or 0)
  local p={}
  if shape=="rectangular_prism" then p.sideA=promptNumber("Side A"); p.sideB=promptNumber("Side B"); p.height=promptNumber("Height")
  elseif shape=="cylinder" then p.radius=promptNumber("Radius"); p.height=promptNumber("Height")
  elseif shape=="dome" then p.radius=promptNumber("Radius"); p.height=p.radius
  elseif shape=="stretched_cylinder" then p.x2=promptNumber("Destination X"); p.y2=promptNumber("Destination Y",oy); p.z2=promptNumber("Destination Z"); p.radius=promptNumber("Radius"); p.length=math.max(1,math.floor(math.sqrt((p.x2-ox)^2+(p.y2-oy)^2+(p.z2-oz)^2)))
  elseif shape=="pyramid" then p.sideA=promptNumber("Base Side A"); p.sideB=promptNumber("Base Side B"); p.height=promptNumber("Height")
  elseif shape=="cone" then p.radius=promptNumber("Base Radius"); p.height=promptNumber("Height")
  elseif shape=="tunnel" or shape=="tunnel_spline" then p.x2=promptNumber("Destination X"); p.y2=promptNumber("Destination Y"); p.z2=promptNumber("Destination Z"); p.width=promptNumber("Width",3); p.length=math.max(1,math.floor(math.sqrt((p.x2-ox)^2+(p.y2-oy)^2+(p.z2-oz)^2))) end
  local torch=promptNumber("Torch spacing",8)
  local job={id=state.nextJobId,shape=shape,origin={x=ox,y=oy,z=oz},params=p,torchSpacing=torch,status="waiting",created=os.clock()}
  job.totalEstimate=estimateTotal(shape,p); state.nextJobId=state.nextJobId+1
  table.insert(state.jobs,job); saveAll(); log("Created compact job #"..job.id.." est "..job.totalEstimate); assignJobs()
end

local function gpsDiagnostics()
  term.redirect(nativeTerm); term.clear(); term.setCursorPos(1,1)
  rednet.broadcast({type="GPS_PING",controller=HOSTNAME},PROTOCOL)
  local start=os.clock(); while os.clock()-start<2 do local sender,msg=rednet.receive(PROTOCOL,0.25); if type(msg)=="table" and msg.type=="GPS_PONG" then state.gpsHosts[tostring(sender)]={id=sender,role=msg.role,x=msg.x,y=msg.y,z=msg.z,lastSeen=os.clock()} end end
  print("GPS Diagnostics"); print(string.rep("-",40)); print("Controller coords: "..(gpsCoords and (gpsCoords.x..","..gpsCoords.y..","..gpsCoords.z) or "not set"))
  print("Subhost PONG results:")
  for id,g in pairs(state.gpsHosts) do print("ID "..id.." "..tostring(g.x)..","..tostring(g.y)..","..tostring(g.z).." active") end
  print(""); print("Constellation total including controller: "..(gpsSubhostsActive()+1)); print("Note: controller may fail gps.locate because it is also a host.")
  print("Press any key."); os.pullEvent("key")
end
local function viewLogs()
  term.redirect(nativeTerm); local scroll=1
  while true do term.clear(); term.setCursorPos(1,1); print("Logs"); print(string.rep("-",30)); local _,h=term.getSize(); for i=scroll, math.min(#state.logs,scroll+h-4) do print(state.logs[i]) end; print("Q back") local _,k=os.pullEvent("key"); if k==keys.q or k==keys.escape then return elseif k==keys.down then scroll=math.min(#state.logs,scroll+1) elseif k==keys.up then scroll=math.max(1,scroll-1) end end
end

local function netLoop()
  while true do
    local sender,msg=rednet.receive(PROTOCOL,0.5)
    if type(msg)=="table" then
      if msg.type=="REGISTER" then
        local tbl = (msg.role=="miner") and state.miners or ((msg.role=="foreman") and state.foremen or nil)
        if tbl then tbl[tostring(sender)]={id=sender,role=msg.role,status=msg.status or "LISTENING",gps=msg.gps,lastSeen=os.clock(),gpsStatus=msg.gpsStatus}; rednet.send(sender,{type="REGISTER_ACK",controller=HOSTNAME},PROTOCOL) end
      elseif msg.type=="HEARTBEAT" then
        local tbl = (msg.role=="miner") and state.miners or ((msg.role=="foreman") and state.foremen or nil)
        if tbl then local rec=tbl[tostring(sender)] or {}; for k,v in pairs(msg) do rec[k]=v end; rec.lastSeen=os.clock(); rec.id=sender; tbl[tostring(sender)]=rec end
      elseif msg.type=="GPS_PONG" then state.gpsHosts[tostring(sender)]={id=sender,role=msg.role,x=msg.x,y=msg.y,z=msg.z,lastSeen=os.clock()}
      elseif msg.type=="REQUEST_ASSIGNMENT" then assignJobs()
      elseif msg.type=="SECTOR_COMPLETE" then log("Sector complete from "..sender) end
      elseif msg.type=="ERROR" then log("ERROR from "..sender..": "..tostring(msg.error)) end
    end
    dashboard()
  end
end
local function periodic()
  while true do rednet.broadcast({type="ROLL_CALL"},PROTOCOL); rednet.broadcast({type="GPS_PING"},PROTOCOL); assignJobs(); saveAll(); dashboard(); sleep(8) end
end
local function menuLoop()
  while running do
    local opts={"Create Job","Configure Shared Storage","GPS Diagnostics","View Logs","Save State","Exit Menu / keep server running"}
    local c=choose(opts,"TurtleTeam Main Controller "..VERSION)
    if c==1 then createJob() elseif c==2 then configureStorage() elseif c==3 then gpsDiagnostics() elseif c==4 then viewLogs() elseif c==5 then saveAll() elseif c==6 or not c then term.clear(); print("Server still running. Reboot to reopen menu."); while true do sleep(10) end end
  end
end

findMonitor(); term.redirect(nativeTerm); term.clear(); term.setCursorPos(1,1); bootLine("TurtleTeam Main Controller "..VERSION); bootLine("Monitor detected before boot: "..tostring(monitor~=nil)); bootLine("Loading state...")
loadAll(); bootLine("Detecting modem..."); modemSide=findModem(); if not modemSide then bootLine("No modem detected. Attach modem and reboot."); while true do sleep(60) end end
rednet.open(modemSide); ensureGpsCoords(); startGpsHost(); saveAll(); bootLine("Ready.")
parallel.waitForAny(netLoop, periodic, menuLoop)
