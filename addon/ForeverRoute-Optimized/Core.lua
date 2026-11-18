-- Forever Route: core namespace, saved settings, events and slash commands.
local ADDON, ns = ...
ForeverRoute = ns
ns.name = ADDON

ns.DEFAULTS = {
  scale = 1.0,
  cardWidth = 360,
  showNext = 3,          -- upcoming steps under the current one
  arrow = true,
  arrowScale = 1.0,
  pins = true,
  pinCount = 4,          -- current + next N-1 on the maps
  pathLine = true,       -- dotted walking path on the world map and minimap
  trails = true,         -- record where you walk in the capital cities (improves city paths)
  locked = false,
  rewardHint = true,     -- highlight the best quest reward
  combatFade = false,    -- fade the card while in combat (off: testers disliked it)
  smartNext = true,      -- the live solver picks what to do next from where you are (Next.lua); off: the plan order and the old reordering
  autoFly = false,       -- at a flight master, take the flight the card's trip needs
  autoQuest = false,     -- accept route quests and hand in finished ones (no reward choice) by themselves
  markTarget = true,     -- the Target button (and its key) also puts a star on the NPC
  -- what the card shows (the options' Card tab; its presets set these)
  cardNotes = true,      -- the small hint line under a step (warnings always show)
  cardZones = true,      -- the footer: "Next zone: Arathi, after 2 quests here"
  cardOffers = true,     -- "another zone is worth a look" (Zones)
  cardItemQuests = true, -- an item in your bags that starts a quest
  remindBags = true,     -- bags nearly full: the nearest vendor
  remindFood = true,     -- eat for Well Fed
  remindGrimoire = true, -- warlocks: a grimoire at the demon trainer
  newsBar = true,        -- the "updated to ..." bar under the card after an update
  moments = true,        -- keep notes of odd moments on the card for the next /fr report (Moments.lua; on your PC only)
}

-- ns.Is(fn, ...): a yes/no question to the game (UnitOnTaxi, UnitIsAFK, IsFlying, IsIndoors...). Forever hides some
-- answers from addons (secret values: in dungeons and in combat); testing one is an error, so a hidden or missing
-- answer counts as "no". Every such question goes through here (install.sh refuses raw calls).
function ns.Is(fn, ...)
  if not fn then return false end
  local ok, v = pcall(fn, ...)
  if not ok or v == nil or (issecretvalue and issecretvalue(v)) then return false end
  return v and true or false
end
local listeners = {}
ns._listeners = listeners -- (the simulator's perf battery times each one: tests/_perf.lua)
-- every repeating timer the addon runs, kept so the perf battery can price what the addon costs per second standing or
-- walking (tests/_perf.lua): { period, fn }
ns._tickers = {}
-- Work spread over frames (Next.PickAsync): a job runs as a coroutine, ns.sliceCo, for up to ns.sliceBudget ms a frame.
-- Its long loops call ns.MaybeYield(), which pauses it there when the frame's slice is used up - and does nothing
-- anywhere else (a call outside the job, a test). ns.Call(f, ...) is pcall outside the job; inside it, a plain call (a
-- pause can't cross a pcall in Lua 5.1; an error ends the job, which says so)
ns.sliceCo, ns.sliceT0, ns.sliceBudget = nil, 0, 1
function ns.MaybeYield()
  if ns.sliceCo and debugprofilestop() - ns.sliceT0 >= ns.sliceBudget and coroutine.running() == ns.sliceCo then coroutine.yield() end
end
function ns.Call(f, ...)
  if ns.sliceCo and coroutine.running() == ns.sliceCo then return true, f(...) end
  return pcall(f, ...)
end
function ns.NewTicker(period, fn)
  ns._tickers[#ns._tickers + 1] = { period = period, fn = fn }
  return C_Timer.NewTicker(period, fn)
end
local function isGameEvent(event)
  if event:find("^FR_") then return false end -- our own messages
  if C_EventUtils and C_EventUtils.IsEventValid then return C_EventUtils.IsEventValid(event) end
  return true
end
-- ns.On("EVENT", fn): pub/sub for our FR_* messages; game events are registered on demand
function ns.On(event, fn)
  if not listeners[event] then
    listeners[event] = {}
    if isGameEvent(event) then pcall(ns.frame.RegisterEvent, ns.frame, event) end
  end
  table.insert(listeners[event], fn)
end
-- Error log: every error in our code is kept (deduplicated, with a count) in ForeverRouteDB.log with what we were doing
-- at the time (route, step, zone, level, build), so it can be read from SavedVariables after a /reload. It also goes to
-- the normal error handler (BugSack), but only the first few times per message, so one bug can't flood the screen.
ns.VERSION = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version") or (GetAddOnMetadata and GetAddOnMetadata(ADDON, "Version")) or "?"
local logged = {}
function ns.LogError(where, err)
  local msg = tostring(err)
  local key = where .. "|" .. msg
  local n = (logged[key] or 0) + 1
  logged[key] = n
  if ForeverRouteDB then
    ForeverRouteDB.log = ForeverRouteDB.log or {}
    local log = ForeverRouteDB.log
    local e
    for _, x in ipairs(log) do if x.key == key then e = x; break end end
    if not e then
      local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
      e = { key = key, where = where, msg = msg, stack = debugstack and debugstack(2, 12, 0) or nil, count = 0,
        first = time and time() or 0, version = ns.VERSION, route = ns.char and ns.char.routeId, step = ns.Engine and ns.Engine.current,
        map = mapID, level = UnitLevel and UnitLevel("player") }
      -- what you were doing: the step on the card, the plan, and the addon's last few decisions (enough to fix most
      -- bugs from the save alone). Gathered under pcall: this runs inside an error already.
      pcall(function()
        local i = ns.Engine and ns.Engine.Shown and ns.Engine.Shown()
        local s = i and ForeverRouteData and ForeverRouteData.steps and ForeverRouteData.steps[i]
        if s then e.shown = string.format("%d %s q%s %s", i, tostring(s.k), tostring(s.q or "-"), tostring(s.text or s.name or ""):sub(1, 60)) end
        e.routeId = ForeverRouteData and ForeverRouteData.id
        e.plan = ForeverRoutePlan and ForeverRoutePlan.generated
        e.combat = InCombatLockdown and InCombatLockdown() or nil
        e.taxi = ns.Is(UnitOnTaxi, "player") or nil
        local w, recent = ForeverRouteDB.why, {}
        if type(w) == "table" then for j = math.max(1, #w - 5), #w do local x = w[j]; if x then recent[#recent + 1] = tostring(x.k) .. ": " .. tostring(x.x):sub(1, 90) end end end
        e.recent = recent
      end)
      table.insert(log, 1, e)
      while #log > 40 do table.remove(log) end
    end
    e.count = e.count + 1; e.last = time and time() or 0
  end
  if n <= 3 then geterrorhandler()(msg) end
end
-- wrap a function so its errors are logged instead of thrown (for OnUpdate scripts and timers)
ns.stats = {} -- name -> { n, total, max } (ms), since the last perf sample
local clock = debugprofilestop
function ns.Time(name, ms)
  local st = ns.stats[name]; if not st then st = { n = 0, total = 0, max = 0 }; ns.stats[name] = st end
  st.n = st.n + 1; st.total = st.total + ms; if ms > st.max then st.max = ms end
end
function ns.Guard(where, fn)
  return function(...)
    local t0 = clock and clock()
    local ok, err = pcall(fn, ...)
    if t0 then ns.Time(where, clock() - t0) end
    if not ok then ns.LogError(where, err) end
    return err
  end
end
-- (a listener runs under pcall, so it may never pause a job: the job's slice is off while listeners run - inside a
-- route pass, FR_STEP_DONE's listeners run in the pass's coroutine, and a pause in one would be lost with its work)
function ns.Fire(event, ...)
  local t0 = clock and clock()
  local co = ns.sliceCo
  ns.sliceCo = nil
  for i, fn in ipairs(listeners[event] or {}) do
    local listenerT0 = event == "FR_STATE" and clock and clock()
    local ok, err = pcall(fn, ...)
    if listenerT0 then ns.Time("FR_STATE listener " .. i, clock() - listenerT0) end
    if not ok then ns.LogError(event, err) end
  end
  ns.sliceCo = co
  if t0 then ns.Time("event " .. event, clock() - t0) end
end

-- item API: Forever moved these into C_Item (the old globals are gone)
ns.GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
ns.GetItemCount = (C_Item and C_Item.GetItemCount) or GetItemCount
ns.GetItemIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
ns.GetItemStats = (C_Item and C_Item.GetItemStats) or GetItemStats

ns.frame = CreateFrame("Frame")
ns.frame:SetScript("OnEvent", function(_, event, ...) ns.Fire(event, ...) end)
ns.frame:RegisterEvent("ADDON_LOADED")

local function copyDefaults(dst, src)
  for k, v in pairs(src) do
    if dst[k] == nil then dst[k] = type(v) == "table" and CopyTable(v) or v end
  end
end

-- one plan file (Route.lua) for all your characters: each has its own block (ForeverRouteByChar["Name-Realm"]), written
-- by that character's companion; only yours is loaded. An older file with a single plan is used as it is.
-- On a fresh login the name can still read "Unknown" when the addon loads; then the key saved last time is used, and the
-- plan is looked up again at PLAYER_LOGIN.
local function plain(s) return (tostring(s or ""):lower():gsub("[^%w]", "")) end
function ns.CharKey()
  local okN, name = pcall(UnitName, "player")
  local okR, realm = pcall(GetRealmName)
  name = okN and type(name) == "string" and not (issecretvalue and issecretvalue(name)) and name or nil
  realm = okR and type(realm) == "string" and not (issecretvalue and issecretvalue(realm)) and realm or nil
  if not name or name == "" or name == UNKNOWNOBJECT or name == "Unknown" or not realm or realm == "" then
    return ForeverRouteChar and ForeverRouteChar.charKey or nil
  end
  return (name .. "-" .. realm):gsub("%s", "") .. ""
end
-- your block: the exact key, else the same key ignoring case, spaces and punctuation (the planner names blocks after
-- the WTF folder, which can spell the realm differently), else the one block with your name. Never another character's.
function ns.FindMyPlan(key)
  if not key then return nil end
  if ForeverRouteByChar[key] then return ForeverRouteByChar[key], key end
  -- the block this character matched before (the game's realm name can differ from the folder the planner names it after)
  local before = ForeverRouteChar and ForeverRouteChar.planBlock
  if before and ForeverRouteByChar[before] and plain(before:match("^([^-]+)")) == plain(key:match("^([^-]+)")) then return ForeverRouteByChar[before], before end
  local want, wantName = plain(key), plain(key:match("^([^-]+)"))
  local byName, nByName
  for k, f in pairs(ForeverRouteByChar) do
    if plain(k) == want then return f, k end
    if plain(k:match("^([^-]+)")) == wantName then byName, nByName = { f, k }, (nByName or 0) + 1 end
  end
  if nByName == 1 then return byName[1], byName[2] end
end
-- the built-in plan for your race and class (Starter.lua, made by tools/starter.js): followed when there is no plan of
-- your own (an addon-only install, or before the companion has planned for a new character)
-- does this install have the companion? It writes the plan file (Route.lua: ForeverRouteByChar); an addon-site install
-- never has one. What only the companion reads (walking trails, learning) is recorded only then.
function ns.HasCompanion() return type(ForeverRouteByChar) == "table" and next(ForeverRouteByChar) ~= nil end
function ns.StarterKey()
  local okR, _, race = pcall(UnitRace, "player")
  local okC, _, class = pcall(UnitClass, "player")
  if not (okR and okC) or type(race) ~= "string" or type(class) ~= "string" then return nil end
  race = plain(race)
  if race == "scourge" then race = "undead" end -- the game's token for undead; the plans are named undead_<class>
  -- the Horde's Skyborne (Windshaper Skyborne): skybornehorde, told apart by the faction
  if race:find("skyborne", 1, true) then
    local okF, f = pcall(UnitFactionGroup, "player")
    race = (race:find("windshaper", 1, true) or (okF and f == "Horde")) and "skybornehorde" or "skyborne"
  end
  return race .. "-" .. plain(class)
end
-- The built-in plan for your race and class. The plans come as one load-on-demand addon per faction
-- (ForeverRoute_Plans_Alliance / _Horde, tools/bundle-plans.js), each plan as text: only yours is made into code and
-- the rest is let go (51 addons, one per race and class, filled the game's addon list). An older install's per-plan
-- addon (ForeverRoute_Starter_<race>_<class>) still works.
function ns.LoadStarter(sk)
  local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
  if not load then return false end
  local okF, fac = pcall(UnitFactionGroup, "player")
  local sides = (okF and fac == "Horde") and { "Horde", "Alliance" } or { "Alliance", "Horde" }
  for _, side in ipairs(sides) do
    if not (type(ForeverRoutePlanSources) == "table" and ForeverRoutePlanSources[sk]) then pcall(load, "ForeverRoute_Plans_" .. side) end
  end
  local src = type(ForeverRoutePlanSources) == "table" and ForeverRoutePlanSources[sk]
  -- the zone routes every plan of the faction shares are kept once (tools/bundle-plans.js): back into yours only
  if src and type(ForeverRoutePlanShared) == "table" then
    local shared = ForeverRoutePlanShared
    src = src:gsub("\n%-%-@zr ([^@\n]+)@", function(id) return shared[id] end)
    -- and the step lines (3.4 part 1): "--@sl i:sec:id,..." is your plan's step list, each step the faction's line i
    -- with its section and id put back
    if type(shared.lines) == "string" and src:find("\n--@sl ", 1, true) then
      local lines = {}
      for l in (shared.lines .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
      src = src:gsub("\n%-%-@sl ([^@\n]*)@", function(list)
        local out = {}
        for e in list:gmatch("[^,]+") do
          local i, sec, id = e:match("^(%d+):(%d*):(%d*)$")
          local body = i and lines[tonumber(i)]
          if not body then return nil end -- (a marker this can't read stays a comment: no steps, the plan still loads)
          out[#out + 1] = "      " .. body:sub(1, -3) .. (sec ~= "" and (", sec = " .. sec) or "") .. (id ~= "" and (", id = " .. id) or "") .. " },"
        end
        return "\n" .. table.concat(out, "\n")
      end)
    end
  end
  ForeverRoutePlanSources, ForeverRoutePlanShared = nil, nil -- every other plan's text goes
  if src then
    local chunk, err = loadstring(src, "plan " .. sk)
    if chunk then
      local ok, e = pcall(chunk)
      if not ok and ns.LogError then ns.LogError("plan", e) end
    elseif ns.LogError then ns.LogError("plan", err) end
    collectgarbage("collect")
  else
    pcall(load, "ForeverRoute_Starter_" .. sk:gsub("%-", "_"))
  end
  return type(ForeverRouteStarter) == "table" and ForeverRouteStarter[sk] ~= nil
end
function ns.LoadMyPlan()
  local key, f, found
  if type(ForeverRouteByChar) == "table" then
    key = ns.CharKey()
    f, found = ns.FindMyPlan(key)
  elseif ForeverRouteRoutes or ForeverRouteData then
    return true -- an older single-plan file
  end
  ns.planKey = { tried = key, found = found }
  if type(f) == "function" then
    if ForeverRouteChar then ForeverRouteChar.charKey = key; ForeverRouteChar.planBlock = found end
  else
    local sk = ns.StarterKey()
    if sk and not (type(ForeverRouteStarter) == "table" and ForeverRouteStarter[sk]) then ns.LoadStarter(sk) end
    f = type(ForeverRouteStarter) == "table" and sk and ForeverRouteStarter[sk]
    if type(f) ~= "function" then return false end
    ns.planKey.starter = sk
  end
  local ok, err = pcall(f)
  if not ok and ns.LogError then ns.LogError("plan", err) end
  return ok
end
local starterSaid
function ns.StarterNote()
  if starterSaid or not (ns.planKey and ns.planKey.starter) then return end
  starterSaid = true
  C_Timer.After(5, function() ns.Print("Following the plan for your race and class (steps you've already done are skipped). Bored of a zone? /fr paths shows where else you could go.") end)
end

-- flight masters and vendors come for both factions (FlightMasters.lua, Vendors.lua: ns.FLIGHT_BY, ns.VENDORS_BY);
-- yours are ns.FLIGHT and ns.VENDORS. Picked when the addon loads and again at login (the faction is surely known then)
function ns.UseFaction()
  local ok, f = pcall(UnitFactionGroup, "player")
  local side = (ok and f == "Horde") and "Horde" or "Alliance"
  if ns.FLIGHT_BY and ns.FLIGHT_BY[side] then ns.FLIGHT = ns.FLIGHT_BY[side] end
  if ns.VENDORS_BY and ns.VENDORS_BY[side] then ns.VENDORS = ns.VENDORS_BY[side] end
  return side
end
ns.On("ADDON_LOADED", function(name)
  if name ~= ADDON then return end
  ns.UseFaction()
  ns.hasPlan = ns.LoadMyPlan()
  ForeverRouteDB = ForeverRouteDB or {}
  ForeverRouteChar = ForeverRouteChar or {}
  copyDefaults(ForeverRouteDB, ns.DEFAULTS)
  ns.db = ForeverRouteDB
  -- combat fade was on by default and testers disliked it: off once for everyone (anyone can turn it back on)
  if not ns.db.combatFadeReset then ns.db.combatFade = false; ns.db.combatFadeReset = true end
  ns.char = ForeverRouteChar
  -- stay on the path you were on; nothing switches unless you choose (the zone you asked for is the one exception)
  ns.SelectRoute(ns.SavedRoute(), true)
  -- a path you asked for has arrived: switch to it once (you can switch away; it won't pull you back)
  if ns.char.requestZone and ns.char.requestHandled ~= ns.char.requestZone then
    for _, r in ipairs(ns.MainRoutes()) do
      if r.requested == ns.char.requestZone then ns.SelectRoute(r.id, true); ns.char.requestHandled = ns.char.requestZone; C_Timer.After(5, function() ns.Print("Now on the path you asked for, starting in " .. r.requested .. ".") end); break end
    end
  end
  ns.Fire("FR_LOADED")
end)
-- the name wasn't known yet when the addon loaded: look again now, and show the plan if it's found
-- maps the planner has no world bounds for (Forever's new ones: Zephras Isle 2521 and its second map 2665, Riverglades 2548, Shen'dralas 2652, Mount Hyjal 2482): the client
-- knows them for any map, wherever you are - recorded at login for the planner (tools/learn.js -> map-extras.json)
ns.MAPS_TO_MEASURE = { 2521, 2665, 2548, 2652, 2482 }
function ns.RecordMapBounds()
  if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) or not ForeverRouteDB then return 0 end
  ForeverRouteDB.mapBounds = type(ForeverRouteDB.mapBounds) == "table" and ForeverRouteDB.mapBounds or {}
  local n = 0
  for _, id in ipairs(ns.MAPS_TO_MEASURE) do
    local ok, inst, tl = pcall(C_Map.GetWorldPosFromMapPos, id, CreateVector2D(0, 0))
    local ok2, _, br = pcall(C_Map.GetWorldPosFromMapPos, id, CreateVector2D(1, 1))
    if ok and ok2 and tl and br and tl.GetXY then
      local top, left = tl:GetXY()
      local bottom, right = br:GetXY()
      if left and right and top and bottom and not (issecretvalue and (issecretvalue(left) or issecretvalue(top))) then
        local info = C_Map.GetMapInfo and C_Map.GetMapInfo(id)
        ForeverRouteDB.mapBounds[id] = { left = left, right = right, top = top, bottom = bottom, inst = inst, name = info and info.name }
        n = n + 1
      end
    end
  end
  return n
end
ns.On("PLAYER_LOGIN", function()
  ns.UseFaction()
  pcall(ns.RecordMapBounds)
  local key = ns.CharKey()
  if ForeverRouteChar and key then ForeverRouteChar.charKey = key end
  -- on the built-in plan: your own may be findable now that the name is known
  local onStarter = ns.planKey and ns.planKey.starter
  if ns.hasPlan and ns.Routes()[1] and not onStarter then return end
  if onStarter and ns.Routes()[1] and not (type(ForeverRouteByChar) == "table" and ns.FindMyPlan(key)) then ns.StarterNote(); return end
  ns.hasPlan = ns.LoadMyPlan()
  if ns.Routes()[1] then
    ns.SelectRoute(ns.SavedRoute(), false)
    ns.StarterNote()
  else
    C_Timer.After(5, function()
      ns.Print("No plan for " .. tostring(key) .. " in Route.lua" .. (type(ForeverRouteByChar) == "table" and " (plans there: " .. (function() local t = {} for k in pairs(ForeverRouteByChar) do t[#t + 1] = k end return table.concat(t, ", ") end)() .. ")" or "") .. ". /reload to load the plan for your race and class.")
    end)
  end
end)

-- Where the Map button takes you for step i: the map to open and the step whose pin to flash there.
--   a step with a spot of its own: its map, its pin
--   a trip (a fly step with no spot): the zone it goes to, and the pin of the first stop there. It used the arrow's
--     target, which for a trip is the flight master in the zone you are in - so the map opened where you stand, not
--     where you're going ("this just seems to open the map on your character and not the destination" - tester)
--   a spot nobody knows (s.unknown): its zone, no pin
-- -> uiMapID, step index (or nil); nil when the step has no place on a map
function ns.MapSpot(i)
  local list = ForeverRouteData and ForeverRouteData.steps
  local s = i and list and list[i]
  if not s then return nil end
  if s.m and s.x and not s.unknown then return s.m, i end
  if s.to and s.k == "fly" then
    for j = i + 1, #list do
      local t = list[j]
      if t.k == "fly" or t.k == "hearth" then break end
      if t.m == s.to and t.x and not t.unknown and not ns.Engine.IsDone(j) then return s.to, j end
    end
    return s.to, nil
  end
  return s.m, nil
end

function ns.ShowOnMap(i)
  local s = i and ForeverRouteData and ForeverRouteData.steps[i]
  if not s then return end
  local m, pin = ns.MapSpot(i)
  if not m then ns.Print("That step has no map spot (it's inside a dungeon, or a note)."); return end
  if InCombatLockdown() then ns.Print("Can't open the map in combat."); return end
  if i ~= ns.Engine.CardAt() then ns.Engine.view = i end
  ns.Fire("FR_STEP", ns.Engine.Shown()) -- pins follow the step being looked at
  local function setMap()
    if WorldMapFrame and WorldMapFrame:IsShown() and WorldMapFrame.SetMapID and WorldMapFrame:GetMapID() ~= m then WorldMapFrame:SetMapID(m) end
  end
  local ok, err = pcall(function()
    if WorldMapFrame and not WorldMapFrame:IsShown() then
      if OpenWorldMap then OpenWorldMap(m) elseif ToggleWorldMap then ToggleWorldMap() end
    end
    setMap()
  end)
  if not ok then ns.LogError("map", err) end
  -- again a moment later: an opening map goes to the zone you're in (the game's map does that as it opens, map addons
  -- can do it a frame later), which undid the step's map
  C_Timer.After(0, function() pcall(setMap) end)
  C_Timer.After(0.2, function() pcall(setMap) end)
  -- and make its pin flash, so the eye finds it among the map's own markers (tester)
  if pin and ns.Pins and ns.Pins.Blink then ns.Pins.Blink(pin) end
end

function ns.Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cffffd25aForever Route|r " .. tostring(msg))
  -- everything the addon tells you is also kept (last 200) in ForeverRouteDB.chat, so it can be read from your saves
  if ForeverRouteDB then
    if type(ForeverRouteDB.chat) ~= "table" then ForeverRouteDB.chat = {} end
    local t = ForeverRouteDB.chat
    t[#t + 1] = { t = time(), x = tostring(msg):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") }
    while #t > 200 do table.remove(t, 1) end
  end
end

-- keybinding labels (Bindings.xml)
BINDING_HEADER_FOREVERROUTE = "Forever Route"
BINDING_NAME_FOREVERROUTE_SKIP = "Skip current step"
BINDING_NAME_FOREVERROUTE_BACK = "Look at previous step"
BINDING_NAME_FOREVERROUTE_UNDO = "Undo last skip / done"
BINDING_NAME_FOREVERROUTE_TOGGLE = "Show / hide the card"
BINDING_NAME_FOREVERROUTE_LIST = "Show the whole route"
_G["BINDING_NAME_CLICK ForeverRouteTargetButton:LeftButton"] = "Forever Route Targeting"

SLASH_FOREVERROUTE1 = "/fr"
SLASH_FOREVERROUTE2 = "/route"
SlashCmdList.FOREVERROUTE = function(msg)
  msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if msg == "" or msg == "toggle" then ns.Fire("FR_TOGGLE")
  elseif msg == "list" then ns.Fire("FR_TOGGLE_LIST")
  elseif msg == "paths" then ns.Fire("FR_TOGGLE_PATHS")
  elseif msg == "why" then ns.WhyPrint(15)
  elseif msg == "save" then if ns.Card and ns.Card.Save then ns.Card.Save() else ReloadUI() end
  elseif msg == "dungeons" or msg == "dungeon" or msg == "trips" or msg == "bag" then ns.Fire("FR_TOGGLE_DUNGEONS")
  elseif msg == "card reset" then ns.db.uiScale, ns.db.scale = nil, 1; ns.Fire("FR_SETTINGS"); ns.db.hidden = nil; if ns.Card and ns.Card.ResetPos then ns.Card.ResetPos() end
  elseif msg == "target reset" then if ns.Card and ns.Card.ResetTarget then ns.Card.ResetTarget() else ns.db.targetPos = nil end
  elseif msg == "storage" then ns.Storage.Print()
  elseif msg == "scale" or msg:find("^scale ") then ns.Style.SlashScale(msg:sub(7))
  elseif msg == "news" then ns.Fire("FR_NEWS")
  elseif msg == "report" then ns.Fire("FR_REPORT", false)
  elseif msg == "report full" then ns.Fire("FR_REPORT", true)
  elseif msg == "logcheck" or msg == "cleanup" then ns.Fire("FR_TOGGLE_LOGCHECK")
  elseif msg == "nope" then ns.Engine.Nope()
  elseif msg == "rejoin" then ns.Engine.Rejoin()
  elseif msg == "nav" or msg == "pins" then for _, l in ipairs(ns.Nav.Report()) do ns.Print(l) end
  elseif msg == "perf" then
    local p = ns.Perf()
    local function timing(avg, peak) return avg and string.format("%.2f ms avg / %.2f ms max", avg, peak or avg) or "not sampled yet" end
    ns.Print(string.format("memory %s  ·  refresh %s  ·  progress %s  ·  %d routes, %d unpacked", p.memoryKB and string.format("%.1f MB", p.memoryKB / 1024) or "?", timing(p.refreshMs, p.refreshMaxMs), timing(p.progressMs, p.progressMaxMs), p.routes, p.unpacked))
  elseif msg == "trails" then
    local n, per = ns.Trails.Count(); local bits = {}
    for k, v in pairs(per) do bits[#bits + 1] = k .. " " .. v end
    ns.Print(string.format("city walking recorded: %d points%s. Saved on /reload or logout; the planner uses it next run.", n, #bits > 0 and (" (" .. table.concat(bits, ", ") .. ")") or ""))
  elseif msg == "log" then
    local log = ForeverRouteDB.log or {}
    if #log == 0 then ns.Print("no errors logged.") end
    for k = 1, math.min(5, #log) do local e = log[k]; ns.Print(string.format("%dx [%s] %s", e.count or 1, e.where or "?", e.msg or "?")) end
  elseif msg == "log clear" then ForeverRouteDB.log = {}; ns.Print("error log cleared.")
  elseif msg == "skip" then ns.Engine.Skip()
  elseif msg == "back" then ns.Engine.Back()
  elseif msg == "undo" then ns.Engine.Undo()
  elseif msg == "reset" then ns.char.skipped, ns.char.manualDone, ns.char.history = {}, {}, {}; ns.Engine.Refresh(); ns.Print("skips and manual ticks cleared.")
  elseif msg == "lock" then ns.db.locked = not ns.db.locked; ns.Fire("FR_SETTINGS"); ns.Print(ns.db.locked and "locked." or "unlocked.")
  elseif msg == "arrow" then ns.db.arrow = not ns.db.arrow; ns.Fire("FR_SETTINGS")
  elseif msg == "demo" then ns.Demo.Start()
  elseif msg == "snapshot" then ns.State.Snapshot("manual"); ns.Print("snapshot saved - written to disk on /reload or logout.")
  elseif msg == "options" or msg == "config" then ns.Fire("FR_OPEN_OPTIONS")
  else
    ns.Print("/fr - card · /fr list - whole route · /fr paths - where to? (pick a zone) · /fr dungeons - side trips · /fr logcheck - what to abandon · /fr rejoin - pick the built-in plan up at your level · /fr report - copy a bug report · /fr news - what changed · /fr log - recent errors · /fr nav - where the game says you, the step and the minimap are · /fr skip · /fr back · /fr undo · /fr lock · /fr arrow · /fr demo · /fr options")
  end
end

-- Passive timings from real work: diagnostics must not run ten route rebuilds or move the player's step.
function ns.Perf(memOnly)
  if UpdateAddOnMemoryUsage then pcall(UpdateAddOnMemoryUsage) end
  local mem = GetAddOnMemoryUsage and select(2, pcall(GetAddOnMemoryUsage, ADDON)) or nil
  if memOnly then
    local p = ns.char.perf or {}
    p.memoryKB, p.at = type(mem) == "number" and math.floor(mem) or nil, time and time()
    ns.char.perf = p
    return p
  end
  local refresh, progress = ns.stats.refresh, ns.stats.progress
  local previous = ns.char.perf or {}
  local unpacked = 0; for _, r in ipairs(ns.Routes()) do if r.steps then unpacked = unpacked + 1 end end
  local p = { memoryKB = type(mem) == "number" and math.floor(mem) or nil,
    refreshMs = refresh and refresh.total / refresh.n or previous.refreshMs,
    refreshMaxMs = refresh and refresh.max or previous.refreshMaxMs,
    progressMs = progress and progress.total / progress.n or previous.progressMs,
    progressMaxMs = progress and progress.max or previous.progressMaxMs,
    routes = #ns.Routes(), unpacked = unpacked, at = time and time() }
  ns.char.perf = p
  return p
end

local function perfSample()
  local perf = ns.Perf() -- Preserve numeric timings before resetting the sample window.
  local e = { at = time and time() or 0, memoryKB = perf.memoryKB, level = UnitLevel("player"), route = ns.char and ns.char.routeId } -- no map id: Forever may hand it out as a protected value that can't be saved
  for name, st in pairs(ns.stats) do e[name] = string.format("%d calls, avg %.2f ms, max %.2f ms", st.n, st.n > 0 and st.total / st.n or 0, st.max) end
  wipe(ns.stats)
  ns.char.perfLog = ns.char.perfLog or {}
  table.insert(ns.char.perfLog, e)
  while #ns.char.perfLog > 20 do table.remove(ns.char.perfLog, 1) end
end
-- failures go to the error log (they used to be swallowed, which hid a broken logger)
local guardedSample = ns.Guard("perf", perfSample)
ns.On("FR_LOADED", function() C_Timer.After(60, guardedSample); ns.NewTicker(300, guardedSample) end)
ns.On("PLAYER_LOGOUT", guardedSample)
ns._perfSample = perfSample -- for tests
