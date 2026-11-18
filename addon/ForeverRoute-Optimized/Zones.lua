-- Zones: your plan's next zone, the XP a zone still holds for you, what Where to? offers, the trip to a zone. Part of Core.lua, split out as is (the code review: Core.lua mixed the event bus, saved data, plan
-- loading, route selection, zone economics, slash commands and perf sampling); loaded right after it.
local _, ns = ...

-- the planned route's next zone at your level: the first quest step on it you haven't done that isn't gray to you
-- (Stranglethorn at 39, after a detour to Arathi, is passed over: the route picks up in the zone after it)
local QUEST_KIND = { accept = true, turnin = true, obj = true }
-- the capitals: a pick-up or hand-in there is a stop on the way, never the zone you go to quest in (Ironforge showed as
-- PLANNED NEXT for Reclaimers' Business in Desolace, picked up there on the way to Desolace)
local CAPITAL = { ["Stormwind"] = true, ["Stormwind City"] = true, ["Ironforge"] = true, ["Darnassus"] = true,
  ["Orgrimmar"] = true, ["Undercity"] = true, ["Thunder Bluff"] = true }
function ns.IsCapital(z) return z ~= nil and CAPITAL[z] == true end
-- the zone a route's quests are in (most of its quest steps, capitals aside): a zone route the planner named after one
-- zone can be all in another (the companion's "Shen'dralas" route was 117 steps in Desolace, the same as its Desolace one)
-- the other zone a route works in for a good share of its quests (a quarter of its main zone's steps, 5 at least):
-- Hillsbrad's routes do Alterac Mountains' quests too - their givers are in Southshore, so Alterac has no route of its
-- own and looked left out of the zone list (tester). -> zone name or nil
function ns.RouteAlso(r)
  if not r then return nil end
  if r._also ~= nil then return r._also or nil end
  local main = ns.RouteZone(r)
  local n = {}
  for _, s in ipairs(ns.Steps(r)) do
    if s.q and QUEST_KIND[s.k] and s.zone and not CAPITAL[s.zone] and s.zone ~= main then n[s.zone] = (n[s.zone] or 0) + 1 end
  end
  local mainN = 0
  for _, s in ipairs(ns.Steps(r)) do if s.q and QUEST_KIND[s.k] and s.zone == main then mainN = mainN + 1 end end
  local best, bn = nil, 0
  for z, c in pairs(n) do if c > bn then best, bn = z, c end end
  r._also = (best and bn >= math.max(5, mainN / 4)) and best or false
  return r._also or nil
end
function ns.RouteZone(r)
  if not r then return nil end
  if r._zone ~= nil then return r._zone or nil end
  local n, best, bestN = {}, nil, 0
  for _, s in ipairs(ns.Steps(r)) do
    if s.q and QUEST_KIND[s.k] and s.zone and not CAPITAL[s.zone] then
      n[s.zone] = (n[s.zone] or 0) + 1
      if n[s.zone] > bestN then best, bestN = s.zone, n[s.zone] end
    end
  end
  r._zone = best or false
  return best
end
-- a built-in plan's visits (ForeverRouteVisits, from its trunk - tools/pieces.js): the first with a quest it hands in
-- that you haven't done, that isn't gray to you, and whose requirements you have handed in. By quests, not step
-- numbers: wherever you wandered, it is where the plan picks up
local function visitNext()
  local V = ForeverRouteVisits
  if type(V) ~= "table" or not (ns.planKey and ns.planKey.starter) then return nil end
  local S, E = ns.State, ns.Engine
  local L = (UnitLevel and UnitLevel("player")) or 1
  local gray = E and E.GrayAt and E.GrayAt(L) or 0
  -- from the visit you left the plan in, not before it: a stretch of the plan you had already passed (quests you
  -- skipped) is behind you, as on the plan itself - PLANNED NEXT read Hillsbrad on the plan and Redridge (~1.6k XP)
  -- once you had picked a zone (review)
  local startV = 1
  local r = ns.ResolvePath and ns.ResolvePath(ns.char and ns.char.returnTo)
  local at = tonumber(ns.char and ns.char.returnAt)
  if r and at then
    local list = ns.Steps(r)
    local q0
    for j = at, #list do local s = list[j]; if s and s.q and s.k == "turnin" then q0 = s.q; break end end
    if q0 then
      for k, v in ipairs(V) do
        local hit = false
        for id in string.gmatch(v.grants or "", "%d+") do if tonumber(id) == q0 then hit = true; break end end
        if hit then startV = k; break end
      end
    end
  end
  for vi, v in ipairs(V) do
    local met = vi >= startV and not CAPITAL[v.zone]
    for id in string.gmatch(v.requires or "", "%d+") do if not S.IsCompleted(tonumber(id)) then met = false; break end end
    if met then
      for id in string.gmatch(v.grants or "", "%d+") do
        local q = tonumber(id)
        local ql = ns.QuestLevel and ns.QuestLevel(q)
        -- (as the card has it: a gray hand-in is skipped, carried or not; one you could take only if it is offered to you)
        if not S.IsCompleted(q) and not (ql and ql <= gray) and (S.OnQuest(q) or ((not ns.PrereqsMet or ns.PrereqsMet(q))
          and not (ns.Avail and ns.Avail.Unavailable(q)) and not (ns.Nope(q)))) then return v.zone end
      end
    end
  end
  return nil
end
ns.VisitNext = visitNext
function ns.PlannedNextZone()
  local d, S, E = ForeverRouteData, ns.State, ns.Engine
  -- on a zone you picked, a built-in plan with visits says it by quests (stage 2.4): wherever you wandered. On the
  -- plan itself the engine knows where you are (the scan below); a plan without visits keeps the scan of the route you left
  if d and d.zoneRoute then
    local vz = visitNext()
    if vz then return vz, ns.Util.PlanRoute() end
  end
  -- on your planned route: the engine knows what's done - the first quest step from where you are that isn't
  -- (from the plan's own place, not the step on the card - code review)
  local at0 = E and (E.planned or E.current) -- (not PlanAt: the step you look at while browsing - review)
  if d and not d.zoneRoute and not d.dungeon and not d.special and E and at0 then
    local list = ns.Steps(d)
    local via -- (a stop in a capital on the way: the row says so)
    for i = at0, #list do
      local s = list[i]
      if s and s.q and s.zone and QUEST_KIND[s.k] and E.Status(i) ~= "done" then
        if not CAPITAL[s.zone] then return s.zone, d, via end
        via = via or { name = s.name, zone = s.zone }
      end
    end
    return nil, d
  end
  -- on a zone you picked: the route you came from (ns.EnterZoneRoute), what's left of it at your level
  local r = (d and d.zoneRoute and ns.ResolvePath(ns.char.returnTo)) or ns.MainRoutes()[1]
  if not r then return nil end
  local list = ns.Steps(r)
  local from = (r.id == ns.char.returnTo and tonumber(ns.char.returnAt)) or 1
  for j = math.max(1, math.min(from, #list)), #list do
    local s = list[j]
    if s.q and s.zone and QUEST_KIND[s.k] and not S.IsCompleted(s.q)
      and not (s.k == "accept" and S.OnQuest(s.q)) and not (s.k ~= "accept" and not S.OnQuest(s.q))
      and not (E and E.Outlevelled and E.Outlevelled(s)) and not CAPITAL[s.zone] then
      return s.zone, r
    end
  end
  return nil, r
end

-- The XP a zone still holds for you: its route walked in order from where you are - a pick-up taken once you could
-- (not done, not gray, its prerequisites handed in or handed in earlier on the walk, its level reached), its hand-in
-- paying at the level you'd be by then - until nothing more there is yours to take: the wall that sends you elsewhere.
-- Quests that open up as you level in the zone count; ones you would outlevel before you get to them don't.
local wallCache = {}
for _, e in ipairs({ "FR_STATE", "PLAYER_XP_UPDATE", "FR_ROUTE_CHANGED", "FR_NOPE" }) do
  ns.On(e, function() wallCache = {} end)
end
-- assume: { [quest] = true } handed in before you start (what a zone would hold once you did the chain start it needs)
-- onlyZone: walk only that zone's steps (your plan's next zone, when it has no zone route of its own)
function ns.ZoneXpLeft(r, level, assume, onlyZone)
  if not (r and ns.QuestXp) then return nil end
  local k = tostring(r.id) .. ":" .. tostring(level) .. ":" .. tostring(onlyZone)
  if assume then local a = {}; for q in pairs(assume) do a[#a + 1] = q end; table.sort(a); k = k .. ":" .. table.concat(a, ",") end
  if wallCache[k] then return wallCache[k] end
  local S, E = ns.State, ns.Engine
  local T = ns.XP_TO_LEVEL or {}
  local L = level
  local xpNow = (UnitXP and UnitXP("player")) or 0
  local total, taken, handed = 0, {}, {}
  for q in pairs(assume or {}) do handed[q] = true end
  local function gain(n)
    total = total + n; xpNow = xpNow + n
    while L < 60 and T[L] and T[L] > 0 and xpNow >= T[L] do xpNow = xpNow - T[L]; L = L + 1 end
  end
  local function preMet(q)
    local pre = ns.QUEST_PRE and ns.QUEST_PRE[q]
    if not pre then return true end
    for _, p in ipairs(pre.g or {}) do if not (S.IsCompleted(p) or handed[p]) then return false end end
    if pre.s and #pre.s > 0 then
      for _, p in ipairs(pre.s) do if S.IsCompleted(p) or handed[p] then return true end end
      return false
    end
    return true
  end
  for _, s in ipairs(ns.Steps(r)) do
    local q = s.q
    -- (handed in or not is asked last, of a pick-up or hand-in that would count: the game is asked about fewer quests -
    -- an objective step, a gray pick-up, a hand-in of a quest you don't have count for nothing either way)
    if q and not handed[q] and (not onlyZone or s.zone == onlyZone or CAPITAL[s.zone]) then
      if s.k == "accept" then
        if not taken[q] and not S.OnQuest(q) then
          local gray = E and E.GrayAt and tonumber(s.level) and s.level > 0 and s.level <= E.GrayAt(L)
          -- (not red at the level you'd be by then, Engine.TooHigh, and not cut off by an earlier quest you skipped or
          -- refused, Engine.ChainCut: the engine waits on the one and passes the other)
          if not gray and not (s.minLevel and L < s.minLevel) and not S.IsCompleted(q) and preMet(q) and not (ns.Avail and ns.Avail.Unavailable(q))
            and not (E and E.Excluded and E.Excluded(s)) and not (ns.Nope(q)) and not (E and E.TooHigh and E.TooHigh(s, L))
            and not (E and E.ChainCut and E.ChainCut(q)) then taken[q] = true end
        end
      elseif s.k == "turnin" and (taken[q] or S.OnQuest(q)) and not S.IsCompleted(q) then
        handed[q] = true
        gain(ns.QuestXp(q, L) or 0)
      end
    end
  end
  wallCache[k] = total
  return total
end

-- What "Where to?" offers (UI/Paths.lua, the card, the simulated player): one row per zone you could go to now -
-- the zone routes for your level (a built-in plan's tree), the zones your companion plan ranked, and your planned
-- route's next zone, which is always the best pick ("BEST NEXT"). A row: { zone, key, xph, route, questsLeft,
-- handIns, here, best, planned }. Zones whose route has nothing left for you are left out.
local zoneKey = function(z) return (ns.Style and ns.Style.ShortZone and ns.Style.ShortZone(z)) or z end
ns.ZoneKey = zoneKey
local leftCache = {}
-- (cleared on every quest or level change: kept by time, a count outlived a quest's hand-in and sent the zone-hopper to
-- Redridge for quests it had already done)
-- (and on "not doing": a quest you refused, and what its chain leads to, is no longer counted)
for _, e in ipairs({ "FR_STATE", "FR_ROUTE_CHANGED", "FR_NOPE" }) do
  ns.On(e, function() leftCache = {} end)
end
-- (the simulated world changes quests without the game's events: its player clears the counts before it looks; Skip
-- and Undo too - a skipped pick-up cuts its chain, Engine.ChainCut)
function ns.ZoneCountsChanged() leftCache = {}; wallCache = {} end
-- your log's quests on a route, from one walk over its steps, kept with the counts (cleared on any quest, level or route
-- change; walked again when its length changed): order = them in the order they first come on the route (S.OnQuest),
-- maps[q] = the maps of q's objective and hand-in steps there, at[q] = the first of those steps (its level: Engine.TooHigh).
-- What Where to? needs of your plan - the quests you carry on
-- a row's maps (Stitch.CarriedFrom), the chains you carry (ns.ChainsAtRisk) - walked it once per row and once more per
-- draw: about 2x the time of opening it (perf gate)
local NO_STEPS = {}
function ns.LogQuestsOn(r)
  local steps = (r and ns.Steps(r)) or NO_STEPS
  local all = leftCache.logOn
  if not all then all = {}; leftCache.logOn = all end
  local c = all[steps]
  if c and c.n == #steps then return c end
  local onQuest, order, maps, seen, at = ns.State.OnQuest, {}, {}, {}, {}
  for j = 1, #steps do
    local t = steps[j]
    local q = t.q
    -- (a quest not in your log is asked each time it comes, as before: a set of every quest on the route is garbage)
    if q and (seen[q] or onQuest(q)) then
      if not seen[q] then seen[q] = true; order[#order + 1] = q end
      local m = t.m
      if m and (t.k == "obj" or t.k == "turnin") then local mm = maps[q]; if not mm then mm = {}; maps[q] = mm end; mm[m] = true; at[q] = at[q] or t end
    end
  end
  c = { n = #steps, order = order, maps = maps, at = at }
  all[steps] = c
  return c
end
-- a quest's prerequisites met (ns.QUEST_PRE: g all of these handed in, s any one of them)
function ns.PrereqsMet(q)
  local pre = ns.QUEST_PRE and ns.QUEST_PRE[q]
  if not pre then return true end
  local S = ns.State
  for _, p in ipairs(pre.g or {}) do if not S.IsCompleted(p) then return false end end
  if pre.s and #pre.s > 0 then
    local any = false
    for _, p in ipairs(pre.s) do if S.IsCompleted(p) then any = true; break end end
    if not any then return false end
  end
  return true
end
-- what a zone route still has for you: quests you can take there now (not done, not gray to you, their prerequisites
-- handed in) and quests in your log with work or a hand-in there. Counting every quest id on the route made a zone
-- you had finished look like 19 quests (the zone-hopper went back to Ashenvale it had already done)
local QUEST_STEP = { accept = true, turnin = true, obj = true }
-- where quests are done on your plan (the first step naming each): wanted = { [q] = true } -> { [q] = step }, for
-- "needs X (zone) first". (Every row's at once, in one walk that stops when all are found: a walk over the whole plan
-- per row was a good part of opening Where to? - perf gate)
local function onPlan(wanted, n)
  local found = {}
  if n == 0 then return found end
  local d = ForeverRouteData
  local r = (d and d.zoneRoute and ns.ResolvePath(ns.char.returnTo)) or (d and not d.zoneRoute and d) or ns.MainRoutes()[1]
  for _, s in ipairs((r and ns.Steps(r)) or {}) do
    local q = s.q
    if q and wanted[q] and s.name and not found[q] then found[q] = s; n = n - 1; if n == 0 then break end end
  end
  return found
end
-- also returns why the zone matters to you: a quest in your log with work there (continues), and the first quest there
-- held up by a prerequisite you haven't handed in (need = { q, prerequisite })
local function questsLeft(r, level)
  local k = tostring(r.id) .. ":" .. tostring(level)
  local c = leftCache[k]
  if c then return c.n, c.cont, c.need, c.ids, c.contQ end
  local n, S, E, seen = 0, ns.State, ns.Engine, {}
  local cont, need, contQ
  local ids = {} -- (the quests counted: for the simulated player's report)
  for _, s in ipairs(ns.Steps(r)) do
    local q = s.q
    -- (handed in or not is asked only of a quest in your log or a pick-up that passed the checks that don't ask the game:
    -- the rest count for nothing either way, and asking about every quest on every row's route was most of the quest
    -- API calls opening Where to? made - perf gate)
    local on = q and QUEST_STEP[s.k] and not seen[q] and S.OnQuest(q)
    -- (a gray one the route dropped is nothing there for you: the one gray rule, Engine.GrayDrop - a level 57 was
    -- offered The Barrens for the low chains it carried)
    if on and not S.IsCompleted(q) and not (E and E.Outlevelled and E.Outlevelled(s)) then
      -- a quest you carry: only work to do there, or its hand-in there with the quest ready (a hand-in waiting on work
      -- elsewhere left Wetlands looking like it had quests when the card had nothing there)
      -- (an objective step counts only while its own objective is unfinished, as the engine has it: Baron Longshore's
      -- kill done in Stonetalon, his head handed in in Ratchet, made Stonetalon look like it had a quest left)
      -- (and not red to you: its work waits for your level, Engine.TooHigh - the row read "continues X", and once picked
      -- the card had only a wait - code review)
      local o = s.k == "obj" and not S.QuestReady(q) and (s.unknown or not (E and E.ObjectiveFor and (E.ObjectiveFor(s) or {}).finished))
        and not (E and E.TooHigh and E.TooHigh(s, level))
      -- (and a ready hand-in only when the engine would send you to it: not a gray one, Baron Longshore at 23)
      if o or (s.k == "turnin" and S.QuestReady(q) and not (E and E.GrayHandIn and E.GrayHandIn(s))) then seen[q] = true; n = n + 1; cont = cont or s.name; contQ = contQ or q; ids[#ids + 1] = q end
    -- (with the reason found, a quest held up by a prerequisite is nothing more: the checks are skipped for it)
    -- (not one you refused, not red to you - it waits - and not one whose earlier quest you skipped or refused: the game
    -- never offers it, Engine.ChainCut. Such a pick-up was the row's "needs X first", and picking the zone gave an empty
    -- card - code review)
    elseif q and not on and s.k == "accept" and not seen[q] and not (s.minLevel and level < s.minLevel) and not ns.Nope(q)
        and not (E and E.TooHigh and E.TooHigh(s, level))
        -- gray by level alone: whether it leads to something worth it depends on the route you are on, and on the zone's
        -- own route it often leads nowhere (A Free Lunch counted from your plan, outlevelled once you got to Redridge).
        -- (Asked first: E.Outlevelled is gray and more, so never true when this is false - and it asks the game about
        -- each quest a gray one leads to)
        and not (E and E.GrayAt and tonumber(s.level) and s.level > 0 and s.level <= E.GrayAt(level))
        and not S.IsCompleted(q) and (need == nil or ns.PrereqsMet(q))
        and not (E and ((E.Outlevelled and E.Outlevelled(s)) or (E.Excluded and E.Excluded(s)) or (E.Breadcrumbed and E.Breadcrumbed(s))))
        and not (ns.Avail and ns.Avail.Unavailable(q)) and not (E and E.ChainCut and E.ChainCut(q)) then
      -- (a quest held up by a prerequisite is the zone's reason only when you'd take it: a gray one kept Hillsbrad's
      -- 22 route on offer at 39, "needs Battle of Hillsbrad first", with nothing there for you - mutate sweep)
      if ns.PrereqsMet(q) then seen[q] = true; n = n + 1; ids[#ids + 1] = q
      elseif not need then
        local pre = ns.QUEST_PRE and ns.QUEST_PRE[q]
        for _, p in ipairs((pre and (pre.g or pre.s)) or {}) do if not S.IsCompleted(p) then need = { q = q, pre = p }; break end end
      end
    end
  end
  leftCache[k] = { n = n, cont = cont, need = need, ids = ids, contQ = contQ }
  return n, cont, need, ids, contQ
end
-- a map id's zone: as the plan's own steps name it (each route scanned once), else as the game names the map
local mapZone, scanned = {}, {}
local function learnMaps(r)
  if not r or scanned[r] then return end
  scanned[r] = true
  for _, s in ipairs(ns.Steps(r)) do if s.m and s.zone and mapZone[s.m] == nil then mapZone[s.m] = s.zone end end
end
local function zoneOfMap(m)
  if not m then return nil end
  if mapZone[m] == nil and C_Map and C_Map.GetMapInfo then
    local ok, info = pcall(C_Map.GetMapInfo, m)
    if ok and info and info.name then mapZone[m] = info.name end
  end
  return mapZone[m] or nil
end
function ns.ZoneChoices()
  local level = (UnitLevel and UnitLevel("player")) or 1
  local d, S = ForeverRouteData, ns.State
  local rows, byKey = {}, {}
  local function add(name, xph, route)
    if not name then return nil end
    local k = zoneKey(name)
    local r = byKey[k]
    if not r then r = { zone = name, key = k, handIns = 0 }; byKey[k] = r; rows[#rows + 1] = r end
    r.xph = r.xph or xph
    r.route = r.route or route
    return r
  end
  for _, r in ipairs(ns.ZoneRoutesAt(level)) do add(ns.RouteZone(r) or r.zoneName, r.xph, r) end
  for _, z in ipairs((ForeverRoutePlan and ForeverRoutePlan.zones) or {}) do
    local zr = ns.ZoneRouteFor(z.name, level)
    add((zr and ns.RouteZone(zr)) or z.name, z.xph, zr)
  end
  local plannedZone, plannedRoute, via = ns.PlannedNextZone()
  local best = add(plannedZone)
  if best then best.best, best.planned, best.via, best.planRoute = true, true, via, plannedRoute end
  -- where you are: the zone you picked, else the zone you're standing in (not the next step's: on your way to
  -- Desolace from Gnomeregan, Desolace was marked YOU'RE HERE)
  learnMaps(d); for _, r in ipairs(rows) do learnMaps(r.route) end
  local hereZone = d and d.zoneRoute and d.zoneName
  if not hereZone and ns.Engine and ns.Engine.HereMap then hereZone = zoneOfMap(ns.Engine.HereMap()) end
  local here = hereZone and byKey[zoneKey(hereZone)]
  -- (standing in a zone whose route is all in another: that one - Shen'dralas is Desolace's)
  if not here and hereZone then local zr = ns.ZoneRouteFor(hereZone, level); local rz = zr and ns.RouteZone(zr); here = rz and byKey[zoneKey(rz)] end
  if not here and hereZone then for _, r in ipairs(rows) do if r.route and ns.RouteAlso(r.route) == hereZone then here = r; break end end end
  if here then here.here = true end
  -- quests you finished whose hand-in is in a zone on the list
  -- (row.handIns: those its route will have even with nothing of its own left - its own hand-in step, or one your plan
  -- does on its maps, Stitch.Carried; row.handInsAny: all of them, for a route with work of its own, where the engine
  -- adds a finished quest's hand-in where it costs least. A hand-in the zone's route had no place for kept Thousand
  -- Needles on offer with nothing left there, and picking it left the card empty - mutate sweep)
  -- (the route's own hand-ins: a walk over its steps; the carried ones from your log's quests on your plan,
  -- ns.LogQuestsOn, only for a row with a finished quest to hand in - kept with the quest counts, cleared on any quest,
  -- level or route change)
  local function routeTakes(row, carried)
    local k = "takes:" .. tostring(row.route.id) .. (carried and ":c" or "")
    local t = leftCache[k]
    if not t then
      t = {}
      for _, s in ipairs(ns.Steps(row.route)) do if s.k == "turnin" and s.q then t[s.q] = "own" end end
      if carried and ns.Stitch and ns.Stitch.CarriedFrom then
        local memo = leftCache.carryMemo or {}; leftCache.carryMemo = memo
        for c in pairs(ns.Stitch.CarriedFrom(ns.Steps(row.route), ns.LogQuestsOn(ns.Util.PlanRoute()), memo)) do t[c] = t[c] or "carried" end
      end
      leftCache[k] = t
    end
    return t
  end
  if ns.Engine and ns.Engine.LogEnders then
    local E = ns.Engine
    for q, e in pairs(E.LogEnders()) do
      -- (a gray one the route dropped is no reason to go there: Engine.GrayDrop)
      if S.QuestReady(q) and not S.IsCompleted(q) and not (E.GrayDrop and E.GrayDrop(q, level, E.logLevels and E.logLevels[q]) == true) then
        local row = byKey[zoneKey(zoneOfMap(e.m))]
        local how = row and (not row.route or routeTakes(row, true)[q])
        if row then row.handInsAny = (row.handInsAny or 0) + 1 end
        if how then
          row.handIns = row.handIns + 1
          -- (a carried hand-in's XP is the zone's too: ZoneXpLeft walks only the route's own steps, and the row read
          -- "0 XP" for two quests waiting to be handed in there)
          if how == "carried" and ns.QuestXp then row.carriedXp = (row.carriedXp or 0) + (ns.QuestXp(q, level) or 0) end
        end
      end
    end
  end
  -- what each row's quests need first, and where your plan does those (onPlan: every row's at once)
  local left, wanted, nWanted = {}, {}, 0
  for j, r in ipairs(rows) do
    if r.route then
      local need
      r.questsLeft, r.continues, need, r.leftIds, r.contQ = questsLeft(r.route, level)
      left[j] = need or false
      if need and not wanted[need.pre] then wanted[need.pre] = true; nWanted = nWanted + 1 end
    end
  end
  local planned = onPlan(wanted, nWanted)
  local out = {}
  for j, r in ipairs(rows) do
    if r.route then
      local need = left[j]
      r.xpLeft = ns.ZoneXpLeft and ns.ZoneXpLeft(r.route, level) or nil
      if r.xpLeft and r.carriedXp then r.xpLeft = r.xpLeft + r.carriedXp end
      r.also = ns.RouteAlso(r.route)
      -- one reason per row: hand-ins waiting, else a quest you carry (r.continues), else what it needs first (Paths.lua)
      local ps = need and planned[need.pre]
      if ps then local name, zone = ps.name, ps.zone; do
        r.needs = { name = name, zone = zone, q = need.q }
        -- what doing it first would open up there (the walk again, with it and what it needs handed in)
        if ns.Stitch and r.xpLeft then
          local a = { [need.pre] = true }
          for _, id in ipairs(ns.Stitch.Closure(need.pre, function(q) return S.IsCompleted(q) end)) do a[id] = true end
          r.needs.xpMore = math.max(0, (ns.ZoneXpLeft(r.route, level, a) or 0) - (r.xpLeft - (r.carriedXp or 0)))
        end
      end end
    end
    if r.route and not r.here then r.tripSecs = ns.ZoneTrip(r.route) end
    -- your plan's next zone with no zone route of its own: the XP your plan has for you there. With one, too, when the
    -- zone's route has none: the row takes you back to your plan, not to that route (Mount Hyjal read "0 XP" as PLANNED
    -- NEXT - mutate sweep)
    if r.planRoute and ns.ZoneXpLeft and (not r.route or r.xpLeft == 0) then r.xpLeft = ns.ZoneXpLeft(r.planRoute, level, nil, r.zone) end
    -- A row says what is there for you: quests its route hands in, a quest you carry with work there, hand-ins, or a
    -- chain start (questsLeft: only for a quest you'd take). Pick-ups whose hand-ins the zone's route doesn't have are
    -- nothing (a band cut off mid-quest: Azshara's 52 route ends on A Taste of Home's objective, offered with no XP left).
    -- (a zone whose quests need a start you haven't done stays, saying so)
    local something = false
    if r.route and (r.questsLeft or 0) > 0 then
      if r.continues then something = true
      else local t = routeTakes(r); for _, q in ipairs(r.leftIds or {}) do if t[q] then something = true; break end end end
    end
    if something and r.handInsAny then r.handIns = r.handInsAny end
    if r.planned or r.here or r.handIns > 0 or not r.route or r.needs or something then out[#out + 1] = r end
  end
  table.sort(out, function(a, b)
    if (a.best and true or false) ~= (b.best and true or false) then return a.best and true or false end
    if (a.here and true or false) ~= (b.here and true or false) then return a.here and true or false end
    if a.handIns ~= b.handIns then return a.handIns > b.handIns end
    if (a.route and true or false) ~= (b.route and true or false) then return a.route and true or false end -- (a ready route before one to ask for)
    -- (XP an hour with the trip there, when both are known: a big zone two continents away no longer beats the one next
    -- door - persona review)
    local ra, rb = ns.ZoneRate(a), ns.ZoneRate(b)
    if ra and rb and ra ~= rb then return ra > rb end
    return (a.xpLeft or 0) > (b.xpLeft or 0)
  end)
  return { rows = out, best = best, level = level }
end
-- How long it takes to get to a zone's route from where you stand (its first stop with a place): the trip planner's
-- seconds, worked out in the background a slice a frame (a search per zone row in one frame would be a hitch when Where
-- to? opens) and kept by the route, where you stand (to ~200 yd), your flight paths and level. -> seconds, or nil while
-- not known yet; ns.ZoneTripsDone() fires FR_ZONETRIPS when a batch is in.
local tripCache, tripQueue, tripJob = {}, {}, nil
local tripDriver = CreateFrame and CreateFrame("Frame") or nil
local function tripKey(r)
  -- (not 'ns.State and ns.State.Position()': an and-expression keeps only the first of its values)
  local pm, px, py
  if ns.State and ns.State.Position then pm, px, py = ns.State.Position() end
  if not (pm and px) then return nil end
  local n = ns.State.KnownTaxiCount()
  return tostring(r.id) .. ":" .. pm .. ":" .. math.floor(px * 20) .. ":" .. math.floor(py * 20) .. ":" .. n .. ":" .. ((UnitLevel and UnitLevel("player")) or 0), pm, px, py
end
local function firstPlace(r)
  for _, s in ipairs(ns.Steps(r)) do if s.m and s.x and not s.unknown and (s.k == "accept" or s.k == "obj" or s.k == "turnin") then return s end end
end
local function priceOne(r, k, pm, px, py)
  local s = firstPlace(r)
  local secs = false
  if s and ns.Travel then
    if s.m == pm then
      -- (in the zone already: the walk, at your speed)
      local HBD = LibStub("HereBeDragons-2.0")
      local ax, ay, ai = HBD:GetWorldCoordinatesFromZone(px, py, pm)
      local bx, by, bi = HBD:GetWorldCoordinatesFromZone(s.x, s.y, s.m)
      if ax and bx and ai == bi then secs = math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) / ((ns.Travel.Speed and ns.Travel.Speed()) or 7) end
    elseif ns.Travel.Plan then
      local ok, legs, t = ns.Call(ns.Travel.Plan, { m = pm, x = px, y = py }, { m = s.m, x = s.x, y = s.y })
      if ok and legs and t then secs = t end
    end
  end
  tripCache[k] = secs
end
local function tripStep()
  if not tripJob then if tripDriver then tripDriver:Hide() end return end
  if ns.Jobs.Busy("route") then return end -- (one slicer a frame: a route change's passes first)
  ns.sliceCo, ns.sliceT0, ns.sliceBudget = tripJob, debugprofilestop(), 1
  local ok, err = coroutine.resume(tripJob)
  ns.sliceCo = nil
  if not ok or coroutine.status(tripJob) == "dead" then
    tripJob = nil; if tripDriver then tripDriver:Hide() end
    if not ok and ns.LogError then ns.LogError("zonetrips", err) end
    ns.Fire("FR_ZONETRIPS")
  end
end
if tripDriver then tripDriver:Hide(); tripDriver:SetScript("OnUpdate", function() local ok, err = pcall(tripStep); if not ok then tripJob = nil; tripDriver:Hide() end end) end
ns._zoneTripDriver = tripDriver -- (the perf battery ticks it)
function ns.ZoneTrip(r)
  if not r then return nil end
  local k, pm, px, py = tripKey(r)
  if not k then return nil end
  local v = tripCache[k]
  if v ~= nil then return v or nil end
  tripQueue[k] = { r = r, pm = pm, px = px, py = py }
  if not tripJob then
    tripJob = coroutine.create(function()
      while true do
        local key, q = next(tripQueue)
        if not key then return end
        tripQueue[key] = nil
        if tripCache[key] == nil then priceOne(q.r, key, q.pm, q.px, q.py) end
        ns.MaybeYield()
      end
    end)
    if tripDriver then tripDriver:Show() end
  end
  return nil
end
-- (tests: price everything asked for now)
function ns.ZoneTripsSettle() local g = 0; while tripJob and g < 100000 do g = g + 1; ns.sliceCo, ns.sliceT0, ns.sliceBudget = tripJob, debugprofilestop(), math.huge; local ok, e = coroutine.resume(tripJob); ns.sliceCo = nil; if not ok and ns.LogError then ns.LogError("zonetrips", e) end; if not ok or coroutine.status(tripJob) == "dead" then tripJob = nil end end end
-- XP an hour with the trip there: the zone's rate over its XP left, plus the time to get there (nil: not known)
function ns.ZoneRate(r)
  if not (r and r.xpLeft and r.xpLeft > 0) then return nil end
  local xph = r.route and r.route.xph or r.xph
  if not (xph and xph > 0) then return nil end
  local trip = r.tripSecs
  if not trip then return nil end
  return r.xpLeft / (r.xpLeft / xph + trip / 3600)
end
