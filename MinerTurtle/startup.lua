-- SquirtleSquad-Miner v1.2
-- MinerTurtle/startup.lua
-- Patch focus:
-- * Local turtle home: chest above = fuel/torches, chest below = deposit/filler recovery.
-- * Layer-based excavation: origin Y is layer 1. job.layers is preferred, job.height is legacy fallback.
-- * 3-layer vertical pass mining: travel through the middle layer and mine down/current/up without task-facing spins.
-- * GO_HOME command and job-complete return/service.
-- * ComputerCraft / CC:Tweaked blocks are protected from mining.

local PROTOCOL = "TurtleTeamNet"
local PROJECT = "SquirtleSquad-Miner"
local VERSION = "v1.2"

local DATA_DIR = "SquirtleSquadData"
local STATE_FILE = DATA_DIR .. "/miner_state.dat"

local state = {
    role = "miner",
    label = "Miner-" .. os.getComputerID(),
    controllerId = nil,
    agentId = nil,
    status = "BOOTING",
    paused = false,

    teamId = nil,
    foremanNet = nil,

    job = nil,
    sector = nil,
    deployHold = true,

    pos = nil,
    facing = nil,
    calibrated = false,

    progress = 0,
    complete = false,
    originReached = false,

    home = nil,
    homeFacing = nil,
    waitingForHomeConfirm = false,

    forceHome = false,
    resumeAfterHome = false
}

local running = true
local modemSide = nil

local DIRS = {
    north = { x = 0,  z = -1, left = "west",  right = "east",  back = "south" },
    east  = { x = 1,  z = 0,  left = "north", right = "south", back = "west"  },
    south = { x = 0,  z = 1,  left = "east",  right = "west",  back = "north" },
    west  = { x = -1, z = 0,  left = "south", right = "north", back = "east"  }
}

local protectedNeedles = {
    -- Storage / inventory
    "chest",
    "barrel",
    "shulker",

    -- ComputerCraft / CC:Tweaked namespace protection
    "computercraft:",

    -- Extra ComputerCraft safety keywords
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
    "scaffold",
    "scaffolding",
    "create:display_link"
}

local function ensureDir()
    if not fs.exists(DATA_DIR) then
        fs.makeDir(DATA_DIR)
    end
end

local function save()
    ensureDir()

    local h = fs.open(STATE_FILE, "w")
    if h then
        h.write(textutils.serialize(state))
        h.close()
    end
end

local function load()
    if fs.exists(STATE_FILE) then
        local h = fs.open(STATE_FILE, "r")
        if h then
            local txt = h.readAll()
            h.close()

            local ok, t = pcall(textutils.unserialize, txt)
            if ok and type(t) == "table" then
                for k, v in pairs(t) do
                    state[k] = v
                end
            end
        end
    end
end

local function openModem()
    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" then
            modemSide = side
            if not rednet.isOpen(side) then
                rednet.open(side)
            end
            return true
        end
    end

    return false
end

local function send(msg)
    if not modemSide then
        return
    end

    msg.project = PROJECT
    msg.version = VERSION

    if state.controllerId then
        rednet.send(state.controllerId, msg, PROTOCOL)
    else
        rednet.broadcast(msg, PROTOCOL)
    end
end

local function sendTo(id, msg)
    if id then
        msg.project = PROJECT
        msg.version = VERSION
        rednet.send(id, msg, PROTOCOL)
    end
end

local function status(s)
    state.status = s
    save()
end

local function clonePos(p)
    if not p then
        return nil
    end

    return {
        x = p.x,
        y = p.y,
        z = p.z
    }
end

local function header()
    term.clear()
    term.setCursorPos(1, 1)

    if term.isColor() then
        term.setTextColor(colors.cyan)
    end

    print(" " .. PROJECT .. " " .. VERSION .. " ")

    if term.isColor() then
        term.setTextColor(colors.white)
    end

    print("Miner Turtle: " .. tostring(state.label))
    print("Status: " .. tostring(state.status))
    print("Team: " .. tostring(state.teamId or "none"))

    if state.pos then
        print("Pos: " .. state.pos.x .. "," .. state.pos.y .. "," .. state.pos.z .. " facing " .. tostring(state.facing))
    end

    if state.home then
        print("Home: " .. state.home.x .. "," .. state.home.y .. "," .. state.home.z .. " facing " .. tostring(state.homeFacing))
    end

    print("")

    if state.status == "WAITING_FOR_HOME_CHESTS" then
        print("Home setup required:")
        print(" * Chest above turtle = fuel + torches")
        print(" * Chest below turtle = deposit + filler recovery")
        print("")
        print("Place both chests, then press ENTER on this turtle.")
    end
end

local function isInventoryName(name)
    if not name then
        return false
    end

    name = string.lower(name)

    return name:find("chest", 1, true)
        or name:find("barrel", 1, true)
        or name:find("shulker", 1, true)
end

local function hasChestUp()
    local ok, data = turtle.inspectUp()
    return ok and data and isInventoryName(data.name)
end

local function hasChestDown()
    local ok, data = turtle.inspectDown()
    return ok and data and isInventoryName(data.name)
end

local function homeChestsPresent()
    return hasChestUp() and hasChestDown()
end

local function inspectIsProtected(inspector)
    local ok, data = inspector()

    if not ok or not data or not data.name then
        return false, nil
    end

    local name = string.lower(data.name)

    -- Torches are intentionally allowed to be broken/replaced.
    if name:find("torch", 1, true) then
        return false, data
    end

    for _, needle in ipairs(protectedNeedles) do
        if name:find(needle, 1, true) then
            return true, data
        end
    end

    return false, data
end

local function refuelIfNeeded()
    if turtle.getFuelLevel() == "unlimited" then
        return true
    end

    if turtle.getFuelLevel() > 200 then
        return true
    end

    turtle.select(1)

    if turtle.getItemCount(1) > 0 then
        turtle.refuel(math.min(8, turtle.getItemCount(1)))
    end

    return turtle.getFuelLevel() == "unlimited" or turtle.getFuelLevel() > 50
end

local function mergeFiller()
    local detail = turtle.getItemDetail(2)

    if not detail then
        return
    end

    for i = 3, 15 do
        local d = turtle.getItemDetail(i)

        if d and d.name == detail.name then
            turtle.select(i)
            turtle.transferTo(2)
        end
    end

    turtle.select(1)
end

local function turnLeft()
    turtle.turnLeft()

    if state.facing then
        state.facing = DIRS[state.facing].left
    end

    save()

    sendTo(state.foremanNet, {
        type = "MINER_TURNED_LEFT",
        teamId = state.teamId,
        pos = clonePos(state.pos),
        facing = state.facing
    })
end

local function turnRight()
    turtle.turnRight()

    if state.facing then
        state.facing = DIRS[state.facing].right
    end

    save()

    sendTo(state.foremanNet, {
        type = "MINER_TURNED_RIGHT",
        teamId = state.teamId,
        pos = clonePos(state.pos),
        facing = state.facing
    })
end

local function turnTo(dir)
    if not dir then
        return
    end

    if not state.facing then
        state.facing = dir
        save()
        return
    end

    local guard = 0

    while state.facing ~= dir and guard < 4 do
        turnRight()
        guard = guard + 1
    end
end

local function updateForward()
    local d = DIRS[state.facing or "north"]
    state.pos.x = state.pos.x + d.x
    state.pos.z = state.pos.z + d.z
end

local function updateBack()
    local d = DIRS[state.facing or "north"]
    state.pos.x = state.pos.x - d.x
    state.pos.z = state.pos.z - d.z
end

local function requestForemanMove()
    if not state.foremanNet then
        return true
    end

    sendTo(state.foremanNet, {
        type = "FOREMAN_MOVE_REQUEST",
        teamId = state.teamId,
        pos = clonePos(state.pos),
        facing = state.facing
    })

    local timer = os.startTimer(4)

    while true do
        local ev, a, b, c = os.pullEvent()

        if ev == "rednet_message" then
            local sender, msg, proto = a, b, c

            if proto == PROTOCOL
                and sender == state.foremanNet
                and type(msg) == "table"
                and msg.type == "FOREMAN_MOVED"
            then
                return not msg.failed
            end
        elseif ev == "timer" and a == timer then
            return false
        end
    end
end

local function digForwardIfSafe()
    local prot, data = inspectIsProtected(turtle.inspect)

    if prot then
        requestForemanMove()
        prot, data = inspectIsProtected(turtle.inspect)

        if prot then
            return false, "protected"
        end
    end

    if data then
        turtle.dig()
    end

    return true
end

local function digUpIfSafe()
    local prot, data = inspectIsProtected(turtle.inspectUp)

    if prot then
        return false, "protected"
    end

    if data then
        turtle.digUp()
    end

    return true
end

local function digDownIfSafe()
    local prot, data = inspectIsProtected(turtle.inspectDown)

    if prot then
        return false, "protected"
    end

    if data then
        turtle.digDown()
    end

    return true
end

local function moveForwardRaw()
    refuelIfNeeded()

    for _ = 1, 3 do
        if turtle.forward() then
            updateForward()
            save()

            sendTo(state.foremanNet, {
                type = "MINER_MOVED_FORWARD",
                teamId = state.teamId,
                pos = clonePos(state.pos),
                facing = state.facing
            })

            return true
        end

        local ok, why = digForwardIfSafe()

        if not ok and why == "protected" then
            return false, "protected"
        end

        sleep(0.2)
    end

    return false, "blocked"
end

local function moveUpRaw()
    refuelIfNeeded()

    for _ = 1, 3 do
        if turtle.up() then
            state.pos.y = state.pos.y + 1
            save()

            sendTo(state.foremanNet, {
                type = "MINER_MOVED_UP",
                teamId = state.teamId,
                pos = clonePos(state.pos),
                facing = state.facing
            })

            return true
        end

        local ok, why = digUpIfSafe()

        if not ok then
            return false, why
        end

        sleep(0.2)
    end

    return false, "blocked"
end

local function moveDownRaw()
    refuelIfNeeded()

    for _ = 1, 3 do
        if turtle.down() then
            state.pos.y = state.pos.y - 1
            save()

            sendTo(state.foremanNet, {
                type = "MINER_MOVED_DOWN",
                teamId = state.teamId,
                pos = clonePos(state.pos),
                facing = state.facing
            })

            return true
        end

        local ok, why = digDownIfSafe()

        if not ok then
            return false, why
        end

        sleep(0.2)
    end

    return false, "blocked"
end

local function safeForward()
    local ok, why = moveForwardRaw()

    if ok then
        return true
    end

    if why == "protected" then
        status("PROTECTED_BLOCK_WAIT")
        return false
    end

    return false
end

local function goY(y)
    while state.pos.y < y do
        if not moveUpRaw() then
            return false
        end
    end

    while state.pos.y > y do
        if not moveDownRaw() then
            return false
        end
    end

    return true
end

local function goX(x)
    if state.pos.x < x then
        turnTo("east")

        while state.pos.x < x do
            if not safeForward() then
                return false
            end
        end
    elseif state.pos.x > x then
        turnTo("west")

        while state.pos.x > x do
            if not safeForward() then
                return false
            end
        end
    end

    return true
end

local function goZ(z)
    if state.pos.z < z then
        turnTo("south")

        while state.pos.z < z do
            if not safeForward() then
                return false
            end
        end
    elseif state.pos.z > z then
        turnTo("north")

        while state.pos.z > z do
            if not safeForward() then
                return false
            end
        end
    end

    return true
end

local function gotoXYZ(p)
    if not state.pos or not p then
        return false
    end

    -- Preserve existing safe travel style: vertical first to the higher Y,
    -- then X/Z, then exact Y.
    local travelY = math.max(state.pos.y, p.y)

    if not goY(travelY) then
        return false
    end

    if not goX(p.x) then
        return false
    end

    if not goZ(p.z) then
        return false
    end

    if not goY(p.y) then
        return false
    end

    return true
end

local function pointLineDistanceSquared(px, py, pz, ax, ay, az, bx, by, bz)
    local vx, vy, vz = bx - ax, by - ay, bz - az
    local wx, wy, wz = px - ax, py - ay, pz - az
    local c1 = wx * vx + wy * vy + wz * vz
    local c2 = vx * vx + vy * vy + vz * vz

    local t = 0
    if c2 > 0 then
        t = math.max(0, math.min(1, c1 / c2))
    end

    local qx, qy, qz = ax + t * vx, ay + t * vy, az + t * vz
    local dx, dy, dz = px - qx, py - qy, pz - qz

    return dx * dx + dy * dy + dz * dz
end

local function splinePoint(job, t)
    local ax, ay, az = job.a.x, job.a.y, job.a.z
    local bx, by, bz = job.b.x, job.b.y, job.b.z
    local cx, cy, cz = (ax + bx) / 2, (ay + by) / 2, (az + bz) / 2
    local u = 1 - t

    return {
        x = u * u * ax + 2 * u * t * cx + t * t * bx,
        y = u * u * ay + 2 * u * t * cy + t * t * by,
        z = u * u * az + 2 * u * t * cz + t * t * bz
    }
end

local function pointSplineDistanceSquared(px, py, pz, job)
    local best = 1e9
    local prev = splinePoint(job, 0)

    for i = 1, 32 do
        local cur = splinePoint(job, i / 32)
        local d = pointLineDistanceSquared(px, py, pz, prev.x, prev.y, prev.z, cur.x, cur.y, cur.z)

        if d < best then
            best = d
        end

        prev = cur
    end

    return best
end

local function jobLayers(job)
    return math.max(1, tonumber(job.layers or job.height or 1) or 1)
end

local function jobMaxY(job)
    if job.shape == "cylinder" or job.shape == "cone" or job.shape == "pyramid" then
        return job.origin.y + jobLayers(job) - 1
    end

    if job.shape == "dome" then
        return job.origin.y + job.radius
    end

    if job.shape == "rect" then
        return math.max(job.a.y, job.b.y)
    end

    return nil
end

local function inside(job, x, y, z)
    if not job then
        return false
    end

    if job.shape == "rect" then
        local minX, maxX = math.min(job.a.x, job.b.x), math.max(job.a.x, job.b.x)
        local minY, maxY = math.min(job.a.y, job.b.y), math.max(job.a.y, job.b.y)
        local minZ, maxZ = math.min(job.a.z, job.b.z), math.max(job.a.z, job.b.z)

        return x >= minX and x <= maxX
            and y >= minY and y <= maxY
            and z >= minZ and z <= maxZ

    elseif job.shape == "cylinder" then
        if y < job.origin.y or y > job.origin.y + jobLayers(job) - 1 then
            return false
        end

        local dx, dz = x - job.origin.x, z - job.origin.z
        return dx * dx + dz * dz <= job.radius * job.radius

    elseif job.shape == "dome" then
        if y < job.origin.y or y > job.origin.y + job.radius then
            return false
        end

        local dx, dy, dz = x - job.origin.x, y - job.origin.y, z - job.origin.z
        return dx * dx + dy * dy + dz * dz <= job.radius * job.radius

    elseif job.shape == "stretched_cylinder" then
        return pointLineDistanceSquared(
            x, y, z,
            job.a.x, job.a.y, job.a.z,
            job.b.x, job.b.y, job.b.z
        ) <= job.radius * job.radius

    elseif job.shape == "pyramid" then
        if y < job.origin.y or y > job.origin.y + jobLayers(job) - 1 then
            return false
        end

        local level = y - job.origin.y
        local layers = jobLayers(job)
        local r = math.max(0, job.radius * (1 - level / math.max(1, layers)))

        return math.abs(x - job.origin.x) <= r and math.abs(z - job.origin.z) <= r

    elseif job.shape == "cone" then
        if y < job.origin.y or y > job.origin.y + jobLayers(job) - 1 then
            return false
        end

        local level = y - job.origin.y
        local layers = jobLayers(job)
        local r = math.max(0, job.radius * (1 - level / math.max(1, layers)))
        local dx, dz = x - job.origin.x, z - job.origin.z

        return dx * dx + dz * dz <= r * r

    elseif job.shape == "tunnel" then
        local r = math.max(job.width or 3, job.height or job.width or 3) / 2

        return pointLineDistanceSquared(
            x, y, z,
            job.a.x, job.a.y, job.a.z,
            job.b.x, job.b.y, job.b.z
        ) <= r * r

    elseif job.shape == "tunnel_spline" then
        local r = math.max(job.width or 3, job.height or job.width or 3) / 2
        return pointSplineDistanceSquared(x, y, z, job) <= r * r
    end

    return false
end

local function batchCount()
    local b = state.sector.bounds
    return math.ceil((b.maxY - b.minY + 1) / 3)
end

local function columnFromIndex(idx)
    local b = state.sector.bounds
    local widthX = b.maxX - b.minX + 1
    local widthZ = b.maxZ - b.minZ + 1
    local columns = widthX * widthZ
    local batch = math.floor(idx / columns)

    if batch >= batchCount() then
        return nil
    end

    local rem = idx % columns
    local zOff = math.floor(rem / widthX)
    local xOff = rem % widthX

    if zOff % 2 == 1 then
        xOff = widthX - 1 - xOff
    end

    local startY = b.minY + batch * 3
    local endY = math.min(startY + 2, b.maxY)
    local travelY = startY

    if endY > startY then
        travelY = startY + 1
    end

    return {
        x = b.minX + xOff,
        z = b.minZ + zOff,
        startY = startY,
        endY = endY,
        travelY = travelY,
        batch = batch
    }
end

local function columnHasWork(c)
    for y = c.startY, c.endY do
        if inside(state.job, c.x, y, c.z) then
            return true
        end
    end

    return false
end

local function nextMiningColumn()
    local b = state.sector.bounds
    local total = (b.maxX - b.minX + 1) * (b.maxZ - b.minZ + 1) * batchCount()

    while state.progress < total do
        local c = columnFromIndex(state.progress)
        state.progress = state.progress + 1

        if c and columnHasWork(c) then
            save()
            return c
        end
    end

    return nil
end

local function placeTorchIfNeeded(c)
    if not state.job or not c then
        return
    end

    local spacing = state.job.torchSpacing or 8
    local floorY = state.sector.fullBounds and state.sector.fullBounds.minY or state.sector.bounds.minY

    if c.startY == floorY
        and c.travelY == floorY
        and ((math.abs(c.x) + math.abs(c.z)) % spacing == 0)
    then
        turtle.select(16)

        if turtle.getItemCount(16) > 0 then
            turtle.placeDown()
        end

        turtle.select(1)
    end
end

local function fillOvercutsNearColumn(c)
    if not c then
        return
    end

    if c.travelY > (state.sector.fullBounds and state.sector.fullBounds.minY or state.sector.bounds.minY) then
        local belowInside = inside(state.job, c.x, c.travelY - 1, c.z)
        local ok = turtle.inspectDown()

        if not belowInside and not ok and turtle.getItemCount(2) > 0 then
            turtle.select(2)
            turtle.placeDown()
            turtle.select(1)
        end
    end
end

local function mineColumn(c)
    -- Do not rotate for block-facing.
    -- The movement planner leaves us facing the next path direction.
    -- The turtle's occupied block is the current layer.
    -- Movement into this column already cleared it if needed.

    if c.startY < c.travelY and inside(state.job, c.x, c.travelY - 1, c.z) then
        digDownIfSafe()
    end

    if c.endY > c.travelY and inside(state.job, c.x, c.travelY + 1, c.z) then
        digUpIfSafe()
    end

    fillOvercutsNearColumn(c)
    placeTorchIfNeeded(c)
end

local function needsService()
    if turtle.getItemCount(16) < 8 then
        return true
    end

    if turtle.getItemCount(2) < 16 then
        return true
    end

    for i = 3, 15 do
        if turtle.getItemCount(i) == 0 then
            return false
        end
    end

    return true
end

local function refillSlotFromUp(slot)
    turtle.select(slot)

    local need = 64 - turtle.getItemCount(slot)

    if need > 0 then
        turtle.suckUp(need)
    end
end

local function refillFillerFromBelowOrInventory()
    -- Slot 2 is filler.
    -- Prefer merging matching filler from inventory, then pull from deposit chest below.

    mergeFiller()

    turtle.select(2)

    if turtle.getItemCount(2) < 64 then
        turtle.suckDown(64 - turtle.getItemCount(2))
    end

    mergeFiller()
    turtle.select(1)
end

local function goHomeAndService(reason, returnAfter)
    if not state.home then
        return false
    end

    local returnPos = nil

    if returnAfter and state.pos then
        returnPos = {
            x = state.pos.x,
            y = state.pos.y,
            z = state.pos.z,
            f = state.facing
        }
    end

    status(reason or "GOING_HOME")

    sendTo(state.foremanNet, {
        type = "SERVICE_RETURN",
        teamId = state.teamId,
        pos = clonePos(state.pos),
        home = clonePos(state.home)
    })

    if not gotoXYZ(state.home) then
        status("HOME_PATH_FAILED")
        return false
    end

    turnTo(state.homeFacing or state.facing or "north")

    status("HOME_SERVICE")

    refillFillerFromBelowOrInventory()

    for i = 3, 15 do
        turtle.select(i)
        turtle.dropDown()
    end

    refillSlotFromUp(1)
    refillSlotFromUp(16)

    turtle.select(1)
    refuelIfNeeded()
    save()

    if returnPos then
        status("RETURNING_TO_WORK")

        if gotoXYZ(returnPos) then
            turnTo(returnPos.f)
            status("MINING")
            return true
        end

        status("RETURN_TO_WORK_FAILED")
        return false
    end

    status("AT_HOME")
    return true
end

local function calibrate()
    status("WAITING_FOR_GPS")

    while not state.calibrated do
        local x, y, z = gps.locate(10)

        if x and y and z then
            state.pos = {
                x = math.floor(x + 0.5),
                y = math.floor(y + 0.5),
                z = math.floor(z + 0.5)
            }

            state.facing = state.facing or "north"
            state.calibrated = true
            save()
            status("CALIBRATED")
            return true
        end

        if state.pos and state.facing then
            state.calibrated = true
            status("RECOVERED_DEAD_RECKONING")
            return true
        end

        sleep(3)
    end

    return true
end

local function ensureHomeSetup()
    calibrate()

    if state.home and state.homeFacing then
        return true
    end

    while running do
        if homeChestsPresent() then
            state.home = clonePos(state.pos)
            state.homeFacing = state.facing or "north"
            state.waitingForHomeConfirm = false
            save()
            status("HOME_SET")
            return true
        end

        state.waitingForHomeConfirm = true
        status("WAITING_FOR_HOME_CHESTS")

        local ev = os.pullEvent()

        if ev == "terminate" then
            error("terminated", 0)
        end
    end

    return false
end

local function originForJob()
    local job = state.job

    if job.origin then
        return {
            x = job.origin.x,
            y = job.origin.y,
            z = job.origin.z
        }
    end

    if job.a then
        return {
            x = job.a.x,
            y = job.a.y,
            z = job.a.z
        }
    end

    return {
        x = state.sector.bounds.minX,
        y = state.sector.bounds.minY,
        z = state.sector.bounds.minZ
    }
end

local function waitForDeploy()
    status("ASSIGNED_WAITING_DEPLOY")

    while state.deployHold and running do
        sleep(1)
    end
end

local function mineLoop()
    if not state.job or not state.sector then
        status("LISTENING")
        return
    end

    ensureHomeSetup()
    waitForDeploy()

    local origin = originForJob()
    local firstY = state.sector.bounds.minY

    if state.sector.bounds.maxY > firstY then
        firstY = firstY + 1
    end

    status("MOVE_TO_ORIGIN")
    gotoXYZ({
        x = origin.x,
        y = firstY,
        z = origin.z
    })

    state.originReached = true
    save()

    send({
        type = "TEAM_READY_AT_ORIGIN",
        teamId = state.teamId,
        jobId = state.job.id
    })

    status("MINING")

    while running and not state.complete do
        if state.forceHome then
            local resume = state.resumeAfterHome
            state.forceHome = false
            state.resumeAfterHome = false
            save()

            goHomeAndService("FORCED_HOME", resume)

            if not resume then
                return
            end
        end

        if state.paused then
            status("PAUSED")

            repeat
                sleep(1)
            until not state.paused or not running or state.forceHome

            if not state.forceHome then
                status("MINING")
            end
        end

        mergeFiller()

        if needsService() then
            goHomeAndService("SERVICE_RETURN", true)
        end

        local c = nextMiningColumn()

        if not c then
            state.complete = true
            save()

            goHomeAndService("JOB_COMPLETE_RETURN", false)
            status("COMPLETE_AT_HOME")

            send({
                type = "SECTOR_COMPLETE",
                teamId = state.teamId,
                jobId = state.job.id
            })

            return
        end

        local ok = gotoXYZ({
            x = c.x,
            y = c.travelY,
            z = c.z
        })

        if not ok then
            send({
                type = "ERROR",
                teamId = state.teamId,
                message = "Could not path to mining column; returning home."
            })

            goHomeAndService("PATH_FAILED_HOME", false)
            return
        end

        mineColumn(c)
    end
end

local function networkLoop()
    while running do
        local sender, msg, proto = rednet.receive(PROTOCOL, 1)

        if type(msg) == "table" then
            if msg.type == "REGISTER_ACK" then
                state.controllerId = sender
                state.agentId = msg.agentId
                save()

            elseif msg.type == "ASSIGN_JOB" then
                state.controllerId = sender
                state.teamId = msg.teamId
                state.foremanNet = msg.foremanNet
                state.job = msg.job
                state.sector = msg.sector
                state.deployHold = msg.deployHold ~= false
                state.progress = 0
                state.complete = false
                state.forceHome = false
                state.resumeAfterHome = false
                save()
                status("ASSIGNED")

            elseif msg.type == "DEPLOY_NOW" and (not msg.teamId or msg.teamId == state.teamId) then
                state.deployHold = false
                save()
                status("DEPLOY_RELEASED")

            elseif msg.type == "PAUSE_JOB" then
                state.paused = true
                save()

            elseif msg.type == "RESUME_JOB" then
                state.paused = false
                save()

            elseif msg.type == "GO_HOME" then
                state.forceHome = true
                state.resumeAfterHome = msg.resume == true
                save()
                status("GO_HOME_REQUESTED")

            elseif msg.type == "CANCEL_JOB" then
                state.job = nil
                state.sector = nil
                state.complete = false
                state.progress = 0
                state.forceHome = true
                state.resumeAfterHome = false
                save()
                status("CANCELLED_GOING_HOME")

            elseif msg.type == "ROLL_CALL" then
                send({
                    type = "ROLL_CALL_RESPONSE",
                    role = "miner",
                    status = state.status,
                    x = state.pos and state.pos.x,
                    y = state.pos and state.pos.y,
                    z = state.pos and state.pos.z
                })
            end
        end
    end
end

local function heartbeatLoop()
    while running do
        send({
            type = "REGISTER",
            role = "miner",
            label = state.label,
            status = state.status,
            x = state.pos and state.pos.x,
            y = state.pos and state.pos.y,
            z = state.pos and state.pos.z
        })

        send({
            type = "HEARTBEAT",
            role = "miner",
            label = state.label,
            status = state.status,
            x = state.pos and state.pos.x,
            y = state.pos and state.pos.y,
            z = state.pos and state.pos.z,
            facing = state.facing
        })

        sleep(10)
    end
end

local function displayLoop()
    while running do
        header()
        sleep(2)
    end
end

local function workLoop()
    ensureHomeSetup()

    while running do
        if state.job and state.sector and not state.complete then
            mineLoop()
        else
            if state.forceHome then
                state.forceHome = false
                state.resumeAfterHome = false
                save()
                goHomeAndService("FORCED_HOME", false)
            end

            status("LISTENING")

            send({
                type = "REQUEST_ASSIGNMENT",
                role = "miner",
                label = state.label
            })

            sleep(5)
        end
    end
end

ensureDir()
load()
openModem()
save()

parallel.waitForAny(
    networkLoop,
    heartbeatLoop,
    displayLoop,
    workLoop
)
