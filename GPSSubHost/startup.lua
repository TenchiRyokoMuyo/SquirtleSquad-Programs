-- SquirtleSquad-Miner v1.3
-- GPSSubHost/startup.lua
-- Auto-retains saved coordinates, continuously redraws status screen,
-- and supports reset command from Main Controller.

local PROTOCOL = "TurtleTeamNet"
local PROJECT = "SquirtleSquad-Miner"
local VERSION = "v1.3"

local DATA_DIR = "SquirtleSquadData"
local STATE_FILE = DATA_DIR .. "/gps_subhost_state.dat"

local state = {
    x = nil,
    y = nil,
    z = nil,
    label = nil,
    controllerId = nil,
    status = "BOOTING",
    message = "Starting GPS Subhost..."
}

local running = true
local modemSide = nil

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
            local t = textutils.unserialize(txt)
            if type(t) == "table" then
                for k, v in pairs(t) do
                    state[k] = v
                end
            end
        end
    end
end

local function hasCoords()
    return tonumber(state.x) ~= nil and tonumber(state.y) ~= nil and tonumber(state.z) ~= nil
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

local function center(text, y, color)
    local w = term.getSize()
    term.setCursorPos(math.max(1, math.floor((w - #text) / 2) + 1), y)
    if term.isColor() and color then
        term.setTextColor(color)
    end
    term.write(text)
end

local function drawScreen()
    if term.isColor() then
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
    end

    term.clear()
    center(PROJECT .. " " .. VERSION, 1, colors.cyan)
    center("GPS Subhost", 2, colors.lightBlue)

    if term.isColor() then term.setTextColor(colors.white) end
    term.setCursorPos(1, 4)

    print("Label      : " .. tostring(state.label or "GPS-" .. os.getComputerID()))
    print("Computer ID: " .. tostring(os.getComputerID()))
    print("Status     : " .. tostring(state.status))
    print("Message    : " .. tostring(state.message))
    print("")
    print("Coordinates: " .. tostring(state.x) .. ", " .. tostring(state.y) .. ", " .. tostring(state.z))
    print("Modem      : " .. tostring(modemSide or "missing"))
    print("Controller : " .. tostring(state.controllerId or "unknown"))
    print("")
    print("Saved file : " .. STATE_FILE)
    print("")
    print("This computer auto-loads saved coordinates.")
    print("Reset coordinates from the Main Controller.")
end

local function promptNumber(label)
    while true do
        term.write(label .. ": ")
        local n = tonumber(read())
        if n then return n end
        print("Invalid number.")
    end
end

local function setupIfNeeded()
    state.label = state.label or ("GPS-" .. os.getComputerID())

    if hasCoords() then
        state.status = "HOSTING"
        state.message = "Loaded saved coordinates."
        save()
        drawScreen()
        return
    end

    state.status = "SETUP_REQUIRED"
    state.message = "No coordinates saved."
    drawScreen()

    print("")
    print("Enter this GPS host's coordinates.")
    print("")

    term.write("Label [" .. state.label .. "]: ")
    local l = read()
    if l ~= "" then state.label = l end

    state.x = promptNumber("X")
    state.y = promptNumber("Y")
    state.z = promptNumber("Z")

    state.status = "HOSTING"
    state.message = "Coordinates saved. Hosting GPS."
    save()
    drawScreen()
end

local function broadcastStatus()
    if modemSide then
        rednet.broadcast({
            type = "REGISTER",
            role = "gps",
            label = state.label,
            x = state.x,
            y = state.y,
            z = state.z,
            project = PROJECT,
            version = VERSION
        }, PROTOCOL)

        rednet.broadcast({
            type = "HEARTBEAT",
            role = "gps",
            label = state.label,
            x = state.x,
            y = state.y,
            z = state.z,
            status = state.status,
            project = PROJECT,
            version = VERSION
        }, PROTOCOL)
    end
end

local function heartbeatLoop()
    while running do
        broadcastStatus()
        sleep(5)
    end
end

local function receiveLoop()
    while running do
        local sender, msg = rednet.receive(PROTOCOL, 2)
        if type(msg) == "table" then
            if msg.type == "REGISTER_ACK" then
                state.controllerId = sender
                state.message = "Linked to controller " .. tostring(sender)
                save()
                drawScreen()

            elseif msg.type == "ROLL_CALL" then
                rednet.send(sender, {
                    type = "ROLL_CALL_RESPONSE",
                    role = "gps",
                    label = state.label,
                    x = state.x,
                    y = state.y,
                    z = state.z,
                    status = state.status
                }, PROTOCOL)

            elseif msg.type == "RESET_GPS_COORDS" or msg.type == "RESET_SUBHOST" then
                state.x = nil
                state.y = nil
                state.z = nil
                state.status = "SETUP_REQUIRED"
                state.message = "Coordinates reset by controller."
                save()
                drawScreen()
                setupIfNeeded()
            end
        end
    end
end

local function displayLoop()
    while running do
        drawScreen()
        sleep(2)
    end
end

local function gpsHostLoop()
    while running do
        if hasCoords() then
            state.status = "HOSTING"
            state.message = "GPS host active."
            save()

            local oldTerm = term.current()
            local hidden = window.create(oldTerm, 1, 1, 1, 1, false)
            local previous = term.redirect(hidden)

            pcall(function()
                shell.run("gps", "host", tostring(state.x), tostring(state.y), tostring(state.z))
            end)

            term.redirect(previous)
            sleep(1)
        else
            sleep(1)
        end
    end
end

ensureDir()
load()
openModem()
setupIfNeeded()
drawScreen()

parallel.waitForAny(
    gpsHostLoop,
    heartbeatLoop,
    receiveLoop,
    displayLoop
)
