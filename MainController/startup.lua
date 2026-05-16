-- SquirtleSquad MainController.lua
-- Industrial turtle fleet controller, GPS host, job scheduler, protected block owner.

local PROJECT = "SquirtleSquad-Miner"
local ROLE = "controller"
local VERSION = "v2.0-loadout"
local PROTOCOL = "TurtleTeamNet"
local DATA_DIR = "SquirtleSquadData/MainController"
local STATE_FILE = DATA_DIR .. "/controller_state.dat"
local LOG_LIMIT = 300
local AGENT_TIMEOUT = 20
local GPS_TIMEOUT = 20
local MINER_HOME_RANGE = 50

local DEFAULT_PROTECTED = {
  "minecraft:spawner", "computercraft:", "turtle", "computer", "modem", "monitor",
  "drive", "disk_drive", "speaker", "printer", "chest", "barrel", "shulker",
  "create:display_link", "display_link"
}

local SHAPES = {
  { label = "Cuboid Center", key = "cuboid_center" },
  { label = "Cuboid Coordinates", key = "cuboid_coords" },
  { label = "Cylinder", key = "cylinder" },
  { label = "Cone", key = "cone" },
  { label = "Dome", key = "dome" },
  { label = "Pyramid", key = "pyramid" },
  { label = "Stretched Cylinder", key = "stretched_cylinder" },
  { label = "Tunnel Spline", key = "tunnel_spline" },
}

local termNative = term.current()
local monitor = nil
local modemSide = nil
local running = true
local gpsProcessStarted = false
local uiBusy = false

local function defaultState()
  local s = {
    version = VERSION,
    project = PROJECT,
    controllerId = os.getComputerID(),
    gps = { x = nil, y = nil, z = nil, hostEnabled = true },
    agents = {},
    jobs = {},
    activeJobs = {},
    queuedJobs = {},
    logs = {},
    protected = { exact = {}, contains = {}, custom = {}, revision = 1 },
    settings = { gpsCheckMoves = 8, torchSpacing = 8 },
    killSwitch = { active = false, id = nil, startedAt = nil },
  }
  return s
end

local state = defaultState()

local function ensureDir()
  if not fs.exists("SquirtleSquadData") then fs.makeDir("SquirtleSquadData") end
  if not fs.exists(DATA_DIR) then fs.makeDir(DATA_DIR) end
end

local function copy(t)
  if type(t) ~= "table" then return t end
  local r = {}
  for k, v in pairs(t) do r[k] = copy(v) end
  return r
end

local function saveTable(path, t)
  ensureDir()
  local h = fs.open(path, "w")
  if not h then return false end
  h.write(textutils.serialize(t))
  h.close()
  return true
end

local function loadTable(path)
  if not fs.exists(path) then return nil end
  local h = fs.open(path, "r")
  if not h then return nil end
  local s = h.readAll()
  h.close()
  local ok, t = pcall(textutils.unserialize, s or "")
  if ok and type(t) == "table" then return t end
  return nil
end

local function normalizeProtected()
  state.protected = state.protected or { exact = {}, contains = {}, custom = {}, revision = 1 }
  state.protected.exact = state.protected.exact or {}
  state.protected.contains = state.protected.contains or {}
  state.protected.custom = state.protected.custom or {}
  for _, v in ipairs(DEFAULT_PROTECTED) do
    local s = string.lower(tostring(v))
    if s:sub(-1) == ":" or s:find("turtle") or s:find("computer") or s:find("modem") or s:find("monitor") or s:find("drive") or s:find("speaker") or s:find("printer") or s:find("chest") or s:find("barrel") or s:find("shulker") or s:find("display_link") then
      state.protected.contains[s] = true
    else
      state.protected.exact[s] = true
    end
  end
end

local function healState(s)
  local d = defaultState()
  if type(s) ~= "table" then s = d end
  for k, v in pairs(d) do if s[k] == nil then s[k] = v end end
  s.version = VERSION
  s.project = PROJECT
  s.controllerId = os.getComputerID()
  s.gps = s.gps or d.gps
  s.agents = s.agents or {}
  s.jobs = s.jobs or {}
  s.activeJobs = s.activeJobs or {}
  s.queuedJobs = s.queuedJobs or {}
  s.logs = s.logs or {}
  s.settings = s.settings or d.settings
  s.killSwitch = s.killSwitch or d.killSwitch
  state = s
  normalizeProtected()
end

local function saveState() saveTable(STATE_FILE, state) end

local function log(msg)
  local line = os.date("%H:%M:%S") .. " " .. tostring(msg)
  table.insert(state.logs, line)
  while #state.logs > LOG_LIMIT do table.remove(state.logs, 1) end
  saveState()
end

local function now() return os.epoch("utc") end

local function openModem()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      modemSide = name
      if not rednet.isOpen(name) then rednet.open(name) end
      return true
    end
  end
  return false
end

local function attachMonitor()
  monitor = nil
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then
      monitor = peripheral.wrap(name)
      pcall(function() monitor.setTextScale(0.5) end)
      return true
    end
  end
  return false
end

local function safePacket(packet)
  if type(packet) ~= "table" then return nil end
  local clean = copy(packet)
  clean.project = PROJECT
  clean.protocol = PROTOCOL
  clean.protocolVersion = 2
  clean.senderRole = ROLE
  clean.senderId = os.getComputerID()
  clean.timestamp = now()
  local ok = pcall(textutils.serialize, clean)
  if not ok then return nil end
  return clean
end

local function send(id, packet)
  local p = safePacket(packet)
  if not p then log("Refused unserializable packet " .. tostring(packet and packet.type)); return false end
  return rednet.send(id, p, PROTOCOL)
end

local function broadcast(packet)
  local p = safePacket(packet)
  if not p then log("Refused unserializable broadcast " .. tostring(packet and packet.type)); return false end
  rednet.broadcast(p, PROTOCOL)
  return true
end

local function validPacket(p)
  return type(p) == "table" and p.project == PROJECT and p.protocol == PROTOCOL and type(p.type) == "string"
end

local function color(c) if term.isColor and term.isColor() then term.setTextColor(c) end end
local function bcolor(c) if term.isColor and term.isColor() then term.setBackgroundColor(c) end end
local function clear() bcolor(colors.black); color(colors.lightGray); term.clear(); term.setCursorPos(1,1) end
local function center(y, text, c)
  local w = term.getSize()
  color(c or colors.lightGray)
  term.setCursorPos(math.max(1, math.floor((w - #text) / 2) + 1), y)
  term.write(text)
end
local function writeCoord(c)
  if not c then color(colors.red); term.write("unknown"); color(colors.lightGray); return end
  color(colors.red); term.write("X " .. tostring(c.x) .. " ")
  color(colors.yellow); term.write("Y " .. tostring(c.y) .. " ")
  color(colors.blue); term.write("Z " .. tostring(c.z))
  color(colors.lightGray)
end
local function header(title)
  clear(); center(1, "SquirtleSquad Main Controller", colors.cyan); center(2, title or VERSION, colors.orange); term.setCursorPos(1,4); color(colors.lightGray)
end

local function choose(title, items, subtitle)
  if not items or #items == 0 then header(title); print("No options."); sleep(1); return nil end
  local sel, top = 1, 1
  while true do
    uiBusy = true
    header(title)
    if subtitle then print(subtitle) end
    print("Use arrows and Enter. Backspace returns.")
    print("")
    local _, h = term.getSize()
    local visible = math.max(3, h - 7)
    if sel < top then top = sel end
    if sel >= top + visible then top = sel - visible + 1 end
    for row = 0, visible - 1 do
      local i = top + row
      if i > #items then break end
      if i == sel then bcolor(colors.blue); color(colors.white); print("> " .. items[i].label); bcolor(colors.black)
      else
        local st = items[i].status
        if st == "QUEUED" then color(colors.blue) elseif st == "IN_PROGRESS" then color(colors.yellow) elseif st == "COMPLETED" then color(colors.green) elseif st == "PROBLEM" or st == "ROGUE" then color(colors.red) else color(colors.lightGray) end
        print("  " .. items[i].label)
      end
    end
    color(colors.lightGray)
    local _, k = os.pullEvent("key")
    if k == keys.up then sel = math.max(1, sel - 1)
    elseif k == keys.down then sel = math.min(#items, sel + 1)
    elseif k == keys.enter then uiBusy = false; return items[sel]
    elseif k == keys.backspace or k == keys.left then uiBusy = false; return nil end
  end
end

local function press() color(colors.gray); print(""); print("Press any key..."); os.pullEvent("key") end
local function promptText(label, default)
  color(colors.lightGray); term.write(label .. (default ~= nil and (" [" .. tostring(default) .. "]") or "") .. ": ")
  local s = read()
  if s == "" and default ~= nil then return default end
  return s
end
local function promptNumber(label, default)
  while true do
    local s = promptText(label, default)
    local n = tonumber(s)
    if n then return n end
    print("Enter a number.")
  end
end
local function promptCoord(name)
  print("Enter " .. name .. ":")
  return { x = promptNumber("X"), y = promptNumber("Y"), z = promptNumber("Z") }
end
local function makeId(prefix) return prefix .. "-" .. tostring(os.epoch("utc")) .. "-" .. tostring(math.random(1000,9999)) end

local function distance(a,b)
  if not a or not b then return 999999 end
  local dx, dy, dz = a.x-b.x, a.y-b.y, a.z-b.z
  return math.sqrt(dx*dx+dy*dy+dz*dz)
end

local function boundsFromPoints(a,b)
  return { minX=math.min(a.x,b.x), maxX=math.max(a.x,b.x), minY=math.min(a.y,b.y), maxY=math.max(a.y,b.y), minZ=math.min(a.z,b.z), maxZ=math.max(a.z,b.z) }
end
local function expandBounds(b, n)
  return { minX=b.minX-n, maxX=b.maxX+n, minY=b.minY-n, maxY=b.maxY+n, minZ=b.minZ-n, maxZ=b.maxZ+n }
end

local function shapeBounds(job)
  local h = math.max(1, tonumber(job.layerHeight) or 1)
  if job.shape == "cuboid_center" then
    local a = math.floor((job.sideA - 1) / 2)
    local b = math.floor((job.sideB - 1) / 2)
    return { minX=job.origin.x-a, maxX=job.origin.x+(job.sideA-a-1), minY=job.origin.y, maxY=job.origin.y+h-1, minZ=job.origin.z-b, maxZ=job.origin.z+(job.sideB-b-1) }
  elseif job.shape == "cuboid_coords" then
    local bb = boundsFromPoints(job.a, job.b)
    job.origin = { x = math.floor((bb.minX + bb.maxX)/2), y = bb.minY, z = math.floor((bb.minZ + bb.maxZ)/2) }
    return bb
  elseif job.shape == "cylinder" or job.shape == "cone" or job.shape == "dome" then
    local r = job.radius
    return { minX=job.origin.x-r, maxX=job.origin.x+r, minY=job.origin.y, maxY=job.origin.y+h-1, minZ=job.origin.z-r, maxZ=job.origin.z+r }
  elseif job.shape == "pyramid" then
    local ax = math.floor(job.sideA / 2)
    local bz = math.floor(job.sideB / 2)
    return { minX=job.origin.x-ax, maxX=job.origin.x+ax, minY=job.origin.y, maxY=job.origin.y+h-1, minZ=job.origin.z-bz, maxZ=job.origin.z+bz }
  elseif job.shape == "stretched_cylinder" then
    local b = boundsFromPoints(job.origin, {x=job.origin2.x,y=job.origin.y,z=job.origin2.z})
    b.minY = job.origin.y; b.maxY = job.origin.y + h - 1
    return expandBounds(b, job.radius)
  elseif job.shape == "tunnel_spline" then
    local b = boundsFromPoints(job.origin, job.dest)
    return expandBounds(b, math.max(2, math.floor((job.width or 3)/2)+1))
  end
  return { minX=job.origin.x, maxX=job.origin.x, minY=job.origin.y, maxY=job.origin.y+h-1, minZ=job.origin.z, maxZ=job.origin.z }
end

local function passesForJob(job)
  local passes = {}
  local h = math.max(1, tonumber(job.layerHeight) or 1)
  local y0 = job.origin.y
  local pass = 1
  local offset = 0
  while offset < h do
    local count = math.min(3, h - offset)
    local travelY = y0 + offset + (count >= 3 and 1 or 0)
    table.insert(passes, { index=pass, minY=y0+offset, maxY=y0+offset+count-1, travelY=travelY, count=count })
    offset = offset + count
    pass = pass + 1
  end
  return passes
end

local function splitQuadrants(job, pass)
  local b = job.fullBounds
  local midX = math.floor((b.minX + b.maxX) / 2)
  local midZ = math.floor((b.minZ + b.maxZ) / 2)
  local qs = {
    { minX=b.minX, maxX=midX, minY=pass.minY, maxY=pass.maxY, minZ=b.minZ, maxZ=midZ },
    { minX=midX+1, maxX=b.maxX, minY=pass.minY, maxY=pass.maxY, minZ=b.minZ, maxZ=midZ },
    { minX=b.minX, maxX=midX, minY=pass.minY, maxY=pass.maxY, minZ=midZ+1, maxZ=b.maxZ },
    { minX=midX+1, maxX=b.maxX, minY=pass.minY, maxY=pass.maxY, minZ=midZ+1, maxZ=b.maxZ },
  }
  local out = {}
  for i, q in ipairs(qs) do if q.minX <= q.maxX and q.minZ <= q.maxZ then q.quadrant = i; q.travelY = pass.travelY; table.insert(out, q) end end
  return out
end

local function createTasks(job)
  job.tasks = {}
  job.fullBounds = shapeBounds(job)
  local passes = passesForJob(job)
  for _, pass in ipairs(passes) do
    for _, q in ipairs(splitQuadrants(job, pass)) do
      local t = {
        id = makeId("task"), jobId = job.id, passIndex = pass.index, quadrantIndex = q.quadrant,
        status = "QUEUED", minerId = nil, startedAt = nil, completedAt = nil, problem = nil,
        bounds = q, fullBounds = copy(job.fullBounds), travelY = pass.travelY,
      }
      table.insert(job.tasks, t)
    end
  end
end

local function compactProtected()
  local exact, contains = {}, {}
  for k in pairs(state.protected.exact or {}) do table.insert(exact, k) end
  for k in pairs(state.protected.contains or {}) do table.insert(contains, k) end
  table.sort(exact); table.sort(contains)
  return { exact=exact, contains=contains, revision=state.protected.revision or 1 }
end

local function sendProtected(id)
  send(id, { type="PROTECTED_LIST", payload=compactProtected() })
end

local function broadcastProtected()
  broadcast({ type="PROTECTED_LIST", payload=compactProtected() })
  log("Protected list broadcast rev " .. tostring(state.protected.revision))
end

local function activeGpsSubhosts()
  local n = 0
  local ids = {}
  local cutoff = now() - GPS_TIMEOUT * 1000
  for id, a in pairs(state.agents) do
    if a.role == "gps" and (a.lastSeen or 0) >= cutoff then n = n + 1; table.insert(ids, id) end
  end
  return n, ids
end

local function makeAnchorPayload()
  local n, ids = activeGpsSubhosts()
  return { controller = true, controllerId = os.getComputerID(), gpsSubhosts = n, gpsSubhostIds = ids, required = 3, ok = n >= 3, controllerCoords = copy(state.gps) }
end

local function agentIsOnline(a)
  return a and (now() - (a.lastSeen or 0)) <= AGENT_TIMEOUT * 1000
end

local function availableMiners()
  local out = {}
  local ctrlPos = state.gps.x and {x=state.gps.x,y=state.gps.y,z=state.gps.z} or nil
  for id, a in pairs(state.agents) do
    if a.role == "miner" and agentIsOnline(a) and a.status ~= "ROGUE" and a.status ~= "ASSIGNED" and a.status ~= "WORKING" and a.status ~= "RETURNING" then
      if a.homeValid and a.inventoryValid and a.gpsValid and a.atHome then
        if not ctrlPos or not a.pos or distance(ctrlPos, a.pos) <= MINER_HOME_RANGE then
          table.insert(out, { id=id, agent=a })
        end
      end
    end
  end
  table.sort(out, function(a,b) return tostring(a.id) < tostring(b.id) end)
  return out
end

local function compactJob(job)
  return {
    id=job.id, shape=job.shape, origin=copy(job.origin), origin2=copy(job.origin2), dest=copy(job.dest),
    a=copy(job.a), b=copy(job.b), sideA=job.sideA, sideB=job.sideB, width=job.width,
    radius=job.radius, layerHeight=job.layerHeight, step=job.step, torchMode=job.torchMode,
    torchSpacing=state.settings.torchSpacing, fullBounds=copy(job.fullBounds)
  }
end

local function assignTasks()
  for _, jobId in ipairs(state.activeJobs) do
    local job = state.jobs[jobId]
    if job and job.status ~= "PAUSED" and job.status ~= "CANCELLED" then
      local miners = availableMiners()
      if #miners == 0 then return end
      for _, task in ipairs(job.tasks or {}) do
        if task.status == "QUEUED" and #miners > 0 then
          local m = table.remove(miners, 1)
          task.status = "IN_PROGRESS"
          task.minerId = m.id
          task.startedAt = now()
          state.agents[m.id].status = "ASSIGNED"
          state.agents[m.id].assignedTask = task.id
          send(m.id, { type="TASK_ASSIGN", payload={ job=compactJob(job), task=copy(task), protectedRevision=state.protected.revision } })
          log("Assigned " .. task.id .. " to miner " .. tostring(m.id))
        end
      end
    end
  end
  saveState()
end

local function checkJobCompletion(job)
  local anyQueued, anyProgress, anyProblem = false, false, false
  for _, t in ipairs(job.tasks or {}) do
    if t.status == "QUEUED" then anyQueued = true elseif t.status == "IN_PROGRESS" then anyProgress = true elseif t.status == "PROBLEM" then anyProblem = true end
  end
  if not anyQueued and not anyProgress then
    job.status = anyProblem and "PROBLEM" or "COMPLETED"
    log("Job " .. job.id .. " " .. job.status)
  end
end

local function handleRegister(id, p)
  local pl = p.payload or {}
  state.agents[id] = state.agents[id] or {}
  local a = state.agents[id]
  a.id = id; a.role = pl.role or p.senderRole or "unknown"; a.label = pl.label or a.label or (a.role .. "-" .. id)
  a.lastSeen = now(); a.status = pl.status or a.status or "REGISTERED"; a.pos = pl.pos or a.pos
  a.home = pl.home or a.home; a.homeValid = pl.homeValid or false; a.inventoryValid = pl.inventoryValid or false
  a.gpsValid = pl.gpsValid or false; a.atHome = pl.atHome or false; a.protectedRevision = pl.protectedRevision or 0
  log("Registered " .. tostring(a.role) .. " " .. tostring(id) .. " " .. tostring(a.status))
  send(id, { type="REGISTER_ACK", payload={ controllerId=os.getComputerID(), protectedRevision=state.protected.revision, anchors=makeAnchorPayload(), killSwitch=state.killSwitch } })
  if a.role == "miner" or a.role == "foreman" then sendProtected(id) end
  saveState()
end

local function handleHeartbeat(id, p)
  local pl = p.payload or {}
  local a = state.agents[id] or { id=id, role=pl.role or p.senderRole or "unknown" }
  a.lastSeen = now(); a.role = pl.role or a.role; a.status = pl.status or a.status
  a.pos = pl.pos or a.pos; a.home = pl.home or a.home; a.homeValid = pl.homeValid or false
  a.inventoryValid = pl.inventoryValid or false; a.gpsValid = pl.gpsValid or false; a.atHome = pl.atHome or false
  a.protectedRevision = pl.protectedRevision or a.protectedRevision or 0
  if pl.rogue then a.status = "ROGUE"; a.rogue = true end
  state.agents[id] = a
  if (a.role == "miner" or a.role == "foreman") and (a.protectedRevision or 0) < (state.protected.revision or 1) then sendProtected(id) end
end

local function markTaskByMiner(minerId, status, problem)
  for _, job in pairs(state.jobs) do
    for _, t in ipairs(job.tasks or {}) do
      if t.minerId == minerId and t.status == "IN_PROGRESS" then
        t.status = status
        if status == "COMPLETED" then t.completedAt = now() end
        if status == "PROBLEM" then t.problem = problem or "Unknown problem" end
        if state.agents[minerId] then state.agents[minerId].status = status == "COMPLETED" and "IDLE" or "PROBLEM"; state.agents[minerId].assignedTask = nil end
        checkJobCompletion(job)
        saveState()
        return true
      end
    end
  end
  return false
end

local function handlePacket(id, p)
  if not validPacket(p) then return end
  if p.type == "REGISTER" then handleRegister(id, p)
  elseif p.type == "HEARTBEAT" then handleHeartbeat(id, p)
  elseif p.type == "ANCHOR_REQUEST" then send(id, { type="ANCHOR_STATUS", payload=makeAnchorPayload() })
  elseif p.type == "PROTECTED_REQUEST" then sendProtected(id)
  elseif p.type == "TASK_COMPLETE" then markTaskByMiner(id, "COMPLETED")
  elseif p.type == "TASK_PROBLEM" then markTaskByMiner(id, "PROBLEM", p.payload and p.payload.reason)
  elseif p.type == "ROGUE" then
    state.agents[id] = state.agents[id] or { id=id }
    state.agents[id].status = "ROGUE"; state.agents[id].rogue = true; state.agents[id].lastSeen = now(); state.agents[id].problem = p.payload and p.payload.reason
    markTaskByMiner(id, "PROBLEM", "Miner became rogue: " .. tostring(state.agents[id].problem))
    log("ROGUE turtle " .. tostring(id) .. ": " .. tostring(state.agents[id].problem))
    saveState()
  elseif p.type == "AT_HOME" then
    if state.agents[id] then state.agents[id].atHome = true; state.agents[id].status = "AT_HOME" end
  elseif p.type == "AT_ORIGIN" then
    if state.agents[id] then state.agents[id].status = "AT_ORIGIN" end
  end
end

local function networkLoop()
  while running do
    local id, msg = rednet.receive(PROTOCOL, 1)
    if id then handlePacket(id, msg) end
  end
end

local function gpsHostLoop()
  while running do
    if state.gps and state.gps.hostEnabled and state.gps.x and state.gps.y and state.gps.z then
      shell.run("gps", "host", tostring(state.gps.x), tostring(state.gps.y), tostring(state.gps.z))
    else
      sleep(1)
    end
  end
end

local function schedulerLoop()
  while running do
    assignTasks()
    sleep(3)
  end
end

local function drawDashboard()
  if not monitor then return end
  local old = term.redirect(monitor)
  header("Dashboard")
  print("ID: " .. os.getComputerID() .. " Modem: " .. tostring(modemSide or "missing"))
  term.write("GPS: "); writeCoord(state.gps.x and state.gps or nil); print("")
  local miners, foremen, gpss, rogue = 0,0,0,0
  for _, a in pairs(state.agents) do
    if a.role == "miner" then miners=miners+1 end
    if a.role == "foreman" then foremen=foremen+1 end
    if a.role == "gps" then gpss=gpss+1 end
    if a.status == "ROGUE" then rogue=rogue+1 end
  end
  print("Miners: "..miners.." Foremen: "..foremen.." GPS Subhosts: "..gpss.." Rogue: "..rogue)
  print("Active jobs: " .. #state.activeJobs .. " Queued jobs: " .. #state.queuedJobs)
  print("Protected rev: " .. tostring(state.protected.revision))
  if state.killSwitch.active then color(colors.red); print("KILL SWITCH ACTIVE " .. tostring(state.killSwitch.id)); color(colors.lightGray) end
  print("")
  print("Recent logs:")
  local _, h = term.getSize()
  local start = math.max(1, #state.logs - (h - 9))
  for i=start,#state.logs do print(string.sub(state.logs[i],1,80)) end
  term.redirect(old)
end

local function dashboardLoop()
  while running do drawDashboard(); sleep(2) end
end

local function setControllerGps()
  header("Controller GPS")
  print("Set this computer's fixed GPS host coordinates.")
  state.gps.x = promptNumber("X", state.gps.x)
  state.gps.y = promptNumber("Y", state.gps.y)
  state.gps.z = promptNumber("Z", state.gps.z)
  state.gps.hostEnabled = true
  saveState(); log("Controller GPS set")
  print("Saved. Reboot may be needed if gps host was already running stale coords.")
  press()
end

local function viewFleet(role)
  local items = {}
  for id, a in pairs(state.agents) do
    if not role or a.role == role then
      table.insert(items, { label = tostring(id) .. " " .. tostring(a.role) .. " " .. tostring(a.status or "?") .. " " .. (a.pos and ("@ "..a.pos.x..","..a.pos.y..","..a.pos.z) or ""), status=a.status })
    end
  end
  table.sort(items, function(a,b) return a.label < b.label end)
  if #items == 0 then header("Fleet"); print("No agents."); press(); return end
  table.insert(items, {label="Back"})
  choose("Fleet", items)
end

local function sendAllTurtlesHome()
  broadcast({ type="GO_HOME", payload={ reason="controller_command" } })
  log("Broadcast GO_HOME")
end

local function killSwitch()
  header("KILL SWITCH")
  color(colors.red); print("This stops all turtles and forces return home."); color(colors.lightGray)
  print("If a turtle cannot confirm home, it must terminate and label itself ROGUE.")
  print("Type KILL to activate.")
  if read() ~= "KILL" then return end
  state.killSwitch = { active=true, id=makeId("kill"), startedAt=now() }
  saveState()
  broadcast({ type="EMERGENCY_STOP_RETURN", payload={ killId=state.killSwitch.id, reason="controller_kill_switch" } })
  log("KILL SWITCH ACTIVATED " .. state.killSwitch.id)
  print("Kill switch broadcast.")
  press()
end

local function clearKillSwitch()
  header("Clear Kill Switch")
  print("This stops broadcasting emergency state, but it does not clear Rogue labels automatically.")
  print("Type CLEAR to confirm.")
  if read() == "CLEAR" then state.killSwitch.active=false; saveState(); broadcast({type="KILL_SWITCH_CLEAR",payload={}}); log("Kill switch cleared") end
end

local function protectedMenu()
  while true do
    local it = choose("Protected Blocks", {
      {label="View Protected List"}, {label="Add Exact ID"}, {label="Add Contains/Substring"}, {label="Remove Custom Entry"}, {label="Broadcast Now"}, {label="Back"}
    })
    if not it or it.label == "Back" then return end
    if it.label == "View Protected List" then
      header("Protected List")
      print("Exact:")
      for k in pairs(state.protected.exact) do print("  "..k) end
      print("")
      print("Contains:")
      for k in pairs(state.protected.contains) do print("  "..k) end
      press()
    elseif it.label == "Add Exact ID" then
      header("Add Exact")
      local v = string.lower(promptText("Block ID", "minecraft:block"))
      state.protected.exact[v] = true; state.protected.custom[v] = "exact"; state.protected.revision = state.protected.revision + 1; saveState(); broadcastProtected()
    elseif it.label == "Add Contains/Substring" then
      header("Add Contains")
      local v = string.lower(promptText("Substring", "modid:"))
      state.protected.contains[v] = true; state.protected.custom[v] = "contains"; state.protected.revision = state.protected.revision + 1; saveState(); broadcastProtected()
    elseif it.label == "Remove Custom Entry" then
      local items = {}
      for k, typ in pairs(state.protected.custom or {}) do table.insert(items, {label=k .. " (" .. typ .. ")", key=k, typ=typ}) end
      table.insert(items, {label="Back"})
      local r = choose("Remove Custom", items)
      if r and r.key then
        if r.typ == "exact" then state.protected.exact[r.key] = nil else state.protected.contains[r.key] = nil end
        state.protected.custom[r.key] = nil; state.protected.revision = state.protected.revision + 1; saveState(); broadcastProtected()
      end
    elseif it.label == "Broadcast Now" then broadcastProtected(); press() end
  end
end

local function askTorchMode(layerHeight)
  if layerHeight <= 1 then
    local it = choose("Torch Behavior", {{label="Removed"},{label="Ignored"}}, "Layer height 1: placement is unavailable.")
    if not it then return "ignored" end
    return string.lower(it.label)
  end
  local it = choose("Torch Behavior", {{label="Removed"},{label="Ignored"},{label="Replaced"}})
  if not it then return "ignored" end
  return string.lower(it.label)
end

local function createJob()
  local shapeItem = choose("Create New Job", SHAPES)
  if not shapeItem then return end
  local job = { id=makeId("job"), shape=shapeItem.key, status="CREATED", createdAt=now() }
  header("Create " .. shapeItem.label)
  if job.shape == "cuboid_center" then
    job.origin = promptCoord("center origin / layer 1")
    job.sideA = promptNumber("Side A length")
    job.sideB = promptNumber("Side B length")
    job.layerHeight = promptNumber("Layer height", 1)
  elseif job.shape == "cuboid_coords" then
    job.a = promptCoord("x y z")
    job.b = promptCoord("x2 y2 z2")
    job.layerHeight = math.abs(job.b.y - job.a.y) + 1
  elseif job.shape == "cylinder" or job.shape == "cone" or job.shape == "dome" then
    job.origin = promptCoord("center origin / layer 1")
    job.radius = promptNumber("Radius")
    job.layerHeight = promptNumber("Layer height", 1)
  elseif job.shape == "pyramid" then
    job.origin = promptCoord("center origin / layer 1")
    job.sideA = promptNumber("Side A")
    job.sideB = promptNumber("Side B")
    job.layerHeight = promptNumber("Layer height", 1)
    if job.layerHeight > 3 then job.step = promptNumber("Step value", 1) else job.step = 1 end
  elseif job.shape == "stretched_cylinder" then
    job.origin = promptCoord("origin x y z / pathing origin")
    print("Second origin uses x2 and z2. y2 = y.")
    job.origin2 = { x=promptNumber("X2"), y=job.origin.y, z=promptNumber("Z2") }
    job.radius = promptNumber("Radius")
    job.layerHeight = promptNumber("Layer height", 1)
  elseif job.shape == "tunnel_spline" then
    job.origin = promptCoord("origin")
    job.dest = promptCoord("destination")
    if distance(job.origin, job.dest) <= 30 then print("Tunnel spline must be more than 30 blocks apart."); press(); return end
    job.width = promptNumber("Width", 3)
    job.layerHeight = promptNumber("Layer height", 3)
  end
  job.torchMode = askTorchMode(job.layerHeight or 1)
  createTasks(job)
  state.jobs[job.id] = job
  local activeCount = #state.activeJobs
  if activeCount > 0 then
    local run = choose("Job Scheduling", {{label="Queue after current active job"},{label="Run simultaneously"}})
    if run and run.label == "Run simultaneously" then table.insert(state.activeJobs, job.id); job.status="ACTIVE" else table.insert(state.queuedJobs, job.id); job.status="QUEUED" end
  else
    table.insert(state.activeJobs, job.id); job.status = "ACTIVE"
  end
  saveState(); log("Created job " .. job.id .. " tasks=" .. tostring(#job.tasks))
  assignTasks()
  header("Job Created")
  print("Job: " .. job.id)
  print("Tasks: " .. #job.tasks)
  press()
end

local function viewJobs()
  local items = {}
  for id, job in pairs(state.jobs) do table.insert(items, {label=id .. " " .. tostring(job.shape) .. " " .. tostring(job.status), job=job, status=job.status}) end
  table.sort(items, function(a,b) return a.label < b.label end)
  table.insert(items,{label="Back"})
  local it = choose("Jobs", items)
  if not it or not it.job then return end
  while true do
    local j = it.job
    local titems = {}
    table.insert(titems, {label="Status: " .. tostring(j.status)})
    table.insert(titems, {label="Tasks:"})
    for _, t in ipairs(j.tasks or {}) do table.insert(titems, {label=t.id .. " P" .. t.passIndex .. " Q" .. t.quadrantIndex .. " " .. t.status .. " miner=" .. tostring(t.minerId or "none"), status=t.status}) end
    table.insert(titems,{label="Back"})
    local back = choose("Job " .. j.id, titems)
    return
  end
end

local function pauseResumeCancel(action)
  local items = {}
  for id, job in pairs(state.jobs) do if job.status ~= "COMPLETED" and job.status ~= "CANCELLED" then table.insert(items,{label=id .. " " .. job.status, job=job}) end end
  table.insert(items,{label="Back"})
  local it = choose(action .. " Job", items)
  if not it or not it.job then return end
  local job = it.job
  if action == "Pause" then job.status="PAUSED"; broadcast({type="PAUSE_JOB",payload={jobId=job.id}})
  elseif action == "Resume" then job.status="ACTIVE"; broadcast({type="RESUME_JOB",payload={jobId=job.id}})
  elseif action == "Cancel" then job.status="CANCELLED"; broadcast({type="CANCEL_JOB",payload={jobId=job.id}}) end
  saveState(); log(action .. " job " .. job.id)
end

local function resetProblemTask()
  local items = {}
  for _, job in pairs(state.jobs) do
    for _, t in ipairs(job.tasks or {}) do
      if t.status == "PROBLEM" then table.insert(items,{label=job.id .. " " .. t.id .. " " .. tostring(t.problem), job=job, task=t, status="PROBLEM"}) end
    end
  end
  table.insert(items,{label="Back"})
  local it = choose("Reset Problem Task", items)
  if it and it.task then it.task.status="QUEUED"; it.task.problem=nil; it.task.minerId=nil; saveState(); log("Reset task "..it.task.id); assignTasks() end
end

local function jobsMenu()
  while true do
    local it = choose("Jobs", {{label="View Jobs"},{label="Create New Job"},{label="Pause Job"},{label="Resume Job"},{label="Cancel Job"},{label="Reset Problem Quadrant"},{label="View Job Status"},{label="Back"}})
    if not it or it.label == "Back" then return end
    if it.label == "View Jobs" or it.label == "View Job Status" then viewJobs()
    elseif it.label == "Create New Job" then createJob()
    elseif it.label == "Pause Job" then pauseResumeCancel("Pause")
    elseif it.label == "Resume Job" then pauseResumeCancel("Resume")
    elseif it.label == "Cancel Job" then pauseResumeCancel("Cancel")
    elseif it.label == "Reset Problem Quadrant" then resetProblemTask() end
  end
end

local function gpsMenu()
  while true do
    local n = activeGpsSubhosts()
    local it = choose("GPS", {{label="Set Controller GPS Coordinates"},{label="View GPS Anchors ("..n.."/3 subhosts)"},{label="Reset GPS Subhosts"},{label="GPS Diagnostics"},{label="Back"}})
    if not it or it.label == "Back" then return end
    if it.label == "Set Controller GPS Coordinates" then setControllerGps()
    elseif it.label:find("View GPS") or it.label == "GPS Diagnostics" then
      header("GPS Diagnostics")
      term.write("Controller: "); writeCoord(state.gps.x and state.gps or nil); print("")
      local c, ids = activeGpsSubhosts(); print("GPS Subhosts online: " .. c .. "/3")
      for _, id in ipairs(ids) do local a=state.agents[id]; print("  "..id.." "..(a.pos and (a.pos.x..","..a.pos.y..","..a.pos.z) or "unknown")) end
      press()
    elseif it.label == "Reset GPS Subhosts" then print("Type RESET to command all GPS subhosts to clear coordinates."); if read()=="RESET" then broadcast({type="GPS_RESET",payload={}}); log("GPS reset broadcast") end end
  end
end

local function fleetMenu()
  while true do
    local it = choose("Fleet", {{label="View Miners"},{label="View Foremen"},{label="View GPS Subhosts"},{label="Send All Turtles Home"},{label="KILL SWITCH: Stop All And Force Home"},{label="Clear Kill Switch"},{label="Roll Call"},{label="Back"}})
    if not it or it.label == "Back" then return end
    if it.label == "View Miners" then viewFleet("miner")
    elseif it.label == "View Foremen" then viewFleet("foreman")
    elseif it.label == "View GPS Subhosts" then viewFleet("gps")
    elseif it.label == "Send All Turtles Home" then sendAllTurtlesHome(); press()
    elseif it.label:find("KILL SWITCH") then killSwitch()
    elseif it.label == "Clear Kill Switch" then clearKillSwitch()
    elseif it.label == "Roll Call" then broadcast({type="ROLL_CALL",payload={}}); log("Roll call broadcast"); press() end
  end
end

local function logsMenu()
  header("Logs")
  local start = math.max(1, #state.logs - 30)
  for i=start,#state.logs do print(state.logs[i]) end
  press()
end

local function mainMenu()
  while running do
    local it = choose("Main Menu", {{label="Jobs"},{label="Fleet"},{label="GPS"},{label="Protected Blocks"},{label="Settings"},{label="Logs"},{label="Exit"}})
    if not it or it.label == "Exit" then running=false; return end
    if it.label == "Jobs" then jobsMenu()
    elseif it.label == "Fleet" then fleetMenu()
    elseif it.label == "GPS" then gpsMenu()
    elseif it.label == "Protected Blocks" then protectedMenu()
    elseif it.label == "Settings" then header("Settings"); print("GPS move interval: "..state.settings.gpsCheckMoves); print("Torch spacing: "..state.settings.torchSpacing); press()
    elseif it.label == "Logs" then logsMenu() end
  end
end

math.randomseed(os.epoch("utc") + os.getComputerID())
ensureDir()
healState(loadTable(STATE_FILE))
saveState()
attachMonitor()
if not openModem() then header("Error"); print("No modem found."); return end
log("Controller boot " .. VERSION)
parallel.waitForAny(networkLoop, gpsHostLoop, schedulerLoop, dashboardLoop, mainMenu)
header("Controller Exit")
print("Controller stopped.")
