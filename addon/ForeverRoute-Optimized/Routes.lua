-- Routes: the routes in the plan, which one you are on, entering and leaving zones and side trips, a route's steps. Part of Core.lua, split out as is (the code review: Core.lua mixed the event bus, saved data, plan
-- loading, route selection, zone economics, slash commands and perf sampling); loaded right after it.
local _, ns = ...

-- Several planned paths (ForeverRouteRoutes) or one route (ForeverRouteData). Progress flags are kept per route.
function ns.Routes() return ForeverRouteRoutes or (ForeverRouteData and { ForeverRouteData }) or {} end
-- main paths (not branches) for the path switcher
function ns.MainRoutes()
  local out = {}
  for _, r in ipairs(ns.Routes()) do if not r.branch and not r.dungeon and not r.zoneRoute then out[#out + 1] = r end end
  return out
end
-- ready-made routes into each of the best zones at your level (the planner builds them with every plan): picking one
-- switches at once, no replan to wait for
function ns.ZoneRoutes()
  local out = {}
  for _, r in ipairs(ns.Routes()) do if r.zoneRoute then out[#out + 1] = r end end
  return out
end
-- a zone route that fits a level: a built-in plan's tree has one per zone and level band (r.level: planned from the
-- trunk at that level - tools/zone-routes.js); the newest one you are in reach of (its level up to 2 above yours). A
-- plan's own zone routes carry no level: the first for the zone, when no band of that zone fits. (A built-in plan has
-- both: its own route per zone, planned at the plan's start - Hillsbrad at 22 - and the tree's bands. The one without a
-- level came first at any level, so at 28 Where to? offered Hillsbrad's 22 route, done long ago, and picking it left
-- the card empty - mutate sweep.)
local function fits(r, level) return not r.level or not level or (r.level <= level + 2 and r.level >= level - 6) end
-- (over ns.Routes() itself, not ns.ZoneRoutes(): no list made per call - Where to? asks once per zone on your plan)
function ns.ZoneRouteFor(zone, level)
  level = level or (UnitLevel and UnitLevel("player")) or nil
  local best, plain
  for _, r in ipairs(ns.Routes()) do
    if r.zoneRoute and r.zoneName == zone and fits(r, level) then
      if not r.level then plain = plain or r
      elseif not best or r.level > best.level then best = r end
    end
  end
  return best or plain
end
-- the zones you could go to now (one route each, the best fit for your level): what "fancy a change?" offers.
-- (one walk over the routes: each zone's ZoneRouteFor pick, the zones in the order their first band that fits comes -
-- a ZoneRouteFor per zone walked every route again, ~100 zone routes on a built-in plan's tree, each time Where to?
-- opened)
function ns.ZoneRoutesAt(level)
  level = level or (UnitLevel and UnitLevel("player")) or nil
  local best, order = {}, {}
  for _, r in ipairs(ns.Routes()) do
    local z = r.zoneRoute and r.zoneName
    if z and r.level and fits(r, level) then
      local b = best[z]
      if not b then order[#order + 1] = z; best[z] = r
      elseif r.level > b.level then best[z] = r end
    end
  end
  -- (a zone with a band that fits has its pick there: a band beats a route without a level)
  local out = {}
  for j, z in ipairs(order) do out[j] = best[z] end
  table.sort(out, function(a, b) return (a.xph or 0) > (b.xph or 0) end)
  return out
end
function ns.DungeonRoutes()
  local out = {}
  for _, r in ipairs(ns.Routes()) do if r.dungeon then out[#out + 1] = r end end
  return out
end
-- dungeon routes are a side trip: remember the path you were on, and go back to it with its progress untouched
function ns.EnterDungeonRoute(id)
  local r = ns.RouteById(id); if not r then return end
  -- (from a zone you picked: your plan stays the way back - the zone route took its place, and "Back to my path" then
  -- went back to the zone, off the plan for good - state map)
  if ForeverRouteData and not ForeverRouteData.dungeon and not ForeverRouteData.zoneRoute then ns.char.returnTo = ForeverRouteData.id end
  ns.char.chosenTrip = id -- (you picked it: kept across logins - ns.SavedRoute)
  ns.SelectRoute(id)
  ns.Print((r.special and "Side trip: " or "Dungeon route: ") .. (r.dungeonName or r.title) .. ". Your plan is kept - \"Back to plan\" on the card returns you to it.")
end
-- a zone you picked (a zone route, ns.ZoneRouteFor): the route you were on is remembered, so "Planned route" in the
-- zone picker goes back to it - picked up where it still has something for you at your level (UI/Paths.lua)
-- The zones you have quested in, in order (stage 2.7): ns.char.zoneOrder = "Westfall>Redridge Mountains>*Duskwood", the
-- last where you are now, * a zone you picked. Written next to the older fields (routeLegs, requestZone, returnTo), which
-- stay as they were: nothing is migrated, an older save just starts its list from the zone of its next hand-in. For the
-- planner (the zones you chose, kept when it replans) and the companion's data.
local ZONE_ORDER_MAX = 12
function ns.NoteZone(zone, picked)
  if not (zone and zone ~= "" and ns.char) then return end
  local list = {}
  for z in string.gmatch(ns.char.zoneOrder or "", "[^>]+") do list[#list + 1] = z end
  local last = list[#list]
  if last and last:gsub("^%*", "") == zone then
    if picked and last:sub(1, 1) ~= "*" then list[#list] = "*" .. zone end
  else
    list[#list + 1] = (picked and "*" or "") .. zone
  end
  while #list > ZONE_ORDER_MAX do table.remove(list, 1) end
  ns.char.zoneOrder = table.concat(list, ">")
end
function ns.ZoneOrder()
  local list = {}
  for z in string.gmatch((ns.char and ns.char.zoneOrder) or "", "[^>]+") do list[#list + 1] = { zone = z:gsub("^%*", ""), picked = z:sub(1, 1) == "*" } end
  return list
end
-- a quest handed in: the zone of its hand-in on your route goes on the list
ns.On("QUEST_TURNED_IN", function(q)
  local d = ForeverRouteData
  if not (q and d) then return end
  for _, s in ipairs(ns.Steps(d)) do if s.q == q and s.k == "turnin" and s.zone then ns.NoteZone(s.zone); return end end
end)
function ns.EnterZoneRoute(id)
  local d = ForeverRouteData
  do local r = ns.RouteById(id); if r and r.zoneName then ns.NoteZone(r.zoneName, true) end end
  -- (and where you were on it: "Planned route" picks up from there, not from its first step)
  -- (where: the first quest step the plan still has for you, as PLANNED NEXT read it - the engine's position can sit
  -- before a stretch it counts as behind you)
  if d and not d.dungeon and not d.special and not d.zoneRoute and not d.branch then
    local E, at = ns.Engine, ns.Engine and (ns.Engine.planned or ns.Engine.current) -- (the plan's place, not the card's step - code review)
    if E and at and E.Status then local list = ns.Steps(d); for i = at, #list do local s = list[i]; if s and s.q and s.zone and (s.k == "accept" or s.k == "turnin" or s.k == "obj") and E.Status(i) ~= "done" then at = i; break end end end
    ns.char.returnTo = d.id; ns.char.returnAt = at
  end
  ns.SelectRoute(id)
end

function ns.LeaveDungeonRoute()
  -- a replan while you were on the trip may have renamed your path: find it by its zone order, not the top path
  local was = ns.char.returnTo
  local back = ns.ResolvePath(was) or ns.MainRoutes()[1]
  if not back then return end
  if was and back.id ~= was then
    if ns.char.pinnedPath == was then ns.char.pinnedPath = back.id end
    if ns.Why then ns.Why("path", "your path " .. tostring(was) .. " was renamed by a replan; back on " .. tostring(back.id) .. " (closest match to your zone order)") end
  end
  ns.char.returnTo = back.id
  ns.char.chosenTrip = nil
  ns.char.returnAt, ns.char.requestZone = nil, nil -- (stale after: reused against a rebuilt plan, and "On your way to X" stayed - state map)
  ns.SelectRoute(back.id); ns.Print("Back on your path: " .. (back.title or ""))
end
-- a route's steps; branches and dungeon routes are kept packed until needed (see the planner's paths.js)
local unpackFn = loadstring or load
function ns.Steps(r)
  if not r then return {} end
  if not r.steps and r.packed then
    local fn = unpackFn and unpackFn("return {" .. r.packed .. "}")
    local ok, t = pcall(fn or error)
    if ok and type(t) == "table" then r.steps = t else ns.LogError("unpack", "could not unpack route " .. tostring(r.id)); r.steps = {} end
  end
  return r.steps or {}
end
-- quest IDs in a route without unpacking it
function ns.QuestIds(r)
  if not r then return {} end
  if not r._qids then
    local t = {}
    if r.questIds then for id in r.questIds:gmatch("%d+") do t[tonumber(id)] = true end
    else for _, s in ipairs(ns.Steps(r)) do if s.q then t[s.q] = true end end end
    r._qids = t
  end
  return r._qids
end
function ns.RouteById(id) for _, r in ipairs(ns.Routes()) do if r.id == id then return r end end end
-- a path's zones in order, each once ("Wetlands > Ashenvale > Wetlands" -> Wetlands, Ashenvale)
local function zoneOrder(legs)
  local out, seen = {}, {}
  for z in (legs or ""):gmatch("[^>]+") do
    z = z:gsub("^%s+", ""):gsub("%s+$", "")
    if z ~= "" and not seen[z] then seen[z] = true; out[#out + 1] = z end
  end
  return out
end
-- how well a path (its zones) continues the one you followed (old zones): the zones the two have in common in the same
-- order, over the next PATH_LOOK zones of each, and more for starting in the same zone - what you do next counts most.
-- "Wetlands > Duskwood > Ashenvale > Desolace" is continued by "Wetlands > Ashenvale > Arathi > Desolace" (3 in order,
-- same start), not by "Duskwood > Ashenvale > Stranglethorn > Wetlands" (2 in order): matching only from the old second
-- zone on once took a player standing in the Wetlands off to Ashenvale.
ns.PATH_LOOK = 6
function ns.PathContinuity(old, legs)
  local n, m = math.min(#old, ns.PATH_LOOK), math.min(#legs, ns.PATH_LOOK)
  if n == 0 or m == 0 then return 0 end
  local prev = {}; for j = 0, m do prev[j] = 0 end
  for i = 1, n do
    local row = { [0] = 0 }
    for j = 1, m do
      if old[i] == legs[j] then row[j] = prev[j - 1] + 1 else row[j] = math.max(prev[j], row[j - 1]) end
    end
    prev = row
  end
  local score = prev[m]
  if score > 0 and old[1] == legs[1] then score = score + 1.5 end
  return score
end
-- the route a saved id or title stands for, without switching to it. -> route, exact (false: matched by zone order)
-- A replan can rename your path (its zones changed a little), and a plan made from an older save does not know the
-- path you switched to since: then it is the path that best continues your zone order (ns.PathContinuity), the one
-- the planner marked as yours on a tie, rather than a different path.
function ns.ResolvePath(title)
  if not title then return nil end
  for _, r in ipairs(ns.Routes()) do if r.id == title or r.title == title then return r, true end end
  if not ns.char.routeLegs then return nil end
  local old = zoneOrder(ns.char.routeLegs)
  local best, bestScore = nil, 0
  for _, r in ipairs(ns.MainRoutes()) do
    local score = ns.PathContinuity(old, zoneOrder(r.meta and r.meta.legs))
    if score > 0 and r.continues then score = score + 0.25 end
    if score > bestScore then best, bestScore = r, score end
  end
  -- the planner marks the path it planned as the continuation of yours: take that one if nothing matched
  if not best then for _, r in ipairs(ns.MainRoutes()) do if r.continues then best = r; break end end end
  return best, false
end
-- your saved path is not in this plan and the one you continue on goes somewhere else next (its next three zones
-- differ): said once, in chat and in /fr why - a path never changes under you without a word. -> the text, or nil
function ns.PathSwitchNote(title, pick)
  if not (pick and ns.char and ns.char.routeLegs and pick.meta and pick.meta.legs) then return nil end
  local old, now = zoneOrder(ns.char.routeLegs), zoneOrder(pick.meta.legs)
  -- the same path, or the same path with the zones you've finished dropped off the front (Westfall > Redridge >
  -- Duskwood, Westfall done: Redridge > Duskwood > Wetlands) - not a switch, nothing to say
  for s = 0, 2 do
    local same = true
    for k = 1, 3 do if now[k] ~= nil and now[k] ~= old[k + s] and not (old[k + s] == nil and k > 1) then same = false end end
    if same then return nil end
  end
  local function head(t) local o = {}; for k = 1, math.min(3, #t) do o[k] = t[k] end; return table.concat(o, " > ") end
  return "The new plan does not have the path you were on (" .. head(old) .. "). You are now on the closest one: " .. head(now) .. ". The Paths window (/fr paths) has the others."
end
-- pick by id or by title (titles from older saves); a renamed path is found by its zone order (ns.ResolvePath);
-- nothing at all falls back to the first main path
-- the route saved last time, at login / a new plan: a dungeon or class route you never chose (no path to go back to)
-- was a fallback (a plan file with no path in it put a player on Gnomeregan): back to a leveling path
function ns.SavedRoute()
  local t = ns.char and ns.char.routeTitle
  local r = t and ns.RouteById and ns.RouteById(t)
  -- (only one you picked - Route me, Do it now - is yours; a path you came from long ago doesn't make it so)
  if r and (r.dungeon or r.special) and ns.char.chosenTrip ~= r.id and ns.MainRoutes()[1] then
    if ns.Why then ns.Why("path", "saved on " .. tostring(t) .. ", which you didn't pick: back on a leveling path") end
    return ns.char.returnTo
  end
  return t
end
function ns.SelectRoute(title, quiet)
  local list = ns.Routes()
  local pick, exact = ns.ResolvePath(title)
  -- (never a dungeon or class route by default: a plan file with no path in it put a player on Gnomeregan)
  if not pick then for _, r in ipairs(list) do if not r.dungeon and not r.special then pick = r; break end end end
  pick = pick or ns.MainRoutes()[1]
  if not exact and title and ns.char.routeLegs and pick then
    if ns.Why then ns.Why("path", "your path " .. tostring(title) .. " is not in the new plan; continuing on " .. tostring(pick.id) .. " (closest match to your zone order)") end
    -- your own pick (Paths window, a zone choice) follows the path to its new name
    if ns.char.pinnedPath == title and pick.id and not pick.branch and not pick.dungeon then ns.char.pinnedPath = pick.id end
    local note = ns.PathSwitchNote(title, pick)
    ns.pathSwitch = note and { from = title, to = pick.id, text = note } or nil
    if note and C_Timer and C_Timer.After then C_Timer.After(5, function() ns.Print(note) end) end
  end
  -- leaving a packed route: drop its unpacked steps (they come back from the string if picked again)
  local old = ForeverRouteData
  if old and old ~= pick and old.packed then old.steps = nil end
  if pick then ns.Steps(pick) end
  ForeverRouteData = pick
  ns.char.routeTitle = pick and (pick.id or pick.title) or nil
  -- (not a zone you picked: its one zone is not your path, and the replan read it as the path you follow)
  if pick and not pick.branch and not pick.dungeon and not pick.zoneRoute and pick.meta and pick.meta.legs then ns.char.routeLegs = pick.meta.legs end
  ns.char.progress = ns.char.progress or {}
  local rid = pick and pick.id or "none"
  local p = ns.char.progress[rid] or {}
  ns.char.progress[rid] = p
  p.skipped, p.manualDone, p.history = p.skipped or {}, p.manualDone or {}, p.history or {}
  -- ticks saved by step number (older versions) land on the wrong steps once a route is regenerated: drop them
  for _, t in ipairs({ p.skipped, p.manualDone }) do for k in pairs(t) do if type(k) == "number" then t[k] = nil end end end
  for n = #p.history, 1, -1 do local h = p.history[n]; for _, id in ipairs(h.ids or {}) do if type(id) == "number" then table.remove(p.history, n); break end end end
  ns.char.skipped, ns.char.manualDone, ns.char.history = p.skipped, p.manualDone, p.history
  ns.char.routeId = rid
  -- drop progress tables of routes that no longer exist
  local live = {}; for _, r in ipairs(list) do live[r.id or "none"] = true end
  for k in pairs(ns.char.progress) do if not live[k] then ns.char.progress[k] = nil end end
  if not quiet then ns.Fire("FR_ROUTE_CHANGED"); if ns.Engine then ns.Engine.view = nil; ns.Engine.Refresh() end end
end
-- "where next?" at a zone boundary: the choice for step i of the current route, if it's still open.
-- It stays on that step (your pick is marked) until you leave, so you can change your mind; a branch shows its parent's choice on step 1.
function ns.ChoiceFor(i)
  local data = ForeverRouteData
  if not (data and i) then return nil end
  local owner, at = data, i
  if data.branch then
    if i ~= 1 then return nil end
    owner = ns.RouteById(data.parent); at = data.branchAt
    if not owner then return nil end
  end
  for _, c in ipairs(owner.choices or {}) do
    if c.at == at then
      local key = (owner.id or "") .. "@" .. at
      return c, owner, key
    end
  end
end
-- take an option: stay on the main path, or switch to the branch planned for that zone
function ns.TakeChoice(opt, owner, key)
  ns.char.choices = ns.char.choices or {}
  ns.char.choices[key] = opt.zone
  local want = opt.route or owner.id
  ns.char.pinnedPath = owner.id -- choosing at a zone boundary is your own pick
  if ForeverRouteData ~= ns.RouteById(want) then
    ns.SelectRoute(want)
    ns.Print("Heading to " .. opt.zone .. (opt.next and (" - then " .. opt.next) or "") .. ".")
  else
    ns.Fire("FR_STEP", ns.Engine.Shown())
  end
end
