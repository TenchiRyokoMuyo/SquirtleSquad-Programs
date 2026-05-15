-- SquirtleSquad-Miner Uninstall Utility
-- Removes startup.lua and SquirtleSquadData.
-- This file intentionally does NOT delete itself so it can be reused.

local DATA_DIR = "SquirtleSquadData"
local STARTUP_FILE = "startup.lua"

term.clear()
term.setCursorPos(1, 1)

print("SquirtleSquad-Miner Uninstall Utility")
print("")
print("This will delete:")
print(" - " .. STARTUP_FILE)
print(" - " .. DATA_DIR .. "/")
print("")
print("It will NOT delete this uninstall program.")
print("")
write("Type DELETE to continue: ")

local confirm = read()

if confirm ~= "DELETE" then
    print("")
    print("Cancelled.")
    return
end

print("")

if fs.exists(STARTUP_FILE) then
    fs.delete(STARTUP_FILE)
    print("Deleted " .. STARTUP_FILE)
else
    print(STARTUP_FILE .. " not found.")
end

if fs.exists(DATA_DIR) then
    fs.delete(DATA_DIR)
    print("Deleted " .. DATA_DIR .. "/")
else
    print(DATA_DIR .. "/ not found.")
end

print("")
print("Uninstall complete. Reboot or replace startup.lua when ready.")
