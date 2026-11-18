-- Live character state: completed quests, quests in the log (queried by ID, so collapsed log headers don't hide them),
-- objective progress, position, flight paths. Writes a snapshot for the PC planner on logout / reload / turn-ins.
local _, ns = ...
local State = {}
ns.State = State

State.completed = {}   -- [questID] = true
State.knownTaxi = {}   -- [nodeName] = true
local cache = {}       -- [questID] = { on, complete, objectives }, updated by settled log changes
-- [questID] = true: not handed in, as asked since the last full look (a refresh asks for every quest on the route, ~950
-- times on a long plan, each a call into the game and a look at every quest that needs it)
local notDone = {}

local function call(fn, ...)
  if type(fn) ~= "function" then return end
  local ok, a, b, c, d, e, f, g, h = pcall(fn, ...)
  if ok then return a, b, c, d, e, f, g, h end
  ns.LogError("state API", a)
end

function State.IsCompleted(id)
  if not id then return false end
  if State.completed[id] then return true end
  if notDone[id] then return false end
  local done = C_QuestLog and call(C_QuestLog.IsQuestFlaggedCompleted, id)
  if done == nil and IsQuestFlaggedCompleted then done = call(IsQuestFlaggedCompleted, id) end
  if done then State.completed[id] = true end
  -- a quest a handed-in quest needed (QUEST_PRE) counts as done: you did it, or went round it (abandoned, then the
  -- chain carried on) - either way the giver won't offer it again. Jungle Secrets, abandoned with Bookie Herod handed
  -- in, was offered on the card again and again and flipped with the next pick (tester)
  if not done and State.SupersededBy(id) then State.completed[id] = true; return true end
  if not done then notDone[id] = true end
  return done and true or false
end
-- the quests that need quest id (the reverse of ns.QUEST_PRE), built once
local needers, needersFor
function State.SupersededBy(id)
  local P = ns.QUEST_PRE
  if not P then return nil end
  if not needers or needersFor ~= P then
    needers, needersFor = {}, P
    for q, pre in pairs(P) do
      for _, p in ipairs(pre.g or {}) do needers[p] = needers[p] or {}; table.insert(needers[p], q) end
      for _, p in ipairs(pre.s or {}) do needers[p] = needers[p] or {}; table.insert(needers[p], q) end
    end
  end
  for _, q in ipairs(needers[id] or {}) do
    local flagged = State.completed[q] or (C_QuestLog and call(C_QuestLog.IsQuestFlaggedCompleted, q))
    if flagged then return q end
  end
  return nil
end

-- the quests in your log, read once per log change: { [questID] = true }, or false when the log can't be read whole
-- (a collapsed header hides its quests from the list: then each quest is asked about by its ID, as before). A refresh
-- asks about every quest on the route - ~600 on a built-in plan - and asking the game each by ID was most of a full
-- look in the game (50-110 ms at level 36, a tester's saved timings; the simulator's quest API costs nothing)
local logSet = nil
State.logRevision = 0
State.logLevels = {}
local function readLog()
  local fn = (C_QuestLog and C_QuestLog.GetNumQuestLogEntries) or GetNumQuestLogEntries
  local entries, quests = call(fn)
  if type(entries) ~= "number" then return false end
  local set, n, collapsed = {}, 0, false
  for i = 1, entries do
    local id, hdr, lv
    if C_QuestLog and C_QuestLog.GetInfo then
      local info = call(C_QuestLog.GetInfo, i)
      if type(info) ~= "table" then return false end
      id, hdr, lv = info.questID, info.isHeader, info.level
      collapsed = collapsed or (hdr and info.isCollapsed)
    elseif GetQuestLogTitle then
      local _, l, _, h, c, _, _, q = call(GetQuestLogTitle, i)
      id, hdr, lv = q, h, l
      collapsed = collapsed or (h and c)
    else return false end
    if not hdr then
      if type(id) ~= "number" or id <= 0 then return false end
      set[id] = true; n = n + 1
    end
    if id then State.logLevels[id] = lv end
  end
  if type(quests) == "number" then
    if n ~= quests then return false end
  elseif collapsed then return false end
  return set
end
State._readLog = readLog -- (tests)
local function onQuest(id)
  local on = C_QuestLog and call(C_QuestLog.IsOnQuest, id)
  if on == nil and C_QuestLog and C_QuestLog.GetLogIndexForQuestID then
    local index = call(C_QuestLog.GetLogIndexForQuestID, id)
    on = type(index) == "number" and index > 0
  end
  return on and true or false
end
local function questInfo(id, on)
  local c = { on = on, objectives = {} }
  if not on then return c end
  local objs = C_QuestLog and call(C_QuestLog.GetQuestObjectives, id)
  if type(objs) == "table" then
    for i, o in ipairs(objs) do c.objectives[i] = { text = o.text or "", finished = o.finished, have = o.numFulfilled or 0, need = o.numRequired or 0 } end
  end
  local complete = C_QuestLog and call(C_QuestLog.IsComplete, id)
  if complete == nil then complete = #c.objectives > 0; for _, o in ipairs(c.objectives) do if not o.finished then complete = false end end end
  c.complete, c.noObjectives = complete and true or false, #c.objectives == 0
  return c
end
-- per-quest live info, by quest ID
function State.Quest(id)
  if not id then return nil end
  local c = cache[id]
  if c then return c end
  if logSet == nil then logSet = readLog() end
  local on
  if logSet then on = logSet[id] and true or false else on = onQuest(id) end
  c = questInfo(id, on)
  cache[id] = c
  return c
end
function State.OnQuest(id) local q = State.Quest(id); return q and q.on end
-- in your log, from the list read once per log change: no objectives read (a quest asked about through State.Quest is
-- looked at again on every log update, State.CheckLog). Asked by ID when the list can't be read whole
local realQuest = State.Quest
function State.InLog(id)
  if not id then return false end
  if State.Quest ~= realQuest then return State.OnQuest(id) and true or false end -- (a scripted quest state: tests)
  local c = cache[id]
  if c then return c.on end
  if logSet == nil then logSet = readLog() end
  if logSet then return logSet[id] and true or false end
  return State.OnQuest(id) and true or false
end
function State.QuestReady(id) local q = State.Quest(id); return q and q.on and (q.complete or q.noObjectives) end

function State.LogCount()
  local n = 0
  local fn = (C_QuestLog and C_QuestLog.GetNumQuestLogEntries) or GetNumQuestLogEntries
  local entries, quests = call(fn)
  if quests then return quests end
  entries = entries or 0
  for i = 1, entries do
    local info = C_QuestLog and C_QuestLog.GetInfo and call(C_QuestLog.GetInfo, i)
    if info then
      if not info.isHeader then n = n + 1 end
    elseif GetQuestLogTitle then
      local name, _, _, header = call(GetQuestLogTitle, i)
      if name and not header then n = n + 1 end
    end
  end
  return n
end
-- is the quest log full? Asked for every pick-up on every refresh: read at most once a second, and again as soon as
-- the log changes (QUEST_LOG_UPDATE)
local fullAt, fullWas = -100, false
-- how many flight paths you know (the trip planner's memos key on it)
function State.KnownTaxiCount() local n = 0; for _ in pairs(State.knownTaxi or {}) do n = n + 1 end; return n end
function State.LogFull()
  local now = GetTime and GetTime() or 0
  if now - fullAt < 1 then return fullWas end
  fullAt, fullWas = now, State.LogCount() >= State.MaxLog()
  return fullWas
end
ns.On("QUEST_LOG_UPDATE", function() fullAt = -100 end)
function State.MaxLog() return C_QuestLog and C_QuestLog.GetMaxNumQuestsCanAccept and call(C_QuestLog.GetMaxNumQuestsCanAccept) or MAX_QUESTLOG_QUESTS or 40 end -- Forever: 40

function State.RefreshCompleted()
  local list = C_QuestLog and call(C_QuestLog.GetAllCompletedQuestIDs)
  if type(list) == "table" then
    for _, id in ipairs(list) do State.completed[id] = true end
  elseif GetQuestsCompleted then
    local t = {}; call(GetQuestsCompleted, t)
    for id in pairs(t) do State.completed[id] = true end
  end
end

-- visible quest log rows (for the snapshot); route quests are added by ID. Second result: complete enumeration.
local function logIDs()
  if logSet == nil then logSet = readLog() end
  if logSet then
    local ids = {}
    for id in pairs(logSet) do ids[id] = true end
    return ids, true
  end
  local ids = {}
  local n = C_QuestLog and C_QuestLog.GetNumQuestLogEntries and call(C_QuestLog.GetNumQuestLogEntries) or (GetNumQuestLogEntries and call(GetNumQuestLogEntries)) or 0
  for i = 1, n do
    local id, hdr
    if C_QuestLog and C_QuestLog.GetInfo then local info = call(C_QuestLog.GetInfo, i); if info then id, hdr = info.questID, info.isHeader end
    elseif GetQuestLogTitle then local _, _, _, h, _, _, _, q = GetQuestLogTitle(i); id, hdr = q, h end
    if id and id > 0 and not hdr then ids[id] = true end
  end
  for _, s in ipairs(ForeverRouteData and ForeverRouteData.steps or {}) do if s.q and State.OnQuest(s.q) then ids[s.q] = true end end
  for id, c in pairs(cache) do if c.on then ids[id] = true end end
  return ids, false
end
State.LogIDs = logIDs
-- every quest seen in your log, kept (ns.char.hadQuest): one that is gone from it and not completed was abandoned.
-- The quest log check needs that to say whose items are left over (UI/LogCheck.lua)
function State.NoteLog()
  if not ns.char then return end
  ns.char.hadQuest = ns.char.hadQuest or {}
  for id in pairs(logIDs()) do ns.char.hadQuest[id] = true end
end
-- (a quest comes into your log only by being taken - or was there when you logged in: not on every refresh, 4 ms at
-- level 50 on each one)
ns.On("QUEST_ACCEPTED", function() C_Timer.After(0.5, function() pcall(State.NoteLog) end) end)
ns.On("PLAYER_LOGIN", function() C_Timer.After(5, function() pcall(State.NoteLog) end) end)
-- what is in your bags: [itemID] = how many (the backpack and your bags, not the bank). nil when the game won't say
function State.BagItems()
  local C = type(C_Container) == "table" and C_Container or nil
  local slots = (C and C.GetContainerNumSlots) or GetContainerNumSlots
  local idAt = (C and C.GetContainerItemID) or GetContainerItemID
  if not (slots and idAt) then return nil end
  local out = {}
  for bag = 0, NUM_BAG_SLOTS or 4 do
    local n = call(slots, bag)
    for slot = 1, type(n) == "number" and n or 0 do
      local id = call(idAt, bag, slot)
      if type(id) == "number" and id > 0 then
        local count = 1
        local info = C and C.GetContainerItemInfo and call(C.GetContainerItemInfo, bag, slot)
        if type(info) == "table" and type(info.stackCount) == "number" and info.stackCount > 0 then count = info.stackCount end
        out[id] = (out[id] or 0) + count
      end
    end
  end
  return out
end

function State.Position()
  local HBD = LibStub("HereBeDragons-2.0", true)
  if HBD then local x, y, mapID = HBD:GetPlayerZonePosition(); if x then return mapID, x, y end end
  local mapID = C_Map.GetBestMapForUnit("player")
  local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
  if pos then return mapID, pos.x, pos.y end
end

-- your skills: name -> { rank, maxRank } (Skinning 127 of 150). Forever's client has them in C_SkillInfo, each line a
-- table (name, rank, maxRank, isHeader); the old GetSkillLineInfo returned a list of values instead. Without this the
-- save's skills were always empty on Forever.
function State.Skills()
  local skills = {}
  local C = type(C_SkillInfo) == "table" and C_SkillInfo
  if C and type(C.GetNumSkillLines) == "function" and type(C.GetSkillLineInfo) == "function" then
    for i = 1, (call(C.GetNumSkillLines) or 0) do
      local s = call(C.GetSkillLineInfo, i)
      if type(s) == "table" and s.name and not s.isHeader then skills[s.name] = { s.rank or 0, s.maxRank or 0 } end
    end
  elseif GetNumSkillLines and GetSkillLineInfo then
    for i = 1, (call(GetNumSkillLines) or 0) do
      local ok, name, isHeader, _, rank, _, _, maxRank = pcall(GetSkillLineInfo, i) -- 7 values: not call() (keeps 4)
      if ok and name and not isHeader then skills[name] = { rank, maxRank } end
    end
  end
  return skills
end

-- "Ride to" only once you can ride: before that, every trip on foot reads "Run to" ("ride to xxx when we don't have a
-- mount"). A riding skill of any kind (Riding, Horse Riding, the warlock's and paladin's mounts teach one) counts.
-- Read at most every 10 s: the card asks on every refresh.
local rideAt, rideCan = -100, false
function State.CanRide()
  local now = GetTime and GetTime() or 0
  if now - rideAt < 10 then return rideCan end
  rideAt, rideCan = now, false
  for name in pairs(State.Skills()) do if type(name) == "string" and name:find("Riding", 1, true) then rideCan = true; break end end
  return rideCan
end
-- "Ride" or "Run", and the card's travel kind follows
function ns.RideWord()
  local w = State.CanRide() and "Ride" or "Run"
  if ns.Style and ns.Style.KIND and ns.Style.KIND.ride then ns.Style.KIND.ride.verb = w .. " to" end
  return w
end

function State.Snapshot(reason)
  -- At logout the game may already have unloaded quest progress, gear, skills and money while the quest log still
  -- lists its rows. Such a read would tell the planner every finished quest is untouched; where a value reads empty
  -- but the previous snapshot had it, the previous value is kept (quests don't lose their objectives, you don't
  -- take off every item at once).
  local prev = ns.char.snapshot or {}
  local kept = {}
  local ids = {}
  for id in pairs(State.completed) do ids[#ids + 1] = id end
  table.sort(ids)
  local log = {}
  for id in pairs(logIDs()) do
    local q = State.Quest(id)
    local was = type(prev.log) == "table" and prev.log[id]
    -- listed in the log but "not on it", or no objectives where it had some: a torn-down read
    if was and (not q.on or (#q.objectives == 0 and type(was.objectives) == "table" and #was.objectives > 0)) then
      log[id] = was; kept.quests = (kept.quests or 0) + 1
    else
      local objs = {}
      for i, o in ipairs(q.objectives) do objs[i] = { o.have, o.need, o.finished and true or false, o.text } end
      log[id] = { complete = q.complete, objectives = objs }
    end
  end
  local mapID, x, y = State.Position()
  local skills = State.Skills()
  local gear = {}
  for slot = 1, 19 do local link = GetInventoryItemLink("player", slot); if link then gear[slot] = tonumber(link:match("item:(%d+)")) end end
  local taxi = {}
  for name in pairs(State.knownTaxi) do taxi[#taxi + 1] = name end
  table.sort(taxi)
  local function filled(t) return type(t) == "table" and next(t) ~= nil end
  if not filled(gear) and filled(prev.gear) then gear = prev.gear; kept.gear = true end
  if not filled(skills) and filled(prev.skills) then skills = prev.skills; kept.skills = true end
  -- money and position only when the read is clearly torn down (an empty purse alone can be real)
  local money, pos = GetMoney(), mapID and { map = mapID, x = x, y = y } or nil
  if kept.gear or kept.skills then
    if money == 0 and (prev.money or 0) > 0 then money = prev.money; kept.money = true end
    if not pos and prev.pos then pos = prev.pos; kept.pos = true end
  end
  if next(kept) and ns.Why then
    local what = {}
    if kept.quests then what[#what + 1] = kept.quests .. " quest" .. (kept.quests == 1 and "" or "s") end
    for _, k in ipairs({ "gear", "skills", "money", "pos" }) do if kept[k] then what[#what + 1] = k end end
    ns.Why("snapshot", reason .. ": the game returned nothing for " .. table.concat(what, ", ") .. "; kept the last good values")
  end
  local _, class = UnitClass("player")
  local _, race = UnitRace("player")
  ns.char.snapshot = {
    reason = reason, time = time(), version = 1,
    name = UnitName("player"), realm = GetRealmName(), faction = UnitFactionGroup("player"),
    class = class, race = race,
    level = (UnitXPMax("player") or 0) > 0 and UnitLevel("player") or (ns.char.snapshot and ns.char.snapshot.level) or UnitLevel("player"),
    xp = (UnitXPMax("player") or 0) > 0 and UnitXP("player") or (ns.char.snapshot and ns.char.snapshot.xp) or 0,
    xpMax = (UnitXPMax("player") or 0) > 0 and UnitXPMax("player") or (ns.char.snapshot and ns.char.snapshot.xpMax) or 0,
    money = money, bind = GetBindLocation and GetBindLocation() or nil,
    pos = pos,
    completed = ids, log = log, taxi = taxi, skills = skills, gear = gear,
    routeId = ForeverRouteData and ForeverRouteData.id, routeStep = ns.Engine and ns.Engine.current or nil,
    hearthCd = ns.HearthCooldown(),
  }
end

-- seconds left on the hearthstone (6948); nil if the game won't say (secret values make the maths error)
function ns.HearthCooldown()
  local get = (C_Container and C_Container.GetItemCooldown) or GetItemCooldown
  if not get then return nil end
  local ok, left = pcall(function()
    local start, dur = get(6948)
    if not start or start == 0 or not dur or dur == 0 then return 0 end
    return math.max(0, math.floor(start + dur - GetTime()))
  end)
  return ok and left or nil
end

-- FR_STATE (the full look) and FR_PROGRESS (a count moved): while a route change's passes run over frames, the
-- strongest of them is kept and fired once they end (Engine.Announce) - their listeners act on steps by number
function State.Announce(ev, coalesce, quests)
  local E = ns.Engine
  if E and E.Announce and E.Announce(ev) then return end
  if ev == "FR_STATE" and coalesce ~= false and E and E.Coalesce then E.Coalesce(function() ns.Fire(ev) end, quests) else ns.Fire(ev) end
end
-- where a flight point is in the world (its flight master's spot, FlightMasters.lua): name -> { x, y, instance }
local function taxiWorld()
  local HBD = LibStub("HereBeDragons-2.0", true)
  local out = {}
  if not HBD then return out end
  for m, list in pairs(ns.FLIGHT or {}) do
    for _, f in ipairs(list) do
      if f[4] and not out[f[4]] then
        local x, y, inst = HBD:GetWorldCoordinatesFromZone(f[1], f[2], m)
        if x then out[f[4]] = { x, y, inst } end
      end
    end
  end
  return out
end
-- A flight master's map is the truth for its continent: what it lists as reachable you know, and every guess there
-- (State.GuessTaxi) goes - a wrong guess costs one trip at most. Guesses on the other continent stay until a flight map
-- is opened there.
function State.TaxiMapSeen(nodes, inst)
  local W = taxiWorld()
  for name, v in pairs(State.knownTaxi) do
    if v == "guess" and (inst == nil or (W[name] and W[name][3] == inst)) then State.knownTaxi[name] = nil end
  end
  for _, n in ipairs(nodes) do
    if n.name and (n.kind == "REACHABLE" or n.kind == "CURRENT") then State.knownTaxi[n.name] = true end
  end
  ns.char.knownTaxi = State.knownTaxi
  ns.char.taxiSeen = true -- (a flight map seen: the flight paths you know are known - Travel.FPNote, no more guessing)
end
ns.On("TAXIMAP_OPENED", function()
  if not NumTaxiNodes then return end
  local nodes = {}
  for i = 1, NumTaxiNodes() do
    nodes[#nodes + 1] = { name = TaxiNodeName(i), kind = TaxiNodeGetType and TaxiNodeGetType(i) }
  end
  local HBD = LibStub("HereBeDragons-2.0", true)
  local inst = HBD and select(3, HBD:GetPlayerWorldPosition())
  State.TaxiMapSeen(nodes, inst)
  ns.Fire("FR_TAXI_OPENED")
  State.Announce("FR_STATE", false)
end)

-- The flight paths you know without opening a flight master's map: the world map's own flight points
-- (C_TaxiMap.GetTaxiNodesForMap, every node of a map with isUndiscovered) - a level 32 trying the addon for the first
-- time already knows a dozen, and until a flight map was opened the plan walked them everywhere.
-- A client that marks nothing undiscovered among many nodes is not telling: nothing is taken from it then.
State.TAXI_SCAN_MAPS = { 1414, 1415 } -- Kalimdor, the Eastern Kingdoms; the zones of FlightMasters.lua and TravelData join them
-- The flight paths you most likely know, from the quests you handed in, while the addon can't tell (on Forever the world
-- map marks no flight point undiscovered, so State.ScanTaxi never trusts it) and no flight master's map was opened on
-- this character (ns.char.taxiSeen). A level 16 trying the addon in the Barrens was taken to know no flight path: told
-- to run to Orgrimmar, and to get the Crossroads flight path he had (a player). Conservative, two rules:
--   1. a flight point of your side (or neutral: ns.FLIGHT has both) with GUESS_NEAR_N or more quests you completed whose
--      pick-up or hand-in on any of your routes is within GUESS_NEAR_YD yards of its flight master - his town: you
--      handed in there, and a player in a town takes its flight path
--   2. the capital's flight point of a starting zone you did GUESS_HOME_N or more quests in, at level GUESS_HOME_LEVEL or
--      above - Durotar's quests send you to Orgrimmar, Tirisfal's to the Undercity
-- Guesses are kept apart (knownTaxi[name] = "guess", read as known everywhere) and a flight map replaces them
-- (State.TaxiMapSeen). Once at load and when the world map is scanned again (TAXI_NODE_STATUS_CHANGED): never per frame.
State.GUESS_NEAR_YD, State.GUESS_NEAR_N, State.GUESS_HOME_N, State.GUESS_HOME_LEVEL = 300, 3, 5, 10
State.HOME_CAPITAL = { [1411] = 1454, [1412] = 1456, [1420] = 1458, [1429] = 1453, [1426] = 1455 } -- starting zone -> its capital
function State.GuessTaxi()
  if ns.char and ns.char.taxiSeen then return 0 end
  local W = taxiWorld()
  local near, home = {}, {}
  local R2 = State.GUESS_NEAR_YD ^ 2
  local seen = {}
  local FL = ns.FLIGHT or {}
  -- (only steps on a map with a flight master or in a starting zone are looked at, the place first and whether you did
  -- the quest last: a quest's state may be asked of the game)
  local function done(q) local d = seen[q]; if d == nil then d = State.IsCompleted(q) and true or false; seen[q] = d end; return d end
  for _, r in ipairs(ns.Routes and ns.Routes() or {}) do
    for _, s in ipairs(r.steps or {}) do
      local q, m = s.q, s.m
      if q and q > 0 and m and (s.k == "accept" or s.k == "turnin") then
        if State.HOME_CAPITAL[m] and done(q) then
          local h = home[m] or {}; home[m] = h; h[q] = true
        end
        if FL[m] then
          local w = ns.Util.WPos(s)
          if w then
            for _, f in ipairs(FL[m]) do
              local p = f[4] and W[f[4]]
              if p and p[3] == w[3] and (p[1] - w[1]) ^ 2 + (p[2] - w[2]) ^ 2 <= R2 and done(q) then
                local n = near[f[4]] or {}; near[f[4]] = n; n[q] = true
              end
            end
          end
        end
      end
    end
  end
  local guess = {}
  local function count(t) local k = 0; for _ in pairs(t) do k = k + 1 end; return k end
  for name, qs in pairs(near) do if count(qs) >= State.GUESS_NEAR_N then guess[name] = true end end
  if (UnitLevel and UnitLevel("player") or 1) >= State.GUESS_HOME_LEVEL then
    for zone, qs in pairs(home) do
      if count(qs) >= State.GUESS_HOME_N then
        for _, f in ipairs((ns.FLIGHT or {})[State.HOME_CAPITAL[zone]] or {}) do if f[4] then guess[f[4]] = true end end
      end
    end
  end
  local added = 0
  for name in pairs(guess) do if not State.knownTaxi[name] then State.knownTaxi[name] = "guess"; added = added + 1 end end
  ns.char.knownTaxi = State.knownTaxi
  if added > 0 then
    if ns.Why then ns.Why("taxi", added .. " flight path(s) you most likely know, from the quests you handed in near them (a flight master's map tells for sure)") end
    State.Announce("FR_STATE", false)
  end
  return added
end
function State.ScanTaxi()
  if not (C_TaxiMap and C_TaxiMap.GetTaxiNodesForMap) then return State.GuessTaxi() end
  local okF, fac = pcall(UnitFactionGroup, "player")
  local mine = Enum and Enum.FlightPathFaction and (okF and fac == "Horde" and Enum.FlightPathFaction.Horde or Enum.FlightPathFaction.Alliance)
  local neutral = Enum and Enum.FlightPathFaction and Enum.FlightPathFaction.Neutral or 0
  local maps, seen = {}, {}
  local function add(m) if m and not seen[m] then seen[m] = true; maps[#maps + 1] = m end end
  for _, m in ipairs(State.TAXI_SCAN_MAPS) do add(m) end
  for _, side in pairs(ns.FLIGHT_BY or {}) do for m in pairs(side) do add(m) end end
  for m in pairs((ns.TravelData and ns.TravelData.BOUNDS) or {}) do add(m) end
  local found, total, undiscovered = {}, 0, 0
  for _, m in ipairs(maps) do
    local ok, nodes = pcall(C_TaxiMap.GetTaxiNodesForMap, m)
    for _, n in ipairs(ok and type(nodes) == "table" and nodes or {}) do
      if n.name and (n.faction == mine or n.faction == neutral) then
        total = total + 1
        if n.isUndiscovered then undiscovered = undiscovered + 1 else found[n.name] = true end
      end
    end
  end
  -- (no flight point at all: the client tells nothing either - guessed the same way)
  if total == 0 then return State.GuessTaxi() end
  if total >= 10 and undiscovered == 0 then
    if ns.Why then ns.Why("taxi", "world map lists " .. total .. " flight points, none undiscovered: not trusted (open a flight master's map)") end
    return State.GuessTaxi()
  end
  local added = 0
  for name in pairs(found) do if not State.knownTaxi[name] then State.knownTaxi[name] = true; added = added + 1 end end
  ns.char.knownTaxi = State.knownTaxi
  if added > 0 then
    if ns.Why then ns.Why("taxi", added .. " flight path(s) you know, from the world map") end
    State.Announce("FR_STATE", false)
  end
  return added
end

-- Coalesce quest events, compare the live log, and keep unchanged cache entries. Counts only redraw bars;
-- membership/readiness changes refresh the route. An unchanged or empty log does no downstream work.
local pending, fullDue = false, true
local changedIDs = {}
function State.CheckLog()
  local count = State.LogCount()
  local current = logSet
  if current == nil or count ~= State.logCountWas then current = readLog() end
  local changed, undone, counts = false, false, false
  local affected, membershipChanged = {}, false
  local function update(id, on)
    local c = cache[id]
    if not c or c.on ~= on then
      cache[id] = questInfo(id, on)
      changed, undone = true, undone or (c and c.on and not on)
      membershipChanged = true
      return
    end
    if not on then return end
    local objs = C_QuestLog and call(C_QuestLog.GetQuestObjectives, id)
    local complete = C_QuestLog and call(C_QuestLog.IsComplete, id)
    if type(objs) ~= "table" then return end -- Keep the last readable objectives.
    if complete == nil then
      complete = #objs > 0
      for _, o in ipairs(objs) do if not o.finished then complete = false end end
    end
    complete = complete and true or false
    if complete ~= c.complete then changed, undone, affected[id] = true, undone or c.complete, true end
    if #objs ~= #c.objectives then changed, undone, affected[id] = true, true, true end
    for i, o in ipairs(objs) do
      local was = c.objectives[i]
      if not was then was = {}; c.objectives[i] = was end
      if (o.finished and true or false) ~= (was.finished and true or false) then changed, undone, affected[id] = true, undone or was.finished, true end
      local text, have, need = o.text or "", o.numFulfilled or 0, o.numRequired or 0
      if text ~= was.text then
        counts = true
        local oldText = was.text or ""
        if have == was.have and need == was.need then
          affected[id] = true
        else
          local oldPair = tostring(was.have or 0) .. "%s*/%s*" .. tostring(was.need or 0)
          local newPair = tostring(have) .. "%s*/%s*" .. tostring(need)
          if oldText:gsub(oldPair, "#") ~= text:gsub(newPair, "#") then affected[id] = true end
        end
      elseif have ~= was.have or need ~= was.need then counts = true end
      was.text, was.have, was.need, was.finished = text, have, need, o.finished
    end
    for i = #c.objectives, #objs + 1, -1 do c.objectives[i] = nil end
    c.complete, c.noObjectives = complete, #objs == 0
  end
  if current then
    for id, c in pairs(cache) do if c.on and not current[id] then update(id, false) end end
    for id in pairs(current) do update(id, true) end
  else
    -- Collapsed headers hide IDs. Known absences only need checking on membership events/count changes.
    local membership = fullDue or State.LogCount() ~= State.logCountWas
    for id, c in pairs(cache) do if membership or c.on then update(id, onQuest(id)) end end
    for id in pairs(changedIDs) do if not cache[id] then update(id, onQuest(id)) end end
  end
  logSet = current
  State.logCountWas = count
  wipe(changedIDs)
  if changed then State.logRevision = State.logRevision + 1 end
  return undone and "undone" or changed and "changed" or counts and "counts" or "same", not membershipChanged and affected or nil
end
local function settle()
  pending = false
  local how, affected = State.CheckLog()
  if how == "undone" and ns.Engine and ns.Engine.ForgetDone then ns.Engine.ForgetDone() end
  if not fullDue and how == "same" then return end
  if not fullDue and how == "counts" then
    -- Objective matching also reads text; a newly supplied description can change which step is done.
    if next(affected) and ns.Engine and ns.Engine.InvalidateProgress then ns.Engine.InvalidateProgress("counts", affected) end
    local t0 = debugprofilestop and debugprofilestop()
    State.Announce("FR_PROGRESS")
    if t0 and ns.Time then ns.Time("counts", debugprofilestop() - t0) end
    return
  end
  local quests = not fullDue and how == "changed" and affected or nil
  fullDue = false
  if ns.Engine and ns.Engine.GrayForget then ns.Engine.GrayForget() end -- (the gray rule's chains: Engine.LeadsTo)
  local t0 = debugprofilestop and debugprofilestop()
  State.Announce("FR_STATE", nil, quests)
  if t0 and ns.Time then ns.Time("logchange", debugprofilestop() - t0) end
end
local function schedule()
  if pending then return end
  pending = true
  C_Timer.After(0.15, ns.Guard("quest update", settle))
end
-- something more than a count may have changed: the full look
local function refreshSoon()
  if ns.Engine and ns.Engine.GrayForget then ns.Engine.GrayForget() end
  fullDue = true
  schedule()
end
-- the log changed: maybe only a count
local function logSoon() schedule() end
function State.Invalidate()
  wipe(cache); logSet = nil
  State.logRevision = State.logRevision + 1
  refreshSoon()
end
State._notDone, State._settle = notDone, settle -- (tests)

ns.On("FR_LOADED", function() State.knownTaxi = ns.char.knownTaxi or {}; C_Timer.After(3, ns.Guard("taxi", State.ScanTaxi)) end)
ns.On("TAXI_NODE_STATUS_CHANGED", function() C_Timer.After(0.5, ns.Guard("taxi", State.ScanTaxi)) end)
ns.On("PLAYER_LOGIN", function() State.RefreshCompleted(); wipe(notDone); refreshSoon(); C_Timer.After(8, function() State.Snapshot("login") end); ns.NewTicker(300, function() State.Snapshot("periodic") end) end)
ns.On("QUEST_LOG_UPDATE", logSoon)
ns.On("UNIT_QUEST_LOG_CHANGED", function(unit) if unit == "player" then logSoon() end end)
local function questChanged(id)
  if type(id) == "number" then cache[id] = nil; changedIDs[id] = true end
  logSet = nil
  State.logRevision = State.logRevision + 1
  refreshSoon()
end
ns.On("QUEST_ACCEPTED", function(a, b) questChanged(type(b) == "number" and b or a) end)
ns.On("QUEST_REMOVED", questChanged)
ns.On("QUEST_WATCH_UPDATE", schedule)
ns.On("PLAYER_ENTERING_WORLD", function() State.RefreshCompleted(); wipe(notDone); State.Invalidate() end)
ns.On("QUEST_DATA_LOAD_RESULT", function(id, success)
  if success and id and notDone[id] then notDone[id] = nil; refreshSoon() end
end)
ns.On("QUEST_TURNED_IN", function(id)
  if id then State.completed[id] = true end
  wipe(notDone) -- (a hand-in is what makes a quest done - and the ones it supersedes: asked again)
  questChanged(id)
  C_Timer.After(0.5, function() State.Snapshot("turnin") end)
end)
ns.On("PLAYER_LEVEL_UP", function() refreshSoon(); C_Timer.After(1, function() State.Snapshot("levelup") end) end)
ns.On("PLAYER_XP_UPDATE", function() ns.Fire("FR_XP") end)
-- a bonus step (a book, a collectible) is done once its item is in your bags: the full look when that count moved -
-- not on every loot while the card is on it (a bonus step with no item of its own: on each bag change, as before)
local bonusSeen = {}
ns.On("BAG_UPDATE_DELAYED", function()
  local i = ns.Engine and ns.Engine.CardAt(); local s = i and ForeverRouteData and ForeverRouteData.steps[i]
  if not (s and s.k == "bonus") then return end
  if s.item and ns.GetItemCount then
    local ok, n = pcall(ns.GetItemCount, s.item, true)
    n = ok and n or nil
    if n ~= nil and bonusSeen.s == s and bonusSeen.n == n then return end
    bonusSeen.s, bonusSeen.n = s, n
  end
  State.Announce("FR_STATE", false)
end)
-- the cache is kept here: it holds the last live reads, and asking the game again during logout can return nothing
-- (memory only at logout: timing ten route rebuilds there ran past the game's script limit on long plans - "State.lua:25:
-- script ran too long" at PLAYER_LOGOUT in a tester's report - and the snapshot after it never got written)
ns.On("PLAYER_LOGOUT", function() State.Snapshot("logout"); pcall(ns.Perf, true) end)
