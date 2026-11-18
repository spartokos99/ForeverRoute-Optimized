-- The route engine, a leftover not worth the trip. The plan's visit to a zone had several quests; you did most of them
-- ahead of it or dropped them, and one is left. The plan still sent you there for it: "all the way to Stranglethorn for
-- one collect quest, a long walk to hand it in, then Arathi" (tester, level 37 on a stretch planned at 33). The sim
-- measured it: drifting from the plan doubles these one-quest trips (tests/_player.lua "one-quest trips").
-- When the card's next step opens such a visit in another zone, its trip is long and the quest pays little for it, and
-- nothing later on the plan needs that quest, its steps are skipped quietly (as "skip" does: /fr undo brings them
-- back; the decision log says why). A visit the plan made for one quest is the plan's own choice and is left alone.
local _, ns = ...
local Engine = ns.Engine
local State = ns.State
local function steps() return ForeverRouteData and ForeverRouteData.steps or {} end
local function key(i) return Engine.Key(i) end

Engine.WORTH_MIN_TRIP = 300 -- seconds: a shorter trip is always worth it
Engine.WORTH_MIN_PLANNED = 3 -- the plan's visit had at least this many quests (fewer: the plan meant it that way)
Engine.WORTH_LEVEL_HOURS = 2 -- (old: a level every 2 h; the price now follows Forever's pace, Engine.XpPerSec)
local TRAVEL = { fly = true, hearth = true, boat = true }

-- the plan's visit that step j opens: j and the steps after it in the same zone, up to the next trip
local function visitOf(j)
  local list = steps()
  local z = list[j] and list[j].zone
  local last = j
  for k = j + 1, #list do
    local t = list[k]
    if TRAVEL[t.k] or (t.zone and t.zone ~= z) then break end
    last = k
  end
  return z, j, last
end
-- does a quest the plan does after `from` (and you haven't done) need q handed in first?
local function neededLater(q, from)
  local opens = ForeverRouteUnlocks and ForeverRouteUnlocks[q]
  if not opens or #opens == 0 then return false end
  local want = {}; for _, d in ipairs(opens) do want[d] = true end
  local list = steps()
  for k = from + 1, #list do local t = list[k]; if t.q and want[t.q] and not State.IsCompleted(t.q) then return true end end
  return false
end

-- the decision for the step the card shows (nil: go). Returns q, its name, the zone, the trip in seconds, its XP
function Engine.NotWorth(i)
  local d = ForeverRouteData
  local function no(why) Engine.worthWhy = why; return nil end
  if not d or d.dungeon or d.special or Engine.view then return no("not on the plan") end
  local list = steps()
  local j = i
  while list[j] and TRAVEL[list[j].k] do j = j + 1 end -- (the card's step can be the trip itself)
  local s = list[j]
  if not (s and s.zone and s.m and s.x) then return no("no place") end
  local pm, px, py = State.Position()
  if not pm or pm == s.m or ns.Util.MapName(pm) == s.zone then return no("there") end -- (you're there: no trip)
  local z, a, b = visitOf(j)
  local planned, left, q, name = {}, {}, nil, nil
  for k = a, b do
    local t = list[k]
    if t.q and t.q > 0 then
      planned[t.q] = true
      if not Engine.IsDone(k) and not left[t.q] then left[t.q] = true; q, name = t.q, t.name; left.n = (left.n or 0) + 1 end
    end
  end
  local np = 0; for _ in pairs(planned) do np = np + 1 end
  if np < Engine.WORTH_MIN_PLANNED or left.n ~= 1 then return no("planned " .. np .. ", left " .. tostring(left.n)) end
  if neededLater(q, b) then return no("needed later") end
  -- (and only with something after it: skipped, the last quest of a route left the card empty - a zone picked for the one
  -- quest you carry there, offered by Where to? and emptied by this rule at once - mutate sweep)
  local more = false
  for k = b + 1, #list do
    local t = list[k]
    if t.q and t.q > 0 and t.q ~= q then local st = Engine.Status(k); if st == "todo" or st == "notready" or st == "full" then more = true; break end end
  end
  if not more then return no("the last on this route") end
  local L = UnitLevel and UnitLevel("player") or 1
  local xp = ns.QuestXp and ns.QuestXp(q, L)
  if not xp then
    for k = a, b do local t = list[k]; if t.q == q and t.k == "turnin" and tonumber(t.level) then xp = Engine.QuestXP(tonumber(t.level), L) end end
  end
  if not xp then return no("no xp") end
  -- the trip there (the cheap tests first: this one asks the trip planner)
  -- (not "a and b and f()": that keeps only f's first value, the legs)
  local secs
  if ns.Travel and ns.Travel.Plan then local _; _, secs = ns.Travel.Plan({ m = pm, x = px, y = py }, { m = s.m, x = s.x, y = s.y, name = s.zone }, { hearth = false }) end
  if not secs or secs < Engine.WORTH_MIN_TRIP then return no("trip " .. tostring(secs)) end
  -- (what the trip's time earns at your pace: Forever's XP an hour at your level, Engine.XpPerSec)
  local pays = Engine.XpPerSec(L) * secs
  if xp >= pays then return no("pays") end
  return q, name, z, secs, xp
end

local lastKey
function Engine.CheckWorth()
  local i = Engine.Shown and Engine.Shown()
  local s = i and steps()[i]
  if not s then return end
  local k = tostring(s) .. ":" .. tostring(UnitLevel and UnitLevel("player"))
  if k == lastKey then return end
  lastKey = k
  local q, name, z, secs, xp = Engine.NotWorth(i)
  if not q then return end
  local ids, list = {}, steps()
  for j = i, #list do
    if list[j].q == q and not ns.char.skipped[key(j)] then ns.char.skipped[key(j)] = true; ids[#ids + 1] = key(j) end
  end
  if #ids == 0 then return end
  Engine.ForgetDone()
  Engine._remember("skip", ids)
  local short = (ns.Style and ns.Style.ShortZone and ns.Style.ShortZone(z)) or z
  local line = string.format("Skipped %s: the last quest left in %s, ~%d min away for ~%s XP. /fr undo brings it back.",
    tostring(name or ("quest " .. q)), short, math.floor(secs / 60 + 0.5), xp >= 1000 and string.format("%.1fk", xp / 1000) or tostring(math.floor(xp)))
  -- (silent: nobody reads a chat line about it - tester; the card simply goes on. The decision log keeps the why)
  if ns.Why then ns.Why("worth", line) end
  Engine.Refresh()
end
-- (the next frame: not inside the refresh that showed the step)
local guarded = ns.Guard and ns.Guard("worth", Engine.CheckWorth) or Engine.CheckWorth
ns.On("FR_STEP", function() if C_Timer then C_Timer.After(0, guarded) else guarded() end end)
