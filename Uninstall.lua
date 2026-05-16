-- SquirtleSquad Uninstall.lua

local DATA_DIR="SquirtleSquadData"
local PROGRAMS={"MainController.lua","MinerTurtle.lua","ForemanTurtle.lua","GPSSubhost.lua","Uninstall.lua"}
local ROLE_DIRS={"MainController","MinerTurtle","ForemanTurtle","GPSSubhost"}

local function color(c) if term.isColor and term.isColor() then term.setTextColor(c) end end
local function bcolor(c) if term.isColor and term.isColor() then term.setBackgroundColor(c) end end
local function clear() bcolor(colors.black); color(colors.lightGray); term.clear(); term.setCursorPos(1,1) end
local function center(y,text,c) local w=term.getSize(); color(c or colors.lightGray); term.setCursorPos(math.max(1,math.floor((w-#text)/2)+1),y); term.write(text) end
local function header(title) clear(); center(1,"SquirtleSquad Uninstall",colors.red); center(2,title or "Utility",colors.orange); term.setCursorPos(1,4); color(colors.lightGray) end
local function choose(title,items) local sel=1 while true do header(title); print("Use arrows and Enter. Backspace exits."); print(""); for i,it in ipairs(items) do if i==sel then bcolor(colors.blue); color(colors.white); print("> "..it.label); bcolor(colors.black) else color(colors.lightGray); print("  "..it.label) end end local _,k=os.pullEvent("key"); if k==keys.up then sel=math.max(1,sel-1) elseif k==keys.down then sel=math.min(#items,sel+1) elseif k==keys.enter then return items[sel] elseif k==keys.backspace then return nil end end end
local function confirm(text) header("Confirm"); color(colors.red); print(text); color(colors.lightGray); print("Type YES to continue."); return read()=="YES" end
local function del(path) if fs.exists(path) then fs.delete(path); print("Deleted "..path) else print("Missing "..path) end end
local function press() print(""); color(colors.gray); print("Press any key..."); os.pullEvent("key") end
local function removeRoleData(role) header("Remove "..role.." Data"); del(DATA_DIR.."/"..role); press() end
local function removeAllData() if not confirm("Delete all SquirtleSquadData?") then return end header("Remove All Data"); del(DATA_DIR); press() end
local function removePrograms(includeStartup) if not confirm("Delete installed SquirtleSquad role files"..(includeStartup and " and startup.lua" or "").."?") then return end header("Remove Programs"); for _,p in ipairs(PROGRAMS) do del(p) end if includeStartup then del("startup.lua") end press() end
while true do
  local items={}
  for _,r in ipairs(ROLE_DIRS) do table.insert(items,{label="Remove "..r.." data",role=r}) end
  table.insert(items,{label="Remove all SquirtleSquad data"})
  table.insert(items,{label="Remove role program files only"})
  table.insert(items,{label="Full uninstall except startup.lua"})
  table.insert(items,{label="Full uninstall including startup.lua"})
  table.insert(items,{label="Exit"})
  local it=choose("Main Menu",items)
  if not it or it.label=="Exit" then header("Exit"); return end
  if it.role then removeRoleData(it.role)
  elseif it.label=="Remove all SquirtleSquad data" then removeAllData()
  elseif it.label=="Remove role program files only" then removePrograms(false)
  elseif it.label=="Full uninstall except startup.lua" then if confirm("Delete all data and role files, keeping startup.lua?") then header("Full Uninstall"); del(DATA_DIR); for _,p in ipairs(PROGRAMS) do del(p) end; press() end
  elseif it.label=="Full uninstall including startup.lua" then if confirm("Delete all data, role files, and startup.lua?") then header("Full Uninstall"); del(DATA_DIR); for _,p in ipairs(PROGRAMS) do del(p) end; del("startup.lua"); press(); return end end
end
