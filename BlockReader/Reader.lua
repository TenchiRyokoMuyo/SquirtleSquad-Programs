-- block_reader_viewer.lua
-- Shows everything an Advanced Peripherals Block Reader can see.
-- Controls:
--   Up/Down or W/S = scroll
--   PageUp/PageDown = faster scroll
--   R = refresh
--   Q = quit

local reader = peripheral.find("blockReader") or peripheral.find("block_reader")

if not reader then
    error("No Block Reader found. Check peripheral name: blockReader or block_reader")
end

local scroll = 0
local lines = {}

local function safeCall(fn)
    local ok, result = pcall(fn)
    if ok then return result end
    return "ERROR: " .. tostring(result)
end

local function serializeValue(value, indent, out)
    indent = indent or ""
    out = out or {}

    if type(value) ~= "table" then
        table.insert(out, indent .. tostring(value))
        return out
    end

    local keys = {}
    for k in pairs(value) do table.insert(keys, k) end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    if #keys == 0 then
        table.insert(out, indent .. "{}")
        return out
    end

    for _, k in ipairs(keys) do
        local v = value[k]
        if type(v) == "table" then
            table.insert(out, indent .. tostring(k) .. ":")
            serializeValue(v, indent .. "  ", out)
        else
            table.insert(out, indent .. tostring(k) .. ": " .. tostring(v))
        end
    end

    return out
end

local function addSection(title, value)
    table.insert(lines, "== " .. title .. " ==")

    if value == nil then
        table.insert(lines, "nil")
    elseif type(value) == "table" then
        serializeValue(value, "", lines)
    else
        table.insert(lines, tostring(value))
    end

    table.insert(lines, "")
end

local function refresh()
    lines = {}

    addSection("Block Name", safeCall(function()
        return reader.getBlockName()
    end))

    addSection("Is Tile Entity", safeCall(function()
        if reader.isTileEntity then
            return reader.isTileEntity()
        end
        return "Unavailable in this Advanced Peripherals version"
    end))

    addSection("Block States", safeCall(function()
        if reader.getBlockStates then
            return reader.getBlockStates()
        end
        return "Unavailable in this Advanced Peripherals version"
    end))

    addSection("Block Data / Tile Entity Data", safeCall(function()
        return reader.getBlockData()
    end))

    scroll = math.min(scroll, math.max(0, #lines - 1))
end

local function draw()
    term.clear()
    term.setCursorPos(1, 1)

    local w, h = term.getSize()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)

    term.setCursorPos(1, 1)
    term.write("Block Reader Viewer")

    term.setCursorPos(1, 2)
    term.write("Up/Down Scroll | R Refresh | Q Quit")

    term.setCursorPos(1, 3)
    term.write(string.rep("-", w))

    local viewHeight = h - 3

    for i = 1, viewHeight do
        local lineIndex = i + scroll
        local line = lines[lineIndex] or ""

        if #line > w then
            line = string.sub(line, 1, w)
        end

        term.setCursorPos(1, i + 3)
        term.clearLine()
        term.write(line)
    end
end

refresh()

while true do
    draw()

    local event, key = os.pullEvent("key")

    if key == keys.q then
        term.clear()
        term.setCursorPos(1, 1)
        print("Closed Block Reader Viewer.")
        break

    elseif key == keys.r then
        refresh()

    elseif key == keys.up or key == keys.w then
        scroll = math.max(0, scroll - 1)

    elseif key == keys.down or key == keys.s then
        scroll = math.min(math.max(0, #lines - 1), scroll + 1)

    elseif key == keys.pageUp then
        scroll = math.max(0, scroll - 10)

    elseif key == keys.pageDown then
        scroll = math.min(math.max(0, #lines - 1), scroll + 10)
    end
end
