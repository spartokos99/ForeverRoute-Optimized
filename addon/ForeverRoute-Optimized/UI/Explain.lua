-- Why the card sends you where it does, in plain words: the card's "?" (Card.lua) and the one line under a trip that
-- leaves your zone. Players don't read paragraphs ("assume no one reads all of this"), so it leads with one line that
-- says it's the quickest way and why, backed by a number where the engine has one (minutes saved, XP), and "the fastest
-- route the planner found" where it has none - never a made-up number. The facts follow on a second line; a trip's
-- legs, in full, after that.
-- Built only when asked (a click on "?"): nothing here runs per frame. The card's line is memoized per step.
local _, ns = ...
local Explain = {}
ns.Explain = Explain

local function steps() return ForeverRouteData and ForeverRouteData.steps or {} end
local function cap(t) return t and (t:sub(1, 1):upper() .. t:sub(2)) or t end
local function plural(n, one, many) return n .. " " .. (n == 1 and one or (many or (one .. "s"))) end
function Explain.Xp(xp)
  xp = math.floor(tonumber(xp) or 0)
  if xp >= 1000 then return (string.format("%.1fk", xp / 1000):gsub("%.0k$", "k")) end
  return tostring(xp)
end
local function minutes(secs) return math.max(1, math.floor((tonumber(secs) or 0) / 60 + 0.5)) end

-- the zone you are in, by the plan's names ("Stormwind City")
function Explain.HereZone()
  local pm = ns.State and ns.State.Position and ns.State.Position()
  local info = pm and C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(pm)
  return info and info.name or nil, pm
end

-- the trip the card leads with for step s: { trip, legs }, or nil (a walk, or no trip). Card.TripHead decides when.
local function tripOf(s)
  local t = s and ns.Engine.TravelFor and ns.Engine.TravelFor(s)
  if not t then return nil end
  return t, t.legs or { t }
end

-- the stretch of the plan step i takes you to: the zone's visit from ZonesAhead and what it is worth at your level
-- (Engine.StretchWorth) -> { zone, after (the zone after it), quests, name (its first quest), n (quests at your
-- level), hand (hand-ins), xp, secs (work), first, last } or nil
function Explain.Stretch(i)
  local s = steps()[i]
  if not (s and ns.Engine.ZonesAhead) then return nil end
  local z = ns.Engine.ZonesAhead(i, 3)
  local want = (s.k == "fly" and (s.dest or s.text)) or s.zone
  local a, b
  for k = 1, #z do if z[k].zone == want or (s.k == "fly" and k == 1) then a, b = z[k], z[k + 1]; break end end
  if not a then return nil end
  local list = steps()
  local last = (b and b.first - 1) or #list
  local out = { zone = a.zone, after = b and b.zone or nil, quests = a.quests, name = a.names and a.names[1], first = a.first, last = last, grind = a.grind }
  if ns.Engine.StretchWorth then
    local ok, xp, secs, n = pcall(ns.Engine.StretchWorth, a.first, last)
    if ok then out.xp, out.secs, out.n = xp, secs, n end
  end
  local hand = 0
  for j = a.first, last do local t = list[j]; if t and t.k == "turnin" and not ns.Engine.IsDone(j) then hand = hand + 1 end end
  out.hand = hand
  return out
end

-- does the trip to step i take you out of the zone you are in?
local function leaves(i)
  local s = steps()[i]
  local here, pm = Explain.HereZone()
  if not (s and pm) then return false end
  if s.k == "fly" then return (s.to and s.to ~= pm) or false end
  return (s.m and s.m ~= pm) or false
end

-- The card's line under a trip that leaves your zone: "For Pearl Diving and 6 more quests at your level". Facts, not
-- a why (the "?" has the why). Memoized per step and what it depends on, so a card refresh pays for it once.
local cardMemo = setmetatable({}, { __mode = "k" })
function Explain.CardLine(i)
  local s = steps()[i]
  if not (s and leaves(i)) then return nil end
  local z = ns.Engine.ZonesAhead and ns.Engine.ZonesAhead(i, 3)
  local a = z and z[1]
  local key = table.concat({ (UnitLevel and UnitLevel("player")) or 0, a and a.first or "-", a and a.quests or "-", tostring(ns.Engine.planned) }, "|")
  local m = cardMemo[s]
  if m and m.key == key then return m.v end
  local st = Explain.Stretch(i)
  local v
  if st then
    local n = st.n or st.quests or 0
    if st.name and n >= 2 then v = string.format("For %s and %s at your level", st.name, plural(n - 1, "more quest"))
    elseif st.name and n == 1 then v = "For " .. st.name
    elseif n > 0 then v = "For " .. plural(n, "quest") .. " at your level"
    elseif st.grind then v = "To level up there" end
  end
  cardMemo[s] = { key = key, v = v }
  return v
end

-- the solver's pick (a step out of the plan's order): its tag (Next.Tag) in words. -> why, fact
local PICK = {
  ["while you're here"] = "Looks odd, but it's the fastest way: doing it now saves a trip back later",
  ["saves a trip back"] = "Looks odd, but it's the fastest way: doing it now saves a trip back later",
  ["on the way"] = "Quickest from here: it's on the way",
  ["before you head out"] = "Pick it up before you leave: its work fits on the same trip",
  ["chain continues"] = "Quickest from here: the chain goes on right here",
  ["you're here already"] = "Quickest from here: you're here already, and these quests are next on your plan",
  ["right here"] = "Worth it: right here, and still XP at your level",
  ["nearby"] = "Worth it: close by, and still XP at your level",
}
local NO_NUMBER = { ["while you're here"] = true, ["saves a trip back"] = true, ["on the way"] = true }
local function pickWhy(i)
  local tag = ns.Next and ns.Next.Enabled and ns.Next.Enabled() and ns.Next.Tag and ns.Next.Tag(i)
  if not tag then return nil end
  local base = (tag:match("^(.-)%s*·") or tag):gsub("%s+$", "")
  local min = tonumber(tag:match("saves ~(%d+) min"))
  local xp = tag:match("%+(%S+) XP")
  local why = PICK[base] or PICK["on the way"]
  if min then why = why .. string.format(" (~%d min)", min)
  elseif xp then why = why .. " (+" .. xp .. " XP)"
  elseif NO_NUMBER[base] or not PICK[base] then why = why .. " (the fastest route the planner found)" end
  return why .. "."
end

-- the newest decision log entry of a kind (ns.Why), at most `within` seconds old
local function recentWhy(kind, within, pattern)
  local w = ForeverRouteDB and ForeverRouteDB.why
  if type(w) ~= "table" then return nil end
  local now = time and time() or 0
  for k = #w, math.max(1, #w - 40), -1 do
    local e = w[k]
    if e and now - (e.t or 0) > within then return nil end
    if e and e.k == kind and (not pattern or (e.x or ""):find(pattern)) then return e end
  end
end

-- -> { { text, color }, ... }: the why first, the fact backing it, then (a trip of several legs) the way, leg by leg
Explain.LEGS = 6
function Explain.Lines(i)
  local out = {}
  local function add(t, c) if t and t ~= "" then out[#out + 1] = { t, c } end end
  local list = steps()
  local s = i and list[i]
  if not s then add("Nothing to do here: your route is done."); return out end
  local planned = ns.Engine.planned
  local trip, legs = tripOf(s)
  local here = Explain.HereZone()
  local why, fact
  -- 1. the solver took this stop out of your plan's order
  if planned and i ~= planned and list[planned] then
    why = pickWhy(i)
    if why then fact = "Your plan's next step after it: " .. ns.Card.Plain((ns.Card.Describe(list[planned]))) .. "." end
  end
  -- 2. a trip out of the zone you're in
  if not why and trip and leaves(i) then
    local st = Explain.Stretch(i)
    local secs
    local pm, px, py = ns.State.Position()
    if pm and px and ns.Travel and ns.Travel.Plan then
      local to = s.k == "fly" and s.to and { m = s.to, x = 0.5, y = 0.5, name = s.dest or s.text } or (s.m and s.x and { m = s.m, x = s.x, y = s.y, name = s.zone, stop = s.npc })
      local fs = st and st.first and list[st.first]
      if s.k == "fly" and fs and fs.m and fs.x then to = { m = fs.m, x = fs.x, y = fs.y, name = s.dest or s.text, stop = fs.npc } end
      if to then local ok, _, t = pcall(ns.Travel.Plan, { m = pm, x = px, y = py }, to); if ok then secs = tonumber(t) end end
    end
    local zone = (st and st.zone) or (s.k == "fly" and (s.dest or s.text)) or s.zone or "the next zone"
    local n = st and (st.n or st.quests) or 0
    local back = st and here and st.after == here
    local round = secs and st and st.secs and (2 * secs + st.secs) or nil
    if back and round and round <= 15 * 60 and n > 0 then
      local what = (st.hand == n) and plural(n, "hand-in") or plural(n, "quest")
      why = string.format("Short hop worth it: %s in %s%s, back in about %d min.", what, ns.Style.ShortZone(zone), (st.xp or 0) > 0 and (" for ~" .. Explain.Xp(st.xp) .. " XP") or "", minutes(round))
    else
      why = (n > 0 and st.xp and st.xp > 0)
        and string.format("Your plan moves on to %s: %s there for ~%s XP. The fastest route the planner found.", ns.Style.ShortZone(zone), plural(n, "quest") .. " at your level", Explain.Xp(st.xp))
        or string.format("Your plan moves on to %s: the fastest route the planner found.", ns.Style.ShortZone(zone))
      local bits = {}
      if st and st.name then bits[#bits + 1] = "First up there: " .. st.name end
      if secs then bits[#bits + 1] = "about " .. minutes(secs) .. " min to get there" end
      if back then bits[#bits + 1] = "then back here" elseif st and st.after then bits[#bits + 1] = "then " .. ns.Style.ShortZone(st.after) end
      fact = #bits > 0 and (cap(table.concat(bits, ", ")) .. ".") or nil
    end
  end
  -- 3. a flight inside your zone that beats the walk (Travel.Shortcut)
  if not why and trip and trip.shortcut and legs[1] and legs[1].gain then
    why = "Quicker than walking: " .. legs[1].gain .. "."
  end
  -- 4. your plan's own next step
  if not why then
    local kept = recentWhy("next", 180, "^kept the plan's step")
    if ns.Next and ns.Next.rejoin and planned and i >= (ns.Next.rejoin.at or math.huge) then
      why = "Quickest from here: you're here already, and these quests are next on your plan."
    elseif kept and kept.x:find("another continent", 1, true) then
      why = "Next on your plan. The quickest other stop is on another continent, so this comes first."
    elseif kept then
      why = "Next on your plan: nothing close by is worth doing before it."
    else
      why = "Next on your plan: the fastest route the planner found."
    end
    local z = ns.Engine.ZonesAhead and ns.Engine.ZonesAhead(i, 2)
    local a, b = z and z[1], z and z[2]
    if a and a.zone == s.zone and a.quests > 0 then
      fact = plural(a.quests, "quest") .. " left in " .. ns.Style.ShortZone(a.zone) .. (b and (", then " .. ns.Style.ShortZone(b.zone)) or "") .. "."
    end
  end
  add(why, { 1, 1, 1 })
  -- a stop left out of this trip a moment ago (Engine/Inserts.lua's "merge" log): said, so it isn't a mystery
  local merge = recentWhy("merge", 600, "^left ")
  if merge and not fact then
    local what = merge.x:match("^left %S+ (.-) %(") or merge.x:match("^left (.-) for later")
    if what and what ~= "" then fact = "Left for later: " .. what .. " (too far off this trip)." end
  end
  add(fact, { 0.75, 0.8, 0.88 })
  -- the way, leg by leg (the card shows only the leg you're on)
  if trip and legs and #legs > 1 then
    add("The way:", { 0.55, 0.6, 0.68 })
    for n, l in ipairs(legs) do
      if n > Explain.LEGS then add(string.format("+%d more", #legs - Explain.LEGS), { 0.55, 0.6, 0.68 }); break end
      add(n .. ". " .. (l.text or ""), n == 1 and { 1, 0.82, 0.36 } or { 0.6, 0.65, 0.72 })
    end
  elseif trip and legs and legs[1] and legs[1].fp and (legs[1].text or "") ~= "" then
    add(legs[1].text, { 0.6, 0.65, 0.72 })
  end
  return out
end

-- the "?" clicked: the lines in a tooltip on the button (until the mouse leaves it)
function Explain.Show(owner, i)
  if not (owner and GameTooltip) then return end
  local ok, lines = pcall(Explain.Lines, i)
  if not ok then lines = { { "The fastest route the planner found." } } end
  GameTooltip:SetOwner(owner, "ANCHOR_BOTTOMLEFT")
  GameTooltip:SetText("Why this step?", 1, 0.82, 0.36)
  for _, l in ipairs(lines) do local c = l[2] or { 1, 1, 1 }; GameTooltip:AddLine(l[1], c[1], c[2], c[3], true) end
  GameTooltip:Show()
end
