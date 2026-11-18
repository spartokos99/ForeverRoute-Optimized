-- "Quest log check": which quests in your log are worth keeping. Each one is checked against your routes:
--   not on any route (you'll never be sent there)          -> suggest abandoning
--   on the route, but gray by the time you get there         -> suggest abandoning
--   finished, but not on the route                           -> hand it in if you pass by
--   on the route                                             -> keep (and when it comes up)
-- Nothing is abandoned unless you click Abandon and confirm. Opened from the route list or /fr logcheck.
-- Below the quests: the quest items in your bags that nothing needs any more (LogCheck.Leftovers) - a list of what is
-- safe to delete. Deleting is yours to do: the addon never destroys an item.
local _, ns = ...
local Style = ns.Style
local C = Style.C
local LogCheck = {}
ns.LogCheck = LogCheck

local f, recount
-- BTNS: the column the buttons take on the right (Bring back / Keep + Abandon); the text keeps clear of it and wraps
local W, PAD, ROW, BTNS = 560, 14, 34, 176
local rows = {}

local function call(fn, ...) if type(fn) == "function" then local ok, a = pcall(fn, ...); if ok then return a end end end
-- (the engine's one gray rule, Engine.GrayDrop: gray and leading to nothing worth XP is off the route and "drop" here; gray
-- but leading on is kept in both. The log check said "drop" for quests the route kept - code review, and user's rule)
-- -> "drop"; or "leads", the follow-up's name; or nil (not gray)
local function grayRule(e, level)
  local E = ns.Engine
  if not (E.GrayDrop and e.level and level) then return nil end
  local drop, via = E.GrayDrop(e.id, level, e.level)
  if drop then return "drop" end
  if via then
    local L = ns.QuestLevel and ns.QuestLevel(via)
    return "leads", (E.QuestName and E.QuestName(via) or ("quest " .. via)) .. (L and (" (level " .. L .. ")") or "")
  end
end

-- your quest log: id, title, level, zone header
function LogCheck.Entries()
  local out, zone = {}, nil
  local n = C_QuestLog and C_QuestLog.GetNumQuestLogEntries and call(C_QuestLog.GetNumQuestLogEntries) or 0
  for i = 1, n do
    local info = C_QuestLog.GetInfo and call(C_QuestLog.GetInfo, i)
    if info then
      if info.isHeader then zone = info.title
      elseif info.questID and info.questID > 0 then out[#out + 1] = { id = info.questID, title = info.title or ("quest " .. info.questID), level = info.level, zone = zone } end
    end
  end
  return out
end

-- where a quest comes up in a route: the first step for it, and the planned level there
-- a step list's steps by quest, made once per list (and again when stops are added): the check runs on every log change,
-- and walking the whole plan for each quest in your log, twice, was 10 ms at level 50 (the perf battery)
local qIndex = setmetatable({}, { __mode = "k" })
local NONE = {}
local function stepsOf(steps, id)
  local ix = qIndex[steps]
  if not ix or ix.n ~= #steps then
    ix = { n = #steps, by = {} }
    for i, s in ipairs(steps) do if s.q then local t = ix.by[s.q]; if not t then t = {}; ix.by[s.q] = t end; t[#t + 1] = i end end
    qIndex[steps] = ix
  end
  return ix.by[id] or NONE
end
local function findIn(route, id)
  if not route then return nil end
  local steps = route.steps or {}
  for _, i in ipairs(stepsOf(steps, id)) do
    local s = steps[i]
    -- (a step behind you is not on your route; on the route you follow, neither is one it skipped, ticked or left)
    if s.q == id and not (ns.Engine.BehindYou and ns.Engine.BehindYou(s)) and not (route == ForeverRouteData and ns.Engine.Status(i) == "done") then
      -- the planned level there (steps the safety net added have none: use the nearest step that has one)
      for j = i, math.min(#steps, i + 30) do if steps[j].lvl then return i, steps[j].lvl end end
      for j = i - 1, math.max(1, i - 30), -1 do if steps[j].lvl then return i, steps[j].lvl end end
      return i, nil
    end
  end
end

-- quests that aren't about leveling but pay off later: never suggested for dropping
local KEEP_HEADERS = { ["Camping"] = "Camping - benefits later", ["Class"] = "class quest", ["First Aid"] = "profession", ["Cooking"] = "profession", ["Fishing"] = "profession",
  ["Alchemy"] = "profession", ["Blacksmithing"] = "profession", ["Enchanting"] = "profession", ["Engineering"] = "profession", ["Herbalism"] = "profession", ["Leatherworking"] = "profession",
  ["Mining"] = "profession", ["Skinning"] = "profession", ["Tailoring"] = "profession", ["Seasonal"] = "seasonal", ["Warlock"] = "class quest", ["Reputation"] = "reputation" }
local function keepReason(e)
  if ns.char.keepQuests and ns.char.keepQuests[e.id] then return "you chose to keep this" end
  if e.zone and KEEP_HEADERS[e.zone] then return KEEP_HEADERS[e.zone] end
  if e.title and e.title:find("^Camping") then return "Camping - benefits later" end
end
-- a zone route for your level with this quest on it (the zone you'd pick as home base to do it): its route, or nil
function LogCheck.ZoneFor(q)
  if not (ns.ZoneRoutesAt and ns.QuestIds) then return nil end
  for _, r in ipairs(ns.ZoneRoutesAt()) do if ns.QuestIds(r)[q] and r ~= ForeverRouteData then return r end end
end
function LogCheck.Classify()
  local here = ForeverRouteData
  -- on a side trip or branch, quests are also judged against your path (found by zone order if a replan renamed it)
  local path = here and (here.branch or here.dungeon or here.zoneRoute) and ns.ResolvePath((here.dungeon or here.zoneRoute) and ns.char.returnTo or here.parent) or here
  local myLevel = UnitLevel("player")
  local list = {}
  for _, e in ipairs(LogCheck.Entries()) do
    local q = ns.State.Quest(e.id)
    local done = q and q.complete
    local i, planLvl = findIn(here, e.id)
    local where = here
    if not i and path ~= here then i, planLvl = findIn(path, e.id); where = path end
    local inDungeon = false
    if not i then for _, r in ipairs(ns.DungeonRoutes()) do if ns.QuestIds(r)[e.id] then inDungeon = r.dungeonName; break end end end
    local verdict, why
    local keep = keepReason(e)
    local gray, via = grayRule(e, myLevel)
    if ns.Nope(e.id) then
      verdict, why = "drop", "You said you're not doing this one"
    elseif not done and ns.Avail and ns.Avail.Pvp(e.id) then
      -- (a battleground quest: its marks come from PvP matches, so the route leaves it - not "drop": it is yours if you
      -- play them, and the card does its hand-in once it is finished)
      verdict, why = "offroute", "A battleground quest (" .. ns.Avail.Pvp(e.id) .. "): its marks come from PvP matches, so your route leaves it out. Yours to finish or drop"
    elseif keep then
      verdict, why = "keep", "Worth keeping: " .. keep
    elseif gray == "drop" then
      -- (the route has dropped it too: its steps, its hand-in, any stop for it - Engine.GrayDrop)
      verdict, why = "drop", done and "Gray, and nothing after it is worth XP - off your route (not worth a trip)" or "Gray, and nothing after it is worth XP - off your route"
    elseif i then
      local later = planLvl and myLevel and planLvl > myLevel and grayRule(e, planLvl)
      if not done and later == "drop" then
        -- (the same rule at the level the plan has you there: it leaves the route when you get there)
        verdict, why = "drop", string.format("Gray by the time the route gets to it (you'll be about %s) - very little XP", planLvl)
      else
        verdict, why = "keep", string.format("On your route at step %d%s", i, where ~= here and " of your path" or "") .. (via and (" - gray, but it leads to " .. via) or "")
      end
    elseif inDungeon then
      verdict, why = "keep", "For " .. inDungeon .. " (dungeon route)"
    elseif gray == "leads" then
      -- (gray, off your route, but its chain goes on to a quest still worth XP: yours, not "drop")
      verdict, why = "yours", "Gray, but it leads to " .. via .. (done and " - hand it in if you pass by" or " - yours to finish")
    elseif done then
      verdict, why = "turnin", "Finished but not on your route - hand it in if you pass by"
    else
      -- (not "drop": it was "Not on any of your routes - you won't be sent there", untrue for a quest another zone's
      -- route has, and a tester abandoned four of those - persona review). Another zone's route has it: picking that
      -- zone as home base brings it along; a side quest: its stops are fitted in; else it's simply yours
      local zr = LogCheck.ZoneFor(e.id)
      if zr then
        verdict, why = "yours", "In " .. Style.ShortZone(zr.zoneName) .. ": pick it as home base and this joins your route"
        list[#list + 1] = { e = e, verdict = verdict, why = why, zone = zr }
        verdict = nil
      elseif ns.SIDE_QUESTS and ns.SIDE_QUESTS[e.id] or ns.ITEM_QUESTS and ns.ITEM_QUESTS[e.id] then
        verdict, why = "yours", "A side quest: its stops join your route where they fit"
      else
        verdict, why = "offroute", "Not on your route. Yours to finish or drop"
      end
    end
    if verdict then list[#list + 1] = { e = e, verdict = verdict, why = why } end
  end
  local order = { drop = 1, offroute = 2, turnin = 3, yours = 4, keep = 5 }
  table.sort(list, function(a, b) if order[a.verdict] ~= order[b.verdict] then return order[a.verdict] < order[b.verdict] end return (a.e.zone or "") < (b.e.zone or "") end)
  return list
end

-- Quest items you still carry that nothing needs: "for the quests you won't do, figure out which ones have items you
-- no longer need, and prompt people what they should delete". ns.QUEST_ITEMS (QuestData.lua) names every quest that
-- uses a quest item - as an objective, handed to you by the giver, needed along the way, or the item that starts it.
-- An item is left over only when EVERY quest of yours that uses it is out of the picture:
--   handed in; or you said you won't do it; or it was in your log once, is gone from it, and your routes don't send
--   you back for it (abandoned).
-- A quest in your log keeps its items, always (also one you finished and chose not to hand in). A quest you never had
-- and may still take keeps them too (the item that starts a quest you haven't started is not rubbish), so does one a
-- route still plans. Quests of the other side or another class don't count. Anything that is not a quest item by the
-- game's own filing (cloth, meat, a potion some quest also asks for) is never listed.
-- bags: [itemID] = count (default: your bags) -> { { id, name, count, why, quests = { id... } } }, by name
function LogCheck.Leftovers(bags)
  local items = ns.QUEST_ITEMS
  if not items then return {} end
  bags = bags or (ns.State.BagItems and ns.State.BagItems())
  if type(bags) ~= "table" then return {} end
  local State, Engine = ns.State, ns.Engine
  local nope, had = (ns.char and ns.char.nope) or {}, (ns.char and ns.char.hadQuest) or {}
  local f = UnitFactionGroup and call(UnitFactionGroup, "player")
  local side = f == "Horde" and "H" or f == "Alliance" and "A" or nil
  local class = UnitClass and select(2, UnitClass("player"))
  local function mine(q)
    local who = ns.QUEST_FOR and ns.QUEST_FOR[q]
    if not who then return true end
    local s, cl = who:match("^(%a?):?(.*)$")
    if s ~= "" and side and s ~= side then return false end
    if cl ~= "" and class and not ("," .. cl .. ","):find("," .. class .. ",", 1, true) then return false end
    return true
  end
  -- the quests a route still plans: a step of your route that is still to do, and whatever your other routes hold
  local wanted
  local function planned(q)
    if not wanted then
      wanted = {}
      local here = ForeverRouteData
      for i, s in ipairs((here and here.steps) or {}) do
        if s.q and s.q > 0 and not wanted[s.q] and (Engine.Status(i) ~= "done" or (ns.Avail and ns.Avail.Unavailable(s.q))) then wanted[s.q] = true end
      end
      local path = here and (here.branch or here.dungeon) and ns.ResolvePath and ns.ResolvePath(here.dungeon and ns.char.returnTo or here.parent) or nil
      for _, s in ipairs((path and path ~= here and path.steps) or {}) do if s.q and s.q > 0 then wanted[s.q] = true end end
      for _, r in ipairs((ns.DungeonRoutes and ns.DungeonRoutes()) or {}) do for q2 in pairs((ns.QuestIds and ns.QuestIds(r)) or {}) do wanted[q2] = true end end
    end
    return wanted[q]
  end
  local out = {}
  for id, count in pairs(bags) do
    local e = items[id]
    if e and type(count) == "number" and count > 0 then
      local free, reasons, quests = true, {}, {}
      for k = 2, #e do
        local q = e[k]
        if mine(q) then
          local why
          if State.OnQuest(q) then why = nil
          elseif State.IsCompleted(q) then why = "handed in"
          elseif nope[q] then why = "not doing"
          elseif had[q] and not planned(q) then why = "abandoned" end
          if not why then free = false; break end
          quests[#quests + 1] = q
          if #reasons < 2 then reasons[#reasons + 1] = Engine.QuestName(q) .. " (" .. why .. ")" end
        end
      end
      -- the game's own word on it, when it has one: only a quest item
      local classID = ns.GetItemInfo and select(12, ns.GetItemInfo(id))
      if type(classID) == "number" and classID ~= 12 then free = false end
      if free and #quests > 0 then
        local name = (ns.GetItemInfo and ns.GetItemInfo(id)) or e[1]
        out[#out + 1] = { id = id, name = type(name) == "string" and name or e[1], count = count, quests = quests,
          why = "From " .. table.concat(reasons, ", ") .. (#quests > 2 and (" and " .. (#quests - 2) .. " more") or "") }
      end
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end
-- said once in chat for each item, when it turns up (you dropped a quest, or handed one in with spares in your bags)
function LogCheck.TellLeftovers()
  local ok, list = pcall(LogCheck.Leftovers)
  if not ok or not ns.char then return end
  ns.char.leftTold = ns.char.leftTold or {}
  local now, new = {}, {}
  for _, x in ipairs(list) do now[x.id] = true; if not ns.char.leftTold[x.id] then ns.char.leftTold[x.id] = true; new[#new + 1] = x.name .. (x.count > 1 and (" x" .. x.count) or "") end end
  for id in pairs(ns.char.leftTold) do if not now[id] then ns.char.leftTold[id] = nil end end -- gone from your bags: said again if it comes back
  if #new == 0 then return end
  local names = table.concat(new, ", ", 1, math.min(#new, 4)) .. (#new > 4 and (" and " .. (#new - 4) .. " more") or "")
  ns.Print("Still in your bags: " .. names .. ". Nothing on your route or in your log needs " .. (#new == 1 and "it" or "them") .. " any more - safe to delete (the quest log check lists them: /fr logcheck).")
end
ns.On("FR_NOPE", function() C_Timer.After(1, LogCheck.TellLeftovers) end)
ns.On("QUEST_TURNED_IN", function() C_Timer.After(1.5, LogCheck.TellLeftovers) end)

-- only quests this check marks to drop get an Abandon button, so an abandon here also drops the quest from the route
-- (otherwise the card would send you straight back to its quest giver until the next replan)
local function abandon(id, title, why)
  if InCombatLockdown() then ns.Print("Not in combat."); return end
  if C_QuestLog and C_QuestLog.SetSelectedQuest and C_QuestLog.SetAbandonQuest and C_QuestLog.AbandonQuest then
    C_QuestLog.SetSelectedQuest(id); C_QuestLog.SetAbandonQuest(); C_QuestLog.AbandonQuest()
  elseif SelectQuestLogEntry and SetAbandonQuest and AbandonQuest then
    local idx = C_QuestLog and C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(id)
    if not idx then return end
    SelectQuestLogEntry(idx); SetAbandonQuest(); AbandonQuest()
  end
  if ns.Engine and ns.Engine.Abandoned then ns.Engine.Abandoned({ id }, why) end
  ns.Print("Abandoned " .. (title or "quest") .. ". Dropped from your route too (Undo brings it back).")
end
LogCheck.Abandon = abandon
StaticPopupDialogs["FOREVERROUTE_ABANDON"] = {
  text = "Abandon %s?\nIt also leaves your route (Bring back undoes that).", button1 = YES or "Yes", button2 = NO or "No", timeout = 0, whileDead = true, hideOnEscape = true,
  OnAccept = function(self, data) abandon(data.id, data.title, data.why); C_Timer.After(0.5, function() LogCheck.Draw() end) end,
}

-- how many quests are worth dropping (the card shows a button when there are any)
LogCheck.dropCount = 0
recount = function()
  local t0 = debugprofilestop and debugprofilestop()
  local ok, list = pcall(LogCheck.Classify)
  if t0 and ns.Time then ns.Time("logcheck", debugprofilestop() - t0) end
  local n = 0; if ok then for _, x in ipairs(list) do if x.verdict == "drop" or x.verdict == "offroute" then n = n + 1 end end end
  if n ~= LogCheck.dropCount then LogCheck.dropCount = n; ns.Fire("FR_STEP", ns.Engine.Shown()) end
end
ns.On("FR_STATE", function() C_Timer.After(0.3, recount) end)
ns.On("FR_ROUTE_CHANGED", function() C_Timer.After(0.3, recount) end)
ns.On("PLAYER_LEVEL_UP", function() C_Timer.After(1, recount) end)

-- drop several: one confirm listing them, then one at a time (the game abandons the selected quest)
local function dropAll(list)
  local k = 0
  local function nextOne() k = k + 1; local e = list[k]; if not e then C_Timer.After(0.5, function() recount(); LogCheck.Draw() end) return end abandon(e.id, e.title, e.why); C_Timer.After(0.4, nextOne) end
  nextOne()
end
StaticPopupDialogs["FOREVERROUTE_DROPALL"] = {
  text = "Drop these %d quests?%s", button1 = YES or "Yes", button2 = NO or "No", timeout = 0, whileDead = true, hideOnEscape = true,
  OnAccept = function(self, data) dropAll(data) end,
}

local COLORS = { drop = { 0.75, 0.62, 0.50 }, offroute = { 0.70, 0.72, 0.78 }, turnin = { 0.45, 0.78, 1.0 }, yours = { 0.45, 0.78, 1.0 }, keep = { 0.36, 0.86, 0.48 } }
local function row(k)
  if rows[k] then return rows[k] end
  local r = CreateFrame("Frame", nil, f.content); r:SetSize(W - 2 * PAD - 10, ROW)
  r.edge = r:CreateTexture(nil, "ARTWORK"); r.edge:SetTexture(Style.WHITE); r.edge:SetWidth(3); r.edge:SetPoint("TOPLEFT", 0, -4); r.edge:SetPoint("BOTTOMLEFT", 0, 4)
  r.title = Style.Text(r, 11, C.text); r.title:SetPoint("TOPLEFT", 10, -3); r.title:SetWordWrap(false); r.title:SetWidth(W - 2 * PAD - BTNS - 14)
  r.why = Style.Text(r, 10, C.sub); r.why:SetPoint("TOPLEFT", r.title, "BOTTOMLEFT", 0, -2); r.why:SetWordWrap(true); r.why:SetJustifyH("LEFT"); r.why:SetWidth(W - 2 * PAD - BTNS - 14)
  if r.why.SetMaxLines then r.why:SetMaxLines(2) end
  r.btn = Style.Button(r, "Abandon", 80, 18, function(self)
    local d = self:GetParent().data; if not d then return end
    local dlg = StaticPopup_Show("FOREVERROUTE_ABANDON", d.title); if dlg then dlg.data = { id = d.id, title = d.title, why = self:GetParent().reason } end
  end, "Drop this quest from your log (asks first)")
  r.btn:SetPoint("RIGHT", r, "RIGHT", -4, 0)
  -- a quest another zone's route has: go there (that zone as home base)
  r.go = Style.Button(r, "Go", 44, 18, function(self)
    local z = self:GetParent().zone; if not (z and ns.Paths and ns.Paths.Pick) then return end
    ns.Paths.Pick({ zone = z.zoneName, route = z }); f:Hide()
  end, "Make that zone your home base: this quest joins its route")
  r.go:SetPoint("RIGHT", r, "RIGHT", -4, 0)
  r.keep = Style.Button(r, "Keep", 44, 18, function(self)
    local d = self:GetParent().data; if not d then return end
    ns.char.keepQuests = ns.char.keepQuests or {}; ns.char.keepQuests[d.id] = true
    LogCheck.Draw(); recount()
  end, "Never suggest dropping this one")
  r.keep:SetPoint("RIGHT", r.btn, "LEFT", -4, 0)
  -- a quest you said you won't do: changed your mind
  r.back = Style.Button(r, "Bring back", 74, 18, function(self)
    local d = self:GetParent().data; if not d then return end
    ns.Engine.Unnope(d.id); LogCheck.Draw(); recount()
  end, "Put this quest back on your route - you had said you won't do it")
  rows[k] = r
  return r
end

local function build()
  f = CreateFrame("Frame", "ForeverRouteLogCheck", UIParent)
  f:SetSize(W, 200); f:SetPoint("CENTER", 0, 40)
  Style.Window(f, "ForeverRouteLogCheck")
  f.title = Style.Text(f, 15, C.gold, "OUTLINE"); f.title:SetPoint("TOPLEFT", PAD, -12); f.title:SetText("Quest log check")
  local close = Style.CloseButton(f)
  f.sum = Style.Text(f, 11, C.sub); f.sum:SetPoint("TOPLEFT", PAD, -34); f.sum:SetWidth(W - 2 * PAD - 120)
  f.all = Style.Button(f, "Abandon gray", 100, 20, function()
    local drop = {}; for _, x in ipairs(LogCheck.Classify()) do if x.verdict == "drop" then drop[#drop + 1] = { id = x.e.id, title = x.e.title, why = x.why } end end
    if #drop == 0 then return end
    local names = ""; for _, e in ipairs(drop) do names = names .. "\n" .. e.title end
    local dlg = StaticPopup_Show("FOREVERROUTE_DROPALL", #drop, names); if dlg then dlg.data = drop end
  end, "Abandon the gray quests and the ones you refused (asks first, listing them)")
  f.all:SetPoint("TOPRIGHT", -PAD, -34)
  -- the list scrolls (a full log plus the won't-do list ran off the screen): at most MAXH tall, mouse wheel, a thumb
  f.scroll = CreateFrame("ScrollFrame", nil, f); f.scroll:EnableMouseWheel(true)
  f.content = CreateFrame("Frame", nil, f.scroll); f.content:SetSize(W, 10); f.scroll:SetScrollChild(f.content)
  f.track = f:CreateTexture(nil, "ARTWORK"); f.track:SetTexture(Style.WHITE); f.track:SetVertexColor(1, 1, 1, 0.05); f.track:SetWidth(4)
  f.thumb = f:CreateTexture(nil, "OVERLAY"); f.thumb:SetTexture(Style.WHITE); f.thumb:SetVertexColor(C.gold[1], C.gold[2], C.gold[3], 0.6); f.thumb:SetWidth(4)
  local function setScroll(v)
    local max = math.max(0, f.content:GetHeight() - f.scroll:GetHeight())
    v = math.max(0, math.min(max, v)); f.scroll:SetVerticalScroll(v)
    local th = f.track:GetHeight() or 0
    f.thumb:SetShown(max > 0); f.track:SetShown(max > 0)
    if max > 0 and th > 0 then local h = math.max(20, th * f.scroll:GetHeight() / f.content:GetHeight()); f.thumb:SetHeight(h); f.thumb:ClearAllPoints(); f.thumb:SetPoint("TOPRIGHT", f.track, "TOPRIGHT", 0, -(th - h) * v / max) end
  end
  f.setScroll = setScroll
  f.scroll:SetScript("OnMouseWheel", function(self, d) setScroll(self:GetVerticalScroll() - d * 60) end)
  f.grip = Style.ScrollGrip(f, f.track, f.thumb, function(fr) setScroll(fr * math.max(0, f.content:GetHeight() - f.scroll:GetHeight())) end)
  f:Hide()
end

function LogCheck.Draw()
  if not f or not f:IsShown() then return end
  local list = LogCheck.Classify()
  local drops, off = 0, 0; for _, x in ipairs(list) do if x.verdict == "drop" then drops = drops + 1 elseif x.verdict == "offroute" then off = off + 1 end end
  local parts = {}
  if drops > 0 then parts[#parts + 1] = string.format("%d gray or refused can go.", drops) end
  if off > 0 then parts[#parts + 1] = string.format("%d off your route: yours to keep.", off) end
  f.sum:SetText(string.format("%d quests in your log (max %d).  %s", #list, ns.State.MaxLog() or 40, #parts > 0 and table.concat(parts, " ") or "Everything here is on your route."))
  f.all:SetShown(drops > 0); f.all.label:SetText(string.format("Abandon %d", drops))
  local top = 34 + math.max(f.sum:GetStringHeight(), 22) + 10
  local y = 0 -- inside the scrolling list
  for k, x in ipairs(list) do
    local r = row(k)
    r.data, r.reason = x.e, x.why
    local c = COLORS[x.verdict]
    r.edge:SetVertexColor(c[1], c[2], c[3], 0.9)
    local qc = Style.QuestColor(x.e.level)
    r.title:SetText(string.format("%s[%s] %s|r  |cff8e99ad%s|r", Style.Hex(qc), x.e.level or "?", x.e.title, x.e.zone or ""))
    r.why:SetText(Style.Hex(c) .. x.why .. "|r")
    local noped = ns.Nope(x.e.id)
    r.btn:SetShown(x.verdict == "drop" or x.verdict == "offroute"); r.keep:SetShown((x.verdict == "drop" or x.verdict == "offroute") and not noped)
    r.zone = x.zone
    r.go:SetShown(x.zone ~= nil)
    r.back:SetShown(noped and true or false); r.back:ClearAllPoints(); r.back:SetPoint("RIGHT", r.btn, "LEFT", -4, 0)
    local h = math.max(ROW, r.title:GetStringHeight() + r.why:GetStringHeight() + 9); r:SetHeight(h)
    r:ClearAllPoints(); r:SetPoint("TOPLEFT", f.content, "TOPLEFT", PAD, -y); r:Show()
    y = y + h + 2
  end
  -- the quests you said you won't do that aren't in your log (dropped before you took them): Bring back for each
  local inLog = {}; for _, x in ipairs(list) do inLog[x.e.id] = true end
  local extra = {}; for _, n in ipairs(ns.Engine.Noped()) do if not inLog[n.q] then extra[#extra + 1] = n end end
  f.nopeHdr = f.nopeHdr or Style.Text(f.content, 12, C.gold, "OUTLINE")
  f.nopeHdr:SetShown(#extra > 0)
  if #extra > 0 then
    f.nopeHdr:ClearAllPoints(); f.nopeHdr:SetPoint("TOPLEFT", f.content, "TOPLEFT", PAD, -y - 6); f.nopeHdr:SetText("You said you won't do these (" .. #extra .. ")")
    y = y + 26
  end
  for i, n in ipairs(extra) do
    local r = row(#list + i)
    r.data, r.reason = { id = n.q, title = n.name }, nil
    r.edge:SetVertexColor(0.55, 0.58, 0.66, 0.9)
    r.title:SetText(n.name)
    r.why:SetText("|cff8c94a8" .. (n.ready and "Finished when you dropped it: its hand-in is off your route" or "Off your route and future plans") .. "|r")
    r.btn:Hide(); r.keep:Hide()
    r.back:Show(); r.back:ClearAllPoints(); r.back:SetPoint("RIGHT", r, "RIGHT", -4, 0)
    local h = math.max(ROW, r.title:GetStringHeight() + r.why:GetStringHeight() + 9); r:SetHeight(h)
    r:ClearAllPoints(); r:SetPoint("TOPLEFT", f.content, "TOPLEFT", PAD, -y); r:Show()
    y = y + h + 2
  end
  -- quest items in your bags that nothing needs any more: what is safe to delete (yours to do - nothing is deleted here)
  local okL, left = pcall(LogCheck.Leftovers)
  if not okL then left = {} end
  f.leftHdr = f.leftHdr or Style.Text(f.content, 12, C.gold, "OUTLINE")
  f.leftSub = f.leftSub or Style.Text(f.content, 10, C.sub)
  f.leftHdr:SetShown(#left > 0); f.leftSub:SetShown(#left > 0)
  if #left > 0 then
    f.leftHdr:ClearAllPoints(); f.leftHdr:SetPoint("TOPLEFT", f.content, "TOPLEFT", PAD, -y - 6); f.leftHdr:SetText("Safe to delete from your bags (" .. #left .. ")")
    f.leftSub:ClearAllPoints(); f.leftSub:SetPoint("TOPLEFT", f.leftHdr, "BOTTOMLEFT", 0, -3); f.leftSub:SetWidth(W - 2 * PAD - 14); f.leftSub:SetJustifyH("LEFT"); f.leftSub:SetWordWrap(true)
    f.leftSub:SetText("Quest items nothing on your route or in your log needs any more. Deleting is yours to do: drag one out of your bags.")
    y = y + 26 + math.max(f.leftSub:GetStringHeight(), 12) + 4
  end
  for i, x in ipairs(left) do
    local r = row(#list + #extra + i)
    r.data, r.reason = nil, nil
    r.edge:SetVertexColor(0.55, 0.58, 0.66, 0.9)
    r.title:SetText(x.name .. (x.count > 1 and ("  |cff8e99adx" .. x.count .. "|r") or ""))
    r.why:SetText("|cff8c94a8" .. x.why .. "|r")
    r.btn:Hide(); r.keep:Hide(); r.back:Hide()
    local h = math.max(ROW, r.title:GetStringHeight() + r.why:GetStringHeight() + 9); r:SetHeight(h)
    r:ClearAllPoints(); r:SetPoint("TOPLEFT", f.content, "TOPLEFT", PAD, -y); r:Show()
    y = y + h + 2
  end
  for k, r in ipairs(rows) do if k > #list + #extra + #left then r:Hide() end end
  -- the window: the header, then the list up to MAXH (scrolling beyond)
  local MAXH = math.min(560, (UIParent:GetHeight() or 800) / f:GetScale() - top - 140)
  local view = math.min(y, MAXH)
  f.content:SetHeight(math.max(y, 1))
  f.scroll:ClearAllPoints(); f.scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -top); f.scroll:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -top); f.scroll:SetHeight(view)
  f.track:ClearAllPoints(); f.track:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -top); f.track:SetHeight(view)
  f:SetHeight(top + view + 10)
  f.setScroll(f.scroll:GetVerticalScroll())
end

function LogCheck.Toggle()
  if f:IsShown() then f:Hide(); return end
  f:Show(); LogCheck.Draw()
end

ns.On("FR_LOADED", build)
ns.On("FR_TOGGLE_LOGCHECK", function() LogCheck.Toggle() end)
-- (open, it follows your log: once for a burst of log updates - a kill or a loot sends two or three - not for each)
local redrawDue = false
ns.On("QUEST_LOG_UPDATE", function()
  if redrawDue or not (f and f:IsShown()) then return end
  redrawDue = true
  C_Timer.After(0.2, function() redrawDue = false; LogCheck.Draw() end)
end)
