-- SquirtleSquad-Miner v1.3
-- GPSSubHost/startup.lua
-- Fixes:
-- * Screen draws immediately on boot.
-- * Screen updates after coordinates are entered.
-- * Saved coordinates auto-load on restart.
-- * gps host runs in a hidden terminal so it cannot blank the visible screen.
-- * Main Controller can reset coordinates with RESET_GPS_COORDS.

local PROTOCOL = "TurtleTeamNet"
local PROJECT = "SquirtleSquad-Miner"
local VERSION = "v1.3"

local DATA_DIR = "SquirtleSquadData"
local STATE_FILE = DATA_DIR .. "/gps_subhost_state.dat"

local state = {
    role = "gps",
    label = "GPSSubHost-" .. os.getComputerID(),
    controllerId = nil,
    x = nil,
    y = nil,
    z = nil,
    status = "BOOTING",
    message = "Starting..."
}

local modemSide = nil
local running = true
local inputMode = false

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

            local ok, data = pcall(textutils.unserialize, txt)
            if ok and type(data) == "table" then
                for k, v in pairs(data) do
                    state[k] = v
                end
            end
        end
    end
end

local function coordsSet()
    return tonumber(state.x) ~= nil and tonumber(state.y) ~= nil and tonumber(state.z) ~= nil
end

local function setStatus(statusText, messageText)
    state.status = statusText or state.status
    state.message = messageText or state.message
    save()
end

local function openModem()
    modemSide = nil

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
        return false
    end

    msg.project = PROJECT
    msg.version = VERSION
    msg.role = msg.role or state.role
    msg.label = msg.label or state.label

    if state.controllerId then
        rednet.send(state.controllerId, msg, PROTOCOL)
    else
        rednet.broadcast(msg, PROTOCOL)
    end

    return true
end

local function center(text, y, color)
    local w = term.getSize()
    local x = math.max(1, math.floor((w - #text) / 2) + 1)

    term.setCursorPos(x, y)
    if term.isColor() and color then
        term.setTextColor(color)
    end
    term.write(text)
end

local function draw()
    if inputMode then
        return
    end

    if term.isColor() then
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
    end

    term.clear()
    center(PROJECT, 1, colors.cyan)
    center("GPS Subhost " .. VERSION, 2, colors.lightBlue)

    if term.isColor() then
        term.setTextColor(colors.white)
    end

    term.setCursorPos(1, 4)
    print("Computer ID : " .. tostring(os.getComputerID()))
    print("Label       : " .. tostring(state.label))
    print("Status      : " .. tostring(state.status))
    print("Message     : " .. tostring(state.message))
    print("")
    print("Coordinates : " .. tostring(state.x) .. ", " .. tostring(state.y) .. ", " .. tostring(state.z))
    print("Modem       : " .. tostring(modemSide or "MISSING"))
    print("Controller  : " .. tostring(state.controllerId or "Not linked yet"))
    print("")
    print("Saved File  : " .. STATE_FILE)
    print("")
    print("Saved coordinates auto-load on restart.")
    print("Use Main Controller to reset subhosts.")
end

local function promptNumber(label, default)
    while true do
        if default ~= nil then
            term.write(label .. " [" .. tostring(default) .. "]: ")
        else
            term.write(label .. ": ")
        end

        local value = read()

        if value == "" and default ~= nil then
            return tonumber(default)
        end

        local n = tonumber(value)
        if n ~= nil then
            return n
        end

        print("Invalid number.")
    end
end

local function promptCoordinates(reason)
    inputMode = true

    if term.isColor() then
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
    end

    term.clear()
    term.setCursorPos(1, 1)

    if term.isColor() then
        term.setTextColor(colors.cyan)
    end
    print(PROJECT .. " GPS Subhost " .. VERSION)

    if term.isColor() then
        term.setTextColor(colors.white)
    end

    print("")
    print(reason or "Coordinates required.")
    print("Enter this subhost's fixed GPS coordinates.")
    print("They will be saved and reused on restart.")
    print("")

    local x = promptNumber("X", state.x)
    local y = promptNumber("Y", state.y)
    local z = promptNumber("Z", state.z)

    state.x = x
    state.y = y
    state.z = z

    setStatus("COORDS_SAVED", "Coordinates saved.")
    inputMode = false
    draw()
end

local function resetCoordinates()
    state.x = nil
    state.y = nil
    state.z = nil
    setStatus("COORDS_RESET", "Coordinates reset by controller.")
    draw()
    promptCoordinates("Coordinates were reset by the Main Controller.")
end

local function networkLoop()
    while running do
        local sender, msg = rednet.receive(PROTOCOL, 1)

        if type(msg) == "table" then
            if msg.type == "REGISTER_ACK" then
                state.controllerId = sender
                setStatus(state.status, "Linked to controller " .. tostring(sender))
                draw()

            elseif msg.type == "RESET_GPS_COORDS" or msg.type == "RESET_SUBHOST" then
                resetCoordinates()

            elseif msg.type == "ROLL_CALL" then
                send({
                    type = "ROLL_CALL_RESPONSE",
                    role = "gps",
                    status = state.status,
                    x = state.x,
                    y = state.y,
                    z = state.z
                })
            end
        end
    end
end

local function heartbeatLoop()
    while running do
        if not modemSide or not rednet.isOpen(modemSide) then
            openModem()
        end

        send({
            type = "REGISTER",
            role = "gps",
            status = state.status,
            x = state.x,
            y = state.y,
            z = state.z
        })

        send({
            type = "HEARTBEAT",
            role = "gps",
            status = state.status,
            x = state.x,
            y = state.y,
            z = state.z
        })

        sleep(5)
    end
end

local function displayLoop()
    while running do
        if not inputMode then
            draw()
        end
        sleep(2)
    end
end

local function gpsHostOnce()
    local oldTerm = term.current()
    local hidden = window.create(oldTerm, 1, 1, 1, 1, false)
    local previous = term.redirect(hidden)

    local ok, err = pcall(function()
        shell.run("gps", "host", tostring(state.x), tostring(state.y), tostring(state.z))
    end)

    term.redirect(previous)

    if not ok then
        setStatus("GPS_ERROR", tostring(err))
        draw()
    end
end

local function gpsHostLoop()
    while running do
        if coordsSet() then
            setStatus("HOSTING_GPS", "GPS host active.")
            gpsHostOnce()
            sleep(1)
        else
            setStatus("AWAITING_COORDS", "No saved coordinates.")
            draw()
            promptCoordinates("No saved coordinates found.")
        end
    end
end

ensureDir()
load()

if not state.label or state.label == "" then
    state.label = "GPSSubHost-" .. os.getComputerID()
end

openModem()

if coordsSet() then
    setStatus("HOSTING_GPS", "Loaded saved coordinates.")
else
    setStatus("AWAITING_COORDS", "No saved coordinates.")
end

draw()

parallel.waitForAny(
    networkLoop,
    heartbeatLoop,
    gpsHostLoop,
    displayLoop
)
