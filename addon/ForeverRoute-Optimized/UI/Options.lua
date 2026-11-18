-- Options: one window with a rail of tabs on its left, like Where to? (a tester: one long column of checkboxes and
-- sliders was hard to work with; the changelog belongs there; the food reminder should be a toggle). The design pass:
--   General  what the card shows: a look (Full / Compact / Minimal), the steps under it, each reminder line, extras
--   Auto   what the addon does for you
--   Map    the arrow, the pins, the walking path
--   Size   the scales, the lock, putting the card and the arrow back
--   News   the changelog: the newest version open, older ones one line each, unread ones marked
--   Help   keys, the main commands, starting over, the credit line
-- A search box at the top finds any option on any tab (its label, its tooltip, a few more words): a click goes there.
-- Short labels, a tooltip only where a label can't say it. Pages are built the first time they show. A control reads
-- ns.db when its page shows and writes it on change (FR_SETTINGS), never on open. Our own frames only (no taint):
-- Options > AddOns has a small page with a button that opens this window.
local _, ns = ...
local Style = ns.Style
local C = Style.C
local Options = {}
ns.Options = Options

local MEDIA = "Interface\\AddOns\\ForeverRoute\\Media\\"
local W, H = 540, 500          -- the window: Where to?'s width, room for the links at the bottom
local RAIL, PAD = 64, 14       -- the tab rail, the page margin
local TOP = 44                 -- where a page starts
local PAGE_W = W - RAIL - 2 * PAD - 6
local host, panel              -- the window, and the page area inside it (ForeverRouteOptions)

local TABS = {
  { key = "card", label = "General", icon = "btn-list", color = C.gold, title = "General" }, -- ("Card" read as jargon - tester)
  { key = "auto", label = "Auto", icon = "icon-accept", color = C.gold, title = "Automation" },
  { key = "map", label = "Map", icon = "pin", color = C.good, title = "Map and arrow" },
  { key = "size", label = "Size", icon = "btn-gear", color = C.gold, title = "Size" },
  { key = "news", label = "News", icon = "icon-note", color = C.good, title = "What's new" },
  { key = "help", label = "Help", icon = "icon-check", color = C.sub, title = "Help" },
}
Options.tab = "card"

-- the card's looks: one click instead of hunting through toggles
Options.PRESETS = {
  { name = "Full", v = { showNext = 3, cardNotes = true, cardZones = true, cardOffers = true, cardItemQuests = true, remindBags = true, remindFood = true, remindGrimoire = true } },
  { name = "Compact", v = { showNext = 1, cardNotes = false, cardZones = true, cardOffers = true, cardItemQuests = true, remindBags = true, remindFood = true, remindGrimoire = true } },
  { name = "Minimal", v = { showNext = 0, cardNotes = false, cardZones = false, cardOffers = false, cardItemQuests = false, remindBags = false, remindFood = false, remindGrimoire = false } },
}
-- the preset your settings match, or nil (custom)
function Options.PresetNow()
  for _, p in ipairs(Options.PRESETS) do
    local same = true
    for k, v in pairs(p.v) do local cur = ns.db[k]; if k ~= "showNext" then cur = cur ~= false end; if cur ~= v then same = false end end
    if same then return p.name end
  end
  return nil
end
function Options.ApplyPreset(name)
  for _, p in ipairs(Options.PRESETS) do if p.name == name then for k, v in pairs(p.v) do ns.db[k] = v end end end
  ns.Fire("FR_SETTINGS")
end

-- ---------------------------------------------------------------- controls (placed by the page's cursor, page.y)

-- the search index: every control, with its tab and what it can be found by
Options.index = {}
local function index(page, frame, label, words)
  Options.index[#Options.index + 1] = { tab = page.tabKey, frame = frame, label = label, find = string.lower(label .. " " .. (words or "")) }
end
local function remember(page, key, default)
  page.keys = page.keys or {}
  page.keys[#page.keys + 1] = { key = key, default = default }
end

local function header(page, text)
  page.y = page.y + (page.y > 0 and 10 or 0)
  local t = Style.Text(page, 11, C.gold, "OUTLINE"); t:SetPoint("TOPLEFT", 0, -page.y); t:SetText(text:upper())
  local line = page:CreateTexture(nil, "ARTWORK"); line:SetTexture(Style.WHITE); line:SetHeight(1)
  line:SetPoint("LEFT", t, "RIGHT", 8, 0); line:SetPoint("RIGHT", page, "RIGHT", 0, 0); line:SetVertexColor(C.dim[1], C.dim[2], C.dim[3], 0.4)
  page.y = page.y + 22
end

local function tip(frame, text)
  if not text then return end
  frame:HookScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(text, 1, 1, 1, 1, true); GameTooltip:Show() end)
  frame:HookScript("OnLeave", GameTooltip_Hide)
end

-- a whole-row toggle: our own box, the row lights on hover (a bigger target than a checkbox)
local function toggle(page, label, key, tipText)
  local b = CreateFrame("Button", nil, page); b:SetSize(PAGE_W, 24); b:SetPoint("TOPLEFT", 0, -page.y)
  b.wash = b:CreateTexture(nil, "BACKGROUND"); b.wash:SetTexture(Style.WHITE); b.wash:SetAllPoints(); b.wash:SetVertexColor(1, 1, 1, 0.06); b.wash:Hide()
  b.box = b:CreateTexture(nil, "ARTWORK"); b.box:SetTexture(MEDIA .. "ring"); b.box:SetSize(16, 16); b.box:SetPoint("LEFT", 4, 0)
  b.tick = b:CreateTexture(nil, "OVERLAY"); b.tick:SetTexture(MEDIA .. "icon-check"); b.tick:SetSize(14, 14); b.tick:SetPoint("CENTER", b.box, "CENTER", 0, 0)
  b.tick:SetVertexColor(C.good[1], C.good[2], C.good[3])
  b.text = Style.Text(b, 12, C.text); b.text:SetPoint("LEFT", b.box, "RIGHT", 8, 0); b.text:SetText(label)
  local function sync()
    local on = ns.db[key] and true or false
    b.tick:SetShown(on)
    local c = on and C.text or C.sub
    b.text:SetTextColor(c[1], c[2], c[3]); b.box:SetVertexColor(on and C.good[1] or C.dim[1], on and C.good[2] or C.dim[2], on and C.good[3] or C.dim[3])
  end
  b.sync = sync
  b:SetScript("OnShow", sync)
  b:SetScript("OnClick", function() ns.db[key] = not ns.db[key]; sync(); ns.Fire("FR_SETTINGS") end)
  b:SetScript("OnEnter", function(self) self.wash:Show() end)
  b:SetScript("OnLeave", function(self) self.wash:Hide() end)
  tip(b, tipText)
  remember(page, key, ns.DEFAULTS[key])
  index(page, b, label, tipText)
  page.y = page.y + 26
  return b
end

local function slider(page, label, key, lo, hi, step, fmt, default, dep, words)
  local s = CreateFrame("Slider", nil, page, "OptionsSliderTemplate")
  s:SetPoint("TOPLEFT", 4, -(page.y + 18)); s:SetWidth(240); s:SetMinMaxValues(lo, hi); s:SetValueStep(step); s:SetObeyStepOnDrag(true)
  local t = Style.Text(page, 11, C.sub); t:SetPoint("BOTTOMLEFT", s, "TOPLEFT", 0, 4); t:SetText(label)
  local v = Style.Text(page, 11, C.gold); v:SetPoint("BOTTOMRIGHT", s, "TOPRIGHT", 0, 4)
  local function upd(x) v:SetText(string.format(fmt or "%.2f", x)) end
  -- greyed out while what it sizes is off (the arrow, the pins)
  local function deps() local on = not dep or ns.db[dep] and true or false; s:SetEnabled(on); s:SetAlpha(on and 1 or 0.4); t:SetAlpha(on and 1 or 0.4); v:SetAlpha(on and 1 or 0.4) end
  s:SetScript("OnShow", function(self) self.loading = true; self:SetValue(ns.db[key] or default); upd(ns.db[key] or default); deps(); self.loading = false end)
  if dep then ns.On("FR_SETTINGS", function() if s:IsVisible() then deps() end end) end
  -- the Forever Route scale also sizes this window: applied while you drag, the slider grew or shrank under the
  -- cursor and ran off to its end. That one takes effect when you let go (the number follows as you drag)
  local onRelease = key == "uiScale"
  s:SetScript("OnValueChanged", function(self, x)
    upd(x)
    if self.loading or (ns.db[key] or default) == x then return end
    if onRelease and self.dragging then self.pending = x; return end
    ns.db[key] = x; ns.Fire("FR_SETTINGS")
  end)
  if onRelease then
    s:HookScript("OnMouseDown", function(self) self.dragging = true end)
    s:HookScript("OnMouseUp", function(self)
      self.dragging = false
      local x = self.pending; self.pending = nil
      if x and (ns.db[key] or default) ~= x then ns.db[key] = x; ns.Fire("FR_SETTINGS") end
    end)
  end
  for _, r in ipairs({ s:GetRegions() }) do if r.GetText and (r:GetText() == "Low" or r:GetText() == "High") then r:SetText("") end end
  if s.Low then s.Low:SetText(""); s.High:SetText("") end
  remember(page, key, ns.DEFAULTS[key] or default)
  index(page, s, label, words)
  page.y = page.y + 42
  return s
end

local function button(page, label, w, onClick, tipText)
  local b = Style.Button(page, label, w, 22, onClick, tipText)
  b:SetPoint("TOPLEFT", 0, -page.y)
  index(page, b, label, tipText)
  page.y = page.y + 28
  return b
end

-- click twice: the label asks first ("Sure? Click again", for 3 s)
local function confirmButton(page, label, w, onConfirm, tipText)
  local b
  b = button(page, label, w, function()
    if b.armed then b.armed = nil; b.label:SetText(label); onConfirm(); return end
    b.armed = true; b.label:SetText("Sure? Click again")
    C_Timer.After(3, function() if b.armed then b.armed = nil; b.label:SetText(label) end end)
  end, tipText)
  return b
end

local function note(page, text, size, color)
  local t = Style.Text(page, size or 11, color or C.sub); t:SetPoint("TOPLEFT", 0, -page.y); t:SetWidth(PAGE_W); t:SetJustifyH("LEFT"); t:SetText(text)
  page.y = page.y + math.max(14, (t:GetStringHeight() or 12)) + 6
  return t
end

-- ---------------------------------------------------------------- pages

local BUILD = {}

function BUILD.card(p)
  -- the look: a cycle button, Custom when the toggles match none
  local pre = Style.Button(p, "", 150, 22, nil, "Full, Compact or Minimal. Changing a toggle below makes it Custom.")
  pre:SetPoint("TOPLEFT", 0, -p.y); p.y = p.y + 28
  index(p, pre, "Look: Full, Compact, Minimal", "card preset minimal compact simple clean")
  local function preLabel() pre.label:SetText("Look: " .. (Options.PresetNow() or "Custom")) end
  pre:SetScript("OnClick", function()
    local now, names = Options.PresetNow(), {}
    for k, q in ipairs(Options.PRESETS) do names[k] = q.name end
    local nxt = names[1]
    for k, n in ipairs(names) do if n == now then nxt = names[k % #names + 1] end end
    Options.ApplyPreset(nxt)
    p:Hide(); p:Show() -- every control reads again
  end)
  pre:HookScript("OnShow", preLabel); ns.On("FR_SETTINGS", function() if pre:IsVisible() then preLabel() end end)
  header(p, "Steps")
  slider(p, "Next steps shown", "showNext", 0, 5, 1, "%d", 3, nil, "upcoming list card")
  toggle(p, "Step notes", "cardNotes", "The small hint under a step. Warnings always show.")
  toggle(p, "Next zone line", "cardZones", "\"Next zone: Arathi, after 2 quests here\"")
  header(p, "Reminders")
  toggle(p, "Bags nearly full", "remindBags", "Names the nearest vendor.")
  toggle(p, "Eat for Well Fed", "remindFood", "About +5% kill XP. Only if you carry the food.")
  local _, class = UnitClass and UnitClass("player")
  if class == "WARLOCK" then toggle(p, "Warlock grimoires", "remindGrimoire", "A pet grimoire you can buy, when you're in a capital.") end
  toggle(p, "Zone suggestions", "cardOffers", "When another zone is worth a look.")
  toggle(p, "Quest items in bags", "cardItemQuests", "Items in your bags that start a quest.")
  header(p, "Extras")
  toggle(p, "Best quest reward", "rewardHint", "Marks the reward that's best for you.")
  toggle(p, "Fade in combat", "combatFade")
  p.example = true
end

function BUILD.auto(p)
  header(p, "Quests")
  toggle(p, "Accept and hand in quests", "autoQuest", "Never picks a reward for you. Shift: do it yourself.")
  toggle(p, "Take route flights", "autoFly", "Only flights you know. Shift: choose yourself.")
  header(p, "Route")
  toggle(p, "Adapt to where I am", "smartNext", "Reorders nearby steps to save walking. Off: fixed order.")
  toggle(p, "Star the target", "markTarget", "The Target button also marks the NPC.")
  toggle(p, "Learn my city paths", "trails", "Remembers your walks in cities. Stays on your PC.")
  -- (Moments.lua: the moments stay on your PC; sending them is the companion's own question, off until you say yes there)
  header(p, "Bug reports")
  toggle(p, "Keep notes for bug reports", "moments", "When the card looks off, notes it on your PC for /fr report.")
  confirmButton(p, "Clear the notes", 190, function() if ns.Moments then ns.Moments.Clear() end end, "Deletes the notes kept for bug reports.")
end

function BUILD.map(p)
  header(p, "Arrow")
  toggle(p, "Waypoint arrow", "arrow")
  slider(p, "Arrow size", "arrowScale", 0.6, 2.5, 0.05, nil, 1, "arrow", "arrow scale bigger smaller")
  header(p, "Maps")
  toggle(p, "Route pins", "pins")
  slider(p, "Steps pinned", "pinCount", 1, 8, 1, "%d", 4, "pins", "pins map minimap")
  toggle(p, "Walking path", "pathLine")
end

function BUILD.size(p)
  local all = slider(p, "Everything", "uiScale", Style.SCALE_MIN, Style.SCALE_MAX, 0.05, nil, 1, nil, "scale size bigger smaller text ui")
  -- the scale that makes our text a comfortable size on this screen, one click away when it differs
  local sug = Style.Button(p, "", 130, 20, function()
    local v = Style.SuggestScale(); if v then ns.db.uiScale = v; ns.Fire("FR_SETTINGS"); p:Hide(); p:Show() end
  end, "Readable text on this screen.")
  sug:SetPoint("LEFT", all, "RIGHT", 14, 0)
  local function sugShow()
    local v = Style.SuggestScale()
    sug:SetShown(v ~= nil and math.abs(v - (ns.db.uiScale or 1)) > 0.01)
    if v then sug.label:SetText(string.format("Use suggested (%.2f)", v)) end
  end
  all:HookScript("OnShow", sugShow); ns.On("FR_SETTINGS", function() if sug:GetParent():IsVisible() then sugShow() end end)
  panel.scaleSlider = all
  slider(p, "Card size", "scale", 0.7, 2.0, 0.05, nil, 1, nil, "card scale bigger smaller")
  slider(p, "Card width", "cardWidth", 280, 520, 10, "%d", 360, nil, "card wide narrow")
  toggle(p, "Lock card and arrow", "locked")
  p.y = p.y + 6
  button(p, "Reset positions", 140, function()
    if ns.Card and ns.Card.ResetPos then ns.Card.ResetPos(true) end
    if ns.Card and ns.Card.ResetTarget then ns.Card.ResetTarget() end
    ns.db.arrowPos = nil
    if ForeverRouteArrow then ForeverRouteArrow:ClearAllPoints(); ForeverRouteArrow:SetPoint("TOP", UIParent, "TOP", 0, -140) end
    ns.Print("Card, arrow and Target button back in place.")
  end, "Puts the card, arrow and Target button back.")
  p.example = true
end

-- News: one row per version. The newest is open (its first three lines, then "+ N more"); older ones are one line
-- each until clicked. Versions you hadn't seen carry NEW (marked from what you had seen before this visit).
local function fmtDate(d)
  local y, m, dd = tostring(d or ""):match("^(%d+)-(%d+)-(%d+)$")
  if not y then return d or "" end
  local M = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
  return (M[tonumber(m)] or m) .. " " .. tonumber(dd)
end
function BUILD.news(p)
  local scroll = CreateFrame("ScrollFrame", nil, p); scroll:SetPoint("TOPLEFT", 0, 0); scroll:SetPoint("BOTTOMRIGHT", 0, 30)
  scroll:EnableMouseWheel(true)
  local content = CreateFrame("Frame", nil, scroll); content:SetSize(PAGE_W, 10); scroll:SetScrollChild(content)
  scroll:SetScript("OnMouseWheel", function(self, d)
    local max = math.max(0, content:GetHeight() - self:GetHeight())
    self:SetVerticalScroll(math.min(max, math.max(0, self:GetVerticalScroll() - d * 50)))
  end)
  -- (cheap rows: building every version's row, pill, body and link up front was 160 ms on a fresh load - the perf
  -- battery's "options tab switched". A row is its one-line header; the NEW mark, the body and the "more" link are
  -- made when needed; the newest SHOWN versions are listed, the rest behind "Older versions")
  local SHOWN = 10
  local rows, open, all = {}, {}, false
  local function row(k)
    if rows[k] then return rows[k] end
    local r = CreateFrame("Button", nil, content); r:SetSize(PAGE_W, 22)
    r.head = Style.Text(r, 12, C.gold, "OUTLINE"); r.head:SetPoint("LEFT", 10, 0)
    r:SetScript("OnClick", function() open[k] = (open[k] or 0) > 0 and 0 or 1; p.layout() end)
    rows[k] = r
    return r
  end
  local function mark(r, on)
    if on and not r.pill then
      r.edge = r:CreateTexture(nil, "ARTWORK"); r.edge:SetTexture(Style.WHITE); r.edge:SetWidth(3); r.edge:SetPoint("TOPLEFT", 0, -3); r.edge:SetPoint("BOTTOMLEFT", 0, 3)
      r.edge:SetVertexColor(C.gold[1], C.gold[2], C.gold[3])
      r.pill = Style.Pill(r, "NEW", C.gold); r.pill:SetPoint("LEFT", r.head, "RIGHT", 8, 0)
    end
    if r.pill then r.pill:SetShown(on); r.edge:SetShown(on) end
  end
  local function body(r, k)
    if r.body then return end
    r.body = Style.Text(content, 11, C.text); r.body:SetWidth(PAGE_W - 14); r.body:SetJustifyH("LEFT"); r.body:SetSpacing(2)
    r.more = CreateFrame("Button", nil, content); r.more:SetSize(120, 16)
    r.more.text = Style.Text(r.more, 10, C.sub); r.more.text:SetPoint("LEFT", 0, 0)
    r.more:SetScript("OnClick", function() open[k] = 2; p.layout() end)
  end
  local older = CreateFrame("Button", nil, content); older:SetSize(PAGE_W, 22); older:Hide()
  older.text = Style.Text(older, 11, C.sub); older.text:SetPoint("LEFT", 10, 0)
  older:SetScript("OnClick", function() all = true; p.layout() end)
  p.layout = function()
    local y, news = 0, ns.NEWS or {}
    local last = all and #news or math.min(#news, SHOWN)
    for k = 1, last do
      local e = news[k]
      local r, state = row(k), open[k] or 0
      local items = e.items or {}
      r:ClearAllPoints(); r:SetPoint("TOPLEFT", 0, -y); r:Show()
      r.head:SetText(e.version .. "  |cff8a93a6" .. fmtDate(e.date) .. "  ·  " .. #items .. (#items == 1 and " change" or " changes") .. "|r")
      local seen = Options.unreadFrom
      local new = seen ~= false and (seen == nil and k == 1 or (seen and ns.News and ns.News.Newer(e.version, seen)))
      mark(r, new and true or false)
      y = y + 24
      if state > 0 then body(r, k) end
      if state > 0 then
        local shown = state == 2 and #items or math.min(3, #items)
        local lines = {}
        for j = 1, shown do lines[#lines + 1] = "- " .. items[j] end
        r.body:SetText(table.concat(lines, "\n")); r.body:ClearAllPoints(); r.body:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -y); r.body:Show()
        y = y + (r.body:GetStringHeight() or 0) + 4
        if shown < #items then
          r.more.text:SetText("+ " .. (#items - shown) .. " more"); r.more:ClearAllPoints(); r.more:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -y); r.more:Show()
          y = y + 18
        else r.more:Hide() end
        y = y + 8
      elseif r.body then r.body:Hide(); r.more:Hide() end
    end
    for k = last + 1, #rows do rows[k]:Hide(); if rows[k].body then rows[k].body:Hide(); rows[k].more:Hide() end end
    older:SetShown(last < #news)
    if last < #news then
      older.text:SetText("Older versions (" .. (#news - last) .. ")"); older:ClearAllPoints(); older:SetPoint("TOPLEFT", 0, -y); y = y + 24
    end
    content:SetHeight(math.max(10, y))
  end
  -- under the list: the bar after an update
  local bar = CreateFrame("Frame", nil, p); bar:SetPoint("BOTTOMLEFT", 0, 0); bar:SetSize(PAGE_W, 26); bar.y = 0; bar.tabKey = "news"
  toggle(bar, "Tell me after updates", "newsBar", "A small bar under the card, once per update.")
  p.fill = function()
    -- (what you had seen before your first visit this session marks NEW - kept for the session, so coming back to the
    -- tab still shows it; then it counts as read. false: nothing was unread)
    if Options.unreadFrom == nil then
      local cur = ns.News and ns.News.Current()
      Options.unreadFrom = (cur and ns.db.newsSeen and ns.News.Newer(cur, ns.db.newsSeen)) and ns.db.newsSeen or false
    end
    wipe(open); open[1] = 1; all = false
    p.layout(); scroll:SetVerticalScroll(0)
    if ns.News and ns.News.Dismiss then ns.News.Dismiss() end
    Options.Dot()
  end
end

function BUILD.help(p)
  header(p, "Keys")
  note(p, "Esc > Key Bindings > AddOns > Forever Route")
  header(p, "Commands")
  for _, c in ipairs({ { "/fr", "show / hide the card" }, { "/fr list", "the whole route" }, { "/fr paths", "pick a home base" }, { "/fr report", "copy a bug report" } }) do
    local a = Style.Text(p, 11, C.gold); a:SetPoint("TOPLEFT", 0, -p.y); a:SetText(c[1])
    local b = Style.Text(p, 11, C.sub); b:SetPoint("TOPLEFT", 90, -p.y); b:SetText(c[2])
    p.y = p.y + 18
  end
  header(p, "Start over")
  confirmButton(p, "Bring back skipped steps", 190, function()
    ns.char.skipped, ns.char.manualDone, ns.char.history = {}, {}, {}
    ns.Engine.Refresh(); ns.Print("Skipped and ticked steps are back.")
  end, "Every step you skipped or ticked by hand comes back.")
  confirmButton(p, "Reset all settings", 190, function()
    for k, v in pairs(ns.DEFAULTS) do ns.db[k] = v end
    ns.db.uiScale = nil
    ns.Fire("FR_SETTINGS"); ns.Print("Settings back to their defaults.")
  end, "Every option back to how it started.")
  note(p, "Settings are shared by your characters. Skips are per character.", 10, C.dim)
  header(p, "Credits")
  -- the attribution the license asks every copy and adaptation to keep (NOTICE)
  note(p, "Forever Route by noopz  ·  github.com/noopz/ForeverRoute  ·  CC BY-NC-SA 4.0, not for sale", 10)
end

-- ---------------------------------------------------------------- the window

local function paintTab(b)
  local lit = b.on or b.hover
  local col = lit and b.t.color or C.sub
  b.icon:SetVertexColor(col[1], col[2], col[3]); b.icon:SetAlpha(lit and 1 or 0.65)
  b.label:SetTextColor(col[1], col[2], col[3])
  b.wash:SetVertexColor(b.t.color[1], b.t.color[2], b.t.color[3], 0.12); b.wash:SetShown(b.on)
  b.bar:SetVertexColor(b.t.color[1], b.t.color[2], b.t.color[3]); b.bar:SetShown(b.on)
end

-- the gold dot on News while an update is unread
function Options.Dot()
  if not host then return end
  local cur, seen = ns.News and ns.News.Current(), ns.db.newsSeen
  host.tabs.news.dot:SetShown(cur ~= nil and seen ~= nil and ns.News.Newer(cur, seen))
end

local function page(key)
  local p = panel.pages[key]
  if not p then
    p = CreateFrame("Frame", nil, panel); p:SetAllPoints(); p:Hide(); p.y = 0; p.tabKey = key
    BUILD[key](p)
    panel.pages[key] = p
  end
  return p
end

-- ---------------------------------------------------------------- search

local TAB_LABEL, TAB_AT = {}, {}
for k, t in ipairs(TABS) do TAB_LABEL[t.key], TAB_AT[t.key] = t.label, k end
-- the options matching text (every word of it), in tab order
function Options.Find(text)
  for _, t in ipairs(TABS) do page(t.key) end -- (the first search builds every page, once)
  local words = {}
  for w in string.lower(text or ""):gmatch("%S+") do words[#words + 1] = w end
  local out = {}
  if #words == 0 then return out end
  for _, e in ipairs(Options.index) do
    local all = true
    for _, w in ipairs(words) do if not (e.find:find(w, 1, true) or TAB_LABEL[e.tab]:lower():find(w, 1, true)) then all = false; break end end
    if all then out[#out + 1] = e end
  end
  -- (in tab order, then the order on the page: the Size tab is built first, for its slider)
  for k, e in ipairs(out) do e.n = k end
  table.sort(out, function(a, b) if TAB_AT[a.tab] ~= TAB_AT[b.tab] then return TAB_AT[a.tab] < TAB_AT[b.tab] end return a.n < b.n end)
  return out
end
-- a found option: its tab, and the row lights up for a moment
function Options.Go(e)
  host.search:SetText(""); host.search:ClearFocus()
  Options.Show(e.tab)
  local fl = e.frame.flash
  if not fl then
    fl = e.frame:CreateTexture(nil, "BACKGROUND"); fl:SetTexture(Style.WHITE); fl:SetAllPoints(); fl:SetVertexColor(C.gold[1], C.gold[2], C.gold[3], 0.18)
    e.frame.flash = fl
  end
  fl:Show(); C_Timer.After(1.2, function() fl:Hide() end)
end
local results
local function showResults(text)
  if not results then
    results = CreateFrame("Frame", nil, panel); results:SetAllPoints(); results.rows = {}
    results.none = Style.Text(results, 12, C.sub); results.none:SetPoint("TOPLEFT", 0, 0)
  end
  local found = Options.Find(text)
  for _, t in ipairs(TABS) do if panel.pages[t.key] then panel.pages[t.key]:Hide() end end
  results:Show()
  host.title:SetText("Search")
  host.reset:Hide(); host.example:Hide()
  results.none:SetText(#found == 0 and ("Nothing matches \"" .. text .. "\".") or "")
  for k = 1, math.max(#found, #results.rows) do
    local e, r = found[k], results.rows[k]
    if e and not r and k <= 14 then
      r = CreateFrame("Button", nil, results); r:SetSize(PAGE_W, 26); r:SetPoint("TOPLEFT", 0, -(k - 1) * 28)
      r.wash = r:CreateTexture(nil, "BACKGROUND"); r.wash:SetTexture(Style.WHITE); r.wash:SetAllPoints(); r.wash:SetVertexColor(1, 1, 1, 0.04)
      r.name = Style.Text(r, 12, C.text); r.name:SetPoint("LEFT", 10, 0)
      r.tab = Style.Text(r, 10, C.sub); r.tab:SetPoint("RIGHT", -10, 0)
      r:SetScript("OnEnter", function(self) self.wash:SetVertexColor(1, 1, 1, 0.1) end)
      r:SetScript("OnLeave", function(self) self.wash:SetVertexColor(1, 1, 1, 0.04) end)
      r:SetScript("OnClick", function(self) if self.e then Options.Go(self.e) end end)
      results.rows[k] = r
    end
    if r then
      r.e = e
      if e then r.name:SetText(e.label); r.tab:SetText(TAB_LABEL[e.tab]); r:Show() else r:Hide() end
    end
  end
end
-- typing in the box: the matches; an empty box: back to the tab
function Options.Search(text)
  if not host then return end
  if text and text:match("%S") then showResults(text) else if results then results:Hide() end; Options.Show() end
end

function Options.Show(key)
  if results then results:Hide() end
  key = key or Options.tab
  Options.tab = key
  for _, t in ipairs(TABS) do
    local on = t.key == key
    host.tabs[t.key].on = on; paintTab(host.tabs[t.key])
    if panel.pages[t.key] then panel.pages[t.key]:SetShown(on) end
    if on then host.title:SetText(t.title) end
  end
  local pg = page(key); pg:Show()
  if pg.fill then pg.fill() end
  host.reset:SetShown(pg.keys ~= nil and key ~= "news")
  host.example:SetShown(pg.example and ns.Demo ~= nil)
  host.example.label:SetText(ns.Demo and ns.Demo.active and "Stop example" or "Show example")
  Options.Dot()
end

local function build()
  if host then return end
  host = CreateFrame("Frame", "ForeverRouteOptionsWindow", UIParent)
  host:SetSize(W, H); host:SetPoint("CENTER", 0, 40); host:Hide()
  Style.Window(host, "ForeverRouteOptionsWindow")
  local close = Style.CloseButton(host); close:SetFrameLevel(host:GetFrameLevel() + 10)
  -- the rail
  host.rail = CreateFrame("Frame", nil, host); host.rail:SetPoint("TOPLEFT", 4, -4); host.rail:SetPoint("BOTTOMLEFT", 4, 4); host.rail:SetWidth(RAIL - 6)
  local railBg = host.rail:CreateTexture(nil, "BACKGROUND"); railBg:SetTexture(Style.WHITE); railBg:SetAllPoints(); railBg:SetVertexColor(0, 0, 0, 0.25)
  host.tabs = {}
  for k, t in ipairs(TABS) do
    local b = CreateFrame("Button", nil, host.rail)
    b:SetSize(RAIL - 6, 48); b:SetPoint("TOP", host.rail, "TOP", 0, -(8 + (k - 1) * 52)); b.t = t
    b.wash = b:CreateTexture(nil, "BACKGROUND"); b.wash:SetTexture(Style.WHITE); b.wash:SetAllPoints()
    b.bar = b:CreateTexture(nil, "ARTWORK"); b.bar:SetTexture(Style.WHITE); b.bar:SetWidth(3); b.bar:SetPoint("TOPLEFT", 0, -6); b.bar:SetPoint("BOTTOMLEFT", 0, 6)
    b.icon = b:CreateTexture(nil, "ARTWORK"); b.icon:SetTexture(MEDIA .. t.icon); b.icon:SetSize(18, 18); b.icon:SetPoint("TOP", 0, -8)
    b.label = Style.Text(b, 10, C.sub); b.label:SetPoint("TOP", b.icon, "BOTTOM", 0, -4); b.label:SetJustifyH("CENTER"); b.label:SetText(t.label)
    b.dot = b:CreateTexture(nil, "OVERLAY"); b.dot:SetTexture(MEDIA .. "dot"); b.dot:SetSize(8, 8); b.dot:SetPoint("TOPRIGHT", -8, -6)
    b.dot:SetVertexColor(C.gold[1], C.gold[2], C.gold[3]); b.dot:Hide()
    b:SetScript("OnClick", function() Options.Show(t.key) end)
    b:SetScript("OnEnter", function(self) self.hover = true; paintTab(self) end)
    b:SetScript("OnLeave", function(self) self.hover = false; paintTab(self) end)
    host.tabs[t.key] = b
  end
  -- the title, and the links at its right: show the demo card, reset this tab
  host.title = Style.Text(host, 16, C.gold, "OUTLINE"); host.title:SetPoint("TOPLEFT", RAIL + PAD, -14)
  host.reset = Style.Button(host, "Reset tab", 70, 18, function()
    local pg = panel.pages[Options.tab]; if not (pg and pg.keys) then return end
    for _, k in ipairs(pg.keys) do ns.db[k.key] = k.default end
    ns.Fire("FR_SETTINGS"); pg:Hide(); pg:Show()
  end, "This tab back to its defaults.")
  host.reset:SetPoint("BOTTOMRIGHT", -PAD, 10)
  host.example = Style.Button(host, "Show example", 96, 18, function(self)
    if not ns.Demo then return end
    ns.Demo.Start() -- (again: stops it)
    self.label:SetText(ns.Demo.active and "Stop example" or "Show example")
    if ForeverRouteCard and ns.Demo.active then ForeverRouteCard:Show() end
  end, "The card cycles through every kind of step, so you see what each option changes.")
  host.example:SetPoint("RIGHT", host.reset, "LEFT", -6, 0)
  -- the search box, at the top right
  local sb = CreateFrame("EditBox", nil, host, "InputBoxTemplate")
  sb:SetSize(150, 20); sb:SetPoint("TOPRIGHT", -40, -12); sb:SetAutoFocus(false); sb:SetMaxLetters(40)
  sb.hint = Style.Text(sb, 11, C.dim); sb.hint:SetPoint("LEFT", 2, 0); sb.hint:SetText("Search options")
  sb:SetScript("OnTextChanged", function(self, user)
    local t = self:GetText() or ""
    self.hint:SetShown(t == "")
    if user then Options.Search(t) end
  end)
  sb:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus(); Options.Search("") end)
  sb:SetScript("OnEnterPressed", function(self) local found = Options.Find(self:GetText()); if found[1] then Options.Go(found[1]) else self:ClearFocus() end end)
  host.search = sb
  -- the pages (each built the first time it shows)
  panel = CreateFrame("Frame", "ForeverRouteOptions", host)
  panel:SetPoint("TOPLEFT", RAIL + PAD, -TOP); panel:SetPoint("BOTTOMRIGHT", -PAD, 36)
  panel.pages = {}
  page("size") -- (its scale slider is panel.scaleSlider from the start)
  -- (shown again with words still in the box: their results, not a tab under a search that says otherwise)
  host:SetScript("OnShow", function() local t = host.search and host.search:GetText() or ""; if t:match("%S") then Options.Search(t) else Options.Show() end end)
  host:HookScript("OnHide", function() if ns.Demo and ns.Demo.active and Options.demoMine then ns.Demo.Stop() end end)
  host.example:HookScript("OnClick", function() Options.demoMine = ns.Demo and ns.Demo.active end)
  -- Options > AddOns: a small page that opens the window (the game's settings canvas is too small for it)
  local link = CreateFrame("Frame", "ForeverRouteOptionsLink", UIParent); link:Hide()
  local lt = Style.Text(link, 16, C.gold, "OUTLINE"); lt:SetPoint("TOPLEFT", 16, -16); lt:SetText("Forever Route")
  local open = Style.Button(link, "Open Forever Route options", 200, 22, function()
    if SettingsPanel and SettingsPanel.Close then pcall(SettingsPanel.Close, SettingsPanel) elseif HideUIPanel and SettingsPanel then HideUIPanel(SettingsPanel) end
    Options.Open()
  end)
  open:SetPoint("TOPLEFT", lt, "BOTTOMLEFT", 0, -12)
  if Settings and Settings.RegisterCanvasLayoutCategory then
    local cat = Settings.RegisterCanvasLayoutCategory(link, "Forever Route")
    Settings.RegisterAddOnCategory(cat)
    link.categoryID = cat:GetID()
  elseif InterfaceOptions_AddCategory then
    link.name = "Forever Route"; InterfaceOptions_AddCategory(link)
  end
end
ns.On("FR_LOADED", build)

-- /fr options and the gear button; key opens that tab ("news": the bar's What's new, /fr news)
function Options.Open(key)
  if not host then build() end
  if key then Options.tab = key; host.search:SetText("") end -- (a tab asked for: not a search left over)
  host:Show(); panel:Show()
  if not host.search:GetText():match("%S") then Options.Show() end
end
ns.On("FR_OPEN_OPTIONS", function()
  if host and host:IsShown() then host:Hide() else Options.Open() end
end)
