-- Step engine: decides which step is current from live quest state, like a hand-written guide's conditions.
-- Steps (from Route.lua): { id, k = kind, q = questID, name, npc, m = uiMapID, x, y (0-1), r = arrive radius, match = objective
--   text, text, note, warn, minLevel, level, lvl (planned level here), xp, to (destination map), bind, fp, item, target, sec }
local _, ns = ...
local Engine = {}
ns.Engine = Engine
local State = ns.State -- (State.lua loads first: the .toc)

Engine.current = nil  -- index of the first step that still needs doing
Engine.view = nil     -- an earlier/later step being looked at (Back, list); never changes progress
local quiet = true    -- no completion animation for the catch-up refresh at login

local function steps() return ForeverRouteData and ForeverRouteData.steps or {} end
-- Ticks and skips are stored against the step itself, not its number: kind + quest + what it targets, plus which
-- occurrence it is. Regenerating the route shifts step numbers; these keys stay on the same step.
local keyCache = setmetatable({}, { __mode = "k" })
Engine._keyCache = keyCache -- (Engine/Inserts.lua)
function Engine.Key(i)
  local list = steps()
  local c = keyCache[list]
  if not c then
    c = {}; local seen = {}
    for j, s in ipairs(list) do
      local base = (s.k or "?") .. ":" .. tostring(s.q or "") .. ":" .. tostring(s.match or s.text or s.dest or s.name or s.npc or s.fp or s.bind or "")
      seen[base] = (seen[base] or 0) + 1
      c[j] = base .. "#" .. seen[base]
    end
    keyCache[list] = c
  end
  return c[i]
end
local function key(i) return Engine.Key(i) end

-- noElim: without the elimination pass (it asks about the quest's other steps, which would ask about this one)
function Engine.ObjectiveFor(step, noElim)
  local q = State.Quest(step.q)
  if not q or not q.on then return nil end
  if step.unknown then return nil end -- (the quest's own words, no objective's: the card shows all of the quest's lines)
  if step.match then
    -- the exact name first ("Murloc slain" for "Murloc"), then any objective containing it: "Murloc" alone matched
    -- "Murloc Streamrunner slain" and the card waited on the wrong objective
    local m = step.match:lower()
    local loose
    for _, o in ipairs(q.objectives) do
      local t = o.text:lower()
      if t:sub(1, #m) == m and (t:sub(#m + 1, #m + 1) == ":" or t:sub(#m + 1, #m + 6) == " slain") then return o end
      if not loose and t:find(m, 1, true) then loose = o end
    end
    if loose then return loose end
  end
  if step.o and q.objectives[step.o] then return q.objectives[step.o] end
  -- no match word from the planner (objects to use, places to explore: the quest data has no text the game shows for
  -- them): the objective sharing the most distinctive words with the step ("Read the Lay of Ameth'Aran" -> "Lay of
  -- Ameth'Aran read"), when exactly one does best. Otherwise the card couldn't tell that objective was done and sat on
  -- it until the whole quest was (you ticked it by hand).
  if not step.match and step.text then
    local want = Engine.Words(step.text)
    local best, bestN, tie = nil, 0, false
    for _, o in ipairs(q.objectives) do
      local n = 0
      for w in pairs(Engine.Words(o.text)) do if want[w] then n = n + 1 end end
      if n > bestN then best, bestN, tie = o, n, false elseif n == bestN and n > 0 then tie = true end
    end
    if best and not tie then return best end
  end
  if not noElim and not step.match and step.text then
    -- by elimination: every other objective of the quest belongs to another step of the route ("Explore" says
    -- nothing; Alther's Mill's other objective is "Use Tarantula Egg"): the one left is this step's
    local claimed, list = {}, steps()
    for _, j in ipairs(Engine.ObjStepsOf(step.q)) do
      local t = list[j]
      if t ~= step then local o2 = (t.match or Engine.Words(t.text) and next(Engine.Words(t.text))) and Engine.ObjectiveFor(t, true) or nil; if o2 then claimed[o2] = true end end
    end
    local left
    for _, o in ipairs(q.objectives) do if not claimed[o] then if left then return nil end; left = o end end
    return left
  end
end
-- the words that tell objectives apart (not "the", "of", the verb, or counts)
local COMMON = { the = 1, ["and"] = 1, ["for"] = 1, ["from"] = 1, ["with"] = 1, ["into"] = 1, ["your"] = 1, use = 1, read = 1, free = 1, locate = 1,
  collect = 1, kill = 1, investigate = 1, explore = 1, find = 1, slain = 1, ["get"] = 1, bring = 1, place = 1, open = 1 }
function Engine.Words(t)
  local out = {}
  if type(t) ~= "string" then return out end
  for w in t:lower():gmatch("[%a'][%a']+") do if #w > 2 and not COMMON[w] then out[w] = true end end
  return out
end

-- dungeons: a "Run <X> with a group" step and the objective steps done inside ("Collect 10 Twilight Pendant (in
-- Blackfathom Deeps)"). Once you've been inside (any visit is your run - ns.char.dungeonsVisited) or skipped the run,
-- what's left inside waits ("later") instead of holding up the card: half a run (drops that didn't drop), skipping
-- dungeons, or running one twice all leave the route moving. Back inside, it's current again.
function Engine.RunDungeon(s) return s and s.k == "goto" and (s.dungeon or tostring(s.text or ""):match("^Run (.-) with a group") or tostring(s.text or ""):match("^Run (.+)$")) or nil end
function Engine.InsideOf(s) return s and s.k == "obj" and tostring(s.text or ""):match("%(in (.-)%)$") or nil end
-- each quest's objective steps, by index - built once per step list (a hand-in's check scanned the whole plan for
-- every unfinished hand-in: on a 2300-step plan that was most of a refresh)
local objIndex, objIndexFor, objIndexN = nil, nil, 0
function Engine.ObjStepsOf(q)
  local list = steps()
  if objIndexFor ~= list or objIndexN ~= #list then
    objIndex, objIndexFor, objIndexN = {}, list, #list
    for j, t in ipairs(list) do if t.k == "obj" and t.q then local l = objIndex[t.q]; if not l then l = {}; objIndex[t.q] = l end; l[#l + 1] = j end end
  end
  return objIndex[q] or {}
end
-- a visit marks one Run step (ns.char.ranRun[key]): the first one of that dungeon not run or skipped yet - a second
-- planned run of the same dungeon later on the route stays to do
-- the mark is for the plan you were on (its stamp): a new plan made after the run (the planner saw drops still missing -
-- 5 of 8 brain stems - and planned another run) has a run of its own to do
local function planStamp() return (ForeverRoutePlan and ForeverRoutePlan.generated) or (ForeverRouteData and ForeverRouteData.id) or 0 end
local function ran(i) local v = ns.char.ranRun and ns.char.ranRun[key(i)]; return v ~= nil and v == planStamp() end
-- the Run step an inside objective belongs to: the nearest one before it for that dungeon
local function runFor(j, name)
  local list = steps()
  for i = j - 1, 1, -1 do local d = Engine.RunDungeon(list[i]); if d and Engine.SamePlace(d, name) then return i end end
end
-- an inside objective (step j) waits for now: its run is done or skipped, and you're not in that dungeon
function Engine.DungeonLater(name, j)
  if not name or Engine.InDungeon(name) then return false end
  local r = j and runFor(j, name)
  return r and (ran(r) or ns.char.skipped[key(r)] or false) or false
end
local function recordDungeon()
  local name = ns.Dungeon.Here() -- which dungeon, by its instance id or the game's name for it (Dungeon.lua)
  if not name then return end
  -- the run the card shows, if it's this dungeon's; else the first of its runs not done yet (one already passed - you
  -- went ahead of it - is not the run you're starting: marking it once took the card back to two old runs)
  ns.char.ranRun = ns.char.ranRun or {}
  local shown = Engine.Shown and Engine.Shown()
  local list = steps()
  local s0 = shown and list[shown]
  local d0 = s0 and Engine.RunDungeon(s0)
  if d0 and Engine.SamePlace(d0, name) and not ran(shown) then ns.char.ranRun[key(shown)] = planStamp(); return end
  for i, s in ipairs(list) do
    local d = Engine.RunDungeon(s)
    if d and Engine.SamePlace(d, name) and not ran(i) and not ns.char.skipped[key(i)] and Engine.Status(i) ~= "done" then
      ns.char.ranRun[key(i)] = planStamp()
      return
    end
  end
end
Engine.RecordDungeon = recordDungeon
ns.On("ZONE_CHANGED_NEW_AREA", function() pcall(recordDungeon) end)
ns.On("PLAYER_ENTERING_WORLD", function() pcall(recordDungeon) end)

-- status: "done", "todo", "blocked" (quest not in log), "wait" (level too low), "full" (a pick-up with your quest log
-- full: passed over like "wait", so the card goes to hand-ins and objectives first), "notready" (turn-in with objectives left),
-- "later" (left for your next run of a dungeon you've been in or skipped: passed over, like "wait")
-- a quest more than this many levels below you is left out: tools/campaign.js plans each zone with
-- minQuestLevel = level - 6 (it never sends you to one), and the route in game drops the same ones
Engine.OUTLEVEL = 6
-- the game's gray line: a quest this level or lower gives (next to) no XP at level L - 5 below you early on, 6-12
-- below later (the client's GetQuestGreenRange table). A fixed 6 kept a level 1 quest on the route of a level 7.
function Engine.GrayAt(L)
  return L - (L < 6 and L or L < 40 and (math.floor(L / 10) + 5) or (math.floor(L / 5) + 1))
end
-- The game's red line: a quest 5 or more levels above you is red ("impossible"). Its work waits until you are within 4
-- levels of it - and so do its pick-up and its unfinished hand-in, as the planner's own gate (+2, +3 from 20) keeps it
-- out of reach until then. A pick-up with nothing to fight (a delivery: no objective on the route) is still taken when
-- the plan has it, unless the step has no level the game asks for (minLevel) - then red is all we know, and a class
-- quest of level 10 is not offered at 3. Only a player behind the plan's levels meets it: the live solve gave them
-- red pick-ups from the plan's later visits (a level 31 took Worth Its Weight in Gold, 36; mutate sweeps).
-- -> the level it comes back at, or nil
function Engine.TooHigh(s, L)
  local ql = s and s.q and tonumber(s.level)
  if not ql then return nil end
  L = L or (UnitLevel and UnitLevel("player")) or 1
  if ql < L + 5 then return nil end
  local k = s.k
  if k == "obj" or (k == "turnin" and not State.QuestReady(s.q)) or (k == "accept" and (not s.minLevel or #Engine.ObjStepsOf(s.q) > 0)) then
    return ql - 4
  end
  return nil
end
-- are you bound at this bind step's place? (the bind's own name, the zone, or the map you were on when you bound)
function Engine.BoundAt(s, b)
  if not b then return false end
  if (s.bind and b == s.bind) or Engine.SamePlace(b, s.zone) then return true end
  local at = ns.char and ns.char.boundAt
  return at and at.name == b and at.m == s.m or false
end
-- Is your hearthstone set on map m, going by the name the game gives your bind (b)? The game names the place - the
-- town or inn ("Darkshire", "Menethil Harbor"), a capital by its own name ("Stormwind City") - never the map, so:
-- where you set it while the addon watched (ns.char.boundAt: that name on that map, and then no other map), else the
-- names this map's inn goes by: the step's own, the zone's, a bind stop of the plan there, the flight point's town
-- ("Darkshire, Duskwood"). No match is "not there": a hearth that isn't yours is never offered.
function Engine.BoundOn(m, b, s)
  if not (m and type(b) == "string" and b ~= "") then return false end
  local at = ns.char and ns.char.boundAt
  if at and at.m and at.name == b then return at.m == m end
  if s and (s.dest == b or s.text == b) then return true end
  local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(m)
  if info and info.name and Engine.SamePlace(b, info.name) then return true end
  for _, t in ipairs(steps()) do if t.k == "bind" and t.m == m and Engine.BoundAt(t, b) then return true end end
  for _, byMap in pairs(ns.FLIGHT_BY or {}) do
    for _, f in ipairs(byMap[m] or {}) do if f[4] and f[4]:match("^(.-),") == b then return true end end
  end
  return false
end
-- Can you take this hearth step? Only when the game says so: your hearthstone is set where the step goes (the plan
-- only assumed you set it at its bind stop - a level 31 was told "Hearth to Darkshire" while bound in Stormwind) and it
-- is off cooldown. Otherwise the step is passed and the way to the stops after it is planned like any other trip
-- (Engine.TravelFor). -> true, or false and why
local hearthMemo = setmetatable({}, { __mode = "k" })
function Engine.HearthUsable(i)
  local list = steps()
  local s = list[i]
  if not s then return false, "no such step" end
  local okB, b = pcall(GetBindLocation)
  if not okB or type(b) ~= "string" or b == "" then return false, "the game does not say where your hearthstone is set" end
  -- whether the step goes where the stone is set: worked out once per step and bind location (the route list asks
  -- about every hearth step on every refresh, and this walks the steps and the flight tables)
  local memo = hearthMemo[s]
  local there
  local at = ns.char and ns.char.boundAt -- (what the addon has learned about where the stone is set counts too)
  if memo and memo.b == b and memo.list == list and memo.at == at then there = memo.there else
    -- where the step goes: the plan says (bindMap), else the bind stop before it (plans from before that field)
    local m = s.bindMap
    if not m then for j = i - 1, 1, -1 do if list[j].k == "bind" then m = list[j].m; break end end end
    if m then there = Engine.BoundOn(m, b, s) else there = s.dest == b or Engine.SamePlace(b, s.dest or s.text) end
    hearthMemo[s] = { b = b, list = list, at = at, there = there }
  end
  if not there then return false, "your hearthstone is set in " .. b .. ", not there" end
  local cd = ns.HearthCooldown and ns.HearthCooldown()
  if type(cd) == "number" and cd > 0 then return false, "your hearthstone is on cooldown (" .. math.ceil(cd / 60) .. " min)" end
  return true
end
-- (said once per step and reason, and only for a step the card is about to reach: the list asks about every step)
local hearthSaid = setmetatable({}, { __mode = "k" })
local function hearthPassed(i, s, why)
  local c = Engine.current
  if hearthSaid[s] == why or not (c and i >= c and i <= c + 3) then return end
  hearthSaid[s] = why
  if ns.Why then ns.Why("hearth", "passed \"Hearth to " .. tostring(s.dest or s.text or "your inn") .. "\": " .. why .. "; the way there is planned like any other trip") end
end
-- the level a training stop is for: "level 8/10 spells" -> 10
function Engine.TrainLevel(s)
  if s.until_ then return tonumber(s.until_) end
  local best
  for n in tostring(s.text or ""):gmatch("%d+") do n = tonumber(n); if not best or n > best then best = n end end
  return best
end
-- Your XP per second at a level: Forever's pace, as the planner measured it - the median XP an hour of the plan's zone
-- routes for that level (ns.ZoneRoutesAt; ~25k an hour at 38, where a level is 80.8k: over 3 hours). Every price of
-- time against XP goes through this (the solve's stops, a leftover's trip, a hand-in now or later): they had fixed
-- "a level every 1.5 h" and "every 2 h" - double Forever's pace in the 30s, and not its curve (tester). Without zone
-- routes (an old plan): a level every 1.5 h, as before.
local paceMemo = {}
function Engine.XpPerSec(L)
  L = L or (UnitLevel and UnitLevel("player")) or 1
  local src = ns.Routes and ns.Routes()
  local m = paceMemo
  if m.src ~= src then paceMemo = { src = src }; m = paceMemo end
  if m[L] then return m[L] end
  local xs = {}
  for _, r in ipairs((ns.ZoneRoutesAt and ns.ZoneRoutesAt(L)) or {}) do if tonumber(r.xph) and r.xph > 0 then xs[#xs + 1] = r.xph end end
  local v
  if #xs > 0 then table.sort(xs); v = xs[math.floor((#xs + 1) / 2)] / 3600
  else v = ((UnitXPMax and UnitXPMax("player")) or 10000) / 5400 end
  m[L] = math.max(1, v)
  return m[L]
end
-- The one gray rule (Engine.GrayDrop): a quest gray to you - in your log or not - is off the route (no pick-up, no
-- objectives, no hand-in stop, and the quest log check says drop it) unless its chain leads to a quest that isn't gray
-- to you. "Leads to": the quests that need it, as far down as the chain goes (ForeverRouteUnlocks - the plan's
-- chains - and the quest data's prerequisites, ns.QUEST_PRE, turned around), through gray links too. Only follow-ups
-- you can still take count: not done, not refused, not the other faction's or another class's (ns.QUEST_FOR), not
-- shut by an exclusive quest you have or did (ns.QUEST_EX), and not one another way in already opened. The
-- follow-up's own level decides: the plan's level for it, else the quest data's. One the plan has with no level
-- anywhere counts (the chain goes on past what we know); one only the quest data has, with no level, does not.
-- (The route kept a gray quest in your log, every step of it, while the quest log check said to drop it. User's rule:
-- "grey in log should drop unless part of chain that leads to yellow+ quests".)
-- What a follow-up must be to keep its chain: "yellow" = the game's yellow and up (2 or fewer levels below you, the
-- user's rule: a chain of gray and green quests goes); "gray" = anything above the gray line. The same line decides what a
-- chain is worth on Where to? (Engine.LeadsToWorth): a level 57 was offered The Barrens for Ignition (18), whose
-- follow-up, off the plan, counted as worth it (mutate seed 2)
Engine.CHAIN_WORTH = "yellow"
local function worthAt(L, lvl)
  if Engine.CHAIN_WORTH == "yellow" then return L >= lvl - 2 end
  return L > Engine.GrayAt(lvl)
end
local levelOfQ, levelSrc = {}, nil
local function planLevel(q)
  local list = steps()
  if levelSrc ~= list then
    levelOfQ, levelSrc = {}, list
    for _, t in ipairs(list) do if t.q and tonumber(t.level) and t.level > 0 and not levelOfQ[t.q] then levelOfQ[t.q] = t.level end end
  end
  return levelOfQ[q]
end
-- the quests that list q among their prerequisites (ns.QUEST_PRE turned around), built once
local neededBy
local function needersOf(q)
  local P = ns.QUEST_PRE
  if not P then return nil end
  if not neededBy or neededBy.src ~= P then
    neededBy = { src = P }
    for d, pre in pairs(P) do
      for _, p in ipairs(pre.g or {}) do local t = neededBy[p]; if not t then t = {}; neededBy[p] = t end; t[#t + 1] = d end
      for _, p in ipairs(pre.s or {}) do local t = neededBy[p]; if not t then t = {}; neededBy[p] = t end; t[#t + 1] = d end
    end
  end
  return neededBy[q]
end
-- can you take follow-up d (reached from quest from), whatever its level?
local mySide, myClass
local function takeable(d, from)
  if State.IsCompleted(d) or ns.Nope(d) then return false end
  local who = ns.QUEST_FOR and ns.QUEST_FOR[d]
  if who then
    if mySide == nil then
      local f = UnitFactionGroup and UnitFactionGroup("player")
      mySide = f == "Horde" and "H" or f == "Alliance" and "A" or false
      myClass = (UnitClass and select(2, UnitClass("player"))) or false
    end
    local sd, cl = who:match("^(%a?):?(.*)$")
    if sd ~= "" and mySide and sd ~= mySide then return false end
    if cl ~= "" and myClass and not ("," .. cl .. ","):find("," .. myClass .. ",", 1, true) then return false end
  end
  for _, x in ipairs((ns.QUEST_EX and ns.QUEST_EX[d]) or {}) do if State.IsCompleted(x) or State.InLog(x) then return false end end
  -- (one of several ways in, and another one is done: it is open without from - from leads nowhere new)
  local pre = from and ns.QUEST_PRE and ns.QUEST_PRE[d]
  if pre and pre.s and #pre.s > 1 then
    local viaS = false
    for _, p in ipairs(pre.s) do if p == from then viaS = true end end
    if viaS then for _, p in ipairs(pre.s) do if p ~= from and State.IsCompleted(p) then return false end end end
  end
  return true
end
-- the highest level anything down q's chain has, whoever can take it (math.huge: a quest the plan has with no level):
-- fixed for a plan, so worked out once per quest. A chain whose best is gray to you leads nowhere, and the walk below
-- (your quests, your faction) is not needed - most gray quests of a plan from level 1, asked about on every refresh
local bestMemo = {}
local function chainBest(q)
  local list, unl = steps(), ForeverRouteUnlocks
  if bestMemo.list ~= list or bestMemo.unl ~= unl or bestMemo.pre ~= ns.QUEST_PRE then bestMemo = { list = list, unl = unl, pre = ns.QUEST_PRE } end
  local b = bestMemo[q]
  if b then return b end
  b = 0
  local seen, queue, head = { [q] = true }, { q }, 1
  while head <= #queue and head <= 400 do
    local x = queue[head]; head = head + 1
    for pass = 1, 2 do
      local ds = pass == 1 and unl and unl[x] or pass == 2 and needersOf(x) or nil
      for _, d in ipairs(ds or {}) do
        if not seen[d] then
          seen[d] = true; queue[#queue + 1] = d
          local L = planLevel(d) or (ns.QuestLevel and ns.QuestLevel(d))
          if not L and pass == 1 then L = math.huge end
          if L and L > b then b = L end
        end
      end
    end
  end
  bestMemo[q] = b
  return b
end
-- remembered per level, per plan and per look at your quests (Engine.GrayForget: each refresh, each full look at the
-- log): the route asks about every gray step on every refresh
local leadsMemo = { lvl = -1, gen = -1 }
Engine.grayGen = 0
function Engine.GrayForget() Engine.grayGen = Engine.grayGen + 1 end
-- -> the quest q's chain leads to that is still worth XP to you at level lvl (the nearest such), or nil
function Engine.LeadsTo(q, lvl)
  if not q then return nil end
  lvl = lvl or (UnitLevel and UnitLevel("player")) or 1
  local list = steps()
  local m = leadsMemo
  if m.lvl ~= lvl or m.gen ~= Engine.grayGen or m.list ~= list then
    m = { lvl = lvl, gen = Engine.grayGen, list = list }; leadsMemo = m
    mySide = nil
  end
  local hit = m[q]
  if hit ~= nil then return hit or nil end
  local best = chainBest(q)
  if best == 0 or (best ~= math.huge and not worthAt(best, lvl)) then m[q] = false; return nil end
  Engine.grayWalks = (Engine.grayWalks or 0) + 1 -- (counted: the perf battery)
  local seen, queue, head, found = { [q] = true }, { q }, 1, false
  local x
  local function visit(d, plan)
    if found or seen[d] then return end
    seen[d] = true
    if not takeable(d, x) then return end
    local L = planLevel(d) or (ns.QuestLevel and ns.QuestLevel(d))
    if (not L and plan) or (L and worthAt(L, lvl)) then found = d; return end
    queue[#queue + 1] = d -- (gray itself: on down its chain)
  end
  while head <= #queue and head <= 200 and not found do
    x = queue[head]; head = head + 1
    for _, d in ipairs((ForeverRouteUnlocks and ForeverRouteUnlocks[x]) or {}) do visit(d, true) end
    for _, d in ipairs(needersOf(x) or {}) do visit(d, false) end
  end
  m[q] = found
  return found or nil
end
function Engine.LeadsToWorth(q, lvl) return Engine.LeadsTo(q, lvl) ~= nil end
-- The rule itself. Quest q (level ql: the step's or your log's; else the plan's, else the quest data's) at your level
-- lvl -> true: off the route, drop it; false, d: gray but kept - it leads to d; false: not gray (or no level known)
function Engine.GrayDrop(q, lvl, ql)
  if not q or q <= 0 then return false end
  lvl = lvl or (UnitLevel and UnitLevel("player")) or 1
  ql = tonumber(ql) or planLevel(q) or (ns.QuestLevel and ns.QuestLevel(q))
  if not ql or ql <= 0 or ql > Engine.GrayAt(lvl) then return false end
  local d = Engine.LeadsTo(q, lvl)
  if d then return false, d end
  return true
end
-- a step of a quest the gray rule takes off the route: its pick-up, objectives and hand-in, in your log or not
function Engine.Outlevelled(s)
  if not (s and s.q and tonumber(s.level) and s.level > 0) then return false end
  local lvl = UnitLevel("player") or 1
  if s.level > Engine.GrayAt(lvl) or State.IsCompleted(s.q) then return false end
  return Engine.GrayDrop(s.q, lvl, s.level) == true
end
-- a finished hand-in the gray rule took off (Messenger to Westfall at 26: 250 XP): Outlevelled, said apart in reports
function Engine.GrayHandIn(s)
  if not (s and s.k == "turnin" and s.q and tonumber(s.level) and s.level > 0) then return false end
  if not State.QuestReady(s.q) then return false end
  return Engine.Outlevelled(s)
end
-- Your place in the built-in plan. It is one path from level 1 to 60, and every step has a level: the level the plan
-- has you at when you get there (lvl; a step without one - a flight, a flight path, a hearth - takes the level of the
-- next step that has one: travel belongs to what it leads to). What the plan does below your place is behind you:
-- passed, whatever kind of step it is. Your place is the higher of two things:
--   where you joined: someone who meets the plan at 30 (installed the addon then, or came back to it) joins at the
--     trip during which the plan reaches 30. Everything before that trip is behind them for good, quests in their log
--     included - those are theirs to finish or drop, like any quest that is not on the route (a finished one gets a
--     hand-in stop where the route passes its NPC, and the quest log check lists them all). Kept in ns.char.join.
--   JOIN_GAP levels below you: rested XP and dungeons put you ahead of the plan, and up to 3 levels ahead you are
--     still doing what it says. Further ahead than that, what it does down there is passed - but a quest in your log
--     stays, here: you picked it up on the plan.
-- A quest goes as a whole: with its pick-up behind you (and the quest not yours), its other steps are too; a pick-up
-- that needs a quest whose hand-in is behind you is not offered; and a quest in your log goes when something still to
-- do for it lies before the trip you joined at. Your own plan (the companion's) is made from your save: none of this.
-- (A level 30 trying the addon was sent to Redridge for a flight path, to Elwynn for errands, then through Duskwood
-- and Ashenvale: travel steps carried no level, and quests in the log pulled the card back to each of those zones.)
Engine.JOIN_GAP = 3
local planCache = setmetatable({}, { __mode = "k" })
local function isTrip(s) return s.k == "fly" or s.k == "hearth" or s.k == "boat" end
local function planIndex()
  local list = steps()
  local c = planCache[list]
  if c and c.n == #list then return c, list end
  -- (binds: the bind stops in order; trainAfter[i]: the lowest level a training stop after step i is for - statusRaw
  -- walked the rest of the plan for each, on every refresh; trainLo[i]: the lowest level training stop i names - "level
  -- 34/36" is 34 - read from its text once, not on every status)
  c = { n = #list, idx = {}, eff = {}, accept = {}, turnin = {}, at = {}, binds = {}, trainAfter = {}, trainLo = {} }
  local nxt, train
  for i = #list, 1, -1 do
    local s = list[i]
    c.trainAfter[i] = train
    if s.k == "train" then
      local L = Engine.TrainLevel(s); if L and (not train or L < train) then train = L end
      local lo; for n in tostring(s.text or ""):gmatch("%d+") do n = tonumber(n); if not lo or n < lo then lo = n end end
      c.trainLo[i] = lo
    end
    if s.k == "bind" then table.insert(c.binds, 1, i) end
    c.idx[s] = i
    if tonumber(s.lvl) then nxt = s.lvl end
    c.eff[i] = nxt
    if s.q and s.q > 0 then
      if s.k == "accept" then c.accept[s.q] = i elseif s.k == "turnin" and not s.inserted then c.turnin[s.q] = i end -- (the first of each: this runs backwards)
    end
  end
  local last -- the last steps of a plan, with no stamped step after them: the level before
  for i = 1, #list do if c.eff[i] then last = c.eff[i] else c.eff[i] = last end end
  planCache[list] = c
  return c, list
end
-- the level the plan has you at, at step i (nil on a plan without levels)
function Engine.PlanLevel(i) return (planIndex()).eff[i] end
-- the level training stop i is for: the lowest its text names ("Train level 34/36 spells": 34), or its until_ when higher -
-- below it the trainer has nothing for you (nil: no level known)
function Engine.TrainFrom(i)
  local s = steps()[i]
  if not (s and s.k == "train") then return nil end
  local lo, u = (planIndex()).trainLo[i], tonumber(s.until_)
  if u and (not lo or u > lo) then return u end
  return lo
end
-- the step you joined at: the trip (flight, hearth, boat) into the stretch where the plan first reaches that level,
-- so you start a stretch from its beginning - its pick-ups before the things they are for. nil: nothing to pass
local function joinStep(level)
  local c, list = planIndex()
  local at = c.at[level]
  if at == nil then
    at = false
    for i = 1, #list do
      if tonumber(list[i].lvl) and list[i].lvl >= level then
        at = 1
        for j = i, 1, -1 do if isTrip(list[j]) then at = j; break end end
        break
      end
    end
    c.at[level] = at
  end
  return at or nil
end
-- the level you joined the built-in plan at, and the step that goes with it (nil, nil: you follow it from the start,
-- or it isn't known yet - Engine.FindPlace)
function Engine.Place()
  local key = ns.planKey and ns.planKey.starter
  local j = key and ns.char and ns.char.join
  if Engine.noPlace or not (j and j.plan == key and tonumber(j.level) and j.level > 1) then return nil end
  return j.level, joinStep(j.level)
end
-- Where you start. The trip you join at is the plan at your level; but the plan's stretches of the JOIN_GAP levels
-- before it are still good for you, and one of them may be worth more than that trip from where you stand: someone
-- who meets the plan at 30 in Darkshire has Duskwood's level 27-31 stretch around them, and the plan's own next
-- stretch a flight away. So when you join, each of those stretches (a stretch: the steps between two trips) is priced
-- like the planner prices a zone - the XP of the quests you can still do in it, over the time they take plus the trip
-- there from where you stand - and the best one is where you start (ns.char.join.first), before the trip you joined
-- at. Value decides, not distance: staying put wins only if its quests beat the alternative with its trip.
-- The numbers are rough and say so: quest XP from the quest's level (less for one far below you), a pick-up or hand-in
-- 10 s, an objective 2 min, the walk between steps at running or riding speed, the trip from Travel.Plan.
Engine.START_HORIZON = 3600 -- stretches are compared by the XP they bring in this many seconds (a short one, then the plan)
Engine.START_MIN_TURNINS = 5 -- a stretch with fewer hand-ins is no place to start (the planner's own floor for a zone)
local function firstTrip(c, list)
  if not c.trip1 then c.trip1 = #list + 1; for j = 1, #list do if isTrip(list[j]) then c.trip1 = j; break end end end
  return c.trip1
end
local function stretchEnd(list, from) for j = from + 1, #list do if isTrip(list[j]) then return j - 1 end end return #list end
local function questXP(ql, L)
  local xp = 100 + 60 * ql + 0.9 * ql * ql
  local d = L - ql
  return xp * (d <= 5 and 1 or d == 6 and 0.8 or d == 7 and 0.6 or d == 8 and 0.4 or d == 9 and 0.2 or 0.1)
end
Engine.QuestXP = questXP
-- the next thing to do for a quest in your log: its first unfinished objective on the route, else its hand-in
local function nextStep(q, c, list)
  if not State.QuestReady(q) then
    for _, j in ipairs(Engine.ObjStepsOf(q)) do
      local o = Engine.ObjectiveFor(list[j])
      if not (o and o.finished) then return j end
    end
    return nil
  end
  return c.turnin[q]
end
-- what a stretch is worth to you now: XP, seconds of work, hand-ins, the first step with a place
function Engine.StretchWorth(from, to)
  local c, list = planIndex()
  local L = UnitLevel("player") or 1
  local speed = (ns.Travel and ns.Travel.Speed and ns.Travel.Speed()) or 7
  local xp, secs, n, spot = 0, 0, 0, nil
  -- a quest you can do there: in your log with its next step there, or picked up in this stretch with every quest it
  -- needs handed in by then
  local can = {}
  local function doable(q)
    if can[q] == nil then
      local a = c.accept[q]
      if State.OnQuest(q) then
        local n = nextStep(q, c, list)
        can[q] = n ~= nil and n >= from and n <= to
      else
        can[q] = a ~= nil and a >= from and a <= to
      end
      if can[q] and not State.OnQuest(q) then
        for _, p in ipairs(Engine.PrereqsOf(q)) do
          local t = c.turnin[p]
          if not State.IsCompleted(p) and not (t and t >= from and t <= to and (State.OnQuest(p) or (c.accept[p] or 0) >= from)) then can[q] = false; break end
        end
      end
    end
    return can[q]
  end
  for j = from, to do
    local s = list[j]
    local q = s.q and s.q > 0 and s.q or nil
    if q and not State.IsCompleted(q) and not Engine.Outlevelled(s) and not Engine.TooHigh(s, L) then
      if doable(q) then
        if not (s.k == "accept" and State.OnQuest(q)) then
          spot = spot or (s.m and s.x and not s.unknown and s) or nil
          secs = secs + (tonumber(s.walk) or 80) / speed + (s.k == "obj" and 120 or 10)
          if s.k == "turnin" and tonumber(s.level) and s.level > 0 then xp = xp + questXP(s.level, L); n = n + 1
          -- (a quest picked up here and handed in after the stretch: its XP counts here too - its work here was counted
          -- and its XP was not, so a zone whose quests end in town after a trip read as all work and no XP)
          elseif s.k == "accept" and tonumber(s.level) and s.level > 0 and (c.turnin[q] or 0) > to then xp = xp + questXP(s.level, L); n = n + 1 end
        end
      end
    end
  end
  return xp, secs, n, spot
end
-- the stretch to start in, for someone joining at this level: its first step's key (nil: the trip you joined at), and
-- the stretches priced { from, to, zone, xph, extra (s of travel it adds), work (s), turnins, plan }, best first.
-- Priced: the plan's trip at your level (its XP over its work and the trip there), and every other stretch the plan
-- has within reach of your level - from OUTLEVEL levels below you (the planner's own line for a quest worth doing) up
-- to your level - with START_MIN_TURNINS hand-ins you can still do: its XP over its work and the travel it ADDS (the
-- trip there, then on to the plan's trip, less the trip you'd make anyway). So a stretch around you costs nothing to
-- reach, and one across the world has to be worth the detour.
function Engine.ChooseStart(level)
  local c, list = planIndex()
  local at = joinStep(level)
  local m, x, y = State.Position()
  if not (at and at > 1 and m and x and ns.Travel and ns.Travel.Plan) then return nil, {} end
  local L = UnitLevel("player") or 1
  local function trip(a, b)
    local ok, _, secs = ns.Call(ns.Travel.Plan, { m = a.m, x = a.x, y = a.y }, { m = b.m, x = b.x, y = b.y, name = b.zone })
    return ok and tonumber(secs) or nil
  end
  local me = { m = m, x = x, y = y }
  local priced = {}
  -- what the plan's stretches in the zone you stand in hold for you, from step 'from' on: the plan comes back to a zone
  -- after a trip (training in the capital, a hand-in in town), and one stretch of it alone undersold staying - an Undead
  -- at 16 in the Barrens had 4 hand-ins in the stretch at hand and the rest of the zone's quests uncounted, and was sent
  -- to Silverpine. Only stretches up to JOIN_GAP levels above you, while their work fits START_HORIZON
  local function worth(from, last)
    local xp, work, n, spot = Engine.StretchWorth(from, last)
    if not (spot and spot.m == m) then return xp, work, n, spot end
    for j = last + 1, #list do
      if work >= Engine.START_HORIZON or (c.eff[j] or 0) > L + Engine.JOIN_GAP then break end
      if isTrip(list[j]) and Engine.StretchOn(j, m) then
        local e2 = stretchEnd(list, j)
        local x2, w2, n2 = Engine.StretchWorth(j, e2)
        xp, work, n = xp + x2, work + w2, n + n2
      end
    end
    return xp, work, n, spot
  end
  -- the plan's trip at your level
  local to = stretchEnd(list, at)
  local xpD, workD, nD, spotD = worth(at, to)
  -- (nothing left for you in that stretch - its quests done, gray, or picked up before it: the plan goes on to the next
  -- one with something, and that is what the stretches around you are weighed against. It gave up here: "nothing to
  -- price", and an Undead at 16 in the Barrens was sent to Silverpine, where the plan's trip at 16 had nothing left)
  for _ = 1, 8 do
    if spotD or to >= #list or (c.eff[to + 1] or 0) > L + Engine.JOIN_GAP then break end
    local nx = to + 1
    to = stretchEnd(list, nx)
    xpD, workD, nD, spotD = worth(nx, to)
  end
  local tripD = spotD and trip(me, spotD)
  if not tripD then return nil, {} end -- no way there from here (or nothing to do there): nothing to compare with
  priced[1] = { from = at, to = to, zone = spotD.zone or list[at].dest or "?", xph = math.floor(xpD / (workD + tripD) * 3600), extra = math.floor(tripD), work = math.floor(workD), turnins = nD, plan = true }
  local function price(from)
    local last = stretchEnd(list, from)
    local xp, work, n, spot = worth(from, last)
    if not spot or n < Engine.START_MIN_TURNINS then return end
    local there, on = trip(me, spot), trip(spot, spotD)
    if not (there and on) then return end
    local extra = math.max(0, there + on - tripD)
    priced[#priced + 1] = { from = from, to = last, zone = spot.zone or list[from].dest or "?", xph = math.floor(xp / (work + extra) * 3600), extra = math.floor(extra), work = math.floor(work), turnins = n }
  end
  -- (and a stretch in the zone you stand in that the plan does up to JOIN_GAP levels above you: its quests are at your
  -- level too - an Undead at 14 in the Barrens, which the plan does at 16, had nothing else priced and was sent by
  -- zeppelin to Silverpine: "over an hour of wasted running that could have been leveling in the area I was already in")
  for j = 1, #list do
    local e = c.eff[j] or 0
    if j > at and e > L + Engine.JOIN_GAP then break end
    if j ~= at and (j == 1 or isTrip(list[j])) and e >= L - Engine.OUTLEVEL and (e <= L or Engine.StretchOn(j, m)) then price(j) end
  end
  -- compared over the same time (START_HORIZON): a stretch shorter than that is followed by the plan at the plan's own
  -- rate. Rates alone over-praised tiny stretches - five errands in 7 minutes scored 168k XP/h and would beat a real
  -- zone, though they are over before the hour is
  local planRate = priced[1].xph / 3600
  local H = Engine.START_HORIZON
  for _, p in ipairs(priced) do
    local t = p.work + p.extra
    local xp = p.xph / 3600 * t
    p.score = t >= H and p.xph or math.floor((xp + (H - t) * planRate) / H * 3600)
  end
  table.sort(priced, function(a, b) if a.score ~= b.score then return a.score > b.score end return (a.plan and 1 or 0) > (b.plan and 1 or 0) end)
  local best = priced[1]
  if best.plan then return nil, priced end
  return Engine.Key(best.from), priced
end
-- does the stretch from step i (a trip, or the plan's first step) work on map m? its trip goes there, or its first
-- steps with a place are there
function Engine.StretchOn(i, m)
  local list = steps()
  local s = list[i]
  if not (s and m) then return false end
  if isTrip(s) and s.to then return s.to == m end
  for j = i, math.min(#list, i + 6) do
    local t = list[j]
    if j > i and isTrip(t) then break end
    if t.m then return t.m == m end
  end
  return false
end
-- the stretch you start in (nil: none chosen, or it is not on this plan any more): its first and last step
function Engine.FirstStretch()
  local j = ns.char and ns.char.join
  local k = j and ns.planKey and j.plan == ns.planKey.starter and j.first
  if not k or Engine.noPlace then return nil end
  local c, list = planIndex()
  if c.firstKey ~= k then
    c.firstKey, c.firstFrom, c.firstTo = k, false, false
    for i = 1, #list do if Engine.Key(i) == k then c.firstFrom, c.firstTo = i, stretchEnd(list, i); break end end
  end
  return c.firstFrom or nil, c.firstTo or nil
end
-- the zone you are in (nil on a flight, or where the game gives no position): taken once per refresh (Engine.here)
function Engine.HereMap()
  if ns.Is and UnitOnTaxi and ns.Is(UnitOnTaxi, "player") then return nil end
  local ok, m = pcall(State.Position)
  return ok and m or nil
end
-- The part of the built-in plan behind you, by the place of a step alone: -> before(j), low(j) for this moment, and
-- the step you joined at
local passedMemo
local function passedPart(c, list)
  local L = UnitLevel("player") or 1
  local _, at = Engine.Place()
  local f1, f2 = nil, nil
  if at then f1, f2 = Engine.FirstStretch() end
  local memo = passedMemo
  if memo and memo.index == c and memo.level == L and memo.at == at and memo.first == f1 and memo.last == f2 then
    return memo.before, memo.low, at
  end
  -- before the trip you joined at, and not in the stretch you start in - nor a quest in the zone you joined in, at your
  -- level: the card sent a tester to Riverglades and the first half of its quests (Gnoll Infestation, 36, at 37, from
  -- the giver he stood at) were behind him, because the plan reached his level at step 1132; offered back one by one as
  -- extras, the nearest few changed as he walked and the card jumped between them
  -- (the zone of your place: the first step there with one - you join at a trip, and a trip has none)
  -- (the stretch you start in, when one was chosen after the trip you joined at: that is where you joined - not the zone
  -- of that trip, which you skip for now. An Undead at 16 starting in the Barrens, which the plan does after Silverpine,
  -- had Silverpine's quests at his level kept as "the zone you joined", and the card sent him there through Orgrimmar and
  -- the Undercity. A stretch chosen before the trip keeps the trip's zone: the plan goes there next)
  local atZone
  local z0 = (f1 and at and f1 > at) and f1 or at
  if z0 then for k = z0, math.min(#list, z0 + 40) do if list[k].zone then atZone = list[k].zone; break end end end
  local function before(j)
    if not (at ~= nil and j < at and not (f1 and j >= f1 and j <= f2)) then return false end
    -- (the quest's own level: one far below you stays behind, wherever the plan put it)
    local t = list[j]
    local ql = tonumber(t.level) or c.eff[j]
    if atZone and t.q and t.q > 0 and t.zone == atZone and (ql == nil or ql >= L - Engine.JOIN_GAP) then return false end
    return true
  end
  -- below your place: that, or more than JOIN_GAP levels below you (not while you are still in the plan's first
  -- stretch, the start zone: its chains lead out of it, and at 5 nothing of it is behind you)
  local start = at == nil and joinStep(L) == 1
  local function low(j)
    if before(j) then return true end
    local e = c.eff[j]
    return (e and e < L - Engine.JOIN_GAP and not (start and j < firstTrip(c, list))) or false
  end
  passedMemo = { index = c, level = L, at = at, first = f1, last = f2, before = before, low = low }
  return before, low, at
end
-- Is step j in the part of the plan behind you by its place alone, whatever its quest's state? Engine.BehindYou says
-- no for a quest you completed (its steps are done anyway), and Engine.InsertStop priced the gap between two such done
-- steps as "the route passes by": a hand-in went into the passed part of Feralas, the plan's next step, and the card sent
-- a level 51 from Tanaris across Kalimdor for it (mutate, Zapped Giants). -> a function of j for this moment, or nil
function Engine.PassedFn()
  if Engine.noPlace or not (ns.planKey and ns.planKey.starter) then return nil end
  if ForeverRouteData and ForeverRouteData.zoneRoute then return nil end
  local c, list = planIndex()
  local _, low = passedPart(c, list)
  return low
end
-- planOnly: as the plan sees it, without the live solve's pick-up from behind you (Next.taken) - Engine.Compute
function Engine.BehindYou(s, planOnly)
  if Engine.noPlace or not (s and ns.planKey and ns.planKey.starter) then return false end
  -- (a zone you picked has nothing behind you: you chose to go there - its steps all read "done" when you came back to it)
  if ForeverRouteData and ForeverRouteData.zoneRoute then return false end
  if not planOnly and ns.Next and ns.Next.taken == s then return false end -- (picked up again by the live solve: right here and worth it)
  if s.side then return false end -- (a stop added for a quest giver next to you is where you are, wherever it lands in the plan)
  local c, list = planIndex()
  local i = c.idx[s]
  if not i then return false end
  local before, low, at = passedPart(c, list)
  local q = s.q and s.q > 0 and s.q or nil
  if not q then
    if low(i) then return true end
    if s.k == "hearth" then
      -- a hearth to an inn the plan bound you at in a part that is behind you: you are not bound there
      for j = i - 1, 1, -1 do
        local t = list[j]
        if t.k == "bind" then return Engine.BehindYou(t, planOnly) and not Engine.BoundAt(t, GetBindLocation and GetBindLocation()) end
      end
    end
    return false
  end
  if State.IsCompleted(q) then return false end
  if State.OnQuest(q) then
    -- in your log. Following the plan, or picked up since you joined it: the plan's, wherever it leads
    local had = at and ns.char.join and ns.char.join.had
    if s.k == "accept" or s.inserted or not (had and had[q]) then return false end -- (a stop added for it is on your way)
    -- yours from before you joined: on the plan if what is left of it is ahead of you - or it is finished and its
    -- hand-in is in the zone you are in (handed in first: The Night Watch, 19 yd from a level 30 in Darkshire)
    local n = nextStep(q, c, list)
    if not n then return before(i) end
    if not before(n) then return false end
    return not (Engine.here ~= nil and list[n].k == "turnin" and list[n].m == Engine.here)
  end
  if s.k ~= "accept" then
    -- a quest goes as a whole: with its pick-up behind you, its other steps are too
    local a = c.accept[q]
    if a and a ~= i then return Engine.BehindYou(list[a], planOnly) end
    return low(i)
  end
  if low(i) then return true end
  -- it needs a quest whose hand-in is behind you: not offered. (ForeverRouteUnlocks is the whole chain before it; it
  -- lists "any one of" with "all of", so a quest with two ways in can be passed here though one of them is done)
  for _, p in ipairs(Engine.PrereqsOf(q)) do
    if not State.IsCompleted(p) then
      local t = c.turnin[p]
      if t and t < i and Engine.BehindYou(list[t], planOnly) then return true end
    end
  end
  return false
end
-- a breadcrumb whose quest is already yours (in your log or done): the game no longer offers it - The Corruption
-- Abroad from Argos Nightwhisper, with Researching the Corruption in your log (ns.BREADCRUMBS, Breadcrumbs.lua)
-- a quest some other quest you took or did shuts (its breadcrumb's target, or an exclusive alternative): passed over
local function shutBy(tbl, s)
  local others = s and s.q and tbl and tbl[s.q]
  if not others or State.OnQuest(s.q) or State.IsCompleted(s.q) then return false end
  for _, t in ipairs(others) do if State.OnQuest(t) or State.IsCompleted(t) then return true end end
  return false
end
function Engine.Breadcrumbed(s) return shutBy(ns.BREADCRUMBS, s) end
-- a quest one of whose alternatives is yours (in your log or done): one quest given in several towns, and you took it
-- in another - the game no longer offers this one, so none of its steps is left to do (ns.QUEST_EX, QuestData.lua).
-- A warlock who had taken In Search of Menara Voidrender from Demisette Cloyce in Stormwind was sent to Briarthorn
-- in Ironforge for it (tester)
function Engine.Excluded(s) return shutBy(ns.QUEST_EX, s) end
-- a quest whose earlier chain quest you skipped (Skip on its pick-up), or said you're not doing, or that is itself cut
-- so: the game will never offer it. By the quest data's prerequisites (ns.QUEST_PRE: all of g, one of s - every one of
-- s cut), not ForeverRouteUnlocks (it mixes "any one of" with "all of"). A player who skipped Samophlange's third part
-- was shown the fourth part's pick-up, "needs Samophlange handed in first", for the rest of the zone (mutate --play)
-- (deep: Call of Water is eight quests long - a cut at its third part cut the last one only at depth 5)
local function cutQuest(q, depth)
  if State.IsCompleted(q) then return false end
  -- (a gray quest the gray rule drops, in your log or not, cuts what needs it: the chain goes as a whole. Its follow-ups
  -- keep it only when one is yellow to you, Engine.LeadsTo - so a green one after it goes too, rather than being the
  -- step you can never take: Harmony in Balance, level 1, dropped at 8 with its level 4 follow-ups on the card - mutate)
  -- (a quest your plan has, at its level there: one the plan doesn't have is left to the rules below)
  local L = planLevel(q)
  if L and Engine.GrayDrop(q, nil, L) == true then return true end
  if State.OnQuest(q) then return false end
  if ns.Nope(q) then return true end
  local a = (planIndex()).accept[q]
  if a and ns.char.skipped[key(a)] then return true end
  return depth < 12 and Engine.ChainCut(q, depth + 1) or false
end
-- (a quest the game showed you on offer - a giver listed it, or the map's "!" - is offered whatever the quest data says it
-- needs, as on a zone route's prerequisites below)
-- (counted loops, no "pre.g or {}": statusRaw asks this of most steps on every look at the route - 13,600 times opening
-- the route window at 12 - and a table, or an ipairs iterator, per ask was half its garbage: perf gate)
function Engine.ChainCut(q, depth)
  local pre = q and ns.QUEST_PRE and ns.QUEST_PRE[q]
  if not pre then return false end
  local av = ns.char and ns.char.avail
  if av and av.seen and av.seen[q] then return false end
  depth = depth or 0
  local g, s = pre.g, pre.s
  if g then for k = 1, #g do if cutQuest(g[k], depth) then return true end end end
  if s and #s > 0 then
    for k = 1, #s do if not cutQuest(s[k], depth) then return false end end
    return true
  end
  return false
end
-- a quest whose prerequisites are not handed in, one of them (or one of theirs, up the chain) in your log unfinished:
-- the game offers it after that hand-in (ns.QUEST_PRE). Clerical Quarantine after Doctor's Orderly after Wound
-- Dressings, at 0/20 in your log: not offered, nor the one between
-- (counted loops, no table per ask: statusRaw asks it of every pick-up with a prerequisite - perf gate)
local function pendingPre(p, depth)
  return not State.IsCompleted(p) and (State.OnQuest(p) or (depth < 6 and Engine.WaitsOnLog(p, depth + 1)))
end
function Engine.WaitsOnLog(q, depth)
  local pre = ns.QUEST_PRE and ns.QUEST_PRE[q]
  if not pre then return false end
  depth = depth or 0
  local g, s = pre.g, pre.s
  if g then for n = 1, #g do if pendingPre(g[n], depth) then return true end end end
  if s and #s > 0 then
    for n = 1, #s do if State.IsCompleted(s[n]) then return false end end -- (one of them is in: met)
    for n = 1, #s do if pendingPre(s[n], depth) then return true end end
  end
  return false
end
-- a pick-up that reads "wait" (statusRaw) for a quest in your log, not for your level: statusRaw's own order - the level
-- checks come first, and on a zone you picked the wait is ns.PrereqsMet's, as before. For the live solve, which takes it
-- as the not-offered pick-up it was before Engine.WaitsOnLog: its window ends there (Next.Pick), and a visit that hands
-- that quest in takes it after (Next.VisitHere). Skipped as a level wait, the window ran on past every chain's next
-- pick-up - twice the solve's time over a play, and its order changed (perf gate, 1.6.8). Asked only of a "wait"
function Engine.WaitsForHandIn(s)
  if not (s and s.k == "accept") or (ForeverRouteData and ForeverRouteData.zoneRoute) then return false end
  if s.minLevel and UnitLevel("player") < s.minLevel then return false end
  return not Engine.TooHigh(s)
end
local PVP = ns.PVP_QUESTS -- (PvpQuests.lua loads before this file: one table, read per step)
local function statusRaw(i)
  local s = steps()[i]
  if not s then return "done" end
  local id = key(i)
  if ns.char.manualDone[id] or ns.char.skipped[id] then return "done" end
  if s.q and ns.Nope(s.q) then return "done" end -- you said you're not doing this quest
  if s.side and s.away and s.k == "accept" then return "done" end -- a side quest offered at its giver, and you walked on (Engine.SideOffer)
  -- the game did not offer it to you (Availability.lua): off the route until you level up or it is offered
  if s.q and ns.Avail and ns.Avail.Unavailable(s.q) and not State.OnQuest(s.q) and not State.IsCompleted(s.q) then return "done" end
  -- a battleground quest (Avail.Pvp: its marks come from PvP matches): not its pick-up, its objectives or a trip to its
  -- hand-in - only that hand-in, once the quest is finished in your log (you played the matches)
  if s.q and PVP and PVP[s.q] and not (s.k == "turnin" and State.OnQuest(s.q) and (State.Quest(s.q) or {}).complete) then return "done" end
  -- far below you and not in your log: off the route (all its steps), the same cut the planner makes - so a plan made
  -- for someone lower (the built-in plan from level 1, or yours after a dungeon run) passes over what you've outgrown,
  -- and a trip to a zone with nothing left for you is passed too (the "went ahead" rule below)
  if Engine.finishNow then
    -- (finishing your quests at 60: the objectives and hand-ins of the quests you hold, gray or behind you, nothing else)
    if not (s.q and s.q > 0 and s.k ~= "accept" and State.OnQuest(s.q)) then return "done" end
  elseif Engine.Outlevelled(s) or Engine.GrayHandIn(s) or Engine.Breadcrumbed(s) or Engine.Excluded(s) or (Engine.asTaken ~= s and Engine.BehindYou(s)) then return "done" end
  -- its earlier chain quest you skipped or said you're not doing: the game never offers it, so none of its steps is
  -- left (the ones of a quest you have are yours to do)
  if s.q and s.q > 0 and not State.OnQuest(s.q) and not State.IsCompleted(s.q) and Engine.ChainCut(s.q) then return "done" end
  local k = s.k
  if k == "hearth" then
    local can, why = Engine.HearthUsable(i)
    if not can then hearthPassed(i, s, why); return "done" end
  end
  if k == "accept" then
    if State.OnQuest(s.q) or State.IsCompleted(s.q) then return "done" end
    if s.minLevel and UnitLevel("player") < s.minLevel then return "wait" end
    if Engine.TooHigh(s) then return "wait" end -- (red: the game's own colour, Engine.TooHigh)
    -- on a zone you picked, its prerequisites not handed in (ns.QUEST_PRE): it waits, like a level - the giver would
    -- have nothing for you (a zone route is planned from the main route's progress, which a player who hops zones may not
    -- have). Your own plan has its prerequisites earlier in it. A quest the game showed on offer anyway (Availability: a
    -- giver listed it, or the map's "!") is taken as offered
    -- On any plan, one whose prerequisite is in your log, not handed in, waits for that hand-in ("Needs ... handed in
    -- first"): the plan has the hand-in before it, but a hand-in can wait (its objective in the part of the plan your
    -- place skips, Engine.Compute) - and the card went on to Doctor's Orderly with Wound Dressings at 0/20, then to
    -- Clerical Quarantine after it (mutate sweep). Up the chain: Engine.WaitsOnLog
    local pre = ns.QUEST_PRE and ns.QUEST_PRE[s.q]
    if pre and ns.PrereqsMet and not (ns.char and ns.char.avail and ns.char.avail.seen and ns.char.avail.seen[s.q]) then
      if ForeverRouteData and ForeverRouteData.zoneRoute then
        if not ns.PrereqsMet(s.q) then return "wait" end
      elseif Engine.WaitsOnLog(s.q) then return "wait" end
    end
    if State.LogFull and State.LogFull() then return "full" end
    return "todo"
  elseif k == "turnin" then
    if State.IsCompleted(s.q) then return "done" end
    if not State.OnQuest(s.q) then return "blocked" end
    if not State.QuestReady(s.q) then
      -- all that's unfinished is inside a dungeon you've run or skipped: it waits, the card moves on
      -- and so does one whose work the quest data has no place for (an unknown step) once you skipped that step: it
      -- comes back when the quest is ready
      local list, inside, outside, unknown = steps(), false, false, false
      for _, j in ipairs(Engine.ObjStepsOf(s.q)) do
        local t = list[j]
        if t.unknown then
          if ns.char.skipped[key(j)] or ns.char.manualDone[key(j)] then unknown = true elseif j ~= i and Engine.Status(j) ~= "done" then outside = true end
        elseif j ~= i and Engine.Status(j) ~= "done" then
          if Engine.DungeonLater(Engine.InsideOf(t), j) then inside = true else outside = true end
        end
      end
      if (inside or unknown) and not outside then return "later" end
      if Engine.TooHigh(s) then return "wait" end -- (its work is red to you: it waits with it)
      return "notready"
    end
    return "todo"
  elseif k == "obj" then
    if State.IsCompleted(s.q) then return "done" end
    if not State.OnQuest(s.q) then return "blocked" end
    if State.QuestReady(s.q) then return "done" end
    -- work the quest data has no place for (s.unknown): done only when the quest is ready - no live objective is
    -- matched to it (its words are the quest text's, not an objective's). Skip passes it: the hand-in then waits
    if s.unknown then return "todo" end
    local o = Engine.ObjectiveFor(s)
    if o and o.finished then return "done" end
    if Engine.DungeonLater(Engine.InsideOf(s), i) then return "later" end
    if Engine.TooHigh(s) then return "wait" end
    return "todo"
  elseif k == "grind" then
    local lvl = UnitLevel("player")
    if lvl > (s.level or 0) or (lvl == (s.level or 0) and UnitXP("player") >= (s.xp or 0)) then return "done" end
    return "todo"
  elseif k == "fp" then
    if s.fp and State.knownTaxi[s.fp] then return "done" end
    -- (this flight master's own point, by its flight-map name - not "a point whose name has the zone's first word": in a
    -- zone with two points for you, the other one counted as this one)
    if Engine.KnowsThisFlightPoint(s) then return "done" end
  elseif k == "bind" then
    local b = GetBindLocation and GetBindLocation()
    if Engine.BoundAt(s, b) then return "done" end
    -- bound at a later bind stop of the route: that one replaced this one - never back to rebind here (binding in
    -- Menethil once sent you back across the sea to Auberdine's inn, and from there back to Menethil's)
    local c, list = planIndex()
    for _, j in ipairs(c.binds) do if j > i and Engine.BoundAt(list[j], b) then return "done" end end
  elseif k == "bonus" then
    -- a book / collectible: done once it's in your bags or the books addon has it as found
    if s.item and ns.GetItemCount and (ns.GetItemCount(s.item, true) or 0) > 0 then return "done" end
    local found = HandyNotes_ForeverBooksCharDB and HandyNotes_ForeverBooksCharDB.collected
    if s.book and type(found) == "table" and found[s.book] then return "done" end
  elseif k == "train" then
    if s.until_ and UnitLevel("player") < s.until_ then return "wait" end
    -- a later training stop on the route is already due at your level: that visit covers this one (a plan made for
    -- someone lower lists every stop from level 2)
    local lvl = UnitLevel("player") or 1
    local c = planIndex()
    local L = c.trainAfter[i]
    if L and L <= lvl then return "done" end
    -- nothing to learn yet: the trainer has no spell of the stop's lowest level for you ("train level 46 spells" at 35
    -- sent a level 35 to Stormwind - mutate --play; "level 34/36" is for 34; planIndex reads it from the text once)
    local lo = c.trainLo[i]
    if lo and lo > lvl then return "wait" end
  end
  -- "Run <dungeon>": done while you're inside that dungeon (the entrance check can't see you once you're in, and a
  -- reload inside would otherwise leave it stuck). Leave early and it comes back.
  if k == "goto" and s.text then
    local dname = Engine.RunDungeon(s)
    -- inside: the run you're on is done - the first of that dungeon's runs not run yet; a second and third XP run
    -- stay to do (all of them read done while inside, so the card ran ahead to the next zone mid-run)
    if dname and Engine.InDungeon(dname) then
      -- the run you're on is the one going in marked (recordDungeon); none marked yet (you were inside when the plan
      -- loaded): the first of that dungeon's runs not run yet
      if ran(i) then return "done" end
      local list, marked, first = steps(), false, nil
      for j = 1, #list do
        local d2 = Engine.RunDungeon(list[j])
        if d2 and Engine.SamePlace(d2, dname) then
          if ran(j) then marked = true elseif not first and not ns.char.skipped[key(j)] then first = j end
        end
      end
      if not marked and first == i then return "done" end
      -- any other run of it: the usual rules (one passed by "you went ahead" stays passed)
    end
    -- been in it (this run, or one before): done; or nothing you're on is left inside: done
    if dname and ran(i) then return "done" end
    -- (a run for its XP - s.xpRun - has nothing to do inside: only going in, or skipping it, passes it)
    if dname and not s.xpRun then
      local list, left = steps(), false
      for j = i + 1, #list do local t = list[j]; local x = Engine.InsideOf(t); if x and Engine.SamePlace(x, dname) and State.OnQuest(t.q) and Engine.Status(j) ~= "done" then left = true; break end end
      if not left then return "done" end
    end
  end
  -- goto / fly / hearth / note: completed by events, arrival or a click, or passed: if the next few quest steps
  -- after it are already done (you went ahead, or did things in another order), the travel was clearly made
  -- (a step that reads to do only through the live solve's pick-up from behind you, Next.taken - the rest of that quest
  -- - is passed as the plan sees it: Reading Room taken up again in Stormwind made its hand-in to do, the training
  -- before that hand-in was no longer passed and became the plan's step, the solve kept it and let the pick-up go, and
  -- the card flipped to the flight out while you stood still - mutate sweep)
  local tk = ns.Next and ns.Next.taken
  local function passed(j, t)
    if Engine.Status(j) == "done" then return true end
    return tk ~= nil and t.q ~= nil and t.q > 0 and Engine.BehindYou(t, true)
  end
  if (k == "goto" or k == "fly" or k == "hearth" or k == "note" or k == "fp" or k == "bind" or k == "train" or k == "bonus") and not (k == "fly" and ns.ChoiceFor and ns.ChoiceFor(i)) then
    local list, seen, done = steps(), 0, 0
    for j = i + 1, math.min(#list, i + 15) do
      local t = list[j]
      if t.k == "turnin" or t.k == "obj" then -- real progress only: accepts can be done long before you get there
        seen = seen + 1
        if passed(j, t) then done = done + 1 else break end
        if seen >= 2 then break end
      end
    end
    if seen >= 2 and done == seen then return "done" end
  end
  -- a flight (or hearth) to nothing: every step from it to the next travel is already done - the safety-net pick-up of
  -- a quest you already have (ensure-steps) sat in the Wetlands between two Stormwind stops, and the list read "Fly to
  -- Wetlands, Fly to Stormwind" twice over
  if (k == "fly" or k == "hearth" or k == "boat") and not (ns.ChoiceFor and ns.ChoiceFor(i)) then
    local list, any = steps(), false
    for j = i + 1, math.min(#list, i + 40) do
      local t = list[j]
      if t.k == "fly" or t.k == "hearth" or t.k == "boat" then break end
      any = true
      if not passed(j, t) then any = nil; break end
    end
    if any then return "done" end
  end
  return "todo"
end
-- during a refresh (and the card / list redraw it triggers) each step's status is worked out once and reused
local batch = nil
function Engine.Status(i)
  if batch then local c = batch[i]; if c then return c end end
  local st = statusRaw(i)
  if batch then batch[i] = st end
  return st
end
-- a look over the route that changes nothing (the route window drawn): each step's status worked out once for it, as
-- in a refresh. Opening the route window asked most steps' status three times (the list, the done count, the zones
-- ahead) - 8,300 at level 12, each one asking the chain-cut walk too: 77 -> 38 ms at orc 12, 94 -> 45 ms at paladin 12
-- (perf gate). Inside a refresh, or a route job's slice (its statuses are the job's), fn just runs.
function Engine.ReadPass(fn)
  if batch or (ns.sliceCo and coroutine.running() == ns.sliceCo) then return fn() end
  batch = {}
  local ok, err = pcall(fn)
  batch = nil
  if not ok then error(err, 0) end
end
function Engine.IsDone(i) return Engine.Status(i) == "done" end
-- would step i be to do if the live solve took it up from behind you (Next.taken)? Behind you is the only thing taking
-- it lifts: a breadcrumb whose quest is yours, a quest not offered, one you said you're not doing stay done. The solve
-- offered Raven Hill from behind you with Worgen in the Woods done, and the card showed it "done" (mutate sweep)
function Engine.TodoIfTaken(i)
  local s = steps()[i]
  if not s then return false end
  Engine.asTaken = s
  local ok, st = pcall(statusRaw, i)
  Engine.asTaken = nil
  return ok and st == "todo"
end

-- Finding your place in the built-in plan (see Engine.BehindYou): the first time this character meets it, and again
-- when you come back to it more than JOIN_GAP levels on (the addon was off, or you were on a plan of your own).
-- Where the plan stands for you without any of that - the first step still to do - tells which you are: within
-- JOIN_GAP levels of you, you are following it, and nothing changes; further back, you join at your level.
-- force (/fr rejoin): join at your level whatever the plan says.
function Engine.PlaceDue()
  local key = ns.planKey and ns.planKey.starter
  if not (key and ns.char) then return false end
  -- (on the plan's path only: a side trip or a dungeon route has no levels to tell by)
  local d = ForeverRouteData
  if not d or d.branch or d.dungeon or d.zoneRoute or d.special then return false end
  -- not before the game has told us the quests you've done: on a cold login it may not have yet, and a player
  -- following the plan would read as one joining it (and lose up to JOIN_GAP levels of it, quests in the log too)
  if (UnitLevel("player") or 1) > 5 then
    if not next(State.completed or {}) and State.RefreshCompleted then State.RefreshCompleted() end
    if not next(State.completed or {}) then return false end
  end
  local j = ns.char.join
  if not (j and j.plan == key) then return true end
  return (UnitLevel("player") or 1) - (tonumber(j.seen) or 0) > Engine.JOIN_GAP
end
-- the quests of the plan that were in your log when you joined it (a join made before this was kept: as of now)
function Engine.JoinHad()
  local j = ns.char and ns.char.join
  if not (j and ns.planKey and j.plan == ns.planKey.starter and tonumber(j.level) and j.level > 1) or j.had then return end
  local had = {}
  for _, s in ipairs(steps()) do if s.q and s.q > 0 and not had[s.q] and State.OnQuest(s.q) then had[s.q] = true end end
  j.had = had
end
function Engine.FindPlace(force)
  Engine.ForgetDone()
  if force then Engine.ResetFloor() end -- (a rejoin: your place in the plan starts again from where you join)
  local key = ns.planKey and ns.planKey.starter
  if not (key and ns.char) then return nil end
  local L = UnitLevel("player") or 1
  local old = ns.char.join and ns.char.join.plan == key and ns.char.join or nil
  local level, fresh = L, true
  if not force then
    local saved = batch
    batch, Engine.noPlace = nil, true -- (no reuse: these are the statuses without a place)
    local ok, first = pcall(Engine.Compute)
    batch, Engine.noPlace = saved, nil
    local e = ok and first and Engine.PlanLevel(first)
    -- within JOIN_GAP levels of where the plan stands for you, or the plan reaches your level in its first stretch
    -- (you are still in the start zone): you are following it
    local at = joinStep(L)
    -- (the first time you meet the plan, its first step left to do must also be on your continent: the quests before it
    -- may be gray only because you levelled elsewhere - an Undead at 16 who levelled in Durotar and the Barrens read as
    -- "following" the plan in Silverpine, and the card sent him from the Barrens to Silverpine through Orgrimmar and
    -- the Undercity; joining, the stretch around you is priced against it - Engine.ChooseStart)
    local away = false
    local here = not old and first and L > 5 and Engine.HereMap() or nil
    if here then
      local _, px, py = State.Position()
      local mine = px and select(3, LibStub("HereBeDragons-2.0"):GetWorldCoordinatesFromZone(px, py, here))
      local list = steps()
      for j = first, math.min(#list, first + 8) do
        local w = ns.Util.WPos(list[j])
        if w then away = mine ~= nil and w[3] ~= mine; break end
      end
    end
    if not e or at == 1 or (e >= L - Engine.JOIN_GAP and not away) then level, fresh = old and old.level or 0, false end
  end
  if not fresh then
    ns.char.join = { plan = key, level = level, seen = L, first = old and old.first, had = old and old.had }
    if batch then wipe(batch) end
    return level
  end
  -- joining: where to start (Engine.ChooseStart), and the quests you bring along
  local first, priced = nil, {}
  if L > 1 then
    local ok, a, b = pcall(Engine.ChooseStart, L)
    if ok then first, priced = a, b or {} elseif ns.LogError then ns.LogError("join", a) end
  end
  ns.char.join = { plan = key, level = level, seen = L, first = first }
  Engine.JoinHad()
  if batch then wipe(batch) end
  if L > 1 and not (old and old.level == L and old.first == first and not force) then
    local _, at = Engine.Place()
    local function k(n) return string.format("%.1fk", n / 1000) end
    local function one(p) return p.zone .. " (step " .. p.from .. (p.plan and ", the plan's trip at your level" or "") .. "): about " .. k(p.score or p.xph) .. " XP in the next hour - " .. p.turnins .. " hand-ins, " .. math.floor(p.work / 60 + 0.5) .. " min of work, " .. math.floor(p.extra / 60 + 0.5) .. (p.plan and " min to get there" or " min of travel added") end
    local won = priced[1] and ("start in " .. one(priced[1]) .. (priced[2] and ("; next best " .. one(priced[2])) or "; nothing else priced")) or "nothing to price (no position, or no stretch near your level): the plan's trip at your level"
    if ns.Why then ns.Why("join", "joined the built-in plan at level " .. L .. (at and (", its step " .. at) or "") .. ": " .. won) end
    local say = function()
      ns.Print("You join the built-in plan at level " .. L .. ": what it does before that is behind you" .. (at and at > 1 and (" (" .. (at - 1) .. " steps)") or "") .. "."
        .. (first and priced[1] and (" You start in " .. priced[1].zone .. ": worth more from where you stand (about " .. k(priced[1].score or priced[1].xph) .. " XP in the next hour" .. (priced[2] and (" against " .. k(priced[2].score or priced[2].xph) .. " in " .. priced[2].zone) or "") .. ").") or "")
        .. " Quests in your log from the parts behind you are yours to finish or drop - /fr logcheck lists them. (/fr rejoin does this again at your level.)")
    end
    if force then say() else C_Timer.After(7, say) end
  end
  return level
end
function Engine.Rejoin()
  Engine.ForgetDone()
  if not (ns.planKey and ns.planKey.starter) then ns.Print("Only on the built-in plan: a plan of your own is made from your save and starts where you are."); return end
  Engine.FindPlace(true)
  Engine.Refresh()
end
-- your level, each time the addon sees you level on the built-in plan: a gap in it is time spent away from the plan
ns.On("PLAYER_LEVEL_UP", function(level)
  local j = ns.char and ns.char.join
  if j and ns.planKey and j.plan == ns.planKey.starter then j.seen = tonumber(level) or UnitLevel("player") or j.seen end
end)
-- not before you are in the world: the quest log and the quests you have done are known from then on
ns.On("PLAYER_ENTERING_WORLD", function() Engine.placeReady = true end)

-- The run of done steps from the plan's start, remembered (Engine.Compute): at level 50 that is ~2000 steps, each
-- worked out again on every refresh (7-8 ms, the perf battery). A done step comes back only through what resets it
-- here (Engine.ForgetDone: undo, back, a skip or jump, a quest dropped, a level, a bind, a dungeon, another route or
-- place in the plan) - and for anything else, the run is checked again in the background after each refresh that used
-- it (a slice a frame); a step found not done there resets it and refreshes.
local doneRun = { list = nil, k = 0, step = nil, key = nil }
Engine.doneRunMiss = 0 -- (the simulator: times the check found the run wrong)
function Engine.ForgetDone()
  doneRun.list = nil; doneRun.k = 0
  if Engine.InvalidateProgress then Engine.InvalidateProgress() end
end
local function doneKey(skipFrom, skipTo)
  local c = ns.char or {}
  local j = c.join
  return table.concat({ tostring(c.manualDone), tostring(c.skipped), tostring(c.nope), tostring(j), j and tostring(j.level) or "", j and tostring(j.first) or "",
    tostring(UnitLevel and UnitLevel("player")), tostring(skipFrom), tostring(skipTo), tostring(ForeverRouteData) }, "|")
end
local verify -- the background check: { co }
local vdriver = CreateFrame and CreateFrame("Frame") or nil
local function verifyStep()
  local v = verify
  if not v then if vdriver then vdriver:Hide() end return end
  if ns.Jobs.Busy("route") then return end -- (one slicer a frame: a route change's passes first)
  ns.sliceCo, ns.sliceT0, ns.sliceBudget = v.co, debugprofilestop(), 0.5
  local ok, wrong = coroutine.resume(v.co)
  ns.sliceCo = nil
  if verify ~= v then return end
  if not ok or coroutine.status(v.co) == "dead" then
    verify = nil; if vdriver then vdriver:Hide() end
    if not ok then if ns.LogError then ns.LogError("donerun", wrong) end; Engine.ForgetDone(); return end
    if wrong then
      Engine.doneRunMiss = Engine.doneRunMiss + 1
      if ns.Why then ns.Why("donerun", "step " .. wrong .. " is not done after all: the plan is looked at from its start again") end
      Engine.ForgetDone(); Engine.RefreshBg()
    end
  end
end
if vdriver then vdriver:Hide(); vdriver:SetScript("OnUpdate", function() local ok, err = pcall(verifyStep); if not ok then verify = nil; vdriver:Hide(); if ns.LogError then ns.LogError("donerun", err) end end end) end
Engine._verifyDriver = vdriver -- (the perf battery ticks it)
local function checkRun(list, k)
  local key = doneRun.key
  verify = { co = coroutine.create(function()
    for j = 1, k do
      if j % 16 == 0 then ns.MaybeYield() end
      if doneRun.list ~= list or doneRun.key ~= key then return nil end -- (reset meanwhile)
      if j > doneRun.skipFrom0 and j <= doneRun.skipTo0 then -- (the part of the plan your place in it passes)
      elseif Engine.Status(j) ~= "done" then return j end
    end
    return nil
  end) }
  if vdriver then vdriver:Show() end
end
-- (tests and the simulator: the run checked at once, every time it is used)
Engine.CHECK_RUN_NOW = false
function Engine.SettleDone() while verify do local v = verify; ns.sliceCo, ns.sliceT0, ns.sliceBudget = v.co, debugprofilestop(), math.huge; local ok, wrong = coroutine.resume(v.co); ns.sliceCo = nil; if verify == v and (not ok or coroutine.status(v.co) == "dead") then verify = nil; if wrong or not ok then Engine.doneRunMiss = Engine.doneRunMiss + 1; Engine.ForgetDone() end end end end
-- Your place in the plan only moves forward: the floor, the furthest step of the plan the card has had as yours
-- (kept per route by step key in ns.char.floor). A quest from the part of the plan you passed - one you took up again
-- there, a pick-up that came back - no longer pulls your place back: Next offers its steps as extras when they are
-- near and worth it (Engine.BelowFloor). It pulled the Base, the zones ahead and the solve's window back to Wetlands
-- while the player was in Riverglades (code review). /fr undo, a rejoin or another place in the plan reset it.
local function floorIndex(list)
  local d = ForeverRouteData
  if not d or d.dungeon or d.special or Engine.noPlace or not ns.char then return nil end
  local fl = Engine._floor
  if not (fl and fl.list == list and fl.char == ns.char) then
    fl = { list = list, char = ns.char }
    local k = ns.char.floor and ns.char.floor[d.id]
    if k then for i = 1, #list do if Engine.Key(i) == k then fl.step = list[i]; break end end end
    Engine._floor = fl
  end
  return fl.step and planIndex().idx[fl.step] or nil
end
local function raiseFloor(list, i)
  local d = ForeverRouteData
  if not d or d.dungeon or d.special or Engine.noPlace or not ns.char then return end
  local cur = floorIndex(list)
  if cur and cur >= i then return end
  Engine._floor = { list = list, char = ns.char, step = list[i] }
  ns.char.floor = ns.char.floor or {}
  ns.char.floor[d.id] = Engine.Key(i)
end
Engine.FloorIndex = function() return floorIndex(steps()) end
function Engine.ResetFloor()
  local d = ForeverRouteData
  Engine._floor = nil
  if d and ns.char and ns.char.floor then ns.char.floor[d.id] = nil end
end
-- the plan's steps below your place still to do for quests in your log (Next.lua offers them as extras): at most n
function Engine.BelowFloor(planned, n)
  local out, list = {}, steps()
  if not planned then return out end
  for j = planned - 1, math.max(1, planned - 400), -1 do
    local t = list[j]
    if t.q and t.q > 0 and State.OnQuest(t.q) and Engine.Status(j) == "todo" then out[#out + 1] = j; if #out >= (n or 12) then break end end
  end
  return out
end
-- Level 60 on the plan: no more questing, the route is done whatever plan steps are left - the card celebrates (the
-- user, 1.6.7). Not a zone, dungeon, special or branch route: those you picked are yours to finish. One level check -
-- nothing is worked out per refresh for a 60 (no scan, no solve, no trips). Unless you ask to finish the quests you
-- hold ("Finish my quests" on the card, ns.char.finish60, kept per character): then the plan is only their objectives
-- and hand-ins (Engine.finishNow, statusRaw) - nothing new picked up, no travel steps (the card's live trip gets you
-- there), no place or floor in the plan (the quests you hold are wherever the plan passed them)
Engine.MAX_LEVEL = 60
local function atCap()
  local d = ForeverRouteData
  return d ~= nil and not (d.zoneRoute or d.dungeon or d.special or d.branch) and ((UnitLevel and UnitLevel("player")) or 1) >= Engine.MAX_LEVEL
end
function Engine.Capped() return atCap() and not (ns.char and ns.char.finish60) end
function Engine.Finishing() return atCap() and (ns.char and ns.char.finish60) and true or false end
-- "Finish my quests" on (true) or off (back to the level 60 card)
function Engine.SetFinishing(on)
  if not ns.char then return end
  ns.char.finish60 = on and true or nil
  Engine.finishNow = Engine.Finishing()
  Engine.view = nil
  Engine.ForgetDone()
  Engine.Refresh()
end
function Engine.Compute()
  Engine.cappedNow = Engine.Capped() -- (Engine.CardAt reads it: no step on the card for a 60)
  Engine.finishNow = not Engine.cappedNow and Engine.Finishing() -- (statusRaw reads it)
  if Engine.cappedNow then Engine.forNow, Engine.planDone, Engine.levelHold = false, true, nil; return nil end
  local finishing = Engine.finishNow
  -- the first step you can act on now. A step that needs a higher level ("wait") or a quest that isn't in your log
  -- ("blocked") doesn't hold up the route: it is passed over and comes back as soon as it can be done.
  local list, fallback = steps(), nil
  -- (firstFull: the first pick-up waiting for room in your log; firstHigh: the first quest step waiting for your level -
  -- red to you, or below its level. The guards below hold the plan on them, not on whichever wait came first)
  local firstFull, firstHigh
  local lvlNow = (UnitLevel and UnitLevel("player")) or 1
  local function held(i, st)
    fallback = fallback or i
    if st == "full" then firstFull = firstFull or i
    elseif st == "wait" and not firstHigh then
      local t = list[i]
      if t.q and t.q > 0 and (Engine.TooHigh(t) or (t.minLevel and lvlNow < t.minLevel)) then firstHigh = i end
    end
  end
  local skipFrom, skipTo = nil, nil
  if not finishing then
    local _, at = Engine.Place()
    local f1, f2 = Engine.FirstStretch()
    if at and f1 and f1 > at then
      for i = f1, f2 do
        local st = Engine.Status(i)
        if st ~= "done" and st ~= "wait" and st ~= "blocked" and st ~= "later" then skipFrom, skipTo = at, f1 - 1; break end
      end
    end
  end
  -- where to start: past the remembered run of done steps, when it is still this plan, place and state
  local key = doneKey(skipFrom, skipTo)
  local start = 1
  local use = not Engine.noPlace and doneRun.list == list and doneRun.key == key and doneRun.k > 0 and list[doneRun.k] == doneRun.step
  if use then start = doneRun.k + 1 end
  if use and Engine.CHECK_RUN_NOW then
    for j = 1, doneRun.k do
      local st = (skipFrom and j >= skipFrom and j <= skipTo) and "done" or Engine.Status(j)
      if st ~= "done" then
        Engine.doneRunMiss = Engine.doneRunMiss + 1; start = 1; use = false
        local t = list[j]; Engine.doneRunWhy = Engine.doneRunWhy or {}
        if #Engine.doneRunWhy < 12 then Engine.doneRunWhy[#Engine.doneRunWhy + 1] = string.format("#%d %s %s now %s", j, tostring(t.k), tostring(t.name or t.text or t.dest or ""):sub(1, 30), st) end
        break
      end
    end
  end
  local run = start - 1
  local found, sawExtra
  -- (the live solve's pick-up from behind you, Next.taken, reads "todo" only while it is the solve's pick: it is an
  -- extra, never the plan's own step - as that it became Engine.planned, the solve moved on, it read "done" again and
  -- the card showed a done step: a level 19 joining Darkshore, mutate sweep). Nor what reads "todo" only through it: the
  -- rest of its quest, and a pick-up it unlocks - with Return to Verner's pick-up taken, A Baying of Gnolls (its
  -- follow-up, behind you) became the plan's step, and the card showed it done once the solve moved on (mutate sweep)
  local taken = ns.Next and ns.Next.taken
  if taken ~= nil and not Engine.BehindYou(taken, true) then taken = nil end
  local function extra(i) return taken ~= nil and (list[i] == taken or Engine.BehindYou(list[i], true)) end
  -- a step as the plan's look reads it: the part of the plan your place skips (the plan before the stretch you joined
  -- at) done - and a hand-in whose objective step is there, still to do, waits with it ("later": passed over, like a
  -- dungeon's). You start in that stretch, and the work you skip is not where you are: joining Riverglades at 39 with
  -- Wound Dressings in the log, the card showed its hand-in "Not finished" in red, and going back for its objective
  -- would fly you to the Badlands for cloth. The hand-in comes back once the quest is ready (the cloth drops anywhere);
  -- the objective is the live solve's to offer, as any step of a quest in your log behind your place (Engine.BelowFloor)
  local function look(i)
    if skipFrom and i >= skipFrom and i <= skipTo then return "done" end
    local st = Engine.Status(i)
    if st == "notready" and skipFrom then
      local objs = Engine.ObjStepsOf(list[i].q)
      for n = 1, #objs do
        local j = objs[n]
        if j > skipTo then break end
        if j >= skipFrom and Engine.Status(j) == "todo" then return "later" end
      end
    end
    return st
  end
  for i = start, #list do
    local st = look(i)
    if st ~= "done" and extra(i) then st = "extra" end
    if st == "extra" then sawExtra = true
    elseif st ~= "done" then
      if st == "wait" or st == "full" or st == "blocked" or st == "later" then held(i, st) else found = i; break end
    elseif run == i - 1 then run = i end
  end
  -- (not below your place in the plan: the floor. Only a step of a quest in your log is kept out down there - one you took
  -- up again from the part you passed: a pick-up waiting for a level or room in your log, a hand-in waiting for its
  -- quest, a quest you abandoned - those come back as they always did, and hold the floor)
  local F = not finishing and floorIndex(list) or nil
  local function below(i) local t = list[i]; return F and i < F and t.q and t.q > 0 and not t.added and State.OnQuest(t.q) end
  -- (but not a step of the quest the plan lands on: its hand-in or later objective above the floor keeps the quest's
  -- steps passed below it on the card - the floor stood past a kill objective, and the card sent a tester to hand in
  -- the quest at 0/12, "Not finished" in red)
  if found and below(found) then
    local f2
    for i = found + 1, #list do
      local st = look(i)
      if st ~= "done" and not extra(i) then
        if st == "todo" and below(i) then -- (passed below the floor)
        elseif st == "wait" or st == "full" or st == "blocked" or st == "later" then held(i, st) else f2 = i; break end
      end
    end
    found = f2
  end
  -- A hand-in not ready, with an objective step of its quest still to do before it (passed below the floor, above, or
  -- however else the look came past it): that objective is the step, not the hand-in "Not finished" in red - the floor
  -- stood past a kill objective, and the card sent a tester to hand in Preventative Measures at 0/12 (1.6.5)
  -- (only for a hand-in: a later objective of the same quest is work to do as it is, and going back for the passed one
  -- moved the card - and its pins - on every objective done, twice the time of one; the perf gate, orc @25)
  if found and list[found].k == "turnin" and list[found].q and Engine.Status(found) == "notready" then
    local objs = Engine.ObjStepsOf(list[found].q)
    for n = 1, #objs do
      local j = objs[n]
      if j >= found then break end
      if Engine.Status(j) == "todo" and not extra(j) then found = j; break end
    end
  end
  -- (a full log: the plan's pick-ups wait for room, but the plan does not run on without them through the trips and
  -- training meant for levels above you - with 36 other quests in the log, a level 35 was flown through a dozen zones to
  -- "train level 46 spells" (mutate --play). The pick-up stays on the card: "Quest log full - hand in or abandon")
  -- (the first full pick-up, not the first wait of any kind: a red pick-up, a hand-in not in your log or a dungeon's
  -- "later" before it let the plan run on as before - code review)
  -- The same for quests waiting for your level: a player 2-3 levels behind the plan finds a hub's top quests red, and
  -- the plan flew on to the next zone's trips; at the level-up those quests woke behind the card and pulled the plan's
  -- step back to the old zone (code review). What is left here is to do here: the card says the level it needs.
  -- ("Here": no trip between the waiting quest and that step - one in a zone the plan has left is not held for)
  local hold
  if found and not list[found].q and (firstFull or firstHigh) then
    local pl = Engine.PlanLevel(found)
    if pl and pl > lvlNow + 2 then
      local function here(w) for j = w + 1, found - 1 do if isTrip(list[j]) then return false end end return true end
      if firstFull and firstFull < found then hold = firstFull end
      if hold then Engine.levelHold = list[found]; found = nil end
    end
  end
  if not hold then Engine.levelHold = nil end
  -- (the floor rises to the first step not done - waiting ones too: they come back from there)
  local first = (found and fallback) and math.min(found, fallback) or found or fallback
  if first and not finishing and not below(first) then raiseFloor(list, first) end
  if not Engine.noPlace then
    doneRun.list, doneRun.key, doneRun.k, doneRun.step = list, key, run, list[run]
    doneRun.skipFrom0, doneRun.skipTo0 = skipFrom or 0, skipTo or -1
    if use and run > 0 and not Engine.CHECK_RUN_NOW then checkRun(list, start - 1) end
  end
  -- (nothing on the route to do now, only steps that wait - for your level, an earlier quest: done for now. The card
  -- says so and offers your next home bases, rather than a step you can't do - a level 59 at the plan's last training,
  -- "Nothing to learn until level 60", with three zones' quests open - mutate --play)
  Engine.forNow = not found and not hold and fallback ~= nil
  -- (and nothing left at all: every step done, none waiting, none held back as the live solve's pick-up - the plan is
  -- finished. The card says so - your next home bases - not a bare "Route complete" with no next step. At 60: Capped)
  Engine.planDone = not found and not hold and fallback == nil and not sawExtra
  return found or hold or fallback
end
function Engine.InDungeon(name)
  local here = ns.Dungeon.Here() -- by the instance id, or the game's name for it (Dungeon.lua)
  return here and Engine.SamePlace(here, name) or false
end
-- "Stormwind City" vs "Stormwind", "Lakeshire" vs "Redridge Mountains": loose place-name match
local function norm(x) return (x or ""):lower():gsub(" city$", ""):gsub("^the ", "") end
function Engine.SamePlace(a, b)
  if not a or not b then return false end
  local A, B = norm(a), norm(b)
  return A == B or A:find(B, 1, true) ~= nil or B:find(A, 1, true) ~= nil
end
-- a known flight path in this zone: node names look like "Sentinel Hill, Westfall" / "Lakeshire, Redridge"
-- the flight point of an "fp" step: by the flight master (Travel.KnowsFlightPoint: the flight map's own names); a step
-- without one, by its zone's name as before
function Engine.KnowsThisFlightPoint(s)
  if s.m and s.npc and ns.Travel and ns.Travel.KnowsFlightPoint then return ns.Travel.KnowsFlightPoint(s.m, s.npc) and true or false end
  return s.zone and Engine.KnowsFlightIn(s.zone) or false
end
function Engine.KnowsFlightIn(zone)
  local z = norm(zone); local first = z:match("^(%S+)")
  for name in pairs(State.knownTaxi or {}) do
    local n = name:lower()
    if n:find(z, 1, true) or (first and #first >= 5 and n:find(first, 1, true)) then return true end
  end
  return false
end

function Engine.Upcoming(from, n)
  local out, list = {}, steps()
  for i = (from or 0) + 1, #list do
    if #out >= n then break end
    if not Engine.IsDone(i) then out[#out + 1] = i end
  end
  return out
end

Engine.progressRevision = 0
local progress
-- A full refresh can change chain/place rules. Bag, XP and cooldown events only affect non-quest
-- steps (including travel passed because of those steps), so their totals can be adjusted by delta.
function Engine.InvalidateProgress(kind, quests)
  Engine.progressRevision = Engine.progressRevision + 1
  if not kind and not quests then progress = nil; return end
  if progress then
    for _, i in ipairs(progress.dynamic) do progress.dirty[i] = true end
    if quests then
      -- BehindYou follows the plan's prerequisite graph. Readiness can move a carried quest's
      -- next step across the join boundary, so include its follow-ups as well as travel steps.
      local seen, queue = {}, {}
      for q in pairs(quests) do seen[q] = true; queue[#queue + 1] = q end
      local head = 1
      while head <= #queue do
        local q = queue[head]; head = head + 1
        for _, i in ipairs(progress.byQuest[q] or {}) do progress.dirty[i] = true end
        for _, d in ipairs((ForeverRouteUnlocks and ForeverRouteUnlocks[q]) or {}) do
          if not seen[d] then seen[d] = true; queue[#queue + 1] = d end
        end
      end
    end
  end
end
local function progressState()
  local list, data = steps(), ForeverRouteData
  local p, ch = progress, ns.char or {}
  local join, taken = ch.join, ns.Next and ns.Next.taken
  local level = UnitLevel("player")
  if not p or p.list ~= list or p.n ~= #list or p.data ~= data or p.level ~= level or p.here ~= Engine.here
    or p.taken ~= taken or p.finish ~= Engine.finishNow or p.noPlace ~= Engine.noPlace
    or p.join ~= join or p.joinLevel ~= (join and join.level) or p.joinFirst ~= (join and join.first)
    or p.manual ~= ch.manualDone or p.skipped ~= ch.skipped or p.nope ~= ch.nope then
    p = { list = list, n = #list, data = data, level = level, here = Engine.here, taken = taken,
      finish = Engine.finishNow, noPlace = Engine.noPlace, join = join, joinLevel = join and join.level,
      joinFirst = join and join.first, manual = ch.manualDone, skipped = ch.skipped, nope = ch.nope,
      done = 0, values = {}, dirty = {}, dynamic = {}, byQuest = {}, legs = {}, legAt = {} }
    local leg
    for i, s in ipairs(list) do
      if not leg or s.k == "fly" then leg = { first = i, last = i, done = 0 }; p.legs[#p.legs + 1] = leg end
      leg.last, p.legAt[i], p.dirty[i] = i, leg, true
      if s.k ~= "accept" and s.k ~= "obj" and s.k ~= "turnin" then p.dynamic[#p.dynamic + 1] = i end
      if s.q then
        local by = p.byQuest[s.q]
        if not by then by = {}; p.byQuest[s.q] = by end
        by[#by + 1] = i
      end
    end
    progress = p
  end
  return p
end
local function updateProgress(p, first, last)
  Engine.ReadPass(function()
    local function update(i)
      local value = Engine.IsDone(i) and 1 or 0
      local delta = value - (p.values[i] or 0)
      p.values[i], p.dirty[i] = value, nil
      p.done = p.done + delta
      p.legAt[i].done = p.legAt[i].done + delta
    end
    if first then for i = first, last do if p.dirty[i] then update(i) end end
    else for i in pairs(p.dirty) do update(i) end end
  end)
end
function Engine.Progress()
  local t0 = debugprofilestop and debugprofilestop()
  local p = progressState()
  updateProgress(p)
  if t0 then ns.Time("progress", debugprofilestop() - t0) end
  return p.done, p.n
end

-- the step on the card, or the one you look at (Engine.view). While a route change's passes run over frames, the
-- card's step is the one it showed when they began (Engine.CardAt)
function Engine.Shown() return Engine.view or Engine.CardAt() end
-- progress through the zone you're in: the stretch between the travel steps around the shown step
-- where you are on your plan: its own step, not a stop shown ahead of it (a hand-in you chose with "Do it now", the
-- solve's pick) - the card's "Base:" count and the zones ahead said Burning Steppes, level 59, while a Stormwind hand-in
-- filed there was on the card (tester)
function Engine.PlanAt()
  local p, list = Engine.planned, steps()
  if p and list[p] and not Engine.view then return p end
  return Engine.Shown()
end
function Engine.LegProgress(i)
  local list = steps(); i = i or Engine.PlanAt()
  if not i or not list[i] then return 0, 0, nil end
  local p = progressState()
  local leg = p.legAt[i]
  local a, b = leg.first, leg.last
  updateProgress(p, a, b)
  local done = leg.done
  if list[a].k == "fly" and a < i then done = done - p.values[a]; a = a + 1 end
  local zone = list[i].zone or (list[a] and list[a].zone)
  return done, b - a + 1, zone
end

-- The zones ahead, from step i (default: where you are on the route) on, in order: { zone, quests = quests with something
-- still to do there on this visit (pick up, work or hand in), names = their quest names, first = its first step }. A zone you only pass through (no
-- hand-in, a flight path or two) is left out; travel steps belong to no zone. Up to n visits (default 8).
-- (the card's "why go there" line, the zones panel, the route list's chips - tester: they showed the plan from the start)
function Engine.ZonesAhead(i, n)
  local list, out = steps(), {}
  n = n or 8
  if not i then i = Engine.PlanAt() or Engine.current or 1 end
  local cur
  local function close()
    if cur and (cur.quests > 0 or cur.grind) then
      -- (a zone only passed through between two visits to one zone is left out: one visit then, not "Riverglades"
      -- twice in a row - tester)
      local last = out[#out]
      if last and last.zone == cur.zone then
        for k, q in pairs(cur.seen) do if not last.seen[k] then last.seen[k] = true; last.quests = last.quests + 1; if type(q) == "string" then last.names[#last.names + 1] = q end end end
        last.grind = last.grind or cur.grind
      else out[#out + 1] = cur end
    end
    cur = nil
  end
  local TRAVEL = { fly = true, hearth = true, boat = true, fp = true, bind = true }
  for j = i, #list do
    local s = list[j]
    if not TRAVEL[s.k] and s.zone and not Engine.IsDone(j) then
      if not cur or cur.zone ~= s.zone then
        close()
        if #out >= n then break end
        cur = { zone = s.zone, quests = 0, names = {}, seen = {}, first = j }
      end
      if s.q and s.q > 0 and not cur.seen[s.q] then cur.seen[s.q] = s.name or true; cur.quests = cur.quests + 1; cur.names[#cur.names + 1] = s.name end
      if s.k == "grind" then cur.grind = true end
    end
  end
  if #out < n then close() end
  return out
end

-- objective steps done in the same spot right after this one: shown together on the card
function Engine.Group(i)
  local list, out = steps(), {}
  local s = list[i]
  if not s or s.k ~= "obj" or s.unknown then return out end -- (work with no known place is not "here")
  for j = i + 1, math.min(#list, i + 8) do
    local t = list[j]
    if t.k ~= "obj" or t.unknown or t.m ~= s.m or math.abs((t.x or 0) - (s.x or 0)) > 0.02 or math.abs((t.y or 0) - (s.y or 0)) > 0.02 then break end
    if not Engine.IsDone(j) then out[#out + 1] = j end
  end
  return out
end

-- The engine's lock while a route change's passes run over frames (route jobs, ns.Jobs: Engine.Post, Engine.After).
-- A pass leaves Engine.current a number while it inserts stops (the passes after it depend on it), and the solve after
-- it takes many frames. Until the run ends:
-- - the card holds the step it showed when the run began, by its table (Engine.CardAt, Engine.Shown);
-- - a refresh asked for from outside waits for the end (Engine.Refresh), as do the full look and a count moving
--   (Engine.Announce: the strongest of them, once) and what acts on a step by its number (Engine.WhenIdle, Engine.Idle:
--   landing, arriving, a hearth cast, a jump), and no background solve starts (Next.PickAsync);
-- - a newer route change wins: the run's jobs are dropped, and until the next route job the refreshes run (run.free).
-- It ends when no route job is queued and no stage of the newest route change is to come: a refresh asked for meanwhile
-- runs then as a route job of its own, then the actors run, the state is announced, and the card moves once.
-- The run's own jobs work as they always did (none of this applies inside them). Under ns.Jobs.SYNC (tests, the
-- simulated players, tools/replay.js) a route job runs to its end inside Post, and there is no run at all.
Engine.routeGen = 0 -- (one more each route change: a job or a stage of an older one is dropped)
local run -- nil, or { shown = the card's step (table), shownAt = its number, due, free, idle = { fn }, state }
local pend = {} -- route change -> its stages (Engine.After) still to come
local cancelling = false
local switching -- (Engine.Switch: the refreshes its switch asks for are its own)
local function insideRoute() return ns.Jobs.Inside("route") end
function Engine.Busy() return run ~= nil and not run.free and not insideRoute() end
Engine._Run = function() return run end -- (tests)
-- the card's step (not the one you look at): Engine.current, or the run's hold
function Engine.CardAt()
  if Engine.cappedNow and Engine.Capped() then return nil end -- (a 60 on the plan: done, Engine.Capped - not a late solve's pick)
  local r = run
  if not (r and r.shown) or insideRoute() then return Engine.current end
  local list = steps()
  if list[r.shownAt or 0] ~= r.shown then
    r.shownAt = nil
    for j = 1, #list do if list[j] == r.shown then r.shownAt = j; break end end
    if not r.shownAt then r.shown = nil; return Engine.current end
  end
  return r.shownAt
end
-- a stop inserted at number at (Engine.InsertStop): the hold's number moves with it
function Engine.RunShift(at) local r = run; if r and r.shownAt and r.shownAt >= at then r.shownAt = r.shownAt + 1 end end
-- fn now, or when the run ends
function Engine.WhenIdle(fn) if Engine.Busy() then run.idle[#run.idle + 1] = fn; return true end; fn(); return false end
-- a handler that acts on a step by its number: while a run is on, it runs when the run ends (with its arguments)
function Engine.Idle(fn)
  return function(...)
    if not Engine.Busy() then return fn(...) end
    local n, a = select("#", ...), { ... }
    run.idle[#run.idle + 1] = function() fn(unpack(a, 1, n)) end
  end
end
-- State's FR_STATE / FR_PROGRESS while a run is on: kept (the full look over a count), fired once when it ends -> true
function Engine.Announce(ev)
  if not Engine.Busy() then return false end
  if ev == "FR_STATE" or not run.state then run.state = ev end
  return true
end
-- a refresh asked for meanwhile (a background solve that did not start, ...): when the run ends
function Engine.Due() if Engine.Busy() then run.due = true end end
-- a route job's state of its own: the statuses its refresh reuses (Engine.Status), swapped out while it waits for its
-- next frame - a status asked from outside meanwhile is neither served from it nor put in it
-- where you are, for a route job: taken once when it starts (a pass spread over frames prices every gap from the same
-- spot, as it did in one frame)
local jobPos
function Engine.Pos() if jobPos then return jobPos[1], jobPos[2], jobPos[3] end return State.Position() end
local function jobEnter(job)
  batch = job.batch
  if not job.pos then job.pos = { State.Position() } end
  jobPos = job.pos
end
local function jobLeave(job) job.batch = batch; batch = nil; jobPos = nil end
Engine._Batch = function() return batch end -- (tests)
local function jobAbort(job)
  batch, job.batch = nil, nil
  if ns.Next and ns.Next._Reset then ns.Next._Reset() end
  if job.onAbort then job.onAbort() end
end
-- a route job: fn spread over frames, for the newest route change (abort: what to put back if it is dropped)
function Engine.Post(name, fn, abort)
  return ns.Jobs.Post("route", fn, { gen = (not ns.Jobs.SYNC) and Engine.routeGen or nil, logAs = "route " .. name,
    enter = jobEnter, leave = jobLeave, abort = function(job) jobAbort(job); if abort then abort() end end })
end
-- a route change's stage: fn at its time after the change, as a route job (C_Timer.After was the whole pass and its
-- refresh in one frame: ~1 s at level 50 for a zone picked in Where to?). The stages queue in the order of their times,
-- so each reads the step the one before it settled on; a newer route change drops the ones still to come.
function Engine.After(delay, name, fn)
  local gen, async = Engine.routeGen, not ns.Jobs.SYNC
  if async then pend[gen] = (pend[gen] or 0) + 1 end
  C_Timer.After(delay, function()
    if async then pend[gen] = (pend[gen] or 1) - 1; if pend[gen] <= 0 then pend[gen] = nil end end
    if async and gen ~= Engine.routeGen then Engine.CheckIdle(); return end
    Engine.Post(name, fn)
  end)
end
-- A route switch you asked for (a zone picked in Where to?, back to your plan): fn switches; the card shows the new
-- route's plan step at once (no solve: Engine.noSolve), and the refresh with its solve is the first route job, spread over
-- frames before the switch's other stages - the card then moves once, when they are all done. It was the whole
-- refresh, twice, in the click's frame (~110 ms at level 50). Under ns.Jobs.SYNC: fn, then the refresh, as always.
function Engine.Switch(fn)
  if ns.Jobs.SYNC then fn(); Engine.Refresh(); return end
  switching = true
  local ok, err = pcall(fn)
  switching = nil
  Engine.noSolve = true
  local ok2, err2 = pcall(Engine.Refresh)
  Engine.noSolve = nil
  -- (the card shows that step from the first job's first frames: its trip - a search across the world, ~70 ms at
  -- level 50 - is worked out there, paused like the rest, and the card's fill finds it done)
  local s = steps()[Engine.current or 0]
  Engine.Post("refresh", function()
    if s and steps()[Engine.current or 0] == s then ns.Call(Engine.TravelFor, s); ns.Fire("FR_STEP", Engine.current) end
    Engine.Refresh()
  end)
  if not ok then error(err, 0) end
  if not ok2 then error(err2, 0) end
end
local function startRun()
  if run and not run.free then return end
  run = run or { idle = {} }
  run.free = nil
  run.shown, run.shownAt = steps()[Engine.current or 0], Engine.current
  Engine.holdShow = run
  -- (a trip asked again during the run is answered from its first search, as within one frame: Travel.Plan)
  if ns.Travel and ns.Travel.PinMemo then ns.Travel.PinMemo(run) end
  if ns.Next and ns.Next.Cancel then ns.Next.Cancel() end
end
function Engine.CheckIdle()
  local r = run
  if not r or cancelling or ns.Jobs.Busy("route") or (pend[Engine.routeGen] or 0) > 0 then return end
  if r.due and not r.free then r.due = nil; Engine.Post("refresh", function() Engine.Refresh() end); return end
  -- (the card's step at the end: its trip worked out in a job of its own, paused like the rest - the card's fill
  -- below finds it done)
  local s = not r.free and steps()[Engine.current or 0]
  if s and r.warmed ~= s then r.warmed = s; Engine.Post("trip", function() ns.Call(Engine.TravelFor, s) end); return end
  run = nil
  if Engine.holdShow == r then Engine.holdShow = nil end
  if ns.Travel and ns.Travel.UnpinMemo then ns.Travel.UnpinMemo(r) end
  for _, fn in ipairs(r.idle) do local ok, e = pcall(fn); if not ok and ns.LogError then ns.LogError("idle", e) end end
  if r.state then if ns.State and ns.State.Announce then ns.State.Announce(r.state) else ns.Fire(r.state) end end
  ns.Fire("FR_STEP", Engine.Shown())
end
ns.Jobs.posted = function(job) if job.kind == "route" and not ns.Jobs.SYNC then startRun() end end
ns.Jobs.ended = function(job) if job.kind == "route" then Engine.CheckIdle() end end
-- a newer route change: the run's jobs go (each puts back what it half did), and until its own first job the card is
-- not held - the switch's refresh shows the new route's step
ns.On("FR_ROUTE_CHANGED", function()
  Engine.routeGen = Engine.routeGen + 1
  if run then
    cancelling = true
    ns.Jobs.Cancel("route")
    cancelling = false
    run.free, run.shown, run.shownAt = true, nil, nil
    if Engine.holdShow == run then Engine.holdShow = nil end
    -- (it ends once the new change's stages are done - or next frame, if it has none)
    if C_Timer and C_Timer.After then C_Timer.After(0, Engine.CheckIdle) end
  end
end)

-- One refresh for one change: while the addon takes in a change (Engine.Coalesce: the log's full look, FR_STATE), the
-- refreshes its parts ask for - the plan's own, a hand-in added, a side trip's stop, a focus - are one, run when
-- they are all done. An objective finished ran three back to back (15 ms each at level 50: the perf battery)
local held -- nil, or true while a change is taken in; "due" once a refresh was asked for
local heldRefreshes = 0
function Engine.Coalesce(fn, quests)
  if held then return fn() end
  held = true
  heldRefreshes = 0
  local ok, err = pcall(fn)
  local due = held == "due"
  held = nil
  if due then
    Engine.bgSolve = true
    local ok2, e2 = pcall(Engine.Refresh, heldRefreshes == 1 and quests or nil)
    Engine.bgSolve = nil
    if not ok2 then error(e2, 0) end
  end
  if not ok then error(err, 0) end
end
for _, e in ipairs({ "QUEST_REMOVED", "HEARTHSTONE_BOUND", "PLAYER_ENTERING_WORLD", "FR_ROUTE_CHANGED", "FR_NOPE" }) do
  ns.On(e, function() Engine.ForgetDone() end)
end
-- (a new zone matters only going into or out of a dungeon: a run there is done while you are inside)
local wasInside
ns.On("ZONE_CHANGED_NEW_AREA", function() local inside = ns.Is(IsInInstance); if inside ~= wasInside then wasInside = inside; Engine.ForgetDone() end end)
-- what you're plainly doing holds the card: a step you chose (Do it now), or one your kills count for (for
-- PROGRESS_HOLD seconds after the last one). anyStatus: the hold whatever the step's status (the refresh checks it itself)
function Engine.Holding(anyStatus)
  local fi, why = Engine.focus, Engine.focusWhy
  if not (fi and (why == "chosen" or (why == "progress" and GetTime() - (Engine.focusAt or 0) < Engine.PROGRESS_HOLD))) then return false end
  return anyStatus or Engine.Status(fi) == "todo"
end
-- a refresh for something the game said (a new zone, logging in): its solve in the background, like the log's
function Engine.RefreshBg() Engine.Coalesce(Engine.Refresh) end
-- remove the steps pred says from the route (inserted stops only): numbers, keys and the remembered run follow
function Engine.RemoveSteps(pred)
  local list = steps()
  local n = 0
  for j = #list, 1, -1 do
    if list[j].inserted and pred(list[j]) then
      table.remove(list, j); n = n + 1
      if Engine.current and Engine.current > j then Engine.current = Engine.current - 1 end
      if Engine.planned and Engine.planned > j then Engine.planned = Engine.planned - 1 end
    end
  end
  if n == 0 then return 0 end
  for j = 1, #list do list[j].id = j end
  keyCache[list] = nil
  Engine.focus, Engine.focusWhy, Engine.view = nil, nil, nil
  if Engine.ForgetDone then Engine.ForgetDone() end
  return n
end
-- a background solve's pick on the card (no rescan of the plan: nothing but the order changed)
-- (a pick not to do is not shown - skipped, ticked, not offered meanwhile - except the plan's own step when the card's is
-- no longer to do either: a solve that let go the quest it had taken from behind you (Next.taken) gives back the plan's
-- step, and when that was a hand-in not finished yet the card stayed on the pick-up, now read "done" - mutate seed 3)
function Engine.ShowPick(pick)
  if not pick or pick == Engine.current then return end
  if Engine.Status(pick) ~= "todo" and not (pick == Engine.planned and not (Engine.current and Engine.Status(Engine.current) == "todo")) then return end
  local fi, why = Engine.focus, Engine.focusWhy
  if Engine.Holding() then return end
  Engine.focus = nil
  Engine.current = pick
  if Engine.view and Engine.view == Engine.current then Engine.view = nil end
  ns.Fire("FR_STEP", Engine.Shown())
end
function Engine.Refresh(quests)
  if held then held = "due"; heldRefreshes = heldRefreshes + 1; return end
  Engine.InvalidateProgress(nil, quests)
  if switching then return end -- (a route switch's own refreshes: Engine.Switch does them)
  if Engine.Busy() then run.due = true; return end -- (while a route change's passes run: when they end)
  if ns.Next then ns.Next.revision = (ns.Next.revision or 0) + 1 end
  local outer = batch == nil
  if outer then batch = {} else wipe(batch) end -- a nested refresh follows a change: start the reuse over
  if Engine.CHECK_RUN_NOW then Engine.GrayForget() end -- (tests change quests without the game's events)
  local t0 = outer and debugprofilestop and debugprofilestop()
  local ok, err = ns.Call(Engine.RefreshInner) -- (inside a route job: no pcall - a pause can't cross one)
  if outer then batch = nil end
  if t0 then ns.Time("refresh", debugprofilestop() - t0) end
  if not ok then error(err, 0) end
end
-- the login catch-up stays quiet; tests switch it to see the completion cue
function Engine.SetQuiet(q) local was = quiet; quiet = q and true or false; return was end
function Engine.RefreshInner()
  -- (a 60 on the plan: done - no place, no solve, no trips; the card shows "Route done - level 60")
  if Engine.Capped() then
    Engine.Compute()
    Engine.current, Engine.planned, Engine.focus, Engine.taxiHold = nil, nil, nil, nil
    if not Engine.holdShow and not Engine.noSolve then ns.Fire("FR_STEP", Engine.Shown()) end
    return
  end
  Engine.here = Engine.HereMap() -- the zone you are in, for this refresh (Engine.BehindYou)
  if Engine.placeReady and Engine.PlaceDue() then Engine.FindPlace() end
  if Engine.placeReady then Engine.JoinHad() end
  local before = Engine.current
  local beforeStep = before and steps()[before]
  -- (a refresh you asked for shows at once: no hold from a solve before it - but a route change's run holds the card)
  if not Engine.bgSolve and not (run and Engine.holdShow == run) then Engine.holdShow = nil end
  local tc = debugprofilestop and debugprofilestop()
  Engine.current = Engine.Compute()
  if tc and ns.Time then ns.Time("compute", debugprofilestop() - tc) end
  -- already standing in a travel step's destination (switched routes there, logged in there, rode in): it's done
  for _ = 1, 5 do
    local s = Engine.current and steps()[Engine.current]
    if not (s and s.k == "fly" and s.to and Engine.InZone and Engine.InZone(s.to)) then break end
    ns.char.manualDone[key(Engine.current)] = true
    if batch then wipe(batch) end
    Engine.current = Engine.Compute()
  end
  -- what to do next: the live solver's pick among the next stops you can do and finished quests near you (Next.lua),
  -- or, with it off, the old reordering - a later step you're working on or standing at (Engine.UpdateFocus)
  Engine.planned = Engine.current
  -- On a flight nothing on the ground is in reach: the step you took off with holds until you land, instead of the
  -- card re-picking as you pass over zones - a hand-in in Elwynn came up while flying over Stranglethorn (tester:
  -- "it can be a bit confusing to see it constantly updating"). Kept by the step itself (a stop inserted meanwhile
  -- moves its number). Landing plans again from where you are
  local aloft = ns.Is and UnitOnTaxi and ns.Is(UnitOnTaxi, "player")
  local holdAt
  -- (only a step the card chose: logged in or reloaded on a flight, no solve has run yet and the card's step is the
  -- plan's - on a zone home base its trip out of the zone, "Fly to Badlands" for Pearl Diving with Stranglethorn's
  -- quests left, held the whole flight (tester). Until a solve has picked, the card picks as on the ground; then it holds)
  if aloft then
    if Engine.taxiHold and not planIndex().idx[Engine.taxiHold] then Engine.taxiHold = nil end -- (another route since)
    if not Engine.taxiHold and before and (Engine.picked == steps() or not (ns.Next and ns.Next.Enabled())) then Engine.taxiHold = steps()[before] end
    holdAt = Engine.taxiHold and planIndex().idx[Engine.taxiHold]
    if holdAt and Engine.Status(holdAt) ~= "done" then Engine.current = holdAt else holdAt = nil end
  else
    Engine.taxiHold = nil
  end
  if holdAt then
    -- (held for the flight: no solve, no reordering)
  elseif Engine.noSolve then
    -- (a route switch's first look: the plan's step - its solve is a route job of its own, Engine.Switch)
  elseif ns.Next and ns.Next.Enabled() then
    -- what you're plainly doing wins over any solve: a step your kills count for (for Engine.PROGRESS_HOLD seconds
    -- after the last one), or one you chose (Do it now)
    local fi, why = Engine.focus, Engine.focusWhy
    local held = Engine.Holding(true)
    if held and Engine.Status(fi) == "todo" then
      Engine.current = fi
    elseif Engine.RecentProgress(Engine.current) then
      Engine.focus = nil -- (farming the plan's own step: your kills count for it - it stays, whatever circle you wander into)
    else
      Engine.focus = nil
      if Engine.bgSolve and ns.Next.PickAsync then
        -- taking in a change from the game (Engine.Coalesce): the solve runs in the background (it was 20-40 ms of a
        -- 50 ms refresh at level 50); meanwhile the card keeps the last pick while it is still to do, else the plan's
        -- step, and moves only if the solve picks another (Engine.ShowPick)
        local keep = ns.Next.LastPick()
        local planned, list = Engine.current, steps()
        if keep then Engine.current = keep end
        -- the card holds while the solve settles (at most Engine.HOLD_SECS): it showed the plan's step, then a moment
        -- later the solve's pick - two slides for one hand-in (persona review). Only when the card would change at all
        local token = {}
        if beforeStep and steps()[Engine.current] ~= beforeStep then
          Engine.holdShow = token
          if C_Timer and C_Timer.After then C_Timer.After(Engine.HOLD_SECS, function() if Engine.holdShow == token then Engine.holdShow = nil; ns.Fire("FR_STEP", Engine.Shown()) end end) end
        end
        ns.Next.PickAsync(planned, function(pick)
          local held = Engine.holdShow == token
          if held then Engine.holdShow = nil end
          if Engine.planned ~= planned or steps() ~= list then if held then ns.Fire("FR_STEP", Engine.Shown()) end return end
          local was = Engine.current
          if pick then Engine.picked = list end -- (a solve has chosen the card's step on this route: a flight may hold it)
          Engine.ShowPick(pick or planned)
          if held and Engine.current == was then ns.Fire("FR_STEP", Engine.Shown()) end
        end)
      else
        local ok, pick = ns.Call(ns.Next.Pick, Engine.current)
        if ok and pick then Engine.picked = steps() end
        -- (a pick is shown only while it is still to do - skipped, ticked or not offered: not again; as Engine.ShowPick)
        -- (or the quest from behind you it just took: its status was worked out a moment before it was taken)
        if ok and pick and (Engine.Status(pick) == "todo" or (ns.Next.taken and ns.Next.taken == steps()[pick])) then Engine.current = pick elseif not ok and ns.LogError then ns.LogError("next", pick) end
      end
    end
  else
    local fi = Engine.focus
    if fi and fi ~= Engine.current then
      local st = Engine.Status(fi)
      if st == "todo" and fi > (Engine.current or 0) then Engine.current = fi else Engine.focus = nil end
    end
  end
  if Engine.view and Engine.view == Engine.current then Engine.view = nil end
  -- the "done" cue only when the step you were on really got done: the current step also moves when live reordering
  -- picks another step, when you abandon a quest, when a level-up opens an earlier step, or after a jump
  if before and Engine.current ~= before and not quiet and beforeStep then
    local list, at = steps(), before
    if list[at] ~= beforeStep then at = planIndex().idx[beforeStep] end -- a stop was inserted before it, or another route
    -- skipped or "not doing" isn't done: no tick for those either
    local dropped = ns.char.skipped[key(at or 0) or ""] or (beforeStep.q and ns.Nope(beforeStep.q))
    if at and Engine.Status(at) == "done" and not dropped then ns.Fire("FR_STEP_DONE", at) end
  end
  if not Engine.holdShow and not Engine.noSolve then ns.Fire("FR_STEP", Engine.Shown()) end
end
Engine.HOLD_SECS = 0.3

-- Look at step i (a click on its row in the card, the route window, a map pin or the zones tab): right-click shows it
-- on the map, shift-click jumps there (noJump: not from here), a click looks at it - the step you are on ends looking.
-- One rule for every row (the card's used to differ from the route window's - code review)
function Engine.Look(i, btn, noJump)
  if not i then return end
  if btn == "RightButton" then ns.ShowOnMap(i) return end
  if IsShiftKeyDown() and not noJump then Engine.Jump(i) return end
  Engine.view = (i ~= Engine.CardAt()) and i or nil
  ns.Fire("FR_STEP", Engine.Shown())
end
-- history entries let Undo restore accidental skips/dones; one entry may cover several steps
local function remember(kind, ids) table.insert(ns.char.history, { kind = kind, ids = ids }); if #ns.char.history > 50 then table.remove(ns.char.history, 1) end end
Engine._remember = remember -- (Engine/Worth.lua)

local function markDone(i)
  i = i or Engine.Shown(); local id = key(i); if not id then return end
  ns.char.manualDone[id] = true
  remember("done", { id })
  Engine.view = nil
  Engine.Refresh()
end
-- you clicked done (the card's check, a slash command): Learn.lua records it as "ticked by hand"
function Engine.MarkDone(i) return markDone(i) end
-- the game told us (you arrived, landed, set your hearth, took the flight, trained): the same tick, not a hand tick -
-- through MarkDone these went into the learning data as things the route got wrong
function Engine.AutoDone(i) return markDone(i) end
function Engine.Skip(i)
  Engine.ForgetDone()
  i = i or Engine.Shown(); local s = steps()[i]; if not s then return end
  local ids = { key(i) }
  ns.char.skipped[key(i)] = true
  -- skipping a quest you don't have: its later objective / turn-in steps go too
  if s.q and (s.k == "accept" or not State.OnQuest(s.q)) and not State.IsCompleted(s.q) then
    for j = i + 1, #steps() do local t = steps()[j]; if t.q == s.q and not ns.char.skipped[key(j)] then ns.char.skipped[key(j)] = true; ids[#ids + 1] = key(j) end end
  end
  remember("skip", ids)
  Engine.view = nil
  if ns.ZoneCountsChanged then ns.ZoneCountsChanged() end -- (Where to?'s counts: a skipped pick-up cuts its chain)
  Engine.Refresh()
end
function Engine.Undo()
  Engine.ForgetDone()
  local h = table.remove(ns.char.history)
  if not h then ns.Print("nothing to undo."); return end
  for _, id in ipairs(h.ids) do ns.char.skipped[id] = nil; ns.char.manualDone[id] = nil end
  Engine.ResetFloor() -- (what you undid may be behind your place in the plan: it is yours again)
  for _, q in ipairs(h.nope or {}) do if ns.char.nope then ns.char.nope[q] = nil end end
  if h.nope then Engine.GrayForget() end
  Engine.view = nil
  if ns.ZoneCountsChanged then ns.ZoneCountsChanged() end -- (Where to?'s counts: what you undid counts again)
  Engine.Refresh()
  ns.Print(h.kind == "skip" and "skip undone." or h.kind == "nope" and "back on your route." or "undone.")
end
-- look at the previous step (view only; progress is unchanged)
function Engine.Back()
  Engine.ForgetDone()
  local cur = Engine.Shown() or (#steps() + 1)
  if cur <= 1 then return end
  Engine.view = cur - 1
  ns.Fire("FR_STEP", Engine.view)
end
function Engine.Forward()
  if not Engine.view then return end
  local nxt = Engine.view + 1
  Engine.view = (Engine.current and nxt < Engine.current) and nxt or nil
  ns.Fire("FR_STEP", Engine.Shown())
end
-- jump: backwards = view it; forwards = skip what's in between (undoable)
function Engine.Jump(i)
  -- (while a route change's passes run, the plan's numbers move: the jump waits, by the step itself)
  if Engine.Busy() then
    local s = steps()[i]
    return Engine.WhenIdle(function() local j = s and planIndex().idx[s]; if j then Engine.Jump(j) end end)
  end
  Engine.ForgetDone()
  local list = steps()
  if not list[i] then return end
  if not Engine.current or i <= Engine.current then
    Engine.view = (i ~= Engine.current) and i or nil
    ns.Fire("FR_STEP", Engine.Shown())
    return
  end
  local ids = {}
  for j = Engine.current, i - 1 do if not Engine.IsDone(j) then local id = key(j); ns.char.skipped[id] = true; ids[#ids + 1] = id end end
  remember("skip", ids)
  Engine.view = nil
  if ns.ZoneCountsChanged then ns.ZoneCountsChanged() end -- (Where to?'s counts: a skipped pick-up cuts its chain)
  Engine.Refresh()
end

function Engine.Arrived(i)
  if Engine.Busy() then return end -- (the arrow says it again once the route change's passes are done)
  local s = steps()[i]
  if s and s.k == "goto" and i == Engine.current then Engine.AutoDone(i) end
end

local function currentStep() local i = Engine.current; return i, i and steps()[i] end
local function nearCurrent(kind, within)
  -- the first not-done step of this kind among the next few (lets you do things a little early) - counted from the
  -- plan's place: with a quest from elsewhere on the card, training in town didn't tick the plan's train step (code review)
  -- (but the card's own step first, when it is of this kind: what you did is what it showed. With the plan's place on a
  -- stop added to the route that the solve passed, the card showed the trip after it - "Hearth to Darkshire" - and the
  -- hearth, counted from the plan's place, never ticked: the card came back to it after every objective, simplay hopper)
  local c = Engine.CardAt and Engine.CardAt()
  local cs = c and steps()[c]
  if cs and cs.k == kind and not Engine.IsDone(c) then return c end
  local i = Engine.planned or Engine.current -- (not PlanAt: that is the step you look at while you browse the route - review)
  if not i then return nil end
  for j = i, math.min(#steps(), i + (within or 0)) do
    local s = steps()[j]
    if s.k == kind and not Engine.IsDone(j) then return j end
  end
end

ns.On("FR_STATE", function() Engine.Refresh() end)
ns.On("BAG_UPDATE_DELAYED", function() Engine.InvalidateProgress("bonus") end)
ns.On("SPELL_UPDATE_COOLDOWN", function() Engine.InvalidateProgress("hearth") end)
ns.On("BAG_UPDATE_COOLDOWN", function() Engine.InvalidateProgress("hearth") end)
ns.On("PLAYER_XP_UPDATE", function() Engine.InvalidateProgress("grind") end)
ns.On("FR_ROUTE_CHANGED", function() Engine.InvalidateProgress() end)
ns.On("PLAYER_ENTERING_WORLD", function()
  quiet = true
  C_Timer.After(1, function() Engine.RefreshBg() end)
  C_Timer.After(3, function() Engine.RefreshBg(); quiet = false end)
end)
ns.On("PLAYER_XP_UPDATE", function() local _, s = currentStep(); if s and s.k == "grind" then Engine.Refresh() end end)
-- fly steps carry no coordinates, so the arrow and pins point at the nearest flight master in your zone (FlightMasters.lua)
local function inZone(to)
  local m = ns.State.Position()
  local guard = 0
  while m and guard < 6 do
    if m == to then return true end
    local info = C_Map.GetMapInfo(m); m = info and info.parentMapID; guard = guard + 1
  end
  return false
end
-- where a travel step without coordinates should point: the flight master in the zone you're in
function Engine.TravelTarget(s)
  if not s or s.x or s.k ~= "fly" then return nil end
  local m, px, py = ns.State.Position()
  local plan = Engine.TravelPlan(s)
  if plan and (plan.ride or not plan.via or plan.via == m) then return plan.m, plan.x, plan.y, nil end
  local list = m and ns.FLIGHT and ns.FLIGHT[m]
  if not list then return nil end
  local best, bd
  for _, fm in ipairs(list) do
    local d = (px and py) and ((fm[1] - px) ^ 2 + (fm[2] - py) ^ 2) or 0
    if not bd or d < bd then best, bd = fm, d end
  end
  return m, best[1], best[2], best[3]
end
-- how to get to a travel step's destination, from the flight paths you actually have. Aims at the first stop there
-- (where you're really going), and compares riding straight there with flying: walk to a flight master on your map,
-- the flight, then walk from where you land. nil = just fly as usual.
-- -> { ride = true (ride straight there) | via = uiMap to fly to first, viaName, m, x, y = where to go, stop = step }
Engine.FLIGHT_YARDS = 700 -- a flight costs about this much walking (take-off, the flight, landing)
local function stepIndex(s) if not s then return nil end return planIndex().idx[s] end
local function firstStop(s)
  if s._stop then return s._stop end
  local i = stepIndex(s); if not i then return nil end
  local list = steps()
  for j = i + 1, #list do
    local t = list[j]
    if t.k == "fly" or t.k == "hearth" then return nil end
    if t.m and t.x and not t.unknown and t.m == s.to then return t end
  end
end
function Engine.TravelPlan(s)
  local HBD = LibStub("HereBeDragons-2.0")
  if not (s and s.k == "fly" and s.to and not s.boat and ns.FLIGHT and HBD) then return nil end
  local destName = s.dest or s.text
  if not destName then return nil end
  local fm = ns.FLIGHT[s.to] and ns.FLIGHT[s.to][1]
  local stop = firstStop(s)
  local tx, ty = (stop and stop.x) or (fm and fm[1]) or 0.5, (stop and stop.y) or (fm and fm[2]) or 0.5
  local wx, wy, inst = HBD:GetWorldCoordinatesFromZone(tx, ty, s.to)
  if not wx then return nil end
  local d = function(ax, ay, bx, by) return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) end
  local pm, px, py = ns.State.Position()
  local hx, hy, hinst
  if pm and px then hx, hy, hinst = HBD:GetWorldCoordinatesFromZone(px, py, pm) end
  local rideYd = (hx and hinst == inst) and d(hx, hy, wx, wy) or nil
  -- the nearest flight master on your map (where a flight would start)
  local startYd
  for _, f in ipairs((pm and ns.FLIGHT[pm]) or {}) do
    local fx, fy, finst = HBD:GetWorldCoordinatesFromZone(f[1], f[2], pm)
    if fx and hx and finst == hinst then local dd = d(hx, hy, fx, fy); if not startYd or dd < startYd then startYd = dd end end
  end
  local plan = { m = s.to, x = tx, y = ty, stop = stop }
  if Engine.KnowsFlightIn(destName) then
    -- you can fly right there: only worth riding if the first stop is closer than the flight would make it
    if not (rideYd and fm) then return nil end
    local lx, ly = HBD:GetWorldCoordinatesFromZone(fm[1], fm[2], s.to)
    local flyYd = (startYd or 0) + Engine.FLIGHT_YARDS + (lx and d(lx, ly, wx, wy) or 0)
    if rideYd < flyYd then plan.ride = true; plan.yards = rideYd; return plan end
    return nil
  end
  -- no flight path there: fly to the one you have that lands closest to the first stop, unless riding is shorter
  local best
  for m, list in pairs(ns.FLIGHT) do
    local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(m)
    if info and info.name and m ~= s.to and Engine.KnowsFlightIn(info.name) then
      local fx, fy, finst = HBD:GetWorldCoordinatesFromZone(list[1][1], list[1][2], m)
      if fx and finst == inst then
        local dd = d(fx, fy, wx, wy)
        if not best or dd < best.d then best = { d = dd, m = m, name = info.name } end
      end
    end
  end
  if best and best.m ~= pm and not (rideYd and rideYd <= (startYd or 0) + Engine.FLIGHT_YARDS + best.d) then plan.via, plan.viaName = best.m, best.name
  else plan.ride = true; plan.yards = rideYd end
  return plan
end

-- any step: how to get there, when it is more than a walk.
-- -> nil (a walk in the zone you are in, or unknown), or { how = "fly" | "via" | "ride", m, x, y = where the arrow
--    points now, text = what to do, fm = flight master name when the arrow points at one }
-- One trip planner for every trip (ns.Travel): another zone or continent is always planned; a step in your own zone
-- is planned too when the walk is long, and comes back as a trip only when a flight you know is clearly quicker
-- (ns.Travel.Shortcut - shortcut = true on the trip: Darkshire to the west end of Duskwood by way of Sentinel Hill).
-- the same trip is asked for by the card, the arrow and the pins on every refresh: worked out once for the same step and
-- the same situation (where you are to a few yards, your level, the flight paths you know, flying or sailing, your
-- hearthstone, the trip you're on). A trip took ~15 ms; three of them made up most of a refresh on a long plan.
local tripMemo = {}
local function tripKey(s)
  local pm, px, py = ns.State.Position()
  local n = State.KnownTaxiCount()
  local okB, b = pcall(GetBindLocation)
  return table.concat({ tostring(pm), px and math.floor(px * 400) or "-", py and math.floor(py * 400) or "-", UnitLevel("player") or 0, n,
    tostring(ns.Is(UnitOnTaxi, "player")), tostring(ns.Arrow and ns.Arrow.aboard), tostring(okB and b), tostring(Engine.lastTripStep == s), (ns.char and ns.char.boundAt and ns.char.boundAt.m) or "-" }, "|")
end
function Engine.TravelFor(s)
  if not s then return nil end
  local k = tripKey(s)
  local m = tripMemo[s]
  if m and m.k == k then return m.v end
  local v = Engine.TravelForUncached(s)
  tripMemo[s] = { k = k, v = v }
  return v
end
function Engine.TravelForUncached(s)
  if not s or s.k == "hearth" or s.unknown then return nil end -- (no known place: no trip to plan)
  -- on a flight the taxi is taking you: nothing to plan from the sky. (Crossing a zone mid-air would otherwise
  -- plan a fresh trip from wherever you are above the ground - "Ride to Wetlands", an arrow at some town below.)
  -- The way on is planned again when you land.
  if ns.Is(UnitOnTaxi, "player") then
    local l = { how = "onflight", text = "On the flight - sit tight, the way on is planned when you land" }
    return { how = "aboard", text = l.text, legs = { l } }
  end
  if s.boat then
    -- the route's own "Boat to X" step, once the ship has sailed: the pier is behind you, nothing to point at
    -- until you land (the step ticks on arrival)
    if ns.Arrow and ns.Arrow.aboard then
      local l = { how = "aboard", text = "On the boat to " .. ((s.text or ""):match("^Boat to (.+)$") or s.dest or "the other side") .. " - sit tight" }
      return { how = "aboard", text = l.text, legs = { l } }
    end
    -- not sailing yet: in the pier's zone the step's own pier is the target (nil below); from anywhere else, the
    -- way to that pier is planned like any other stop (not a straight line from Goldshire or the tram)
    if not (s.m and s.x) then return nil end
  end
  local pm, px, py = ns.State.Position()
  -- another continent: boats, flights you know and rides, as one planned trip (ns.Travel)
  local HBD = LibStub("HereBeDragons-2.0")
  if pm and px and ns.Travel then
    local tm, tx, ty, tname, tstop -- (tstop: who the trip ends at, the last leg in their zone names them)
    if s.k == "fly" and s.to and not s.boat then
      local st = firstStop(s); local fm = ns.FLIGHT and ns.FLIGHT[s.to] and ns.FLIGHT[s.to][1]
      tm, tx, ty, tname = s.to, (st and st.x) or (fm and fm[1]) or 0.5, (st and st.y) or (fm and fm[2]) or 0.5, s.dest or s.text
      tstop = st and st.npc
    elseif s.m and s.x then tm, tx, ty, tname, tstop = s.m, s.x, s.y, s.zone, s.npc end
    if tm then
      local a1, a2, ai = HBD:GetWorldCoordinatesFromZone(px, py, pm)
      local b1, b2, bi = HBD:GetWorldCoordinatesFromZone(tx, ty, tm)
      -- somewhere no trip can start from (on the Deeprun Tram, in a dungeon) and the step is out in the world: the trip
      -- you were on carries on (the tram leg is under way); with none, it is planned when you come out. A trip planned
      -- from here would start from coordinates that mean nothing outside (it pointed "down 98 yd" from the tram).
      if pm ~= tm and ns.Travel.OnNetwork and not ns.Travel.OnNetwork(pm, px, py) and not (a1 and b1 and ai == bi) then
        local last = Engine.lastTripStep == s and Engine.lastTrip
        if last and last[1] then
          local legs = {}
          for k, l in ipairs(last) do legs[k] = l end
          if ns.Travel.IsTram(legs[1]) then legs[1] = { how = "aboard", text = (legs[1].text:gsub("^Take the", "On the")) .. " - sit tight" } end
          return { how = "aboard", text = ns.Travel.Describe(legs), legs = legs }
        end
        local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(pm)
        local l = { how = "aboard", text = "In " .. ((info and info.name) or "here") .. ": the way on is planned when you come out" }
        return { how = "aboard", text = l.text, legs = { l } }
      end
      -- any other zone (or continent): the trip planner weighs riding, your flight paths and boats together.
      -- Your own zone: the same planner, asked only whether something beats the walk by a margin (nil: walk)
      if a1 and b1 then
        local legs
        local shortcut = ai == bi and pm == tm
        if not shortcut then legs = ns.Travel.Plan({ m = pm, x = px, y = py }, { m = tm, x = tx, y = ty, name = tname, stop = tstop })
        elseif s.k ~= "fly" and ns.Travel.Shortcut then
          legs = ns.Travel.Shortcut({ m = pm, x = px, y = py }, { m = tm, x = tx, y = ty, name = s.npc or tname })
        end
        if legs and legs[1] then
          -- already on the boat of the first leg: that leg is done, sit tight
          if legs[1].how == "boat" and ns.Arrow and ns.Arrow.aboard then
            local dest = legs[1].text:match(".* to (.+)$") or "the other side" -- the last "to": the boat's destination
            legs[1] = { how = "aboard", text = "On the boat to " .. dest .. " - sit tight" }
            return { how = "aboard", text = ns.Travel.Describe(legs), legs = legs }
          end
          -- which step it is for: a trip worked out for a step you only looked at must not teach the boat's pier
          Engine.lastTrip, Engine.lastTripStep = legs, s
          local text = ns.Travel.Describe(legs)
          if ns.Why then ns.Why("travel", "to " .. (tname or "another continent") .. ": " .. text) end
          return { how = legs[1].how, m = legs[1].m, x = legs[1].x, y = legs[1].y, text = text, legs = legs, shortcut = shortcut or nil }
        end
      end
    end
  end
  if not (s.m and s.x) or s.k == "fly" then return nil end
  if not pm or pm == s.m then return nil end
  local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(s.m)
  local destName = (info and info.name) or s.zone or "there"
  local plan = Engine.TravelPlan({ k = "fly", to = s.m, dest = destName, text = destName, _stop = s })
  local function atFlightMaster(goal)
    local list = ns.FLIGHT and ns.FLIGHT[pm]; if not list then return nil end
    local best, bd; for _, f in ipairs(list) do local dd = (f[1] - px) ^ 2 + (f[2] - py) ^ 2; if not bd or dd < bd then best, bd = f, dd end end
    local m, x, y, fm = pm, best[1], best[2], best[3]
    return { how = "fly", m = m, x = x, y = y, fm = fm, text = "Fly to " .. goal .. (fm and (" - flight master " .. fm) or "") }
  end
  if not plan then return atFlightMaster(destName) end -- you have its flight path and flying is quicker
  if plan.ride then return { how = "ride", m = s.m, x = s.x, y = s.y, text = ns.RideWord() .. " to " .. destName .. (plan.yards and (" - " .. ns.Style.Distance(plan.yards)) or "") } end
  if plan.via and plan.via ~= pm then
    local t = atFlightMaster(plan.viaName); if t then t.how = "via"; t.text = "No " .. destName .. " flight path yet: fly " .. (t.fm and ("from " .. t.fm .. " ") or "") .. "to " .. plan.viaName .. ", then ride" end
    return t
  end
  return { how = "ride", m = s.m, x = s.x, y = s.y, text = ns.RideWord() .. " to " .. destName }
end

-- arriving in the destination zone completes a fly step, however you got there (flew, rode, or were already there)
Engine.InZone = inZone
local function travelDone()
  local i, s = currentStep()
  if s and s.k == "fly" and s.to and inZone(s.to) then Engine.AutoDone(i) end
end
-- (what acts on the card's or the plan's step by its number waits while a route change's passes move the numbers:
-- Engine.Idle)
travelDone = Engine.Idle(travelDone)
ns.On("ZONE_CHANGED_NEW_AREA", function() C_Timer.After(1, function() travelDone(); Engine.RefreshBg() end) end)
ns.On("PLAYER_ENTERING_WORLD", function() C_Timer.After(4, travelDone) end)
ns.On("HEARTHSTONE_BOUND", function()
  -- remember where you bound (the map you were on and the name the game gives it); every hearth step on that map
  -- counts as done while you stay bound there
  local m = ns.State.Position()
  -- (bound at one of the plan's bind stops - its innkeeper within 100 yd: that stop's own map, so the bind step and
  -- every hearth to it match whatever map id the game hands out indoors. A tester's bind went unnoticed)
  local HBDx = LibStub("HereBeDragons-2.0")
  local px, py, pinst = HBDx:GetPlayerWorldPosition()
  if px then
    for _, t in ipairs(steps()) do
      if t.k == "bind" and t.m and t.x then
        local x, y, inst = HBDx:GetWorldCoordinatesFromZone(t.x, t.y, t.m)
        if x and inst == pinst and (x - px) ^ 2 + (y - py) ^ 2 <= 100 * 100 then m = t.m; break end
      end
    end
  end
  ns.char.boundAt = { m = m, name = GetBindLocation and GetBindLocation() or nil }
  C_Timer.After(0.5, function() ns.char.boundAt.name = GetBindLocation and GetBindLocation() or ns.char.boundAt.name; Engine.Refresh() end)
  Engine.Refresh()
end)
-- standing in the place your hearthstone is set (the game's name for it is the name of where you are): that is the
-- map it is on, whenever you set it - before the addon, or while it was off
local function learnBind()
  local okB, b = pcall(GetBindLocation)
  if not okB or type(b) ~= "string" or b == "" or not ns.char then return end
  local at = ns.char.boundAt
  if at and at.name == b and at.m then return end
  local okS, sub = pcall(GetSubZoneText); local okZ, zone = pcall(GetRealZoneText)
  if not ((okS and sub == b) or (okZ and zone == b)) then return end
  local m = ns.State.Position()
  if not m then return end
  ns.char.boundAt = { m = m, name = b }
  if ns.Why then ns.Why("hearth", "your hearthstone is set here (" .. b .. "): noted") end
end
Engine.LearnBind = learnBind
for _, ev in ipairs({ "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "ZONE_CHANGED_NEW_AREA" }) do ns.On(ev, function() pcall(learnBind) end) end
ns.On("PLAYER_ENTERING_WORLD", function() C_Timer.After(2, function() pcall(learnBind) end) end)
-- opening a flight map ticks a "get the flight path" step only at that flight master (same map) - not when you
-- open the map somewhere else to fly toward it (the zone check in the step status covers learning it normally)
ns.On("FR_TAXI_OPENED", Engine.Idle(function()
  local j = nearCurrent("fp", 3); if not j then return end
  local s = steps()[j]; local m = ns.State.Position()
  if s and (not s.m or s.m == m) then Engine.AutoDone(j) end
end))
-- once: undo "got the flight path" ticks from before that fix, where you still have no flight path in that zone
ns.On("FR_LOADED", function()
  if ns.char.fixFpTicks then return end
  ns.char.fixFpTicks = true
  C_Timer.After(2, function()
    local undone = 0
    for i, s in ipairs(steps()) do
      local k = s.k == "fp" and key(i)
      if k and ns.char.manualDone[k] and s.zone and not Engine.KnowsThisFlightPoint(s) then ns.char.manualDone[k] = nil; undone = undone + 1 end
    end
    if undone > 0 then ns.Print("Un-ticked " .. undone .. " \"get the flight path\" step" .. (undone == 1 and "" or "s") .. " you don't actually have yet."); Engine.Refresh() end
  end)
end)
-- hearthstone cast: complete a hearth step
ns.On("UNIT_SPELLCAST_SUCCEEDED", Engine.Idle(function(unit, _, spellID)
  if unit ~= "player" then return end
  if spellID == 8690 then local j = nearCurrent("hearth", 1); if j then Engine.AutoDone(j) end end
end))
-- landing from a flight: complete a fly step (if it names a destination map, be in it)
local onTaxi = false
ns.On("PLAYER_CONTROL_LOST", function() C_Timer.After(0.5, function() onTaxi = ns.Is(UnitOnTaxi, "player") end) end)
ns.On("PLAYER_CONTROL_GAINED", Engine.Idle(function()
  if not onTaxi then return end
  onTaxi = false
  local j = nearCurrent("fly", 1)
  if j then
    local s = steps()[j]
    local m = ns.State.Position()
    -- (no position yet, as at a loading screen: an unnamed flight still counts, a named one waits for the zone change)
    local info = m and C_Map.GetMapInfo(m)
    if not s.to or s.to == m or (info and info.parentMapID == s.to) then Engine.AutoDone(j) end
  end
end))
-- class trainer visits complete a train step (profession trainers don't)
local atClassTrainer = false
ns.On("TRAINER_SHOW", function() atClassTrainer = not (IsTradeskillTrainer and IsTradeskillTrainer()) end)
ns.On("TRAINER_CLOSED", function()
  if not atClassTrainer then return end
  atClassTrainer = false
  -- (not a stop that waits for your level - "Nothing to learn until level 60": you learned nothing there, and ticked it
  -- never came back at 60 - mutate --play, a level 59 at the plan's last training)
  Engine.WhenIdle(function() local j = nearCurrent("train", 4); if j and Engine.Status(j) ~= "wait" then Engine.AutoDone(j) end end)
end)
