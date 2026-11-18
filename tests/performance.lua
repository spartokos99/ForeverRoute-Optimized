-- Run from the repository root with Lua 5.1 (or fengari for the portable checks).
unpack = unpack or table.unpack
loadstring = loadstring or load
local root = arg[1] or "."
local sep = package.config:sub(1, 1)
local function path(s) return root .. sep .. s:gsub("\\", sep) end
local addonDir = "ForeverRoute"
if not loadfile(path("addon\\ForeverRoute\\Core.lua")) then addonDir = "ForeverRoute-Optimized" end
local now, level, xp, cooldown, itemCount = 0, 30, 0, 0, 0
local log, completed, calls, timers, errors = {}, {}, {}, {}, {}
local function counted(k) calls[k] = (calls[k] or 0) + 1 end
local function ids()
  local out = {}
  for q in pairs(log) do out[#out + 1] = q end
  table.sort(out)
  return out
end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function GetTime() return now end
function time() return math.floor(now) end
function debugprofilestop() return os.clock() * 1000 end
function UnitLevel() return level end
function UnitXP() return xp end
function UnitXPMax() return 100000 end
function UnitFactionGroup() return "Alliance" end
function UnitClass() return "Paladin", "PALADIN", 2 end
function UnitOnTaxi() return false end
function UnitIsDeadOrGhost() return false end
function GetBindLocation() return "Stormwind" end
function GetItemCount() return itemCount end
function GetItemCooldown() return cooldown > 0 and now or 0, cooldown end
function geterrorhandler() return function(e) errors[#errors + 1] = e end end
function CreateFrame()
  return { RegisterEvent = function() end, SetScript = function(self, k, f) self[k] = f end,
    Hide = function() end, Show = function() end }
end
SlashCmdList = {}
StaticPopupDialogs = {}
DEFAULT_CHAT_FRAME = { AddMessage = function() end }
C_Timer = {
  After = function(delay, fn) timers[#timers + 1] = { at = now + delay, fn = fn } end,
  NewTicker = function() return { Cancel = function() end } end,
}
C_Map = { GetMapInfo = function(m) return { name = "Zone " .. m } end }
local hbd = {
  GetPlayerWorldPosition = function() return 500, 500, 0 end,
  GetPlayerZonePosition = function() return 0.5, 0.5, 1 end,
  GetWorldCoordinatesFromZone = function(_, x, y) return x * 1000, y * 1000, 0 end,
}
function LibStub() return hbd end
C_QuestLog = {
  GetNumQuestLogEntries = function() counted("log"); local n = #ids(); return n, n end,
  GetInfo = function(i) counted("info"); return { questID = ids()[i], level = level } end,
  IsOnQuest = function(q) counted("on"); return log[q] ~= nil end,
  IsComplete = function(q) counted("ready"); return log[q] and log[q].complete or false end,
  IsQuestFlaggedCompleted = function(q) counted("completed"); return completed[q] or false end,
  GetAllCompletedQuestIDs = function() local out = {}; for q in pairs(completed) do out[#out + 1] = q end; return out end,
  GetQuestObjectives = function(q)
    counted("objectives")
    local v = log[q]
    return v and { { text = "Wolf slain: " .. v.have .. "/5", numFulfilled = v.have, numRequired = 5, finished = v.have >= 5 } } or {}
  end,
}
local ns = {}
local function loadAddon(file) assert(loadfile(path("addon\\" .. addonDir .. "\\" .. file)))("ForeverRoute", ns) end
loadAddon("Core.lua")
loadAddon("Jobs.lua")
loadAddon("Routes.lua")
loadAddon("State.lua")
loadAddon("Util.lua")
loadAddon("PvpQuests.lua")
loadAddon("Engine.lua")
loadAddon("Engine\\Focus.lua")
loadAddon("Engine\\Nope.lua")
loadAddon("QuestData.lua")
loadAddon("Chains.lua")
ns.Dungeon = { Here = function() end }
ns.char = { manualDone = {}, skipped = {}, history = {}, nope = {} }
ns.db = { smartNext = false }
ForeverRouteDB = {}
ns.Jobs.SYNC = true
ns.Engine.noSolve = true
local E, S = ns.Engine, ns.State
S.Snapshot = function() end -- Persistence APIs are not part of this headless fixture.
local optimized = E.InvalidateProgress ~= nil
local rawStatus, statusReads = E.Status, 0
E.Status = function(i) statusReads = statusReads + 1; return rawStatus(i) end
local stateEvents, progressEvents = 0, 0
ns.On("FR_STATE", function() stateEvents = stateEvents + 1 end)
ns.On("FR_PROGRESS", function() progressEvents = progressEvents + 1 end)
local function flush(dt)
  now = now + (dt or 0.2)
  local pending = timers
  timers = {}
  for _, t in ipairs(pending) do
    if t.at <= now then t.fn() else timers[#timers + 1] = t end
  end
  assert(#errors == 0, table.concat(errors, "\n"))
end
local function equal(a, b, label) assert(a == b, (label or "value") .. ": expected " .. tostring(b) .. ", got " .. tostring(a)) end
local function fullProgress()
  local n = 0
  E.ReadPass(function() for i = 1, #ForeverRouteData.steps do if E.IsDone(i) then n = n + 1 end end end)
  return n
end
local function checkProgress(label)
  equal(E.Progress(), fullProgress(), label)
  local list = ForeverRouteData.steps
  for _, i in ipairs({ 1, math.floor(#list / 2), #list }) do
    local a, b = i, i
    while a > 1 and list[a].k ~= "fly" do a = a - 1 end
    if list[a].k == "fly" and a < i then a = a + 1 end
    while b < #list and list[b + 1].k ~= "fly" do b = b + 1 end
    local n = 0
    E.ReadPass(function() for j = a, b do if E.IsDone(j) then n = n + 1 end end end)
    local done, total = E.LegProgress(i)
    equal(done, n, label .. " leg"); equal(total, b - a + 1, label .. " leg length")
  end
end

local function synthetic()
  local list = {}
  for q = 50001, 51000 do
    list[#list + 1] = { k = "accept", q = q, level = 30, zone = "Test" }
    list[#list + 1] = { k = "obj", q = q, level = 30, match = "Wolf", zone = "Test" }
    list[#list + 1] = { k = "turnin", q = q, level = 30, zone = "Test" }
  end
  ForeverRouteData = { id = "test", steps = list }
  ForeverRouteRoutes = { ForeverRouteData }
  for q = 50001, 50020 do log[q] = { have = 1, complete = false } end
end
synthetic()
S.Invalidate(); flush()
checkProgress("initial")
local function measure(label, fn, n)
  wipe(calls)
  statusReads = 0
  local start = debugprofilestop()
  for _ = 1, n do fn() end
  local ms = (debugprofilestop() - start) / n
  local total = 0; for _, count in pairs(calls) do total = total + count end
  print(string.format("%s: %.3f ms/call, %d quest API calls, %d status reads (%d iterations)", label, ms, total, statusReads, n))
  return total, statusReads
end
local api, reads = measure("synthetic 3000 steps, warm Progress", E.Progress, 10)
if optimized then equal(api, 0, "warm API calls"); equal(reads, 0, "warm status reads") end
stateEvents = 0
measure("unchanged QUEST_LOG_UPDATE", function() ns.Fire("QUEST_LOG_UPDATE"); flush() end, 10)
equal(stateEvents, 0, "unchanged log has no route refresh")
local untouched = S.Quest(50020)
log[50001].have = 2
local progressRevision = E.progressRevision
ns.Fire("QUEST_LOG_UPDATE"); flush()
equal(S.Quest(50001).objectives[1].have, 2, "objective count")
equal(stateEvents, 0, "counts do not refresh the route")
equal(progressEvents, 1, "counts notify only progress")
if optimized then equal(E.progressRevision, progressRevision, "numeric objective counts do not invalidate step status") end
checkProgress("count")
local getObjectives = C_QuestLog.GetQuestObjectives
C_QuestLog.GetQuestObjectives = function(q)
  local objectives = getObjectives(q)
  if q == 50001 then objectives[1].text = objectives[1].text:gsub("Wolf slain", "Boar slain") end
  return objectives
end
progressRevision = E.progressRevision
ns.Fire("QUEST_LOG_UPDATE"); flush()
if optimized then equal(E.progressRevision, progressRevision + 1, "objective description changes invalidate step status") end
C_QuestLog.GetQuestObjectives = getObjectives
ns.Fire("QUEST_LOG_UPDATE"); flush()
log[50001].have, log[50001].complete = 5, true
ns.Fire("QUEST_LOG_UPDATE"); flush()
if optimized then
  equal(S.Quest(50020), untouched, "unrelated quest cache retained")
  statusReads = 0; E.Progress()
  assert(statusReads <= 12, "one completed quest must not reevaluate all 3000 steps: " .. statusReads)
end
checkProgress("finished")
log[50001].have, log[50001].complete = 0, false
ns.Fire("QUEST_LOG_UPDATE"); flush()
checkProgress("lost quest item")
log[50001] = nil; completed[50001] = true
ns.Fire("QUEST_TURNED_IN", 50001); flush()
checkProgress("handed in")
log[50002] = nil
ns.Fire("QUEST_REMOVED", 50002); flush()
checkProgress("abandoned")
log[50002] = { have = 0 }
ns.Fire("QUEST_ACCEPTED", 1, 50002); flush()
checkProgress("accepted legacy arguments")
E.Skip(4); checkProgress("skip")
E.Undo(); checkProgress("undo")
E.MarkDone(5); checkProgress("manual done")
E.Undo(); checkProgress("undo manual")
level = 40
ns.Fire("PLAYER_LEVEL_UP", level); flush()
checkProgress("level up")
level = 30

if optimized then
  -- Empty logs must not repeatedly rebuild the route (the old no-cached-active-quest case).
  wipe(log); S.Invalidate(); flush(); stateEvents = 0
  for _ = 1, 5 do ns.Fire("QUEST_LOG_UPDATE"); flush() end
  equal(stateEvents, 0, "unchanged empty log")

  -- Collapsed headers still resolve by ID, including quests accepted outside this route.
  local modernInfo, modernCount = C_QuestLog.GetInfo, C_QuestLog.GetNumQuestLogEntries
  C_QuestLog.GetNumQuestLogEntries = function() return 1, #ids() end
  C_QuestLog.GetInfo = function() return { isHeader = true, isCollapsed = true } end
  log[50001] = { have = 2 }
  S.Invalidate(); flush()
  equal(S.OnQuest(50001), true, "collapsed header by ID")
  log[99999] = { have = 1 }
  ns.Fire("QUEST_ACCEPTED", 99999); flush()
  equal(S.LogIDs()[99999], true, "collapsed off-route accepted quest")
  log[50001] = nil; ns.Fire("QUEST_REMOVED", 50001); flush()
  equal(S.OnQuest(50001), false, "collapsed abandon")

  -- Classic title API returns the quest ID eighth; a zero log index is not membership.
  C_QuestLog.GetInfo = nil
  C_QuestLog.GetNumQuestLogEntries = modernCount
  GetQuestLogTitle = function(i) return "Quest", 30, nil, false, false, nil, nil, ids()[i] end
  equal(S._readLog()[99999], true, "legacy title ID")
  C_QuestLog.GetNumQuestLogEntries = function() return #ids() end
  equal(S.LogCount(), 1, "legacy count without second return")
  equal(S._readLog()[99999], true, "legacy enumeration without second return")
  GetQuestLogTitle = nil
  C_QuestLog.GetInfo = modernInfo
  local isOn = C_QuestLog.IsOnQuest
  C_QuestLog.IsOnQuest = nil
  C_QuestLog.GetLogIndexForQuestID = function(q) return log[q] and 1 or 0 end
  C_QuestLog.GetInfo = function() return { isHeader = true, isCollapsed = true } end
  C_QuestLog.GetNumQuestLogEntries = function() return 1, 2 end
  S.Invalidate(); flush()
  equal(S.OnQuest(50004), false, "zero index is not on quest")
  C_QuestLog.IsOnQuest, C_QuestLog.GetInfo, C_QuestLog.GetNumQuestLogEntries = isOn, modernInfo, modernCount
  S.Invalidate(); flush()

  -- Quest event bursts are settled once, and both modern/legacy acceptance arguments are supported.
  stateEvents = 0
  log[50003] = { have = 1 }; log[50004] = { have = 1 }
  ns.Fire("QUEST_ACCEPTED", 50003); ns.Fire("QUEST_ACCEPTED", 2, 50004)
  for _ = 1, 20 do ns.Fire("QUEST_LOG_UPDATE") end
  flush()
  equal(stateEvents, 1, "one settled event per burst")
  equal(S.OnQuest(50003), true, "modern acceptance")
  equal(S.OnQuest(50004), true, "legacy acceptance")

  -- Incremental non-quest updates, with the original fly-step boundary convention.
  ForeverRouteData = { id = "dynamic", steps = {
    { k = "fly", to = 2 }, { k = "grind", level = 30, xp = 10, zone = "Test" },
    { k = "bonus", item = 123, zone = "Test" },
    { k = "hearth", dest = "Stormwind", zone = "Test" },
    { k = "fly", to = 3 }, { k = "note", text = "next", zone = "Next" },
  } }
  ns.Fire("FR_ROUTE_CHANGED"); E.Refresh()
  checkProgress("dynamic initial")
  xp = 20; ns.Fire("PLAYER_XP_UPDATE"); checkProgress("XP threshold")
  itemCount = 1; ns.Fire("BAG_UPDATE_DELAYED"); checkProgress("bonus collected")
  cooldown = 60; ns.Fire("BAG_UPDATE_COOLDOWN"); checkProgress("hearth cooling down")
  cooldown = 0; ns.Fire("BAG_UPDATE_COOLDOWN"); checkProgress("hearth available again")
  itemCount = 0; ns.Fire("BAG_UPDATE_DELAYED"); checkProgress("bonus removed")
  table.insert(ForeverRouteData.steps, 2, { k = "note", text = "inserted", inserted = true })
  checkProgress("inserted stop")
  E.RemoveSteps(function() return true end); checkProgress("removed stop")
  ns.char.manualDone, ns.char.skipped, ns.char.history = {}, {}, {}
  E.Refresh(); checkProgress("reset")

  -- Choosing a different route and returning retains that route's saved manual ticks.
  local routeA = { id = "a", steps = { { k = "note", text = "A" } } }
  local routeB = { id = "b", zoneRoute = true, steps = { { k = "note", text = "B" } } }
  ForeverRouteRoutes = { routeA, routeB }
  ns.SelectRoute("a"); E.MarkDone(1)
  equal(E.Progress(), 1, "route A manual tick")
  ns.SelectRoute("b"); equal(E.Progress(), 0, "route B separate progress")
  ns.SelectRoute("a"); equal(E.Progress(), 1, "route A restored progress")

  -- Diagnostics are passive, even if a refresh would change the current step.
  local refresh = E.Refresh
  E.Refresh = function() error("diagnostics must not refresh") end
  local current = E.current
  SlashCmdList.FOREVERROUTE("perf")
  equal(E.current, current, "perf leaves current step unchanged")
  assert(ns.stats["event QUEST_LOG_UPDATE"], "event timings observed")
  ns._perfSample()
  assert(ns.char.perf.progressMs, "observed progress timing preserved")
  E.Refresh = refresh
end

-- Real shipped route: this exercises the chain and behind-you rules, not a replacement engine.
local plans = { "human_paladin", "orc_warrior" }
for _, plan in ipairs(plans) do
  assert(loadfile(path("addon\\ForeverRoute_Starter_" .. plan .. "\\Plan.lua")))()
  local key = plan:gsub("_", "-")
  ForeverRouteStarter[key]()
  ForeverRouteData = ForeverRouteRoutes[1]
  ns.Steps(ForeverRouteData)
  ns.planKey = { starter = key }
  ns.char.join = { plan = key, level = 1 }
  wipe(log); wipe(completed); wipe(S.completed); wipe(S._notDone)
  ns.Fire("FR_ROUTE_CHANGED")
  S.Invalidate(); flush()
  checkProgress(plan)
  print(plan .. ": " .. #ForeverRouteData.steps .. " steps")
  local api, reads = measure(plan .. ", warm Progress", E.Progress, 5)
  if optimized then equal(api, 0, "shipped warm API calls"); equal(reads, 0, "shipped warm status reads") end
  if optimized then
    -- Uncached reference remains live while the displayed counter is reused.
    measure(plan .. ", uncached reference", fullProgress, 2)
    level = 50; ns.Fire("PLAYER_LEVEL_UP", level); flush()
    checkProgress(plan .. " level 50")
    level = 60; ns.Fire("PLAYER_LEVEL_UP", level); flush()
    checkProgress(plan .. " capped")
    E.SetFinishing(true); checkProgress(plan .. " finishing at 60")
    E.SetFinishing(false)
    level = 30
  end
end
if optimized then
  -- Exercise the real motion gate and input signature without mocking the gate itself.
  local worldPos, simulatedClock = ns.Util.WPos, nil
  ns.Util.WPos = function(s)
    if simulatedClock then simulatedClock = simulatedClock + 0.2 end
    return worldPos(s)
  end
  loadAddon("Next.lua")
  ns.Util.WPos = worldPos
  local solverRevision = ns.Next.revision
  ns.Fire("FR_PROGRESS")
  equal(ns.Next.revision, solverRevision, "partial counts do not relaunch the route solver")
  ns.db.smartNext = true
  ns.char.join, ns.planKey = nil, nil
  ForeverRouteData = { id = "motion", steps = { { k = "note", text = "stay" }, { k = "note", text = "then" } } }
  E.current, E.planned, E.focus, E.view, E.cappedNow = 1, 1, nil, nil, false
  local oldWatch, oldSide = E.WatchShortcut, E.SideOffer
  E.WatchShortcut, E.SideOffer = function() end, function() end
  local oldPick, picks = ns.Next.PickAsync, 0
  ns.Next.PickAsync = function() picks = picks + 1 end
  E.UpdateFocus(0, 0, 0)
  for _ = 1, 60 do now = now + 1; E.UpdateFocus(0, 0, 0) end
  equal(picks, 1, "standing for a minute does not repeat solves")
  E.UpdateFocus(31, 0, 0); equal(picks, 2, "30-yard movement threshold")
  ns.Fire("BAG_UPDATE_DELAYED"); E.UpdateFocus(31, 0, 0); equal(picks, 3, "bag changes wake solver")
  S.knownTaxi.test = true; E.UpdateFocus(31, 0, 0); equal(picks, 4, "taxi changes wake solver")
  ns.Next.dismissed[ForeverRouteData.steps[2]] = { t = now - ns.Next.DISMISS_SECS, x = 31, y = 0, inst = 0 }
  E.UpdateFocus(31, 0, 0); equal(picks, 5, "dismissal expiration wakes solver")
  E.focus, E.focusWhy, E.focusAt = 1, "progress", now
  E.UpdateFocus(31, 0, 0); equal(picks, 5, "progress hold prevents solve")
  E.Refresh() -- The test's noSolve switch avoids running a solver inside the refresh.
  E.noSolve = nil
  E.focus, E.focusWhy, E.focusAt = 1, "progress", now - E.PROGRESS_HOLD - 1
  E.UpdateFocus(31, 0, 0)
  equal(E.focus, nil, "expired hold released without a five-second timer")
  E.current, E.planned = nil, nil
  local refresh = E.Refresh
  E.Refresh = function() error("empty/finished routes must not refresh on the motion timer") end
  for _ = 1, 60 do now = now + 1; E.UpdateFocus(31, 0, 0) end
  E.Refresh = refresh
  ns.Next.PickAsync, E.WatchShortcut, E.SideOffer = oldPick, oldWatch, oldSide

  -- Cold route indexing must yield and a cancelled partial index must not become visible.
  local function indexFixture()
    local list = {}
    for i = 1, 1000 do
      list[i] = { k = "obj", q = 70000 + i, m = 1, x = 0.1 + (i % 80) / 100, y = 0.5 }
    end
    return list
  end
  local indexList = indexFixture()
  local expected = ns.Next.DeferCost(indexList, indexList[500], 1)
  indexList = indexFixture()
  local clock = debugprofilestop
  simulatedClock = 0
  debugprofilestop = function() return simulatedClock end
  local indexResult
  ns.Jobs.Post("verify", function() indexResult = ns.Next.DeferCost(indexList, indexList[500], 1) end, { budget = 1 })
  ns.Jobs.Step()
  assert(ns.Jobs.Busy("verify"), "cold route indexing must yield")
  ns.Jobs.Cancel("verify")
  ns.Jobs.Post("verify", function() indexResult = ns.Next.DeferCost(indexList, indexList[500], 1) end, { budget = 1 })
  local indexSlices, maxSlice = 0, 0
  while ns.Jobs.Busy("verify") and indexSlices < 10000 do
    local before = simulatedClock
    ns.Jobs.Step()
    maxSlice = math.max(maxSlice, simulatedClock - before)
    indexSlices = indexSlices + 1
  end
  debugprofilestop, simulatedClock = clock, nil
  assert(not ns.Jobs.Busy("verify"), "route indexing must finish")
  assert(indexSlices > 2, "route indexing must span several slices")
  assert(maxSlice <= 1.7, "route indexing exceeded the simulated slice bound: " .. maxSlice)
  equal(indexResult, expected, "cancelled route index must rebuild with the same result")

  local testClock = 0
  debugprofilestop = function() return testClock end
  ns.Jobs.Post("solve", function()
    ns.Jobs.Mark("test a")
    testClock = testClock + 2
    ns.MaybeYield()
    testClock = testClock + 3
    ns.Jobs.Mark("test b")
    testClock = testClock + 4
  end, { budget = 1 })
  ns.Jobs.Step(); ns.Jobs.Step()
  debugprofilestop = clock
  equal(ns.stats["solve phase test a"].total, 5, "phase timing excludes time between frames")
  equal(ns.stats["solve phase test b"].total, 4, "phase timing follows the running job")
  assert(ns.stats["FR_STATE listener 1"], "quest state listener timings are recorded")

  -- The actual solver still produces a valid pick and rejects a just-completed cached pick.
  loadAddon("Horizon.lua")
  ForeverRouteData = { id = "solve", zoneRoute = true, steps = {
    { k = "obj", q = 50003, match = "Wolf", m = 1, x = 0.53, y = 0.5, level = 30 },
    { k = "turnin", q = 50003, m = 1, x = 0.54, y = 0.5, level = 30 },
  } }
  E.current, E.planned, E.focus, E.pos, ns.Next.taken = 1, 1, nil, nil, nil
  E.ForgetDone()
  log[50003] = { have = 1 }
  S.Invalidate(); flush()
  local pick = ns.Next.Pick(1)
  equal(pick or 1, 1, "real solver chooses unfinished objective")
  assert(ns.Next.res and #ns.Next.res.seq > 0, "real horizon search executed")
  local asyncPick, asyncDone
  ns.Next.PickAsync(1, function(result) asyncPick, asyncDone = result, true end)
  ns.Jobs.Settle("solve")
  flush()
  assert(asyncDone, "background solver completes")
  equal(asyncPick or 1, pick or 1, "background solver agrees with synchronous solver")
  assert(ns.stats["solve phase setup"], "real solver phase timings are recorded")
  do
    local statuses, oldStatus = 0, E.Status
    E.Status = function() statuses = statuses + 1; return "todo" end
    local unlocated = { { k = "note" }, { k = "note" }, { k = "note" } }
    equal(ns.Next.VisitHere(unlocated, 1, 2, 1, 0, 0, 0), nil, "unlocated steps cannot form a visit")
    equal(statuses, 0, "unlocated steps do not need route-status reads")
    E.Status = oldStatus
  end
  log[50003].have, log[50003].complete = 5, true
  ns.Fire("QUEST_LOG_UPDATE"); flush()
  equal(E.planned, 2, "ready quest advances to hand-in")
  equal(ns.Next.Pick(2) or 2, 2, "real solver chooses hand-in after readiness change")

  loadAddon("Engine\\Inserts.lua")
  loadAddon("UI\\Extras.lua")
  ns.Style = { Distance = function(d) return tostring(math.floor(d)) .. " yd" end }
  ForeverRouteEnders = { [50003] = { m = 1, x = 0.5, y = 0.5, name = "Quest", npc = "Giver" } }
  local enders = E.LogEnders()
  equal(E.LogEnders(), enders, "log-ender intersection reused")
  do
    local oldBehind, oldInsert, checks, opts = E.BehindYou, E.InsertStop, 0, nil
    E.BehindYou = function(s) checks = checks + 1; return s.behind end
    E.InsertStop = function(_, _, _, _, options) opts = options; return true end
    local steps = ForeverRouteData.steps
    steps[#steps + 1] = { k = "turnin", q = 50004 }
    assert(not E.ApplyInserts(), "existing ready hand-in is not inserted again")
    equal(checks, 1, "unrelated hand-ins are not checked against the route")
    steps[2].behind = true
    steps[#steps + 1] = { k = "turnin", q = 50003 }
    assert(not E.ApplyInserts(), "a duplicate ahead prevents an insert even with another behind")
    steps[#steps] = nil
    assert(E.ApplyInserts(), "a hand-in behind the player can be inserted")
    assert(opts and opts.maxCost == E.MERGE_PATH_YARDS, "behind hand-in retains its insertion limit")
    steps[2].behind = nil
    steps[#steps] = nil
    E.BehindYou, E.InsertStop = oldBehind, oldInsert
  end
  equal(#ns.Extras.Current(), 0, "route already has hand-in")
  ForeverRouteData.steps[2] = { k = "note", text = "replacement" }
  E.ForgetDone()
  equal(#ns.Extras.Current(), 1, "same-length replacement invalidates hand-in membership")
  local cardEvents, stepEvents = 0, 0
  ns.On("FR_CARD", function() cardEvents = cardEvents + 1 end)
  ns.On("FR_STEP", function() stepEvents = stepEvents + 1 end)
  local loaded = ns._listeners.FR_LOADED
  loaded[#loaded]() -- Only install Extras' ticker, not the unrelated UI/login machinery.
  local ticker = ns._tickers[#ns._tickers]
  ticker.fn(); ticker.fn()
  equal(cardEvents, 1, "changed extras notify the card once")
  equal(stepEvents, 0, "extras do not wake list, arrow or pins")

  -- Real list scheduling with fake frames; rendering is intentionally outside this headless test.
  local function widget()
    local w = { shown = false }
    for _, name in ipairs({ "SetSize", "SetPoint", "SetHeight", "SetWidth", "SetWordWrap", "RegisterForDrag",
      "SetTexture", "SetAllPoints", "SetVertexColor", "SetJustifyV", "RegisterForClicks", "EnableMouse",
      "EnableMouseWheel", "SetText", "SetScript" }) do w[name] = function() end end
    w.Show = function(self) self.shown = true end
    w.Hide = function(self) self.shown = false end
    w.IsShown = function(self) return self.shown end
    w.CreateTexture = widget
    return w
  end
  local createFrame = CreateFrame
  CreateFrame = widget
  ns.Style.C = { gold = { 1, 1, 1 }, text = {}, sub = {}, dim = {}, good = {} }
  ns.Style.Window = function() end
  for _, name in ipairs({ "Text", "CloseButton", "Nine", "Pill", "Button", "ScrollGrip" }) do ns.Style[name] = widget end
  loadAddon("UI\\List.lua")
  loaded[#loaded]()
  local headers, rows = 0, 0
  ns.List.DrawHeader = function() headers = headers + 1 end
  ns.List.DrawRows = function() rows = rows + 1 end
  ns.List.Toggle()
  local rebuilt = ns.List.rebuilds
  for _ = 1, 60 do now = now + 1; ns.List.Draw() end
  equal(ns.List.rebuilds, rebuilt, "list has no timed full rebuild")
  equal(headers, 1, "unchanged header is not redrawn")
  equal(rows, 1, "unchanged rows are not redrawn")
  ns.List.Scroll(1)
  equal(ns.List.rebuilds, rebuilt, "scroll redraws rows only")
  equal(rows, 2, "scroll redraws visible rows")
  E.InvalidateProgress()
  ns.List.Draw()
  equal(ns.List.rebuilds, rebuilt + 1, "state change rebuilds visible list")
  CreateFrame = createFrame

  local info, num = C_QuestLog.GetInfo, C_QuestLog.GetNumQuestLogEntries
  log[99998] = { have = 5, complete = true }
  ForeverRouteEnders[99998] = { m = 1, x = 0.5, y = 0.5, name = "Hidden quest", npc = "Giver" }
  C_QuestLog.GetInfo = function() return { isHeader = true, isCollapsed = true } end
  C_QuestLog.GetNumQuestLogEntries = function() return 1, 2 end
  S.Invalidate(); S.CheckLog()
  equal(E.LogEnders()[99998], ForeverRouteEnders[99998], "collapsed off-route quest already present at login")
  C_QuestLog.GetInfo, C_QuestLog.GetNumQuestLogEntries = info, num

  local objectives, cached = C_QuestLog.GetQuestObjectives, S.Quest(50003)
  C_QuestLog.GetQuestObjectives = function() error("fixture: objectives unavailable") end
  S.CheckLog()
  equal(S.Quest(50003), cached, "failed objective read keeps last readable state")
  assert(#errors > 0 and ForeverRouteDB.log[1].where == "state API", "API failures must be logged")
  C_QuestLog.GetQuestObjectives = objectives
  wipe(errors)
end
equal(#errors, 0, "logged errors")
print("PASS: progress, quest events, solver scheduling, diagnostics and UI invalidation")
