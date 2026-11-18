-- Chain starts for a zone you picked (the design for zones and chains, stage 3): when a quest there needs an earlier
-- quest you haven't handed in, the steps for it are cut from your own plan (it already has them, in order) and put in
-- front of that quest when the detour is small; otherwise the quest waits and you are told what it needs and where.
-- Nothing is saved: the splice is made again each time the zone's route is unpacked.
--   ns.Stitch.Closure(q, isDone, onPlan)  the quests q needs first, not done, prerequisites before what needs them
--   ns.Stitch.Packet(steps, ids, isDone, onQuest)  the steps of those quests cut from a route -> copies, missing ids
--   ns.Stitch.Splice()  on a zone route: the chain starts it needs, spliced or noted
--   ns.STITCH  the limits (the simulator can set them: FR_SIM_STITCH)
local _, ns = ...
local Stitch = {}
ns.Stitch = Stitch

-- maxYards: the most a chain start may add to the trip (Engine.InsertStop, per stop); maxSteps: the most steps one
-- chain start may add; minShare: the least XP it must pay (its own quests and the one it opens), as a share of your
-- level; grayMargin: a quest it opens that is gray within this many levels isn't worth it
ns.STITCH = ns.STITCH or { maxYards = 3000, maxSteps = 14, minShare = 0.03, grayMargin = 1 }

-- the quests q needs handed in first (QUEST_PRE: g all of, s any one of - the one on your plan when there is one),
-- those not done, each after its own prerequisites. A loop in the data stops where it closes.
function Stitch.Closure(q, isDone, onPlan)
  local out, seen = {}, {}
  local function visit(id, depth)
    if seen[id] or depth > 40 then return end
    seen[id] = true
    local pre = ns.QUEST_PRE and ns.QUEST_PRE[id]
    if pre then
      for _, p in ipairs(pre.g or {}) do if not isDone(p) then visit(p, depth + 1) end end
      if pre.s and #pre.s > 0 then
        local any = false
        for _, p in ipairs(pre.s) do if isDone(p) then any = true; break end end
        if not any then
          local pick = pre.s[1]
          if onPlan then for _, p in ipairs(pre.s) do if onPlan[p] then pick = p; break end end end
          visit(pick, depth + 1)
        end
      end
    end
    if id ~= q then out[#out + 1] = id end
  end
  visit(q, 0)
  return out
end

local PACKET_KIND = { accept = true, obj = true, turnin = true }
-- the steps of quests ids, in the route's order: pick-ups, objectives, hand-ins with a place (no flights or hearths:
-- the trip between is the card's). missing: a quest whose pick-up the route doesn't have (and you don't carry)
function Stitch.Packet(list, ids, isDone, onQuest)
  local want, has = {}, {}
  for _, id in ipairs(ids) do want[id] = true end
  local out = {}
  for _, s in ipairs(list or {}) do
    local q = s.q
    if q and want[q] and PACKET_KIND[s.k] and s.m and s.x and not s.unknown and not isDone(q) then
      if s.k == "accept" then has[q] = true end
      if not (s.k == "accept" and onQuest(q)) then
        local copy = {}; for k, v in pairs(s) do copy[k] = v end
        copy.inserted, copy.id, copy.wp = true, nil, nil
        out[#out + 1] = copy
      end
    end
  end
  local missing = {}
  for _, id in ipairs(ids) do if not has[id] and not onQuest(id) then missing[#missing + 1] = id end end
  return out, missing
end

local function questName(q, list)
  for _, s in ipairs(list or {}) do if s.q == q and s.name then return s.name, s.zone end end
  local d = ns.SIDE_QUESTS and ns.SIDE_QUESTS[q]
  if d and d.n then return d.n, nil end
  local n = ns.Engine and ns.Engine.QuestName and ns.Engine.QuestName(q)
  if n and not n:find("^quest %d") then return n, nil end
  -- (a quest the plan and the game's cache don't name: by its chain, where it is)
  local ch = ns.ChainOf and ns.ChainOf(q)
  local z = ch and ns.AREA_NAME and ns.AREA_NAME[ch.z[ch.at]]
  if ch then return "an earlier part of " .. ch.name, z end
  return "an earlier quest", nil
end

-- the maps a zone's route quests on: three quest steps or more there (a step or two across the boat - an Auberdine
-- hand-in on the Wetlands route - is not where the zone is: Darkshore's quests in your log aren't the Wetlands')
Stitch.ZONE_MIN_STEPS = 3
function Stitch.ZoneMaps(d)
  local n, maps = {}, {}
  for _, t in ipairs((d and d.steps) or {}) do if not t.inserted and t.m and (t.k == "accept" or t.k == "obj" or t.k == "turnin") then n[t.m] = (n[t.m] or 0) + 1 end end
  for m, c in pairs(n) do if c >= Stitch.ZONE_MIN_STEPS then maps[m] = true end end
  return maps
end

-- the quests in your log your plan does on a zone route's maps (Stitch.ZoneMaps), its objectives or hand-in, that the
-- zone's route doesn't have itself: -> { q, ... } in plan order, the maps. What a pick of the zone takes along (Splice),
-- and which hand-ins Where to? counts for the zone (ns.ZoneChoices): the same rule, so a row offered for a hand-in has it
-- on the card once picked.
-- (a quest a pick takes along: in your log, not handed in, not one you said no to, and not one whose work is red to you -
-- t, a step of it: it waits for your level, Engine.TooHigh. Spliced, it read "wait" on the card - code review)
local function carries(q, t)
  local S, E = ns.State, ns.Engine
  if not (S.OnQuest(q) and not S.IsCompleted(q) and not ns.Nope(q)) then return false end
  return not (t and E and E.TooHigh and not S.QuestReady(q) and E.TooHigh(t))
end
function Stitch.Carried(steps, mainSteps)
  local maps = Stitch.ZoneMaps({ steps = steps })
  local here = {}; for _, t in ipairs(steps or {}) do if t.q then here[t.q] = true end end
  local carried, seenQ = {}, {}
  for _, t in ipairs(mainSteps or {}) do
    local q = t.q
    if q and not seenQ[q] and not here[q] and (t.k == "obj" or t.k == "turnin") and t.m and maps[t.m] and carries(q, t) then
      seenQ[q] = true; carried[#carried + 1] = q
    end
  end
  return carried, maps
end
-- the same quests as a set, from your log's quests on your plan (ns.LogQuestsOn: order, and maps[q] - the maps of q's
-- objectives and hand-in there), for Where to?'s rows: no walk over your whole plan per row. memo keeps carries(q) for
-- the look. -> { [q] = true }
function Stitch.CarriedFrom(steps, on, memo)
  local maps, out, here = Stitch.ZoneMaps({ steps = steps }), {}, nil
  for _, q in ipairs(on.order) do
    local mm = on.maps[q]
    local hit = false
    if mm then for m in pairs(mm) do if maps[m] then hit = true; break end end end
    if hit then
      if not here then here = {}; for _, t in ipairs(steps) do if t.q then here[t.q] = true end end end
      if not here[q] then
        local c = memo[q]
        if c == nil then c = carries(q, on.at and on.at[q]) and true or false; memo[q] = c end
        if c then out[q] = true end
      end
    end
  end
  return out
end

-- a stop after a route's last step, as InsertStop puts one there (its stretch, the step numbers, the engine's key cache)
local function appendStop(list, new)
  local last = list[#list]
  if last then new.sec = last.sec end
  new.added = true
  list[#list + 1] = new
  new.id = #list
  local E = ns.Engine
  if E and E._keyCache then E._keyCache[list] = nil end
  if ns.Why then ns.Why("insert", "added " .. (new.k or "") .. " " .. (new.name or new.dest or "") .. " as step " .. #list .. " (nothing else left on this route: the quests you carry here)") end
  return #list
end

-- the last splice's outcome, for the simulated player's report and /fr why: { spliced = n, notes = { text } }
Stitch.last = nil

function Stitch.Splice()
  local d, E, S = ForeverRouteData, ns.Engine, ns.State
  if not (d and d.zoneRoute and d.steps) or not (E and E.InsertStop) then return false end
  -- nothing of the zone's own left for you (E.current nil): no chain starts (they go before a quest here), but the
  -- quests you carry still come, after its last step (InsertStop needs a current step: a zone whose own quests were all
  -- done was offered for the hand-in you carried there, and picking it left the card empty - mutate sweep)
  local empty = not E.current
  -- chain starts once per unpacked route; the quests you carry every time you come to it (back to a zone you had picked
  -- before, its route still unpacked: what you picked up since was left off - the simulated zone-hopper's check)
  local firstTime = not empty and not d.steps._stitched
  local P = ns.STITCH
  local main = ns.Util.PlanRoute()
  local mainSteps = main and ns.Steps(main) or {}
  local onPlan = {}; for _, s in ipairs(mainSteps) do if s.q and s.k == "accept" then onPlan[s.q] = true end end
  local isDone = function(q) return S.IsCompleted(q) end
  local onQuest = function(q) return S.OnQuest(q) end
  local L = (UnitLevel and UnitLevel("player")) or 1
  local px, py, pinst
  local HBD = LibStub and LibStub("HereBeDragons-2.0", true)
  if HBD then px, py, pinst = HBD:GetPlayerWorldPosition() end
  local res = { spliced = 0, notes = {} }
  local done = {} -- quests already spliced (two quests here needing the same start)
  local i = firstTime and E.current or (#d.steps + 1)
  while i <= #d.steps do
    ns.MaybeYield() -- (a route job: a step a pause)
    local s = d.steps[i]
    if s.k == "accept" and s.q and not s.inserted and not isDone(s.q) and not onQuest(s.q) and ns.PrereqsMet and not ns.PrereqsMet(s.q) then
      local ids = Stitch.Closure(s.q, function(q) return isDone(q) or done[q] end, onPlan)
      local packet, missing = Stitch.Packet(mainSteps, ids, isDone, onQuest)
      local name = s.name or questName(s.q)
      local why
      local ql = tonumber(s.level) or (ns.QuestLevel and ns.QuestLevel(s.q))
      local xp = ns.QuestXp and (ns.QuestXp(s.q, L) or 0) or 0
      for _, id in ipairs(ids) do xp = xp + (ns.QuestXp and ns.QuestXp(id, L) or 0) end
      local need = (P.minShare or 0) * ((ns.XP_TO_LEVEL and ns.XP_TO_LEVEL[L]) or 0)
      if #missing > 0 then
        local mn, mz = questName(missing[1], mainSteps)
        why = name .. " - needs " .. mn .. (mz and (" (" .. mz .. ")") or "") .. " first"
      elseif #packet == 0 then
        why = nil -- (everything it needs is in your log: its hand-ins are on the route already)
      elseif #packet > P.maxSteps then
        why = name .. " - its chain start is " .. #packet .. " steps, too long a detour"
      elseif ql and E.GrayAt and ql <= E.GrayAt(L + P.grayMargin) then
        why = name .. " - gray before you'd get to it"
      elseif xp < need then
        why = name .. " - not worth the detour"
      elseif ns.char.stitchNo and ns.char.stitchNo[s.q] then
        why = nil -- (you said no to this chain start: not offered again)
      else
        -- in order, each after the one before, all before the quest that needs them
        local added, minI, ok, yards = {}, E.current, true, 0
        for _, c in ipairs(packet) do
          local target; for j = minI, #d.steps do if d.steps[j] == s then target = j; break end end
          local at = target and E.InsertStop(c, px, py, pinst, { minIndex = minI, maxIndex = target, maxCost = P.maxYards, why = "a chain start for " .. name })
          if not at then ok = false; break end
          yards = yards + (E.lastInsertCost or 0)
          c.chainStart = s.q
          added[#added + 1] = c; minI = at + 1
        end
        if ok then
          -- what it costs and what it opens: the detour at your speed plus the stops, and the XP of it and what it opens
          -- ("+4 min, opens ~12k XP" - a detour without its cost read as being sent across a zone for one quest)
          local secs = yards / ((ns.Travel and ns.Travel.Speed and ns.Travel.Speed()) or 7) + 10 * #added
          local cost = string.format("+%d min, opens ~%s XP", math.max(1, math.floor(secs / 60 + 0.5)), (ns.Paths and ns.Paths.Short and ns.Paths.Short(xp)) or tostring(xp))
          for _, c in ipairs(added) do c.note = "Chain start for " .. name .. " (" .. cost .. ")."; c.chainCost = cost end
          res.costs = res.costs or {}; res.costs[#res.costs + 1] = name .. ": " .. cost
          res.spliced = res.spliced + #added
          for _, id in ipairs(ids) do done[id] = true end
        else
          -- (all or nothing: half a chain start is a walk for nothing)
          for _, c in ipairs(added) do for j = #d.steps, 1, -1 do if d.steps[j] == c then table.remove(d.steps, j); break end end end
          local mn, mz = questName(ids[1], mainSteps)
          why = name .. " - needs " .. mn .. (mz and (" (" .. mz .. ")") or "") .. " first, too far from here"
        end
      end
      if why then res.notes[#res.notes + 1] = why; if ns.Why then ns.Why("stitch", "left out: " .. why) end end
    end
    i = i + 1
  end
  -- The quests you carry here. A zone's route has its own quests only: the ones in your log that your plan does in this
  -- zone were nowhere on it, and the card sent you to the zone route's first pick-up across the zone with 27 quests in
  -- your log, most of them there (Stranglethorn, tester). Their objectives and hand-ins on this zone's maps are cut from
  -- your plan and put where each costs least, objectives before the hand-in. A hand-in elsewhere stays on your plan
  -- (finished, its hand-in is added where it costs least anyway: Engine applyInserts).
  local carried, maps = Stitch.Carried(d.steps, mainSteps)
  local tripAdded = false
  local carriedN, carriedQ = 0, 0
  res.carriedTried = {}
  for _, q in ipairs(carried) do
    ns.MaybeYield()
    res.carriedTried[q] = true
    local packet = Stitch.Packet(mainSteps, { q }, isDone, onQuest)
    local minI, any = E.current, false
    for _, c in ipairs(packet) do
      if maps[c.m] and c.k ~= "accept" then
        local at
        if empty and not tripAdded then
          -- (the way there first, as the zone's own route starts: its flight to the zone, unless you are on its maps)
          tripAdded = true
          local here = ns.State.Position and ns.State.Position()
          if not (here and maps[here]) then
            for _, t in ipairs(d.steps) do
              if t.k == "fly" and t.to and (t.dest == d.zoneName or maps[t.to]) then
                local trip = {}; for k2, v in pairs(t) do trip[k2] = v end
                trip.id, trip.wp, trip.manual = nil, nil, nil
                appendStop(d.steps, trip); break
              end
            end
          end
        end
        if empty then at = appendStop(d.steps, c)
        else at = E.InsertStop(c, px, py, pinst, { minIndex = minI, why = "a quest you carry, done here" }) end
        if at then c.note = "In your log: done here."; minI = at + 1; carriedN = carriedN + 1; any = true end
        if not at then res.notes[#res.notes + 1] = (c.name or questName(q)) .. " (in your log) - no place on this route for its " .. c.k .. " (step " .. tostring(E.current) .. " of " .. #d.steps .. ")"; if ns.Why then ns.Why("stitch", "carried: " .. res.notes[#res.notes]) end end
      end
    end
    if any then carriedQ = carriedQ + 1 end
  end
  res.carried, res.carriedQuests = carriedN, carriedQ
  -- (stitched once it is done: a splice dropped half way runs again)
  if not empty then d.steps._stitched = true end
  Stitch.last = res
  if carriedQ > 0 then ns.Print(carriedQ .. " quest" .. (carriedQ == 1 and "" or "s") .. " from your log added to this zone's route (" .. carriedN .. " step" .. (carriedN == 1 and "" or "s") .. ").") end
  if res.spliced > 0 then ns.Print(res.spliced .. " step" .. (res.spliced == 1 and "" or "s") .. " added first, the start of a chain this zone needs (" .. table.concat(res.costs or {}, "; ") .. "). \"Skip chain start\" on the card if you'd rather not.") end
  if #res.notes > 0 then ns.Print("Left out here: " .. res.notes[1] .. (#res.notes > 1 and (" (+" .. (#res.notes - 1) .. " more: /fr why)") or "") .. ".") end
  return res.spliced > 0 or carriedN > 0
end

-- "Skip chain start": that chain start leaves this route, and is never spliced in again (Stitch.Splice)
function Stitch.Refuse(q)
  if not q then return 0 end
  ns.char.stitchNo = ns.char.stitchNo or {}
  ns.char.stitchNo[q] = true
  local n = ns.Engine.RemoveSteps(function(s) return s.chainStart == q end)
  if ns.Why then ns.Why("stitch", "you skipped a chain start (" .. n .. " steps)") end
  ns.Engine.Refresh()
  return n
end

ns.On("FR_ROUTE_CHANGED", function() ns.Engine.After(0.7, "stitch", function() if Stitch.Splice() then ns.Engine.Refresh() end end) end)
-- and at login (a /reload, the next session): the route you were on is selected quietly, with no FR_ROUTE_CHANGED, and a
-- zone route is unpacked afresh - the quests you carry there were gone from it. A level 40 on Stranglethorn after a
-- /reload had The Second Rebellion and Some Assembly Required in the log, "off-route", never on the card (tester).
-- After the other login stages (hand-ins 3 s, side quests 3.2 s, side trips 3.5 s), as after a pick; nothing on a plan.
Stitch.LOGIN_DELAY = 3.7
function Stitch.OnLogin() if Stitch.Splice() then ns.Engine.Refresh() end end
ns.On("FR_LOADED", function() ns.Engine.After(Stitch.LOGIN_DELAY, "stitch", Stitch.OnLogin) end)
