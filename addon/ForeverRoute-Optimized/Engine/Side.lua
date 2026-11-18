-- The route engine, a quest giver next to you with a quest your plan could not hold (side quests). Part of Engine.lua, split out as is (the code review: Engine.lua was 13 features in
-- one file); loaded right after it, so its event handlers run in the same order as before.
local _, ns = ...
local Engine = ns.Engine
local State = ns.State
local function steps() return ForeverRouteData and ForeverRouteData.steps or {} end
local function key(i) return Engine.Key(i) end
local keyCache = Engine._keyCache
local HBD = LibStub("HereBeDragons-2.0")
local wpos = ns.Util.WPos

----------------------------------------------------------------------------------------------------------------
-- A quest giver right next to you with a quest your plan could not hold (ns.SIDE_QUESTS, QuestData.lua: the giver in
-- a capital, or an objective in another zone than the giver - the planner takes a leg's quests from the givers in the
-- leg's zones and drops one with an objective outside them). A Noble Brew: Zardeth stands by the warlock trainers in
-- Stormwind, a Tear of Tilloa lies by Darkshire and a Musquash Root in the Wetlands, both on a level 31's route - and
-- the card said nothing ("why doesn't this end up in my list since I'm right here?").
-- The rule, kept small: you stand within SIDE_NEAR_YD of the giver; the quest is yours to take (side, class, level,
-- what comes before it) and near your level; it is not on your route, not "not doing", not turned down by the giver;
-- every objective lies within SIDE_OBJ_YD of a stop still ahead (while the quest is not gray there) and so does the
-- hand-in, or it is where you are. One offer at a time: a pick-up as the next step, with the reason on the card and in
-- the why log. Walk on (SIDE_HOLD_YD) and it is passed; come back and it is there again. Once it is in your log its
-- objectives become stops where they cost least; the hand-in is added when it is finished (applyInserts).
----------------------------------------------------------------------------------------------------------------
Engine.SIDE_NEAR_YD = 60   -- the giver is this close: "right here"
Engine.SIDE_HOLD_YD = 150  -- the offer stands while you are within this of the giver
Engine.SIDE_OBJ_YD = 800   -- an objective (or the hand-in) is on your route within this of a stop ahead (the Musquash Root
                           -- lies 740 yd from the Wetlands' nearest quest spots: about four minutes there and back on foot)
Engine.SIDE_BELOW = 3      -- the quest at most this many levels below you (full XP, or close to)
Engine.SIDE_ABOVE = 3      -- ... or above you
Engine.SIDE_LATE = 4       -- a stop ahead counts while the plan has you at most this many levels above the quest
Engine.SIDE_XP = 25        -- XP per quest level it must give: a 230 XP errand at 28 is not worth a line on the card
local function sideMine(d)
  local f = UnitFactionGroup and UnitFactionGroup("player")
  if d.f and f and d.f ~= (f == "Horde" and "H" or "A") then return false end
  if d.cl then local _, c = UnitClass("player"); if not (c and ("," .. d.cl .. ","):find("," .. c .. ",", 1, true)) then return false end end
  if d.rc then local _, r = UnitRace("player"); if not (r and ("," .. d.rc .. ","):find("," .. r .. ",", 1, true)) then return false end end
  return true
end
Engine.SideMine = sideMine -- (ItemQuests.lua: the same check for a quest an item starts)
local sideIndex -- [map] = { quest ids whose giver stands there }
local function sideOn(m)
  if not sideIndex or sideIndex.src ~= ns.SIDE_QUESTS then
    sideIndex = { src = ns.SIDE_QUESTS }
    for q, d in pairs(ns.SIDE_QUESTS or {}) do local gm = d.g[2]; sideIndex[gm] = sideIndex[gm] or {}; table.insert(sideIndex[gm], q) end
  end
  return sideIndex[m] or {}
end
local function yardsOf(m, x, y, px, py, pinst)
  local a, b, inst = HBD:GetWorldCoordinatesFromZone(x, y, m)
  if not a or inst ~= pinst then return nil end
  return math.sqrt((a - px) ^ 2 + (b - py) ^ 2), a, b
end
local mapNameOf = ns.Util.MapName
-- Does this quest fit your route? -> true, the zones its objectives are in; or false and why not
function Engine.SideFits(q)
  local d = ns.SIDE_QUESTS and ns.SIDE_QUESTS[q]
  if not d then return false, "not a side quest" end
  local lvl = UnitLevel("player") or 1
  if not sideMine(d) then return false, "not for you" end
  if lvl < d.r then return false, "needs level " .. d.r end
  if d.l < lvl - Engine.SIDE_BELOW or d.l > lvl + Engine.SIDE_ABOVE then return false, "not near your level" end
  if d.xp < Engine.SIDE_XP * d.l then return false, "little XP" end
  if State.IsCompleted(q) or State.OnQuest(q) then return false, "yours already" end
  if ns.Nope(q) then return false, "you are not doing it" end
  local needs = ns.Avail and ns.Avail.Needs and ns.Avail.Needs(q)
  if needs then return false, needs end
  if ns.Avail and ns.Avail.Unavailable(q) then return false, "the giver has nothing for you" end
  if ns.char.skipped["accept:" .. q .. ":" .. d.n .. "#1"] then return false, "you skipped it" end
  for _, p in ipairs(d.pre or {}) do if not State.IsCompleted(p) then return false, "something comes before it" end end
  if d.any then
    local one = false
    for _, p in ipairs(d.any) do one = one or State.IsCompleted(p) end
    if not one then return false, "something comes before it" end
  end
  for _, x in ipairs(d.ex or {}) do if State.IsCompleted(x) or State.OnQuest(x) then return false, "not with a quest you have or did" end end
  if State.LogFull and State.LogFull() then return false, "your quest log is full" end
  -- the stops still ahead of you, by zone - while the quest is not gray there
  -- (from the plan's own next step: the card may be on a later one you happen to stand at)
  local list, ahead, from = steps(), {}, Engine.planned or Engine.current or 1
  for j = 1, from - 1 do if list[j].q == q then return false, "on your route" end end
  for j = from, #list do
    local s = list[j]
    if s.q == q then return false, "on your route" end
    local L = s.lvl or Engine.PlanLevel(j)
    if s.m and s.x and not s.side and not s.unknown and (not L or L <= d.l + Engine.SIDE_LATE) and Engine.Status(j) ~= "done" then
      local a, b, inst = HBD:GetWorldCoordinatesFromZone(s.x, s.y, s.m)
      if a then ahead[s.m] = ahead[s.m] or {}; table.insert(ahead[s.m], { a, b, inst }) end
    end
  end
  local function near(m, x, y)
    for _, w in ipairs(ahead[m] or {}) do
      local dd = yardsOf(m, x, y, w[1], w[2], w[3])
      if dd and dd <= Engine.SIDE_OBJ_YD then return true end
    end
    return false
  end
  local zones, seen = {}, {}
  for _, o in ipairs(d.o or {}) do
    local at
    for k = 3, #o do local p = o[k]; if near(p[1], p[2], p[3]) then at = p[1]; break end end
    if not at then return false, o[2] .. " is nowhere near your route" end
    if not seen[at] then seen[at] = true; zones[#zones + 1] = mapNameOf(at) end
  end
  -- the hand-in: where you are (nothing to fetch), or near a stop ahead
  local here = State.Position()
  if not ((not d.o and d.e[2] == here) or near(d.e[2], d.e[3], d.e[4])) then return false, "its hand-in (" .. d.e[1] .. ") is nowhere near your route" end
  return true, zones
end
local sideSteps, sideAt, sideX, sideY = {}, -100, nil, nil -- the pick-ups offered on this step list; when and where you last looked around
local sideNo = {} -- [quest] = when it last did not fit (asked again after SIDE_AGAIN s: the answer walks the whole route)
Engine.SIDE_AGAIN = 30
ns.On("FR_ROUTE_CHANGED", function() wipe(sideSteps); wipe(sideNo); sideAt = -100 end)
-- called with the focus, about once a second with your position (force: look now)
function Engine.SideOffer(px, py, pinst, force)
  local d = ForeverRouteData
  if not (ns.SIDE_QUESTS and px and Engine.current and d and d.steps) or d.dungeon or d.special or d.branch or Engine.view then return false end
  local now = GetTime and GetTime() or 0
  -- (again after 3 s, or as soon as you have moved 10 yd: walking up to a giver is noticed at once)
  if not force and now - sideAt < 3 and sideX and (px - sideX) ^ 2 + (py - sideY) ^ 2 < 100 then return false end
  sideAt, sideX, sideY = now, px, py
  if sideSteps.list ~= d.steps then wipe(sideSteps); wipe(sideNo); sideSteps.list = d.steps end -- (another step list: its own offers)
  local changed, standing = false, false
  for k = #sideSteps, 1, -1 do
    local s = sideSteps[k]
    if State.OnQuest(s.q) or State.IsCompleted(s.q) then table.remove(sideSteps, k)
    else
      local dd = yardsOf(s.m, s.x, s.y, px, py, pinst)
      local away = not (dd and dd <= Engine.SIDE_HOLD_YD)
      if away ~= (s.away or false) then s.away = away; changed = true end
      standing = standing or not away
    end
  end
  if not standing and not (ns.Is(UnitOnTaxi, "player") or ns.Is(UnitIsDeadOrGhost, "player") or ns.Is(IsInInstance)) then
    local pm = State.Position()
    local best, bestD, bestZones
    for _, q in ipairs(sideOn(pm)) do
      local g = ns.SIDE_QUESTS[q].g
      local dd = yardsOf(g[2], g[3], g[4], px, py, pinst)
      if dd and dd <= Engine.SIDE_NEAR_YD and (not bestD or dd < bestD) then
        local offered = false
        for _, s in ipairs(sideSteps) do offered = offered or s.q == q end
        local ok, zones = false, nil
        if not offered and (force or not sideNo[q] or now - sideNo[q] >= Engine.SIDE_AGAIN) then
          ok, zones = Engine.SideFits(q)
          sideNo[q] = not ok and now or nil
          -- (why not, for the quests you could take: "why doesn't this end up in my list" has an answer in /fr why)
          if not ok and zones ~= "not for you" and zones ~= "yours already" and zones ~= "not near your level" and ns.Why then
            ns.Why("side", ns.SIDE_QUESTS[q].n .. " (" .. g[1] .. ", right here) is not offered: " .. tostring(zones))
          end
        end
        if ok then best, bestD, bestZones = q, dd, zones end
      end
    end
    if best then
      local sq = ns.SIDE_QUESTS[best]
      local where = #bestZones > 0 and ("what it asks for (" .. table.concat(bestZones, ", ") .. ") is on your route") or ("it is handed in right here (" .. sq.e[1] .. ")")
      -- (sq.u: work the quest data lists none of - Brewer's Trade - so nothing can be said about where it is)
      local note = sq.u and (sq.n .. " is offered here (follow your quest log for where). " .. sq.xp .. " xp.")
        or ("Not in your plan, but you are right here: " .. where .. ". " .. sq.xp .. " xp.")
      if sq.u then where = "follow your quest log for where" end
      local step = { k = "accept", q = best, name = sq.n, level = sq.l, npc = sq.g[1], m = sq.g[2], x = sq.g[3], y = sq.g[4], r = 6, inserted = true, side = true, note = note }
      local why = string.format("%s is %d yd away and %s; a plan cannot hold a quest like this (the giver in a city, or an objective in another zone than the giver)", sq.g[1], bestD, where)
      -- as the plan's next step (a step you are standing at and the card holds stays first)
      if Engine.InsertStop(step, px, py, pinst, { at = Engine.planned or Engine.current, why = why }) then sideSteps[#sideSteps + 1] = step; changed = true end
    end
  end
  if changed then Engine.Refresh() end
  return changed
end
-- a side quest in your log (one this rule offered, or any other of that kind you picked up): a stop for each objective
-- still open, where it costs least; and its hand-in when it is finished and the plan has no place for it.
-- A quest an item starts (ns.ITEM_QUESTS, offered by ItemQuests.lua) is fitted in the same way: no plan can count on
-- its drop either.
local sideMiss = {}
local function sideData(q) return (ns.SIDE_QUESTS and ns.SIDE_QUESTS[q]) or (ns.ITEM_QUESTS and ns.ITEM_QUESTS[q]) end
local function sideStops()
  local list = steps()
  local d = ForeverRouteData
  if not ((ns.SIDE_QUESTS or ns.ITEM_QUESTS) and d and #list > 0 and Engine.current) or d.dungeon or d.special or d.branch then return false end
  local added = false
  local zoneMaps -- (lazy: a picked zone's maps, Stitch.ZoneMaps; false on your plan)
  local px, py, pinst = HBD:GetPlayerWorldPosition()
  -- (also the ones in your log from before the addon knew about them: A Noble Brew, picked up by hand)
  ns.char.side = ns.char.side or {}
  for _, t in ipairs({ ns.SIDE_QUESTS or {}, ns.ITEM_QUESTS or {} }) do
    for q in pairs(t) do if not ns.char.side[q] and State.OnQuest(q) then ns.char.side[q] = true end end
  end
  -- (the quests first, then each with a pause after it in a route job: a quest picked up meanwhile is not added to the
  -- table being walked)
  local qs = {}; for q in pairs(ns.char.side) do qs[#qs + 1] = q end
  for _, q in ipairs(qs) do
    ns.MaybeYield()
    local sq = sideData(q)
    -- (what its stops say they are for: the item that started it, or a side quest you picked up)
    local _, itemName = next((sq and sq.it) or {})
    local forWhat = itemName and ("the quest your " .. itemName .. " started") or "the side quest you picked up"
    if not sq or State.IsCompleted(q) then ns.char.side[q] = nil
    elseif State.OnQuest(q) and not (ns.Nope(q)) then
      -- (a quest the plan has steps of its own for is the plan's)
      local has, planned = {}, false
      for _, s in ipairs(list) do if s.q == q then has[s.k .. ":" .. tostring(s.match or "")] = true; planned = planned or (s.k ~= "accept" and not s.side) end end
      if planned then -- nothing to add
      elseif State.QuestReady(q) then
        if sq.e and not has["turnin:"] and not (ForeverRouteEnders and ForeverRouteEnders[q]) then
          local step = { k = "turnin", q = q, name = sq.n, level = sq.l, npc = sq.e[1], m = sq.e[2], x = sq.e[3], y = sq.e[4], r = 6, inserted = true, side = true, note = "Added: you finished this one on the way." }
          -- (weighed like the plan's own finished quests: waiting for the cheapest spot can lose more XP than going now -
          -- it was placed by walking cost alone, levels later and gray by then - code review)
          local opts
          if tonumber(sq.l) and Engine.HandInNow then
            local now, lost, secs = Engine.HandInNow(step, tonumber(sq.l), Engine.InsertStop(step, px, py, pinst, { dry = true }))
            if now then opts = { at = now, why = string.format("worth going now: waiting would lose ~%d XP, ~%d min there and back", lost, math.floor(2 * secs / 60 + 0.5)) } end
          end
          if Engine.InsertStop(step, px, py, pinst, opts) then added = true end
        end
      else
        for _, o in ipairs(sq.o or {}) do
          local open = Engine.ObjectiveFor({ q = q, match = o[2] }, true)
          -- (no place last time: not asked again until the route changes, you've moved 60 yd or 30 s have passed -
          -- every quest log event re-ran the whole search and said so in /fr why)
          local mk = q .. ":" .. o[2]
          local miss = sideMiss[mk]
          local recent = miss and miss.list == list and px and miss.x and (px - miss.x) ^ 2 + (py - miss.y) ^ 2 < 3600 and GetTime() - miss.t < 30
          if not has["obj:" .. o[2]] and not (open and open.finished) and not recent then
            local function stop(p)
              return { k = "obj", q = q, name = sq.n, level = sq.l, text = o[1] .. " " .. o[2], match = o[2], loot = o[1] == "Collect" or nil, m = p[1], x = p[2], y = p[3], r = 60, inserted = true, side = true,
                note = "For " .. forWhat .. ": here it costs least." }
            end
            -- (only while the quest is worth it: up to the last step the plan has you at most SIDE_LATE levels above it)
            local last -- (a plan without levels: anywhere)
            for j in ipairs(list) do local L = Engine.PlanLevel(j); if L then last = last or 0; if L <= sq.l + Engine.SIDE_LATE then last = j end end end
            -- (on a zone you picked, only on that zone's maps, as the quests you carry there (Stitch.Carried): a side
            -- quest's objective in the next zone over went first on the card after picking Thousand Needles, and sent
            -- you to Stonetalon - mutate sweep. Back on your plan it is fitted again)
            if d.zoneRoute and zoneMaps == nil then zoneMaps = (ns.Stitch and ns.Stitch.ZoneMaps and ns.Stitch.ZoneMaps(d)) or false end
            local best, bestCost
            for k = 3, #o do
              if not zoneMaps or zoneMaps[o[k][1]] then
                local at, cost = Engine.InsertStop(stop(o[k]), px, py, pinst, { dry = true, maxCost = 2.5 * Engine.SIDE_OBJ_YD, maxIndex = last })
                if at and (not best or (cost or math.huge) < bestCost) then best, bestCost = o[k], cost or math.huge end
              end
            end
            -- (never a long way round: with no place close to the route yet, it waits - asked again as you go)
            if best and Engine.InsertStop(stop(best), px, py, pinst, { maxCost = 2.5 * Engine.SIDE_OBJ_YD, maxIndex = last, why = "a side quest in your log (" .. sq.n .. "): where it costs least" }) then
              added = true; sideMiss[mk] = nil
            else
              sideMiss[mk] = { list = list, x = px, y = py, t = GetTime() }
              if ns.Why then ns.Why("side", sq.n .. ": no place on your route for " .. o[2] .. " yet") end
            end
          end
        end
      end
    end
  end
  return added
end
Engine.SideStops = sideStops
ns.On("QUEST_ACCEPTED", function(a, b)
  local q = type(b) == "number" and b or a
  if q and sideData(q) and ns.char then ns.char.side = ns.char.side or {}; ns.char.side[q] = true end
end)
ns.On("FR_STATE", function() if sideStops() then Engine.Refresh() end end)
ns.On("FR_LOADED", function() C_Timer.After(3.2, function() if sideStops() then Engine.Refresh() end end) end)
ns.On("FR_ROUTE_CHANGED", function() Engine.After(0.55, "side", function() if Engine.SideStops() then Engine.Refresh() end end) end)
