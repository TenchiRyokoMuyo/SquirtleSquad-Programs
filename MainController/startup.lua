-- SquirtleSquad-Miner v1
-- MainController/startup.lua
-- CC:Tweaked distributed excavation controller.
-- Protocol: TurtleTeamNet

local PROTOCOL = "TurtleTeamNet"
local PROJECT = "SquirtleSquad-Miner"
local VERSION = "v1"
local DATA_DIR = "SquirtleSquadData"
local STATE_FILE = DATA_DIR .. "/controller_state.dat"
local LOG_FILE = DATA_DIR .. "/controller_log.dat"

local state = {
  version = VERSION,
  controllerId = os.getComputerID(),
  gps = { x = nil, y = nil, z = nil, hostEnabled = true },
  storage = {
    dump = nil,
    supply = nil
  },
  agents = {},
  teams = {},
  jobs = {},
  activeJobId = nil,
  deploymentQueue = {},
  logs = {}
}

local modemSide = nil
local monitor = nil
local terminal = term.current()
local selectedMenu = 1
local running = true

local function ensureDir()
  if not fs.exists(DATA_DIR) then fs.makeDir(DATA_DIR) end
end

local function safeSerializeToFile(path, value)
  ensureDir()
  local h = fs.open(path, "w")
  if not h then return false end
  h.write(textutils.serialize(value))
  h.close()
  return true
end

local function safeLoad(path)
  if not fs.exists(path) then return nil end
  local h = fs.open(path, "r")
  if not h then return nil end
  local txt = h.readAll()
  h.close()
  if not txt or txt == "" then return nil end
  local ok, data = pcall(textutils.unserialize, txt)
  if ok and type(data) == "table" then return data end
  return nil
end

local function healState(s)
  if type(s) ~= "table" then s = {} end
  s.version = s.version or VERSION
  s.controllerId = s.controllerId or os.getComputerID()
  s.gps = s.gps or { hostEnabled = true }
  if s.gps.hostEnabled == nil then s.gps.hostEnabled = true end
  s.storage = s.storage or {}
  s.storage.dump = s.storage.dump or nil
  s.storage.supply = s.storage.supply or nil
  s.agents = s.agents or {}
  s.teams = s.teams or {}
  s.jobs = s.jobs or {}
  s.activeJobId = s.activeJobId or nil
  s.deploymentQueue = s.deploymentQueue or {}
  s.logs = s.logs or {}
  return s
end

local function saveState()
  safeSerializeToFile(STATE_FILE, state)
end

local function log(msg)
  local line = os.date("%H:%M:%S") .. " " .. tostring(msg)
  table.insert(state.logs, line)
  while #state.logs > 200 do table.remove(state.logs, 1) end
  saveState()
end

local function openModem()
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      modemSide = side
      if not rednet.isOpen(side) then rednet.open(side) end
      return true
    end
  end
  return false
end

local function attachMonitor()
  monitor = nil
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "monitor" then
      monitor = peripheral.wrap(side)
      pcall(function() monitor.setTextScale(0.5) end)
      return true
    end
  end
  return false
end

local function color(c) if term.isColor() then term.setTextColor(c) end end
local function bcolor(c) if term.isColor() then term.setBackgroundColor(c) end end

local function writeCentered(t, y, text, col)
  local w,h = t.getSize()
  if col and t.isColor and t.isColor() then t.setTextColor(col) end
  t.setCursorPos(math.max(1, math.floor((w - #text)/2)+1), y)
  t.write(text)
end

local function header(t)
  local w,h = t.getSize()
  if t.isColor and t.isColor() then
    t.setBackgroundColor(colors.black)
    t.setTextColor(colors.cyan)
  end
  t.clear()
  writeCentered(t, 1, "🐢 " .. PROJECT .. " " .. VERSION .. " 🐢", colors.cyan)
  writeCentered(t, 2, "Industrial Fleet Excavation Controller", colors.lightBlue)
  if t.isColor and t.isColor() then t.setTextColor(colors.white) end
end

local function drawDashboard()
  if not monitor then return end
  local old = term.redirect(monitor)
  header(monitor)
  local w,h = monitor.getSize()
  local y = 4
  local miners, foremen, gpshosts = 0,0,0
  for _,a in pairs(state.agents) do
    if a.role == "miner" then miners = miners + 1 end
    if a.role == "foreman" then foremen = foremen + 1 end
    if a.role == "gps" then gpshosts = gpshosts + 1 end
  end
  monitor.setCursorPos(1,y); monitor.write("Controller ID: " .. os.getComputerID()); y=y+1
  monitor.setCursorPos(1,y); monitor.write("Modem: " .. tostring(modemSide or "missing")); y=y+1
  monitor.setCursorPos(1,y); monitor.write("Miners: " .. miners .. "  Foremen: " .. foremen .. "  GPS Subhosts: " .. gpshosts); y=y+1
  monitor.setCursorPos(1,y); monitor.write("Teams: " .. tostring(#state.teams)); y=y+1
  monitor.setCursorPos(1,y); monitor.write("Active Job: " .. tostring(state.activeJobId or "none")); y=y+1
  local dump = state.storage.dump
  local supply = state.storage.supply
  monitor.setCursorPos(1,y); monitor.write("Dump: " .. (dump and (dump.x..","..dump.y..","..dump.z) or "unset")); y=y+1
  monitor.setCursorPos(1,y); monitor.write("Supply: " .. (supply and (supply.x..","..supply.y..","..supply.z) or "unset")); y=y+2
  monitor.setCursorPos(1,y); monitor.write("Recent Logs:"); y=y+1
  local start = math.max(1, #state.logs - (h-y) + 1)
  for i=start,#state.logs do
    if y > h then break end
    monitor.setCursorPos(1,y)
    monitor.write(string.sub(state.logs[i],1,w))
    y=y+1
  end
  term.redirect(old)
end

local function promptNumber(label, default)
  term.write(label .. (default and (" ["..default.."]") or "") .. ": ")
  local s = read()
  if s == "" and default ~= nil then return tonumber(default) end
  return tonumber(s)
end

local function promptCoord(name)
  print("Enter " .. name .. " coordinates:")
  local x = promptNumber("X")
  local y = promptNumber("Y")
  local z = promptNumber("Z")
  if not x or not y or not z then print("Invalid coordinates."); return nil end
  return {x=x,y=y,z=z}
end

local function configureStorage()
  header(term)
  print("Configure Shared Storage")
  print("")
  print("1. Set Dump Chest XYZ")
  print("2. Set Fuel/Torches/Filler Chest XYZ")
  print("3. Back")
  term.write("> ")
  local c = read()
  if c == "1" then state.storage.dump = promptCoord("dump chest") log("Dump chest updated.") saveState()
  elseif c == "2" then state.storage.supply = promptCoord("fuel/torches/filler chest") log("Supply chest updated.") saveState()
  end
end

local function configureGPS()
  header(term)
  print("Main Controller GPS Host Coordinates")
  print("This controller will run shell.run(\"gps\", \"host\", x, y, z) in parallel.")
  local c = promptCoord("controller GPS host")
  if c then
    state.gps.x, state.gps.y, state.gps.z = c.x,c.y,c.z
    state.gps.hostEnabled = true
    saveState()
    log("Controller GPS host coords updated.")
  end
end

local function makeId(prefix)
  return prefix .. "-" .. tostring(os.epoch("utc")) .. "-" .. tostring(math.random(1000,9999))
end

local function createJob()
  header(term)
  print("Create Job")
  print("1. Rectangular Prism")
  print("2. Cylinder")
  print("3. Dome")
  print("4. Stretched Cylinder")
  print("5. Pyramid")
  print("6. Cone")
  print("7. Tunnel")
  print("8. Tunnel Spline")
  term.write("> ")
  local c = read()
  local job = { id = makeId("job"), status="CREATED", torchSpacing=8, created=os.epoch("utc") }
  if c == "1" then
    job.shape = "rect"
    print("Rectangular prism uses x y z to x2 y2 z2.")
    job.a = promptCoord("corner A")
    job.b = promptCoord("corner B")
  elseif c == "2" then
    job.shape = "cylinder"
    job.origin = promptCoord("center origin")
    job.radius = promptNumber("Radius")
    job.height = promptNumber("Height")
  elseif c == "3" then
    job.shape = "dome"
    job.origin = promptCoord("center origin")
    job.radius = promptNumber("Radius")
  elseif c == "4" then
    job.shape = "stretched_cylinder"
    job.a = promptCoord("origin A")
    job.b = promptCoord("origin B")
    job.radius = promptNumber("Radius")
  elseif c == "5" then
    job.shape = "pyramid"
    job.origin = promptCoord("center origin")
    job.radius = promptNumber("Base half-width/radius")
    job.height = promptNumber("Height")
  elseif c == "6" then
    job.shape = "cone"
    job.origin = promptCoord("center origin")
    job.radius = promptNumber("Radius")
    job.height = promptNumber("Height")
  elseif c == "7" then
    job.shape = "tunnel"
    job.a = promptCoord("origin")
    job.b = promptCoord("destination")
    job.width = promptNumber("Width", 3)
    job.height = promptNumber("Height", job.width)
  elseif c == "8" then
    job.shape = "tunnel_spline"
    job.a = promptCoord("origin")
    job.b = promptCoord("destination")
    job.width = promptNumber("Width", 3)
    job.height = promptNumber("Height", job.width)
    job.shallow = true
  else
    print("Cancelled."); sleep(1); return
  end
  if not state.storage.dump or not state.storage.supply then
    print("Storage is not configured. Configure storage first.")
    sleep(2); return
  end
  if not job.shape then print("Invalid job."); sleep(1); return end
  state.jobs[job.id] = job
  state.activeJobId = job.id
  log("Job created: " .. job.id .. " (" .. job.shape .. ")")
  saveState()
  print("Job created: " .. job.id)
  sleep(1)
end

local function activeMiners()
  local t={}
  for id,a in pairs(state.agents) do
    if a.role=="miner" and os.epoch("utc")-(a.lastSeen or 0) < 45000 then table.insert(t, a) end
  end
  table.sort(t, function(a,b) return a.id < b.id end)
  return t
end

local function activeForemen()
  local t={}
  for id,a in pairs(state.agents) do
    if a.role=="foreman" and os.epoch("utc")-(a.lastSeen or 0) < 45000 then table.insert(t, a) end
  end
  table.sort(t, function(a,b) return a.id < b.id end)
  return t
end

local function computeJobBounds(job)
  local minX,maxX,minY,maxY,minZ,maxZ
  local function set(x,y,z)
    minX=math.min(minX or x,x); maxX=math.max(maxX or x,x)
    minY=math.min(minY or y,y); maxY=math.max(maxY or y,y)
    minZ=math.min(minZ or z,z); maxZ=math.max(maxZ or z,z)
  end
  if job.shape=="rect" then
    set(job.a.x,job.a.y,job.a.z); set(job.b.x,job.b.y,job.b.z)
  elseif job.shape=="cylinder" or job.shape=="cone" then
    set(job.origin.x-job.radius, job.origin.y, job.origin.z-job.radius)
    set(job.origin.x+job.radius, job.origin.y+job.height-1, job.origin.z+job.radius)
  elseif job.shape=="dome" then
    set(job.origin.x-job.radius, job.origin.y, job.origin.z-job.radius)
    set(job.origin.x+job.radius, job.origin.y+job.radius, job.origin.z+job.radius)
  elseif job.shape=="pyramid" then
    set(job.origin.x-job.radius, job.origin.y, job.origin.z-job.radius)
    set(job.origin.x+job.radius, job.origin.y+job.height-1, job.origin.z+job.radius)
  elseif job.shape=="stretched_cylinder" then
    local r=job.radius
    set(math.min(job.a.x,job.b.x)-r, math.min(job.a.y,job.b.y)-r, math.min(job.a.z,job.b.z)-r)
    set(math.max(job.a.x,job.b.x)+r, math.max(job.a.y,job.b.y)+r, math.max(job.a.z,job.b.z)+r)
  elseif job.shape=="tunnel" or job.shape=="tunnel_spline" then
    local r=math.ceil(math.max(job.width or 3, job.height or job.width or 3)/2)
    set(math.min(job.a.x,job.b.x)-r, math.min(job.a.y,job.b.y)-r, math.min(job.a.z,job.b.z)-r)
    set(math.max(job.a.x,job.b.x)+r, math.max(job.a.y,job.b.y)+r, math.max(job.a.z,job.b.z)+r)
  end
  return {minX=minX,maxX=maxX,minY=minY,maxY=maxY,minZ=minZ,maxZ=maxZ}
end

local function buildTeams()
  local miners = activeMiners()
  local foremen = activeForemen()
  state.teams = {}
  if #miners == 0 then return end
  local foremanCount = math.max(1, #foremen)
  for i, miner in ipairs(miners) do
    local f = foremen[((i-1) % foremanCount) + 1]
    local teamId = "team-" .. tostring(i)
    table.insert(state.teams, {
      id=teamId,
      minerId=miner.id,
      minerNet=miner.netId,
      foremanId=f and f.id or nil,
      foremanNet=f and f.netId or nil,
      groupIndex=i,
      groupCount=#miners
    })
  end
  saveState()
end

local function assignActiveJob()
  local job = state.jobs[state.activeJobId or ""]
  if not job then log("No active job to assign."); return end
  buildTeams()
  if #state.teams == 0 then log("No miners available."); return end
  local bounds = computeJobBounds(job)
  local total = #state.teams
  state.deploymentQueue = {}
  for i,team in ipairs(state.teams) do
    local sx1 = bounds.minX + math.floor((bounds.maxX-bounds.minX+1)*(i-1)/total)
    local sx2 = bounds.minX + math.floor((bounds.maxX-bounds.minX+1)*i/total) - 1
    if i == total then sx2 = bounds.maxX end
    local sector = {
      id = "sector-" .. i,
      index = i,
      count = total,
      bounds = { minX=sx1, maxX=sx2, minY=bounds.minY, maxY=bounds.maxY, minZ=bounds.minZ, maxZ=bounds.maxZ },
      fullBounds = bounds
    }
    team.sector = sector
    table.insert(state.deploymentQueue, team.id)
    if team.foremanNet then
      rednet.send(team.foremanNet, {type="ASSIGN_FOREMAN", teamId=team.id, minerId=team.minerId, minerNet=team.minerNet, jobId=job.id, sector=sector}, PROTOCOL)
    end
    rednet.send(team.minerNet, {
      type="ASSIGN_JOB",
      project=PROJECT,
      version=VERSION,
      teamId=team.id,
      minerId=team.minerId,
      foremanId=team.foremanId,
      foremanNet=team.foremanNet,
      jobId=job.id,
      job=job,
      sector=sector,
      storage=state.storage,
      deployOrder=i,
      deployHold=true
    }, PROTOCOL)
  end
  job.status = "ASSIGNED"
  saveState()
  log("Assigned job to " .. tostring(#state.teams) .. " miner teams.")
  if #state.deploymentQueue > 0 then
    local first = state.deploymentQueue[1]
    for _,team in ipairs(state.teams) do
      if team.id == first then
        rednet.send(team.minerNet,{type="DEPLOY_NOW",teamId=team.id,jobId=job.id},PROTOCOL)
        if team.foremanNet then rednet.send(team.foremanNet,{type="DEPLOY_NOW",teamId=team.id,jobId=job.id},PROTOCOL) end
        log("Deployment started: " .. team.id)
      end
    end
  end
end

local function pauseJob()
  for _,a in pairs(state.agents) do rednet.send(a.netId, {type="PAUSE_JOB"}, PROTOCOL) end
  log("Pause sent.")
end

local function resumeJob()
  for _,a in pairs(state.agents) do rednet.send(a.netId, {type="RESUME_JOB"}, PROTOCOL) end
  log("Resume sent.")
end

local function cancelJob()
  for _,a in pairs(state.agents) do rednet.send(a.netId, {type="CANCEL_JOB"}, PROTOCOL) end
  if state.activeJobId and state.jobs[state.activeJobId] then state.jobs[state.activeJobId].status="CANCELLED" end
  state.activeJobId=nil
  saveState()
  log("Cancel sent.")
end

local function gpsDiagnostics()
  header(term)
  print("GPS Diagnostics")
  print("Controller GPS host: " .. tostring(state.gps.x) .. "," .. tostring(state.gps.y) .. "," .. tostring(state.gps.z))
  print("Known GPS subhosts:")
  for _,a in pairs(state.agents) do
    if a.role=="gps" then
      print(" - " .. tostring(a.label or a.id) .. " id " .. tostring(a.netId) .. " at " .. tostring(a.x)..","..tostring(a.y)..","..tostring(a.z) .. " last " .. tostring(math.floor((os.epoch("utc")-(a.lastSeen or 0))/1000)) .. "s ago")
    end
  end
  print("")
  print("Note: Controller self gps.locate() is not required to validate the constellation.")
  print("Press any key.")
  os.pullEvent("key")
end

local function viewLogs()
  header(term)
  print("Logs:")
  local start = math.max(1,#state.logs-18)
  for i=start,#state.logs do print(state.logs[i]) end
  print("Press any key.")
  os.pullEvent("key")
end

local function clearHistory()
  state.logs = {}
  for id,j in pairs(state.jobs) do
    if j.status=="COMPLETE" or j.status=="CANCELLED" then state.jobs[id]=nil end
  end
  saveState()
  log("History cleared.")
end

local menu = {
  {"Create Job", createJob},
  {"Assign/Deploy Active Job", assignActiveJob},
  {"Pause Job", pauseJob},
  {"Resume Job", resumeJob},
  {"Cancel Job", cancelJob},
  {"Configure Shared Storage", configureStorage},
  {"Reset Controller GPS Coordinates", configureGPS},
  {"GPS Diagnostics", gpsDiagnostics},
  {"View Logs", viewLogs},
  {"Save State", function() saveState(); log("Manual save.") end},
  {"Clear Saved History", clearHistory},
  {"Exit", function() running=false end}
}

local function drawMenu()
  term.redirect(terminal)
  header(term)
  print("")
  print("Use Up/Down and Enter.")
  print("")
  for i,item in ipairs(menu) do
    if i == selectedMenu then
      bcolor(colors.blue); color(colors.white); print("> " .. item[1]); bcolor(colors.black)
    else
      color(colors.white); print("  " .. item[1])
    end
  end
  color(colors.white)
end

local function menuLoop()
  while running do
    drawMenu()
    local ev,k = os.pullEvent("key")
    if k == keys.up then selectedMenu = math.max(1, selectedMenu-1)
    elseif k == keys.down then selectedMenu = math.min(#menu, selectedMenu+1)
    elseif k == keys.enter then
      local fn = menu[selectedMenu][2]
      pcall(fn)
    end
  end
end

local function nextDeployment(teamId)
  if #state.deploymentQueue == 0 then return end
  if state.deploymentQueue[1] == teamId then
    table.remove(state.deploymentQueue,1)
    saveState()
    local nextTeamId = state.deploymentQueue[1]
    if nextTeamId then
      for _,team in ipairs(state.teams) do
        if team.id == nextTeamId then
          rednet.send(team.minerNet,{type="DEPLOY_NOW",teamId=team.id,jobId=state.activeJobId},PROTOCOL)
          if team.foremanNet then rednet.send(team.foremanNet,{type="DEPLOY_NOW",teamId=team.id,jobId=state.activeJobId},PROTOCOL) end
          log("Deployment started: " .. team.id)
          return
        end
      end
    else
      log("All teams deployed.")
    end
  end
end

local function networkLoop()
  while running do
    local sender, msg = rednet.receive(PROTOCOL, 1)
    if type(msg) == "table" then
      local now = os.epoch("utc")
      if msg.type == "REGISTER" then
        local id = msg.role .. "-" .. tostring(sender)
        state.agents[id] = state.agents[id] or {}
        local a = state.agents[id]
        a.id = id
        a.netId = sender
        a.role = msg.role
        a.label = msg.label
        a.x,a.y,a.z = msg.x,msg.y,msg.z
        a.lastSeen = now
        rednet.send(sender,{type="REGISTER_ACK",controllerId=os.getComputerID(),agentId=id,project=PROJECT,version=VERSION},PROTOCOL)
        log("Registered " .. tostring(msg.role) .. " " .. tostring(sender))
        saveState()
      elseif msg.type == "HEARTBEAT" then
        local id = (msg.role or "agent") .. "-" .. tostring(sender)
        state.agents[id] = state.agents[id] or {id=id, netId=sender}
        local a = state.agents[id]
        a.netId=sender; a.role=msg.role or a.role; a.status=msg.status; a.lastSeen=now
        a.x=msg.x or a.x; a.y=msg.y or a.y; a.z=msg.z or a.z
      elseif msg.type == "REQUEST_ASSIGNMENT" then
        if state.activeJobId then
          log("Assignment recovery requested by " .. sender)
          assignActiveJob()
        end
      elseif msg.type == "TEAM_READY_AT_ORIGIN" then
        log("Team at origin: " .. tostring(msg.teamId))
        nextDeployment(msg.teamId)
      elseif msg.type == "SECTOR_COMPLETE" then
        log("Sector complete: " .. tostring(msg.teamId))
      elseif msg.type == "ERROR" then
        log("ERROR from " .. sender .. ": " .. tostring(msg.message))
      end
    end
  end
end

local function dashboardLoop()
  while running do
    drawDashboard()
    sleep(2)
  end
end

local function controllerGpsHostLoop()
  while running do
    if state.gps and state.gps.hostEnabled and state.gps.x and state.gps.y and state.gps.z then
      local old = term.current()
      local win = window.create(old, 1, 1, 1, 1, false)
      local prior = term.redirect(win)
      pcall(function()
        shell.run("gps", "host", tostring(state.gps.x), tostring(state.gps.y), tostring(state.gps.z))
      end)
      term.redirect(prior)
    else
      sleep(5)
    end
    sleep(1)
  end
end

ensureDir()
state = healState(safeLoad(STATE_FILE) or state)
saveState()
openModem()
attachMonitor()
math.randomseed(os.epoch("utc") % 100000)
log(PROJECT .. " " .. VERSION .. " controller booted.")
if not modemSide then log("No modem found. Network disabled until reboot/retry.") end

parallel.waitForAny(menuLoop, networkLoop, dashboardLoop, controllerGpsHostLoop)
term.redirect(terminal)
term.clear()
term.setCursorPos(1,1)
print(PROJECT .. " " .. VERSION .. " stopped.")
