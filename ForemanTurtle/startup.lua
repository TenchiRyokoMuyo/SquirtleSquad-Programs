
-- === TurtleTeam v17 Foreman patch: follow miner position ===
-- Add these helpers to ForemanTurtle/startup.lua.

local minerTarget = nil
local lastMinerTargetTime = 0

local function shouldFollowMiner(msg)
  if not state or not state.job or not state.sector then return false end
  local jobId = state.job.id or state.jobId
  local sectorId = state.sector.id or state.sectorId
  return msg.jobId == jobId and msg.sectorId == sectorId and msg.pos ~= nil
end

local function gpsOrNil()
  local x, y, z = gps.locate(1)
  if x then return {x=x,y=y,z=z} end
  return nil
end

local function tryStepAwayFromMiner()
  -- Very conservative movement. Prefer backing away instead of entering miner's front/path.
  if turtle.back() then return true end
  turtle.turnLeft()
  if turtle.forward() then turtle.turnRight(); return true end
  turtle.turnRight()
  turtle.turnRight()
  if turtle.forward() then turtle.turnLeft(); return true end
  turtle.turnLeft()
  return false
end

local function followMinerTick()
  if not minerTarget or not minerTarget.pos then return end
  if os.clock() - lastMinerTargetTime > 10 then return end

  local me = gpsOrNil()
  if not me then
    -- Without GPS, do not wander blindly. Stay ready and only move aside on direct request.
    state.status = "WAITING_FOR_MINER"
    return
  end

  local dx = minerTarget.pos.x - me.x
  local dy = minerTarget.pos.y - me.y
  local dz = minerTarget.pos.z - me.z
  local dist = math.abs(dx) + math.abs(dy) + math.abs(dz)

  -- Stay close, but not adjacent/in the way.
  if dist <= 2 then
    state.status = "WAITING_FOR_MINER"
    return
  end

  state.status = "FOLLOWING_MINER"
  save()

  -- Intentionally conservative: move only one step per tick.
  -- Real directional pathing can be upgraded later once facing/dead-reckoning is shared.
  -- For now, if too far, step toward open space near miner; if blocked, wait.
  if dy > 1 then turtle.up()
  elseif dy < -1 then turtle.down()
  else
    -- Avoid walking into the miner's exact line. Try lateral/back movement first.
    tryStepAwayFromMiner()
  end
end

-- In netLoop(), add:
-- elseif msg.type == "MINER_POSITION" and shouldFollowMiner(msg) then
--   minerTarget = msg
--   lastMinerTargetTime = os.clock()
-- end
--
-- In foremanWork(), while WAITING_FOR_MINER, call:
-- followMinerTick()
--
-- Also update FOREMAN_MOVE_REQUEST handling to:
-- tryStepAwayFromMiner()
-- send({type="FOREMAN_MOVED", id=id, jobId=state.job and state.job.id, sectorId=state.sector and state.sector.id})
