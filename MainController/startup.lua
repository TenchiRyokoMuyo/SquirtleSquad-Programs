-- SquirtleSquad-Miner v1.3
-- MainController/startup.lua
-- Patch focus:
-- * Controller-owned protected block list.
-- * Broadcasts protected list to miners on register and whenever updated.
-- * Keeps turtle-local home system.
-- * Keeps layers instead of height for cylinder/cone/pyramid.
-- * Scrollable menus.
-- * Live turtle coordinate viewer and GO_HOME command.
-- * Reset connected GPS subhosts.

local PROTOCOL = "TurtleTeamNet"
local PROJECT = "SquirtleSquad-Miner"
local VERSION = "v1.3"

local DATA_DIR = "SquirtleSquadData"
local STATE_FILE = DATA_DIR .. "/controller_state.dat"

local defaultProtectedBlocks = {
    "minecraft:spawner",

    -- Storage and turtle home infrastructure
    "chest",
    "barrel",
    "shulker",

    -- ComputerCraft / CC:Tweaked
    "computercraft:",
    "turtle",
    "computer",
    "modem",
    "monitor",
    "drive",
    "disk_drive",
    "speaker",
    "printer",

    -- Other infrastructure
    "display_link",
    "create:display_link",
    "scaffold",
    "scaffolding"
}

local state = {
    version = VERSION,
    controllerId = os.getComputerID(),
    gps = { x = nil, y = nil, z = nil, hostEnabled = true },
    agents = {},
    teams = {},
    jobs = {},
    activeJobId = nil,
    deploymentQueue = {},
    logs = {},
    protectedBlocks = {},
    protectedRevision = 1
}

local modemSide = nil
local monitor = nil
local terminal = term.current()
local running = true

local function ensureDir()
    if not fs.exists(DATA_DIR) then
        fs.makeDir(DATA_DIR)
    end
end

local function normalizeProtectedList(list)
    local out = {}
    local seen = {}

    for _, v in ipairs(defaultProtectedBlocks) do
        local s = string.lower(tostring(v or ""))
        if s ~= "" and not seen[s] then
            table.insert(out, s)
            seen[s] = true
        end
    end

    if type(list) == "table" then
        for _, v in ipairs(list) do
            local s = string.lower(tostring(v or ""))
            if s ~= "" and not seen[s] then
                table.insert(out, s)
                seen[s] = true
            end
        end
    end

    table.sort(out)
    return out
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

    s.version = VERSION
    s.controllerId = s.controllerId or os.getComputerID()
    s.gps = s.gps or { hostEnabled = true }
    if s.gps.hostEnabled == nil then s.gps.hostEnabled = true end
    s.agents = s.agents or {}
    s.teams = s.teams or {}
    s.jobs = s.jobs or {}
    s.activeJobId = s.activeJobId or nil
    s.deploymentQueue = s.deploymentQueue or {}
    s.logs = s.logs or {}
    s.protectedBlocks = normalizeProtectedList(s.protectedBlocks)
    s.protectedRevision = tonumber(s.protectedRevision) or 1

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

local function color(c)
    if term.isColor() then term.setTextColor(c) end
end

local function bcolor(c)
    if term.isColor() then term.setBackgroundColor(c) end
end

local function writeCentered(t, y, text, col)
    local w = t.getSize()
    if col and t.isColor and t.isColor() then t.setTextColor(col) end
    t.setCursorPos(math.max(1, math.floor((w - #text) / 2) + 1), y)
    t.write(text)
end

local function header(t)
    if t.isColor and t.isColor() then
        t.setBackgroundColor(colors.black)
        t.setTextColor(colors.cyan)
    end
    t.clear()
    t.setCursorPos(1, 1)
    writeCentered(t, 1, " " .. PROJECT .. " " .. VERSION .. " ", colors.cyan)
    writeCentered(t, 2, "Industrial Fleet Excavation Controller", colors.lightBlue)
    if t.isColor and t.isColor() then t.setTextColor(colors.white) end
end

local function promptNumber(label, default)
    term.write(label .. (default ~= nil and (" [" .. default .. "]") or "") .. ": ")
    local s = read()
    if s == "" and default ~= nil then return tonumber(default) end
    return tonumber(s)
end

local function promptText(label, default)
    term.write(label .. (default and (" [" .. default .. "]") or "") .. ": ")
    local s = read()
    if s == "" then return default end
    return s
end

local function promptCoord(name)
    print("Enter " .. name .. " coordinates:")
    local x = promptNumber("X")
    local y = promptNumber("Y")
    local z = promptNumber("Z")
    if not x or not y or not z then
        print("Invalid coordinates.")
        sleep(1)
        return nil
    end
    return { x = x, y = y, z = z }
end

local function makeId(prefix)
    return prefix .. "-" .. tostring(os.epoch("utc")) .. "-" .. tostring(math.random(1000, 9999))
end

local function cloneCoord(c)
    if not c then return nil end
    return { x = c.x, y = c.y, z = c.z }
end

local function cloneBounds(b)
    if not b then return nil end
    return {
        minX = b.minX, maxX = b.maxX,
        minY = b.minY, maxY = b.maxY,
        minZ = b.minZ, maxZ = b.maxZ
    }
end

local function chooseMenu(title, items, subtitle)
    if not items or #items == 0 then
        header(term)
        print(title)
        print("")
        print("No options.")
        sleep(1)
        return nil, nil
    end

    local selected, top = 1, 1

    while true do
        term.redirect(terminal)
        header(term)
        print("")
        print(title)
        if subtitle then print(subtitle) end
        print("Use Up/Down and Enter. Backspace to go back.")
        print("")

        local _, h = term.getSize()
        local visible = math.max(3, h - 7)

        if selected < top then top = selected end
        if selected >= top + visible then top = selected - visible + 1 end

        for row = 0, visible - 1 do
            local i = top + row
            if i > #items then break end

            if i == selected then
                bcolor(colors.blue)
                color(colors.white)
                print("> " .. items[i][1])
                bcolor(colors.black)
            else
                color(colors.white)
                print("  " .. items[i][1])
            end
        end

        color(colors.white)
        local _, k = os.pullEvent("key")
        if k == keys.up then
            selected = math.max(1, selected - 1)
        elseif k == keys.down then
            selected = math.min(#items, selected + 1)
        elseif k == keys.enter then
            return items[selected][2], selected
        elseif k == keys.backspace or k == keys.left then
            return nil, nil
        end
    end
end

local function drawDashboard()
    if not monitor then return end

    local old = term.redirect(monitor)
    header(monitor)

    local w, h = monitor.getSize()
    local y = 4
    local miners, foremen, gpshosts = 0, 0, 0

    for _, a in pairs(state.agents) do
        if a.role == "miner" then miners = miners + 1
        elseif a.role == "foreman" then foremen = foremen + 1
        elseif a.role == "gps" then gpshosts = gpshosts + 1 end
    end

    monitor.setCursorPos(1, y); monitor.write("Controller ID: " .. os.getComputerID()); y = y + 1
    monitor.setCursorPos(1, y); monitor.write("Modem: " .. tostring(modemSide or "missing")); y = y + 1
    monitor.setCursorPos(1, y); monitor.write("Miners: " .. miners .. " Foremen: " .. foremen .. " GPS Subhosts: " .. gpshosts); y = y + 1
    monitor.setCursorPos(1, y); monitor.write("Teams: " .. tostring(#state.teams)); y = y + 1
    monitor.setCursorPos(1, y); monitor.write("Active Job: " .. tostring(state.activeJobId or "none")); y = y + 1
    monitor.setCursorPos(1, y); monitor.write("Protected Rev: " .. tostring(state.protectedRevision)); y = y + 2
    monitor.setCursorPos(1, y); monitor.write("Recent Logs:"); y = y + 1

    local start = math.max(1, #state.logs - (h - y) + 1)
    for i = start, #state.logs do
        if y > h then break end
        monitor.setCursorPos(1, y)
        monitor.write(string.sub(state.logs[i], 1, w))
        y = y + 1
    end

    term.redirect(old)
end

local function jobLayers(job)
    return math.max(1, tonumber(job.layers or job.height or 1) or 1)
end

local function createJob()
    local choices = {
        { "Rectangular Prism", "rect" },
        { "Cylinder", "cylinder" },
        { "Dome", "dome" },
        { "Stretched Cylinder", "stretched_cylinder" },
        { "Pyramid", "pyramid" },
        { "Cone", "cone" },
        { "Tunnel", "tunnel" },
        { "Tunnel Spline", "tunnel_spline" }
    }

    local shape = chooseMenu("Create Job", choices, "Each miner uses its own home chests. No controller storage is used.")
    if not shape then return end

    header(term)

    local job = {
        id = makeId("job"),
        status = "CREATED",
        torchSpacing = 8,
        created = os.epoch("utc"),
        shape = shape
    }

    if shape == "rect" then
        print("Rectangular prism uses x y z to x2 y2 z2.")
        job.a = promptCoord("corner A")
        job.b = promptCoord("corner B")
    elseif shape == "cylinder" then
        job.origin = promptCoord("center origin")
        job.radius = promptNumber("Radius")
        job.layers = promptNumber("Layers (origin Y is layer 1)", 1)
    elseif shape == "dome" then
        job.origin = promptCoord("center origin")
        job.radius = promptNumber("Radius")
    elseif shape == "stretched_cylinder" then
        job.a = promptCoord("origin A")
        job.b = promptCoord("origin B")
        job.radius = promptNumber("Radius")
    elseif shape == "pyramid" then
        job.origin = promptCoord("center origin")
        job.radius = promptNumber("Base half-width/radius")
        job.layers = promptNumber("Layers (origin Y is layer 1)", 1)
    elseif shape == "cone" then
        job.origin = promptCoord("center origin")
        job.radius = promptNumber("Radius")
        job.layers = promptNumber("Layers (origin Y is layer 1)", 1)
    elseif shape == "tunnel" then
        job.a = promptCoord("origin")
        job.b = promptCoord("destination")
        job.width = promptNumber("Width", 3)
        job.height = promptNumber("Height", job.width)
    elseif shape == "tunnel_spline" then
        job.a = promptCoord("origin")
        job.b = promptCoord("destination")
        job.width = promptNumber("Width", 3)
        job.height = promptNumber("Height", job.width)
        job.shallow = true
    end

    if not job.shape then
        print("Invalid job.")
        sleep(1)
        return
    end

    state.jobs[job.id] = job
    state.activeJobId = job.id
    log("Job created: " .. job.id .. " (" .. job.shape .. ")")
    saveState()
    print("Job created: " .. job.id)
    sleep(1)
end

local function activeAgents(role)
    local t = {}
    local now = os.epoch("utc")

    for id, a in pairs(state.agents) do
        if (not role or a.role == role) and now - (a.lastSeen or 0) < 45000 then
            table.insert(t, a)
        end
    end

    table.sort(t, function(a, b)
        return tostring(a.id) < tostring(b.id)
    end)

    return t
end

local function activeForemen()
    return activeAgents("foreman")
end

local function computeJobBounds(job)
    if not job then return nil end

    if job.shape == "rect" then
        return {
            minX = math.min(job.a.x, job.b.x), maxX = math.max(job.a.x, job.b.x),
            minY = math.min(job.a.y, job.b.y), maxY = math.max(job.a.y, job.b.y),
            minZ = math.min(job.a.z, job.b.z), maxZ = math.max(job.a.z, job.b.z)
        }
    elseif job.shape == "cylinder" or job.shape == "cone" or job.shape == "pyramid" then
        local r = tonumber(job.radius or 0) or 0
        local layers = jobLayers(job)
        return {
            minX = job.origin.x - r, maxX = job.origin.x + r,
            minY = job.origin.y, maxY = job.origin.y + layers - 1,
            minZ = job.origin.z - r, maxZ = job.origin.z + r
        }
    elseif job.shape == "dome" then
        local r = tonumber(job.radius or 0) or 0
        return {
            minX = job.origin.x - r, maxX = job.origin.x + r,
            minY = job.origin.y, maxY = job.origin.y + r,
            minZ = job.origin.z - r, maxZ = job.origin.z + r
        }
    elseif job.shape == "stretched_cylinder" or job.shape == "tunnel" or job.shape == "tunnel_spline" then
        local r = tonumber(job.radius or math.max(job.width or 3, job.height or job.width or 3) / 2) or 2
        return {
            minX = math.floor(math.min(job.a.x, job.b.x) - r), maxX = math.ceil(math.max(job.a.x, job.b.x) + r),
            minY = math.floor(math.min(job.a.y, job.b.y) - r), maxY = math.ceil(math.max(job.a.y, job.b.y) + r),
            minZ = math.floor(math.min(job.a.z, job.b.z) - r), maxZ = math.ceil(math.max(job.a.z, job.b.z) + r)
        }
    end

    return nil
end

local function buildTeams()
    local miners = activeAgents("miner")
    local foremen = activeForemen()

    state.teams = {}

    for i, miner in ipairs(miners) do
        local f = nil
        if #foremen > 0 then
            f = foremen[((i - 1) % #foremen) + 1]
        end

        table.insert(state.teams, {
            id = "team-" .. tostring(i),
            minerId = miner.id,
            minerNet = miner.netId,
            foremanId = f and f.id or nil,
            foremanNet = f and f.netId or nil,
            groupIndex = i,
            groupCount = #miners
        })
    end

    saveState()
end

local function compactJob(job)
    return {
        id = job.id,
        shape = job.shape,
        status = job.status,
        origin = cloneCoord(job.origin),
        a = cloneCoord(job.a),
        b = cloneCoord(job.b),
        radius = job.radius,
        layers = jobLayers(job),
        height = jobLayers(job),
        width = job.width,
        torchSpacing = job.torchSpacing,
        shallow = job.shallow,
        created = job.created
    }
end

local function compactSector(sector)
    return {
        id = sector.id,
        index = sector.index,
        count = sector.count,
        bounds = cloneBounds(sector.bounds),
        fullBounds = cloneBounds(sector.fullBounds)
    }
end

local function safeSend(target, packet, protocol)
    if not target then return false end

    local ok, payload = pcall(textutils.serialize, packet)
    if not ok then
        print("Packet serialization failed:")
        print(tostring(payload))
        log("Packet serialization failed: " .. tostring(payload))
        return false
    end

    return rednet.send(target, textutils.unserialize(payload), protocol)
end

local function protectedPacket()
    return {
        type = "PROTECTED_LIST_UPDATE",
        project = PROJECT,
        version = VERSION,
        revision = state.protectedRevision,
        protectedBlocks = state.protectedBlocks
    }
end

local function sendProtectedListTo(netId)
    safeSend(netId, protectedPacket(), PROTOCOL)
end

local function broadcastProtectedList()
    state.protectedBlocks = normalizeProtectedList(state.protectedBlocks)
    state.protectedRevision = (tonumber(state.protectedRevision) or 0) + 1
    saveState()

    local count = 0
    for _, a in pairs(state.agents) do
        if a.role == "miner" and a.netId then
            sendProtectedListTo(a.netId)
            count = count + 1
        end
    end

    log("Protected list rev " .. tostring(state.protectedRevision) .. " sent to " .. tostring(count) .. " miner(s).")
end

local function assignActiveJob()
    local job = state.jobs[state.activeJobId or ""]
    if not job then
        log("No active job to assign.")
        return
    end

    buildTeams()

    if #state.teams == 0 then
        log("No miners available.")
        return
    end

    local foremen = activeForemen()
    if #foremen == 0 then
        log("Assigning job with 0 foremen present; miners are allowed to run without foremen.")
    end

    local bounds = computeJobBounds(job)
    if not bounds or not bounds.minX then
        log("Could not compute job bounds.")
        return
    end

    local total = #state.teams
    state.deploymentQueue = {}

    local jobPacket = compactJob(job)

    for i, team in ipairs(state.teams) do
        local sx1 = bounds.minX + math.floor((bounds.maxX - bounds.minX + 1) * (i - 1) / total)
        local sx2 = bounds.minX + math.floor((bounds.maxX - bounds.minX + 1) * i / total) - 1
        if i == total then sx2 = bounds.maxX end

        local sector = {
            id = "sector-" .. i,
            index = i,
            count = total,
            bounds = {
                minX = sx1, maxX = sx2,
                minY = bounds.minY, maxY = bounds.maxY,
                minZ = bounds.minZ, maxZ = bounds.maxZ
            },
            fullBounds = cloneBounds(bounds)
        }

        team.jobId = job.id
        team.sectorId = sector.id
        team.sectorBounds = cloneBounds(sector.bounds)
        team.fullBounds = cloneBounds(sector.fullBounds)
        team.deployOrder = i
        team.status = "ASSIGNED"

        table.insert(state.deploymentQueue, team.id)

        if team.foremanNet then
            safeSend(team.foremanNet, {
                type = "ASSIGN_FOREMAN",
                project = PROJECT,
                version = VERSION,
                teamId = team.id,
                minerId = team.minerId,
                minerNet = team.minerNet,
                jobId = job.id,
                job = jobPacket,
                sector = compactSector(sector),
                deployOrder = i,
                deployHold = true
            }, PROTOCOL)
        end

        sendProtectedListTo(team.minerNet)

        safeSend(team.minerNet, {
            type = "ASSIGN_JOB",
            project = PROJECT,
            version = VERSION,
            teamId = team.id,
            minerId = team.minerId,
            foremanId = team.foremanId,
            foremanNet = team.foremanNet,
            jobId = job.id,
            job = jobPacket,
            sector = compactSector(sector),
            deployOrder = i,
            deployHold = true,
            protectedRevision = state.protectedRevision,
            protectedBlocks = state.protectedBlocks
        }, PROTOCOL)
    end

    job.status = "ASSIGNED"
    saveState()
    log("Assigned job to " .. tostring(#state.teams) .. " miner teams.")

    if #state.deploymentQueue > 0 then
        local first = state.deploymentQueue[1]

        for _, team in ipairs(state.teams) do
            if team.id == first then
                safeSend(team.minerNet, { type = "DEPLOY_NOW", teamId = team.id, jobId = job.id }, PROTOCOL)
                if team.foremanNet then
                    safeSend(team.foremanNet, { type = "DEPLOY_NOW", teamId = team.id, jobId = job.id }, PROTOCOL)
                end
                log("Deployment started: " .. team.id)
            end
        end
    end
end

local function pauseJob()
    for _, a in pairs(state.agents) do
        if a.netId then rednet.send(a.netId, { type = "PAUSE_JOB" }, PROTOCOL) end
    end
    log("Pause sent.")
end

local function resumeJob()
    for _, a in pairs(state.agents) do
        if a.netId then rednet.send(a.netId, { type = "RESUME_JOB" }, PROTOCOL) end
    end
    log("Resume sent.")
end

local function cancelJob()
    for _, a in pairs(state.agents) do
        if a.netId then rednet.send(a.netId, { type = "CANCEL_JOB" }, PROTOCOL) end
    end

    if state.activeJobId and state.jobs[state.activeJobId] then
        state.jobs[state.activeJobId].status = "CANCELLED"
    end

    state.activeJobId = nil
    saveState()
    log("Cancel sent. Miners will return home if they have a home set.")
end

local function distanceFromController(a)
    if not (state.gps.x and state.gps.y and state.gps.z and a.x and a.y and a.z) then
        return "?"
    end

    local dx, dy, dz = a.x - state.gps.x, a.y - state.gps.y, a.z - state.gps.z
    return tostring(math.floor(math.sqrt(dx * dx + dy * dy + dz * dz) + 0.5))
end

local function agentLabel(a)
    return tostring(a.label or a.id) .. " [" .. tostring(a.role) .. "] " .. tostring(a.status or "?") .. " dist " .. distanceFromController(a)
end

local function chooseAgent(title, roleFilter)
    local agents = activeAgents(roleFilter)

    if #agents == 0 then
        header(term)
        print("No active agents found.")
        sleep(1.5)
        return nil
    end

    local items = {}
    for _, a in ipairs(agents) do
        table.insert(items, { agentLabel(a), a })
    end

    local chosen = chooseMenu(title, items)
    return chosen
end

local function viewLiveCoordinates()
    local a = chooseAgent("View Turtle Live Coordinates", nil)
    if not a then return end

    while true do
        header(term)
        local live = state.agents[a.id] or a

        print(tostring(live.label or live.id))
        print("Role: " .. tostring(live.role))
        print("Status: " .. tostring(live.status))
        print("Net ID: " .. tostring(live.netId))
        print("Coords: " .. tostring(live.x) .. ", " .. tostring(live.y) .. ", " .. tostring(live.z))
        print("Distance from controller GPS: " .. distanceFromController(live))
        print("Protected rev: " .. tostring(live.protectedRevision or "?"))
        print("Last seen: " .. tostring(math.floor((os.epoch("utc") - (live.lastSeen or 0)) / 1000)) .. "s ago")
        print("")
        print("Press Q or Backspace to exit. Refreshes every second.")

        local timer = os.startTimer(1)
        while true do
            local ev, k = os.pullEvent()
            if ev == "timer" and k == timer then break end
            if ev == "key" and (k == keys.q or k == keys.backspace) then return end
        end
    end
end

local function sendTurtleHome()
    local a = chooseAgent("Send Turtle Home", nil)
    if not a then return end

    rednet.send(a.netId, { type = "GO_HOME", resume = false }, PROTOCOL)
    log("GO_HOME sent to " .. tostring(a.label or a.id))
end

local function resetConnectedSubhosts()
    local count = 0

    for _, a in pairs(state.agents) do
        if a.role == "gps" and a.netId then
            rednet.send(a.netId, { type = "RESET_GPS_COORDS" }, PROTOCOL)
            count = count + 1
        end
    end

    log("RESET_GPS_COORDS sent to " .. count .. " GPS subhost(s).")
end

local function configureGPS()
    header(term)
    print("Main Controller GPS Host Coordinates")
    print("This controller will run shell.run(\"gps\", \"host\", x, y, z) in parallel.")

    local c = promptCoord("controller GPS host")
    if c then
        state.gps.x, state.gps.y, state.gps.z = c.x, c.y, c.z
        state.gps.hostEnabled = true
        saveState()
        log("Controller GPS host coords updated.")
    end
end

local function gpsDiagnostics()
    header(term)
    print("GPS Diagnostics")
    print("Controller GPS host: " .. tostring(state.gps.x) .. "," .. tostring(state.gps.y) .. "," .. tostring(state.gps.z))
    print("Known GPS subhosts:")

    for _, a in pairs(state.agents) do
        if a.role == "gps" then
            print(" - " .. tostring(a.label or a.id) .. " id " .. tostring(a.netId) .. " at " .. tostring(a.x) .. "," .. tostring(a.y) .. "," .. tostring(a.z) .. " last " .. tostring(math.floor((os.epoch("utc") - (a.lastSeen or 0)) / 1000)) .. "s ago")
        end
    end

    print("")
    print("Press any key.")
    os.pullEvent("key")
end

local function viewLogs()
    header(term)
    print("Logs:")

    local start = math.max(1, #state.logs - 18)
    for i = start, #state.logs do
        print(state.logs[i])
    end

    print("Press any key.")
    os.pullEvent("key")
end

local function clearHistory()
    state.logs = {}

    for id, j in pairs(state.jobs) do
        if j.status == "COMPLETE" or j.status == "CANCELLED" then
            state.jobs[id] = nil
        end
    end

    saveState()
    log("History cleared.")
end

local function viewProtectedBlocks()
    while true do
        local items = {}

        for i, v in ipairs(state.protectedBlocks) do
            table.insert(items, { tostring(i) .. ". " .. tostring(v), i })
        end

        table.insert(items, { "Back", "back" })

        local choice = chooseMenu("Protected Blocks / No-Mine List", items, "These are substring matches. Example: minecraft:spawner or computercraft:")
        if not choice or choice == "back" then return end
    end
end

local function addProtectedBlock()
    header(term)
    print("Add protected block/pattern")
    print("")
    print("Examples:")
    print(" minecraft:spawner")
    print(" computercraft:")
    print(" create:display_link")
    print("")

    local s = promptText("Block ID or substring")
    if not s or s == "" then return end

    s = string.lower(s)

    for _, v in ipairs(state.protectedBlocks) do
        if v == s then
            log("Protected entry already exists: " .. s)
            return
        end
    end

    table.insert(state.protectedBlocks, s)
    state.protectedBlocks = normalizeProtectedList(state.protectedBlocks)
    broadcastProtectedList()
end

local function removeProtectedBlock()
    local removable = {}
    local defaults = {}
    for _, v in ipairs(defaultProtectedBlocks) do defaults[string.lower(v)] = true end

    for i, v in ipairs(state.protectedBlocks) do
        if not defaults[v] then
            table.insert(removable, { tostring(v), i })
        end
    end

    if #removable == 0 then
        header(term)
        print("No custom protected entries to remove.")
        print("Default safety entries are retained.")
        sleep(2)
        return
    end

    local idx = chooseMenu("Remove Protected Entry", removable)
    if not idx then return end

    local removed = table.remove(state.protectedBlocks, idx)
    state.protectedBlocks = normalizeProtectedList(state.protectedBlocks)
    broadcastProtectedList()
    log("Removed protected entry: " .. tostring(removed))
end

local function manageProtectedBlocks()
    while true do
        local choice = chooseMenu("Manage Protected Blocks", {
            { "View Protected List", viewProtectedBlocks },
            { "Add Protected Entry", addProtectedBlock },
            { "Remove Custom Protected Entry", removeProtectedBlock },
            { "Broadcast Protected List Now", broadcastProtectedList },
            { "Back", "back" }
        }, "Miners cache this list locally and refuse to mine matching blocks.")

        if not choice or choice == "back" then return end
        pcall(choice)
    end
end

local menu = {
    { "Create Job", createJob },
    { "Assign/Deploy Active Job", assignActiveJob },
    { "Pause Job", pauseJob },
    { "Resume Job", resumeJob },
    { "Cancel Job", cancelJob },
    { "View Turtle Live Coordinates", viewLiveCoordinates },
    { "Send Turtle Home", sendTurtleHome },
    { "Manage Protected Blocks", manageProtectedBlocks },
    { "Reset Connected GPS Subhosts", resetConnectedSubhosts },
    { "Reset Controller GPS Coordinates", configureGPS },
    { "GPS Diagnostics", gpsDiagnostics },
    { "View Logs", viewLogs },
    { "Save State", function() saveState(); log("Manual save.") end },
    { "Clear Saved History", clearHistory },
    { "Exit", function() running = false end }
}

local function menuLoop()
    while running do
        local fn = chooseMenu("Main Menu", menu)
        if fn then pcall(fn) end
    end
end

local function nextDeployment(teamId)
    if #state.deploymentQueue == 0 then return end

    if state.deploymentQueue[1] == teamId then
        table.remove(state.deploymentQueue, 1)
        saveState()

        local nextTeamId = state.deploymentQueue[1]

        if nextTeamId then
            for _, team in ipairs(state.teams) do
                if team.id == nextTeamId then
                    safeSend(team.minerNet, { type = "DEPLOY_NOW", teamId = team.id, jobId = state.activeJobId }, PROTOCOL)
                    if team.foremanNet then
                        safeSend(team.foremanNet, { type = "DEPLOY_NOW", teamId = team.id, jobId = state.activeJobId }, PROTOCOL)
                    end
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
                local id = (msg.role or "agent") .. "-" .. tostring(sender)
                state.agents[id] = state.agents[id] or {}

                local a = state.agents[id]
                a.id = id
                a.netId = sender
                a.role = msg.role
                a.label = msg.label
                a.status = msg.status or a.status
                a.x = msg.x or a.x
                a.y = msg.y or a.y
                a.z = msg.z or a.z
                a.protectedRevision = msg.protectedRevision or a.protectedRevision
                a.lastSeen = now

                rednet.send(sender, {
                    type = "REGISTER_ACK",
                    controllerId = os.getComputerID(),
                    agentId = id,
                    project = PROJECT,
                    version = VERSION
                }, PROTOCOL)

                if msg.role == "miner" then
                    sendProtectedListTo(sender)
                end

                saveState()

            elseif msg.type == "HEARTBEAT" then
                local id = (msg.role or "agent") .. "-" .. tostring(sender)
                state.agents[id] = state.agents[id] or { id = id, netId = sender }

                local a = state.agents[id]
                a.netId = sender
                a.role = msg.role or a.role
                a.label = msg.label or a.label
                a.status = msg.status
                a.lastSeen = now
                a.x = msg.x or a.x
                a.y = msg.y or a.y
                a.z = msg.z or a.z
                a.facing = msg.facing or a.facing
                a.protectedRevision = msg.protectedRevision or a.protectedRevision

                if a.role == "miner" and (tonumber(a.protectedRevision) or 0) < (tonumber(state.protectedRevision) or 0) then
                    sendProtectedListTo(sender)
                end

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

if not modemSide then
    log("No modem found. Network disabled until reboot/retry.")
end

parallel.waitForAny(menuLoop, networkLoop, dashboardLoop, controllerGpsHostLoop)

term.redirect(terminal)
term.clear()
term.setCursorPos(1, 1)
print(PROJECT .. " " .. VERSION .. " stopped.")
