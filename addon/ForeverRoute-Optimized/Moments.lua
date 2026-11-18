-- Moments: the card looked wrong, kept as a bug report without anyone stopping to type /fr report. Each moment is the
-- same snapshot /fr report packs (UI/Report.lua, the full form: an exact replay), plus a short tag of why it was kept:
--   flagged    you clicked "this looks wrong" on the card
--   done       the card shows a step that is already done (a gray pick-up the route dropped, Engine.Outlevelled, and a
--              gray hand-in no longer worth it, Engine.GrayHandIn, read "done" too: statusRaw says so)
--   heads-out  the card sends you out of town (over 250 yd, or work with no known spot) while the plan picks up a quest
--              right here (giver within 250 yd, room in the log) - tools/replay.js's HEADS-OUT
--   flip       the card went back and forth between two steps (A, B, A, B within a minute and a half)
--   arrow      the arrow is hidden on a step for no reason it knows (no position for the step)
-- They mirror tools/replay.js's "!!" flags where the game lets us see them. Kept in ForeverRouteDB.moments (account
-- SavedVariables, on your PC): at most Moments.MAX, the same step and tag once (the newest), the oldest noticed one
-- dropped first (one you flagged goes only when all ten are flagged). A capture in combat waits for combat's end.
-- /fr report carries the ones not sent yet inside it (marked sent once its box closes); the companion's upload
-- (tools/report-upload.js) is dormant: only with a yes there.
-- Cost: nothing per frame. FR_STEP only compares the step on the card with the last one; a changed step is looked at
-- once, a few seconds later (one timer at a time), and a capture (the report's gather, a few ms) happens at most once
-- per Moments.COOLDOWN for the automatic ones. tests/_perf.lua prices both ("moment check", "moment saved").
local _, ns = ...
local Moments = {}
ns.Moments = Moments

Moments.MAX = 10
Moments.COOLDOWN = 120   -- seconds between automatic captures
Moments.SETTLE = 3       -- seconds a changed card waits before it is looked at (the card settles after a refresh)
Moments.FLIP_WINDOW = 90 -- seconds: A, B, A, B inside it is a flip
Moments.NEAR, Moments.AWAY = 250, 250 -- yards: a pick-up "here", a step "out"
Moments.TAGS = { flagged = true, done = true, gray = true, ["heads-out"] = true, flip = true, arrow = true } -- (gray: a fallback, see CheckStep)
-- (the perf battery: detectors run, captures are counted, not gathered - the battery prices a capture on its own)
Moments.dryRun = false
Moments.captured = 0

local function now() return (GetTime and GetTime()) or 0 end
local function store()
  ForeverRouteDB.moments = type(ForeverRouteDB.moments) == "table" and ForeverRouteDB.moments or {}
  local M = ForeverRouteDB.moments
  M.list = type(M.list) == "table" and M.list or {}
  return M
end
function Moments.List() return store().list end
function Moments.Count() return ForeverRouteDB and type(ForeverRouteDB.moments) == "table" and type(ForeverRouteDB.moments.list) == "table" and #ForeverRouteDB.moments.list or 0 end
function Moments.Clear() if ForeverRouteDB then ForeverRouteDB.moments = { list = {} } end end

-- keep one: the same route, step and tag replace the older one; over MAX the oldest noticed one goes (one you flagged
-- is never pushed out by noticed ones: only by your own, once all of them are)
function Moments.Keep(m)
  local list = store().list
  -- (the same step and tag again: folded into this one and counted - unless that one went out in a report already)
  for k = #list, 1, -1 do if list[k].key == m.key then if not list[k].sent then m.n = (m.n or 1) + (list[k].n or 1) end; table.remove(list, k) end end
  local S = store(); S.seq = (S.seq or 0) + 1; m.seq = S.seq -- (the order kept, within one second too)
  list[#list + 1] = m
  -- (over MAX: the oldest sent one goes, then the oldest noticed one, then the oldest)
  while #list > Moments.MAX do
    local drop
    for k = 1, #list do if list[k].sent then drop = k; break end end
    if not drop then for k = 1, #list do if list[k].auto then drop = k; break end end end
    table.remove(list, drop or 1)
  end
  return m
end

local function stepKeyNow()
  local cur = ns.Engine.Shown and ns.Engine.Shown()
  local data = ForeverRouteData
  return (data and data.id or "") .. "|" .. (cur and ns.Engine.Key(cur) or "")
end
-- the already-kept check, before any gather: a moment kept for this step and tag (not sent yet) costs nothing again -
-- it is counted instead (x3 in the report) -> that moment, or nil
function Moments.Has(tag)
  local key = stepKeyNow() .. "|" .. tag
  for _, m in ipairs(Moments.List()) do if m.key == key and not m.sent then return m end end
  return nil
end

-- a capture: the full report of this moment, its tag and a short why. auto: a detector's (cooldown, the option).
-- In combat it waits for PLAYER_REGEN_ENABLED (a few ms of gathering is a frame you notice in a fight); the newest one
-- asked for is the one kept -> the moment, or true when it waits
Moments.lastAuto, Moments.deferred = nil, nil
function Moments.InCombat() return InCombatLockdown and InCombatLockdown() and true or false end
function Moments.Capture(tag, why, auto)
  if not (ForeverRouteDB and ns.Report and ns.Engine and ForeverRouteData) then return nil end
  if Moments.InCombat() and not Moments.dryRun then Moments.deferred = { tag = tag, why = why, auto = auto }; return true end
  if auto then
    if ns.db.moments == false then return nil end
    local had = Moments.Has(tag)
    if had then had.n = (had.n or 1) + 1; return nil end
    if Moments.lastAuto and now() - Moments.lastAuto < Moments.COOLDOWN then return nil end
    if Moments.dryRun then Moments.captured = Moments.captured + 1; return nil end -- (no cooldown: every check priced whole)
    Moments.lastAuto = now()
  end
  Moments.captured = Moments.captured + 1
  local ok, text = pcall(function()
    local d = ns.Report.Gather(true)
    d.why = Moments.WhyWindow()
    d.moment = { tag = tag, why = tostring(why or ""), auto = auto and true or false }
    return ns.Report.Pack(d)
  end)
  if not ok then if ns.LogError then pcall(ns.LogError, "moment", text) end; return nil end
  local m = Moments.Keep({ t = time(), tag = tag, why = tostring(why or ""):sub(1, 120), auto = auto and true or false, key = stepKeyNow() .. "|" .. tag,
    v = ns.VERSION, text = text })
  if ns.Why then ns.Why("moment", tag .. ": " .. tostring(why or "")) end
  return m
end

ns.On("PLAYER_REGEN_ENABLED", function()
  local d = Moments.deferred
  Moments.deferred = nil
  if d then pcall(Moments.Capture, d.tag, d.why, d.auto) end
end)

-- the card's reasoning around a moment: the decision log's entries (ns.Why) of the last WHY_SECS, at most WHY_MAX -
-- packed into the moment itself, so an older moment keeps its own context (the log is shared and rolls on)
Moments.WHY_SECS, Moments.WHY_MAX = 60, 15
function Moments.WhyWindow(at)
  local w = (ForeverRouteDB and ForeverRouteDB.why) or {}
  at = at or time()
  local out = {}
  for k = #w, 1, -1 do
    local e = w[k]
    if not e or (e.t or 0) < at - Moments.WHY_SECS then break end
    if (e.t or 0) <= at then table.insert(out, 1, e) end
    if #out >= Moments.WHY_MAX then break end
  end
  return out
end

Moments.COPY_MAX = 30000 -- characters in one report: past it the oldest noticed moments are left out (and counted)

-- the moments for the next report (not sent yet): flagged ones first, then noticed ones, each newest first; past
-- COPY_MAX characters (budget: the report's own) the oldest noticed ones are left out -> list, how many left out
-- (a moment's text is base64: its bytes take about 3/4 of it, base64'd again in the report - the same length)
function Moments.ForCopy(budget)
  local mine, auto = {}, {}
  for _, m in ipairs(Moments.List()) do if type(m.text) == "string" and not m.sent then if m.auto then auto[#auto + 1] = m else mine[#mine + 1] = m end end end
  local newest = function(a, b) if (a.t or 0) ~= (b.t or 0) then return (a.t or 0) > (b.t or 0) end; return (a.seq or 0) > (b.seq or 0) end
  table.sort(mine, newest); table.sort(auto, newest)
  local used = budget or 0
  for _, m in ipairs(mine) do used = used + #m.text + 2 end
  local keep, out = {}, 0
  for _, m in ipairs(auto) do
    if used + #m.text + 2 <= Moments.COPY_MAX then keep[#keep + 1] = m; used = used + #m.text + 2 else out = out + 1 end
  end
  local list = {}
  for _, m in ipairs(mine) do list[#list + 1] = m end
  for _, m in ipairs(keep) do list[#list + 1] = m end
  return list, out
end
-- these went out in a report (its box closed): left out of the next one, kept until pushed out
function Moments.MarkSent(these)
  local now = time()
  for _, m in ipairs(these or {}) do m.sent = now end
end

-- the card's button: you say it looks wrong (always kept, whatever the option and the cooldown)
function Moments.Flag() return Moments.Capture("flagged", "you clicked: this looks wrong", false) end

---------------------------------------------------------------------------------------------------------------
-- the detectors (pure: what is wrong with the card now, or nil; tests call them directly)
local function quiet()
  -- (no verdict while you look at another step, ride a flight, stand in a dungeon or a side trip, or are dead: the card
  -- is not the route's answer to where you are)
  local E = ns.Engine
  if E.view then return true end
  if ns.Is(UnitOnTaxi, "player") or ns.Is(UnitIsDeadOrGhost, "player") then return true end
  if ns.Dungeon and ns.Dungeon.Inside and ns.Dungeon.Inside() then return true end
  local data = ForeverRouteData
  if not (data and data.steps) or data.dungeon then return true end
  return false
end
Moments.Quiet = quiet

local function yardsTo(s)
  local HBD = LibStub and LibStub("HereBeDragons-2.0", true)
  if not (HBD and s and s.m and s.x) then return nil end
  local px, py, pinst = HBD:GetPlayerWorldPosition()
  local wx, wy, winst = HBD:GetWorldCoordinatesFromZone(s.x, s.y, s.m)
  if not (px and wx) then return nil end
  if pinst ~= winst then return -1 end
  return math.sqrt((px - wx) ^ 2 + (py - wy) ^ 2)
end
Moments.Yards = yardsTo

-- done or gray on the card -> tag, why
function Moments.CheckStep(i)
  local E = ns.Engine
  local s = i and ForeverRouteData and ForeverRouteData.steps[i]
  if not s then return nil end
  if E.Status(i) == "done" then return "done", "the card shows a done step: " .. tostring(s.k) .. " " .. tostring(s.name or s.text or "") end
  local lvl = UnitLevel("player") or 1
  local ql = tonumber(s.level)
  -- (by the route's own gray line, not any gray quest: one already in your log is shown on purpose - its objectives and
  -- hand-in stay on the route. Wrong is a gray pick-up the route should have dropped (Engine.Outlevelled) or a gray
  -- hand-in no longer worth the trip (Engine.GrayHandIn). Engine's statusRaw already calls both "done", so the line
  -- above catches them: this is only a fallback, should a status ever say otherwise)
  if s.q and ql and ql > 0 and ((E.Outlevelled and E.Outlevelled(s)) or (E.GrayHandIn and E.GrayHandIn(s))) then
    return "gray", string.format("a level %d quest at level %d: %s %s", ql, lvl, tostring(s.k), tostring(s.name or ""))
  end
  return nil
end

-- sent out while the plan picks up a quest here -> tag, why (as tools/replay.js's HEADS-OUT and the rule the card
-- follows, Next.PickupFirst: from the plan's own step on, up to 60 steps, this visit only - stopping at a flight, a
-- hearth, a boat or the first step with a known spot over 600 yd; a pick-up offered now, prerequisites and all,
-- Engine.Available). Not a verdict with the live solve off (the plan's order is then the card's) or while something
-- holds the card (a step you chose, one your kills count for)
function Moments.CheckHeadsOut(i)
  local E, S = ns.Engine, ns.State
  local list = ForeverRouteData and ForeverRouteData.steps
  local s = i and list and list[i]
  if not s or s.k == "accept" then return nil end
  if ns.Next and ns.Next.Enabled and not ns.Next.Enabled() then return nil end
  if E.Holding and E.Holding(true) then return nil end
  local NEAR, FAR = (ns.Next and ns.Next.HERE_YD) or Moments.NEAR, (ns.Next and ns.Next.HERE_FAR) or 600
  local y0 = yardsTo(s)
  if not (s.unknown or y0 == -1 or (y0 and y0 > Moments.AWAY)) then return nil end
  if S.LogCount and S.MaxLog and S.LogCount() >= S.MaxLog() then return nil end
  local from = E.planned or i
  for j = from, math.min(#list, from + 60) do
    local t = list[j]
    if t.k == "fly" or t.k == "hearth" or t.k == "boat" then break end
    local y = (t.m and not t.unknown) and yardsTo(t) or nil
    if j > from and t.m and not t.unknown and (not y or y < 0 or y > FAR) then break end
    if j ~= i and t.k == "accept" and t.q and E.Status(j) == "todo" and (not E.Available or E.Available(j)) and not (ns.Avail and ns.Avail.Unavailable(t.q))
      and not (ns.Nope and ns.Nope(t.q)) and not (E.Outlevelled and E.Outlevelled(t)) and y and y >= 0 and y <= NEAR then
      return "heads-out", string.format("sends you out (%s %s) while %s is picked up here, %d yd", tostring(s.k), tostring(s.name or s.text or ""), tostring(t.name or "?"), math.floor(y))
    end
  end
  return nil
end

-- the card's step changes: A, B, A, B inside the window -> tag, why. Not every change counts: a card held by what
-- you do (Engine.focusWhy: a step you chose, one your kills count for, one you're at) or moved by kill progress on
-- either step (Engine.RecentProgress: two quests' mobs in one camp move the card back and forth, rightly) is not the
-- route flipping; and your own actions (skip, done, undo, back) start the count again
Moments.changes = {}
function Moments.Counts(i, prevI)
  local E = ns.Engine
  if E.focusWhy then return false end
  if E.RecentProgress and ((i and E.RecentProgress(i)) or (prevI and E.RecentProgress(prevI))) then return false end
  return true
end
function Moments.ForgetChanges() Moments.changes = {} end
do
  -- (wrapped at load: the card's buttons and the slash commands call these by name)
  local E = ns.Engine
  for _, name in ipairs({ "Skip", "MarkDone", "Undo", "Back", "Forward", "FocusOn", "Nope", "NotOffered" }) do
    local f = E[name]
    if type(f) == "function" then E[name] = function(...) Moments.ForgetChanges(); return f(...) end end
  end
end
function Moments.NoteChange(s, t)
  local c = Moments.changes
  c[#c + 1] = { t = t or now(), s = s }
  while #c > 6 do table.remove(c, 1) end
end
function Moments.CheckFlip(t)
  local c, n = Moments.changes, #Moments.changes
  if n < 4 then return nil end
  t = t or now()
  local a, b = c[n].s, c[n - 1].s
  if a == b or (t - c[n - 3].t) > Moments.FLIP_WINDOW then return nil end
  if c[n - 2].s == a and c[n - 3].s == b then
    local function nm(s) return tostring(s and (s.name or s.text or s.dest) or "?") end
    return "flip", "the card went back and forth: " .. nm(b) .. " / " .. nm(a)
  end
  return nil
end

---------------------------------------------------------------------------------------------------------------
-- the hooks: FR_STEP (the card changed: compare, and look again once it settled) and the arrow's hidden reason
Moments.last, Moments.pending = nil, nil
function Moments.Look()
  Moments.pending = nil
  if quiet() then return nil end
  local i = ns.Engine.CardAt()
  if not i then return nil end
  local tag, why = Moments.CheckStep(i)
  if not tag then tag, why = Moments.CheckFlip() end
  if not tag then tag, why = Moments.CheckHeadsOut(i) end
  if tag then Moments.Capture(tag, why, true) end
  return tag, why
end
function Moments.OnStep()
  if ns.db.moments == false or not ForeverRouteData then return end
  local list = ForeverRouteData.steps
  local s = ns.Engine.CardAt() and list and list[ns.Engine.CardAt()]
  if ns.Engine.view or not s then return end
  if s == Moments.last then
    -- (the same step again, after a refresh: looked at again only if it went done under the card - one status read)
    if Moments.pending or ns.Engine.Status(ns.Engine.CardAt()) ~= "done" then return end
  else
    local prevI = Moments.lastI
    if prevI and list[prevI] ~= Moments.last then prevI = nil end -- (a stop inserted before it moved its number)
    Moments.last, Moments.lastI = s, ns.Engine.CardAt()
    if Moments.Counts(ns.Engine.CardAt(), prevI) then Moments.NoteChange(s) else Moments.ForgetChanges() end
  end
  if Moments.pending or not (C_Timer and C_Timer.After) then return end
  Moments.pending = true
  C_Timer.After(Moments.SETTLE, function() local ok, err = pcall(Moments.Look); if not ok and ns.LogError then pcall(ns.LogError, "moment", err) end end)
end
ns.On("FR_STEP", function() local ok, err = pcall(Moments.OnStep); if not ok and ns.LogError then pcall(ns.LogError, "moment", err) end end)

-- the arrow says why it is hidden (UI/Arrow.lua, on a change only): no position for a step it should point at
-- (looked at again once it settled: still hidden for that reason, on the same step)
-- Only a step that could be pointed at: you have coordinates (not loading, not indoors where the game gives none), and
-- not a flight (its flight master is the taxi's job) or a hearth
function Moments.ArrowCase(why, s)
  if not why or not tostring(why):find("^no position for this step") then return false end
  if not s or s.k == "fly" or s.k == "hearth" or s.k == "boat" then return false end
  local HBD = LibStub and LibStub("HereBeDragons-2.0", true)
  local px = HBD and HBD:GetPlayerWorldPosition()
  if not px then return false end
  return true
end
function Moments.ArrowHidden(why)
  if not why or not tostring(why):find("^no position for this step") then return end
  if ns.db.moments == false or not (C_Timer and C_Timer.After) then return end
  local s = ns.Engine.CardAt() and ForeverRouteData and ForeverRouteData.steps[ns.Engine.CardAt()]
  if not Moments.ArrowCase(why, s) then return end
  C_Timer.After(Moments.SETTLE, function()
    local still = ns.Arrow and ns.Arrow.HiddenWhy and ns.Arrow.HiddenWhy() == why
    local same = s and ForeverRouteData and ForeverRouteData.steps[ns.Engine.CardAt() or 0] == s
    if still and same and not quiet() and Moments.ArrowCase(why, s) then pcall(Moments.Capture, "arrow", "the arrow is hidden: " .. tostring(why), true) end
  end)
end
