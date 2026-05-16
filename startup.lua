-- SquirtleSquad Universal Shell / OS Loader
-- Root-level startup.lua

local PROJECT = "SquirtleSquad-Miner"
local VERSION = "v2.0-loadout"
local DATA_DIR = "SquirtleSquadData"
local SHELL_STATE = DATA_DIR .. "/shell_state.dat"
local DEFAULT_FILE = DATA_DIR .. "/default_program.dat"

local PROGRAMS = {
  { key = "MainController", file = "MainController.lua", url = "https://raw.githubusercontent.com/TenchiRyokoMuyo/SquirtleSquad-Programs/main/MainController.lua", computer = true, turtle = false },
  { key = "MinerTurtle", file = "MinerTurtle.lua", url = "https://raw.githubusercontent.com/TenchiRyokoMuyo/SquirtleSquad-Programs/main/MinerTurtle.lua", computer = false, turtle = true },
  { key = "ForemanTurtle", file = "ForemanTurtle.lua", url = "https://raw.githubusercontent.com/TenchiRyokoMuyo/SquirtleSquad-Programs/main/ForemanTurtle.lua", computer = false, turtle = true },
  { key = "GPSSubhost", file = "GPSSubhost.lua", url = "https://raw.githubusercontent.com/TenchiRyokoMuyo/SquirtleSquad-Programs/main/GPSSubhost.lua", computer = true, turtle = false },
  { key = "Uninstall", file = "Uninstall.lua", url = "https://raw.githubusercontent.com/TenchiRyokoMuyo/SquirtleSquad-Programs/main/Uninstall.lua", computer = true, turtle = true },
}

local monitor = nil
local nativeTerm = term.current()
local modemSide = nil

local function ensureDir()
  if not fs.exists(DATA_DIR) then fs.makeDir(DATA_DIR) end
end

local function loadTable(path)
  if not fs.exists(path) then return nil end
  local h = fs.open(path, "r")
  if not h then return nil end
  local s = h.readAll()
  h.close()
  local ok, t = pcall(textutils.unserialize, s or "")
  if ok then return t end
  return nil
end

local function saveTable(path, t)
  ensureDir()
  local h = fs.open(path, "w")
  if not h then return false end
  h.write(textutils.serialize(t))
  h.close()
  return true
end

local function findModem()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      modemSide = name
      if not rednet.isOpen(name) then pcall(rednet.open, name) end
      return name
    end
  end
  return nil
end

local function findMonitor()
  monitor = nil
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then
      monitor = peripheral.wrap(name)
      pcall(function() monitor.setTextScale(0.5) end)
      return monitor
    end
  end
  return nil
end

local function color(c)
  if term.isColor and term.isColor() then term.setTextColor(c) end
end

local function bcolor(c)
  if term.isColor and term.isColor() then term.setBackgroundColor(c) end
end

local function clear()
  bcolor(colors.black)
  color(colors.lightGray)
  term.clear()
  term.setCursorPos(1,1)
end

local function center(y, text, c)
  local w = term.getSize()
  color(c or colors.lightGray)
  term.setCursorPos(math.max(1, math.floor((w - #text) / 2) + 1), y)
  term.write(text)
end

local function header(title)
  clear()
  center(1, "SquirtleSquad Industrial Fleet", colors.cyan)
  center(2, title or VERSION, colors.orange)
  color(colors.lightGray)
  term.setCursorPos(1,4)
end

local function drawBoth(title, lines)
  header(title)
  for _, line in ipairs(lines or {}) do print(line) end
  if monitor then
    local old = term.redirect(monitor)
    header(title)
    for _, line in ipairs(lines or {}) do print(line) end
    term.redirect(old)
  end
end

local function choose(title, items)
  local sel, top = 1, 1
  while true do
    header(title)
    print("Use arrows and Enter. Backspace returns.")
    print("")
    local _, h = term.getSize()
    local visible = math.max(3, h - 6)
    if sel < top then top = sel end
    if sel >= top + visible then top = sel - visible + 1 end
    for row = 0, visible - 1 do
      local i = top + row
      if i > #items then break end
      if i == sel then bcolor(colors.blue); color(colors.white); print("> " .. items[i].label); bcolor(colors.black)
      else color(colors.lightGray); print("  " .. items[i].label) end
    end
    local _, k = os.pullEvent("key")
    if k == keys.up then sel = math.max(1, sel - 1)
    elseif k == keys.down then sel = math.min(#items, sel + 1)
    elseif k == keys.enter then return items[sel]
    elseif k == keys.backspace or k == keys.left then return nil end
  end
end

local function press()
  color(colors.gray)
  print("")
  print("Press any key...")
  os.pullEvent("key")
end

local function detectGpsCount(seconds)
  seconds = seconds or 2
  local start = os.clock()
  local okCount = 0
  while os.clock() - start < seconds do
    local x, y, z = gps.locate(0.5)
    if x then okCount = math.max(okCount, 4) end
    sleep(0.1)
  end
  return okCount
end

local function bootScreen()
  findMonitor()
  drawBoth("Boot", {"Loading monitor... " .. (monitor and "OK" or "none")})
  sleep(0.25)
  findModem()
  drawBoth("Boot", {"Loading monitor... " .. (monitor and "OK" or "none"), "Connecting modem... " .. (modemSide or "missing")})
  sleep(0.25)
  if turtle then
    drawBoth("Turtle Boot", {"Turtle coming online", "Checking attachments...", "Modem: " .. tostring(modemSide or "missing"), "Tool: " .. tostring(turtle.getEquippedLeft and (peripheral.getType("left") or peripheral.getType("right") or "unknown") or "unknown"), "Checking GPS Status..."})
    local count = detectGpsCount(2)
    if count >= 4 then
      drawBoth("Turtle Boot", {"GPS Connected", "4 GPS points appear available"})
    else
      drawBoth("Turtle Boot", {"GPS Failed", tostring(count) .. " Subhosts found, 4 needed"})
    end
  else
    drawBoth("Computer Boot", {"Loading monitor... " .. (monitor and "OK" or "none"), "Connecting modem... " .. tostring(modemSide or "missing"), "Starting GPS Server check...", "Proceeding to menu/default program"})
    sleep(2)
  end
  sleep(1)
end

local function runProgram(p)
  if not p or not fs.exists(p.file) then return false end
  header("Loading Program " .. p.key)
  sleep(0.5)
  shell.run(p.file)
  return true
end

local function getProgram(key)
  for _, p in ipairs(PROGRAMS) do if p.key == key then return p end end
  return nil
end

local function loadDefault()
  local t = loadTable(DEFAULT_FILE)
  if type(t) == "table" and t.key then return getProgram(t.key) end
  return nil
end

local function installProgram(p)
  header("Install " .. p.key)
  if fs.exists(p.file) then
    print(p.file .. " already exists.")
    print("Overwrite? y/N")
    local ans = read()
    if string.lower(ans or "") ~= "y" then return end
    fs.delete(p.file)
  end
  print("Downloading:")
  print(p.url)
  local ok = shell.run("wget", p.url, p.file)
  print("")
  if ok and fs.exists(p.file) then print("Installed " .. p.file) else print("Install failed.") end
  press()
end

local function uninstallProgram(p, deleteData)
  header("Uninstall " .. p.key)
  if fs.exists(p.file) then fs.delete(p.file); print("Deleted " .. p.file) else print("Program not installed.") end
  if deleteData then
    local roleDir = DATA_DIR .. "/" .. p.key
    if fs.exists(roleDir) then fs.delete(roleDir); print("Deleted " .. roleDir) end
  end
  local def = loadDefault()
  if def and def.key == p.key then fs.delete(DEFAULT_FILE); print("Default cleared.") end
  press()
end

local function updateProgram(p)
  header("Update " .. p.key)
  if fs.exists(p.file) then fs.delete(p.file) end
  local roleDir = DATA_DIR .. "/" .. p.key
  if fs.exists(roleDir) then fs.delete(roleDir) end
  print("Downloading clean copy...")
  local ok = shell.run("wget", p.url, p.file)
  if ok and fs.exists(p.file) then print("Updated " .. p.file) else print("Update failed.") end
  press()
end

local function setDefault(p)
  local current = loadDefault()
  if current then
    header("Set Default")
    print("Current default: " .. current.key)
    if current.key == p.key then
      print("Program " .. p.key .. " is already the default program.")
    else
      print("Change default to " .. p.key .. "?")
    end
    print("Type YES to confirm.")
    if read() ~= "YES" then return end
  end
  saveTable(DEFAULT_FILE, { key = p.key, file = p.file })
  print("Default set to " .. p.key)
  sleep(1)
end

local function editProgramMenu(p)
  while true do
    local installed = fs.exists(p.file)
    local item = choose("Edit " .. p.key, {
      { label = "Install" },
      { label = "Uninstall" },
      { label = "Update" },
      { label = installed and "Set as Default" or "Set as Default (install first)", disabled = not installed },
      { label = "Back" },
    })
    if not item or item.label == "Back" then return end
    if item.label == "Install" then installProgram(p)
    elseif item.label == "Uninstall" then uninstallProgram(p, true)
    elseif item.label == "Update" then updateProgram(p)
    elseif item.label:find("Set as Default") and not item.disabled then setDefault(p) end
  end
end

local function launchMenu()
  local items = {}
  for _, p in ipairs(PROGRAMS) do
    if fs.exists(p.file) then table.insert(items, { label = p.key, p = p }) end
  end
  table.insert(items, { label = "Back" })
  local it = choose("Launch Programs", items)
  if it and it.p then runProgram(it.p) end
end

local function editMenu()
  local items = {}
  for _, p in ipairs(PROGRAMS) do table.insert(items, { label = p.key .. (fs.exists(p.file) and " (installed)" or ""), p = p }) end
  table.insert(items, { label = "Back" })
  local it = choose("Edit Programs", items)
  if it and it.p then editProgramMenu(it.p) end
end

local function reinstallOS()
  header("Reinstall OS")
  print("This downloads a fresh startup.lua over this shell.")
  print("Type YES to continue.")
  if read() ~= "YES" then return end
  local tmp = "startup.new"
  local url = "https://raw.githubusercontent.com/TenchiRyokoMuyo/SquirtleSquad-Programs/main/startup.lua"
  if fs.exists(tmp) then fs.delete(tmp) end
  local ok = shell.run("wget", url, tmp)
  if ok and fs.exists(tmp) then
    fs.delete("startup.lua")
    fs.move(tmp, "startup.lua")
    print("Reinstalled startup.lua. Rebooting.")
    sleep(1)
    os.reboot()
  else
    print("Download failed.")
    press()
  end
end

local function mainMenu()
  while true do
    local it = choose("SquirtleSquad Shell", {
      { label = "Launch Programs" },
      { label = "Edit Programs" },
      { label = "Reinstall OS" },
      { label = "Reboot" },
      { label = "Exit to Shell" },
    })
    if not it then return end
    if it.label == "Launch Programs" then launchMenu()
    elseif it.label == "Edit Programs" then editMenu()
    elseif it.label == "Reinstall OS" then reinstallOS()
    elseif it.label == "Reboot" then os.reboot()
    elseif it.label == "Exit to Shell" then clear(); return end
  end
end

ensureDir()
bootScreen()
local def = loadDefault()
if def and fs.exists(def.file) then
  runProgram(def)
else
  mainMenu()
end
