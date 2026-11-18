-- The step card.
--   header:   section (hub) + zone, route progress % and a hairline progress bar
--   current:  coloured accent strip, icon disc, title, details, distance; live objective bars for everything done
--             at this spot; target / use-item buttons; note or warning
--   timeline: the next few steps on a vertical line with coloured nodes
--   controls: icon buttons that fade in while the mouse is over the card
--   inside a dungeon (no coordinates in there): the dungeon's name and what your quest log has for it, with live
--             bars - Card.FillDungeon; the plan's step waits in the timeline below
local _, ns = ...
local Style = ns.Style
local C = Style.C
local Card = {}
ns.Card = Card

local PAD, DIST_W = 14, 64
local f
-- the step's tool row (right-aligned under the distance): Map, and the quest icon buttons left of it
Card.TOOL, Card.TOOL_GAP, Card.MAP_W = 16, 4, 38

local function steps() return ForeverRouteData and ForeverRouteData.steps or {} end
local function section(i) local s = steps()[i]; local secs = ForeverRouteData and ForeverRouteData.sections; return s and secs and secs[s.sec] end

-- the footer's flag: "this looks wrong" keeps what the card showed for the next /fr report (Moments.lua) - no chat
-- line; a brief green tick on the icon says it was kept
Card.FLAG_TIP = { "Looks wrong? Click, then send /fr report." }
function Card.FlagMoment(b)
  local m = ns.Moments and ns.Moments.Flag()
  if not (b and b.icon) then return m end
  if m then b.icon:SetTexture(Style.MEDIA .. "icon-check"); b.icon:SetVertexColor(C.good[1], C.good[2], C.good[3]) end
  if C_Timer and C_Timer.After then
    C_Timer.After(2, function() b.icon:SetTexture(Style.MEDIA .. "btn-flag"); local r = C.sub; b.icon:SetVertexColor(r[1], r[2], r[3]) end)
  end
  return m
end

-- quests numbered from 10000 up came after the original game (all of its quests are below that): Forever's own and
-- other later additions, whose quest data is younger and can miss what unlocks them
Card.NEW_QUEST_MIN = 10000
function Card.IsNewQuest(q) return type(q) == "number" and q >= Card.NEW_QUEST_MIN end
function Card.Describe(s)
  local kind = Style.Kind(s)
  local verb = Style.Hex(kind.color) .. (kind.verb or "") .. "|r"
  local qc = Style.Hex(Style.QuestColor(s.level))
  local title, detail
  if s.k == "accept" or s.k == "turnin" then
    title = verb .. " " .. qc .. (s.name or ("quest " .. tostring(s.q))) .. "|r"
    detail = s.npc and ((s.k == "accept" and "from " or "to ") .. s.npc) or nil
  elseif s.k == "obj" then
    title = Style.Hex(kind.color) .. (s.text or "Objective") .. "|r"
    detail = s.name and (qc .. s.name .. "|r") or nil
  elseif s.k == "fly" and s.boat then
    -- the planner names the town the boat docks at ("Boat to Auberdine"); dest is only the zone
    title = Style.Hex(kind.color) .. (s.text or ((kind.verb or "") .. " " .. (s.dest or ""))) .. "|r"
    detail = s.npc
  elseif s.k == "fly" or s.k == "hearth" then
    title = verb .. " " .. (s.dest or s.text or "")
    detail = s.npc
  elseif s.k == "fp" then
    title = verb .. (s.fp and (" - " .. s.fp) or "")
    detail = s.npc and ("talk to " .. s.npc) or nil
  elseif s.k == "bind" then
    title = verb .. (s.bind and (" in " .. s.bind) or "")
    detail = s.npc and ("talk to " .. s.npc) or nil
  elseif s.k == "train" then
    title = verb .. " " .. (s.text or "your new spells")
    detail = s.npc
  elseif s.k == "bonus" then
    title = verb .. " " .. Style.Hex(kind.color) .. (s.text or "") .. "|r"
    detail = nil
  elseif s.k == "grind" then
    title = verb .. string.format(" to level %d%s", s.level or 0, (s.xp and s.xp > 0) and string.format(" + %d xp", s.xp) or "")
    detail = s.text
  else
    title = s.text or ""
  end
  return title, detail
end
local function plain(t) return ((t or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
Card.Plain = plain

local pendingSecure
local function setSecure(fn) if InCombatLockdown() then pendingSecure = fn; return end fn() end

local function build()
  f = CreateFrame("Frame", "ForeverRouteCard", UIParent)
  f:SetSize(ns.db.cardWidth, 160)
  f:SetPoint("TOPRIGHT", UIParent, "RIGHT", -60, 230) -- (Card.DEFAULT_POS; Card.ApplyPos sets the real place)
  f:SetClampedToScreen(true); f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
  -- movable in combat too: the card itself is not protected (its secure target / item buttons are their own frames
  -- on UIParent; moved in combat, they catch up when combat ends - Card.PlaceSecure). Out of combat they follow the
  -- card while it is dragged.
  f:SetScript("OnDragStart", function(self) if not ns.db.locked then self:StartMoving(); self.dragging = true end end)
  f:SetScript("OnDragStop", function(self) self.dragging = nil; self:StopMovingOrSizing(); Card.AnchorTop(); Card.PlaceSecure() end)
  f:SetScript("OnUpdate", function(self) if self.dragging and not InCombatLockdown() then Card.PlaceSecure() end end)
  Style.Panel(f)

  -- header
  f.title = Style.Text(f, 11, C.gold, "OUTLINE"); f.title:SetPoint("TOPLEFT", PAD, -11); f.title:SetWordWrap(false)
  -- "?": why the card sends you here, in a line or two (UI/Explain.lua, worked out on the click). Always on the header,
  -- not in the hover bar: the moment you wonder is the moment you look at the card
  f.help = Style.Button(f, "?", 16, 16, function(self) if ns.Explain then ns.Explain.Show(self, ns.Engine.Shown and ns.Engine.Shown()) end end, "Why this step? Click to see.")
  f.help:SetPoint("TOPRIGHT", -PAD + 4, -8)
  f.help.label:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
  f.help:SetScript("OnLeave", function(self) self.label:SetTextColor(C.gold[1], C.gold[2], C.gold[3]); GameTooltip:Hide() end)
  f.count = Style.Text(f, 10, C.dim); f.count:SetPoint("RIGHT", f.help, "LEFT", -6, 0); f.count:SetJustifyH("RIGHT")
  f.title:SetPoint("RIGHT", f.count, "LEFT", -8, 0)
  f.prog = CreateFrame("Frame", nil, f); f.prog:SetPoint("TOPLEFT", PAD, -28); f.prog:SetPoint("TOPRIGHT", -PAD, -28); f.prog:SetHeight(2)
  local pbg = f.prog:CreateTexture(nil, "BACKGROUND"); pbg:SetTexture(Style.WHITE); pbg:SetAllPoints(); pbg:SetVertexColor(1, 1, 1, 0.06)
  f.progFill = f.prog:CreateTexture(nil, "ARTWORK"); f.progFill:SetTexture(Style.WHITE); f.progFill:SetPoint("TOPLEFT"); f.progFill:SetPoint("BOTTOMLEFT")
  f.progFill:SetVertexColor(C.gold[1], C.gold[2], C.gold[3], 0.9)
  f.prog:SetScript("OnSizeChanged", function() Card.UpdateProgress() end)

  -- current step
  local cur = CreateFrame("Frame", nil, f); f.cur = cur
  cur:SetPoint("TOPLEFT", PAD, -40); cur:SetPoint("RIGHT", -PAD, 0); cur:SetHeight(60)
  cur.accent = f:CreateTexture(nil, "ARTWORK"); cur.accent:SetTexture(Style.WHITE); cur.accent:SetWidth(3)
  cur.accent:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -40); cur.accent:SetPoint("BOTTOMLEFT", cur, "BOTTOMLEFT", -PAD, 0)
  cur.halo = cur:CreateTexture(nil, "ARTWORK", nil, 0); cur.halo:SetTexture(Style.MEDIA .. "glow"); cur.halo:SetSize(66, 66)
  cur.disc = cur:CreateTexture(nil, "ARTWORK", nil, 1); cur.disc:SetTexture(Style.MEDIA .. "disc"); cur.disc:SetSize(38, 38); cur.disc:SetPoint("TOPLEFT", 0, 0)
  cur.halo:SetPoint("CENTER", cur.disc)
  cur.icon = cur:CreateTexture(nil, "ARTWORK", nil, 2); cur.icon:SetSize(22, 22); cur.icon:SetPoint("CENTER", cur.disc); cur.icon:SetVertexColor(0.07, 0.07, 0.09)
  cur.check = cur:CreateTexture(nil, "OVERLAY"); cur.check:SetTexture(Style.MEDIA .. "icon-check"); cur.check:SetSize(30, 30); cur.check:SetPoint("CENTER", cur.disc)
  cur.check:SetVertexColor(C.good[1], C.good[2], C.good[3]); cur.check:SetAlpha(0)
  cur.dist = Style.Text(cur, 11, C.gold); cur.dist:SetPoint("TOPRIGHT", 0, -1); cur.dist:SetWidth(DIST_W); cur.dist:SetJustifyH("RIGHT"); cur.dist:SetWordWrap(false)
  cur.titleText = Style.Text(cur, 15, C.text); cur.titleText:SetPoint("TOPLEFT", cur.disc, "TOPRIGHT", 12, 1)
  cur.detail = Style.Text(cur, 11, C.sub); cur.detail:SetPoint("TOPLEFT", cur.titleText, "BOTTOMLEFT", 0, -4)
  cur.map = Style.Button(cur, "Map", Card.MAP_W, Card.TOOL, function() ns.ShowOnMap(ns.Engine.Shown()) end, "Open the world map where this step is (for a trip: where it takes you), its pin flashing")
  cur.map.label:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
  cur.map:SetScript("OnLeave", function(self) self.label:SetTextColor(C.gold[1], C.gold[2], C.gold[3]); GameTooltip:Hide() end)
  cur.map:SetPoint("TOPRIGHT", cur, "TOPRIGHT", 0, -18)
  -- the step's quest buttons: small icons in a row left of Map (Card.Layout), with what they do in their tooltips.
  -- They were two lines of text under the bars, as wide as their words: "these buttons should be placed elsewhere
  -- and not just giant text" (tester).
  -- a red X, "not doing this quest": drops it from the route and future plans (warns first if later quests need it)
  cur.nope = Style.IconButton(cur, "btn-x", Card.TOOL, function() ns.Engine.Nope() end,
    { "Not doing this quest", "Drops it from your route and from future plans. If later quests need it, you're asked first. Undo brings it back." }, C.bad)
  -- a struck-through "!", "the giver doesn't offer it": the giver has nothing for you (no window opens, so the addon
  -- can't tell by itself - James Halloran, Argos Nightwhisper). Off your route until you level up, like a giver who
  -- lists other quests but not this one
  cur.notOffered = Style.IconButton(cur, "btn-no-offer", Card.TOOL, function() ns.Engine.NotOffered() end,
    { "The giver doesn't offer it", "Click if the quest giver has nothing for you. The quest leaves your route until your next level (a level or a quest you haven't done can be the reason), then it's tried again. Turned down a second time, it stays off until the game offers it. Its chain stays." })
  -- (a bigger glyph than the footer's buttons have: at their size the "!" under its stroke was a smudge)
  for _, b in ipairs({ cur.nope, cur.notOffered }) do b.icon:SetSize(Card.TOOL * 0.75, Card.TOOL * 0.75) end
  -- "not now": a stop the route took in from where you are (a hand-in while you're here) leaves the card until you move
  -- on; the plan's own next step comes back
  cur.notNow = Style.Button(cur, "not now", 60, 14, function() if ns.Next and ns.Next.Dismiss then ns.Next.Dismiss(ns.Engine.Shown and ns.Engine.Shown()) end end, "Skip this stop for now: the route goes back to its planned next step. It's offered again once you've moved on, or in 15 minutes.")
  cur.notNow.label:SetFontObject(Style.Font(10)); cur.notNow.label:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
  cur.notNow:SetScript("OnLeave", function(self) self.label:SetTextColor(C.dim[1], C.dim[2], C.dim[3]); GameTooltip:Hide() end)
  -- a quest newer than the original game: a short tag, its meaning on hover (it was three lines of note - tester)
  cur.fq = Style.Button(cur, "Forever Quest", 84, 14, function() end, "Added by WoW Forever. If the giver has nothing for you, it drops off your route by itself.")
  cur.fq.label:SetFontObject(Style.Font(10)); cur.fq.label:SetTextColor(0.56, 0.83, 1)
  cur.fq:SetScript("OnLeave", function(self) self.label:SetTextColor(0.56, 0.83, 1); GameTooltip:Hide() end)
  cur.fq:SetWidth(cur.fq.label:GetStringWidth() + 12)
  cur.fq:Hide()
  -- a chain-start step spliced in for a zone you picked: you can say no (Stitch.Refuse)
  cur.noChain = Style.Button(cur, "skip chain start", 90, 14, function() local s = steps()[ns.Engine.Shown() or 0]; if s and s.chainStart and ns.Stitch then ns.Stitch.Refuse(s.chainStart) end end, "Take this chain start off your route. It won't be added again.")
  cur.noChain.label:SetFontObject(Style.Font(10)); cur.noChain.label:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
  cur.noChain:SetScript("OnLeave", function(self) self.label:SetTextColor(C.dim[1], C.dim[2], C.dim[3]); GameTooltip:Hide() end)
  cur.noChain:SetWidth(cur.noChain.label:GetStringWidth() + 10)
  cur.noChain:Hide()
  -- a step picked out of plan order: its short reason and what it saves; the whole reason and the plan's step on hover
  cur.why = Style.Button(cur, "", 60, 14, function() end, nil)
  cur.why.label:SetFontObject(Style.Font(10)); cur.why.label:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
  cur.why:SetScript("OnEnter", function(self)
    self.label:SetTextColor(1, 0.86, 0.5)
    if self.tip then GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText(self.tip, 1, 1, 1, 1, true); if self.tip2 then GameTooltip:AddLine(self.tip2, 0.75, 0.8, 0.88, true) end; GameTooltip:Show() end
  end)
  cur.why:SetScript("OnLeave", function(self) self.label:SetTextColor(C.dim[1], C.dim[2], C.dim[3]); GameTooltip:Hide() end)
  cur.why:Hide()
  cur.bars = {}
  cur.heads = {} -- the dungeon state's quest names, one above each quest's bars
  cur.note = Style.Text(cur, 11, C.sub)

  -- target / use-item: secure buttons on UIParent, floating just above the card's top edge (Card.PlaceSecure, out of
  -- combat). Not in a slot on the card: a secure button can't move in combat, the card's rows can (a step with more
  -- objective bars mid-fight ran its bars under the button).
  -- on the card's own layer, a level above it (Card.PlaceSecure sets the level): what covers the card - the
  -- character sheet, the map - covers these too (on "HIGH" they floated over every window)
  cur.target = CreateFrame("Button", "ForeverRouteTargetButton", UIParent, "SecureActionButtonTemplate"); cur.target:SetFrameStrata(f:GetFrameStrata())
  -- Ctrl+drag puts it wherever you like (ns.db.targetPos; /fr target reset brings it back); a Ctrl-click runs an empty
  -- macro, so grabbing it never targets
  cur.target:SetAttribute("ctrl-type1", "macro"); cur.target:SetAttribute("ctrl-macrotext1", "")
  cur.target:SetMovable(true); cur.target:RegisterForDrag("LeftButton"); cur.target:SetClampedToScreen(true)
  cur.target:SetScript("OnDragStart", function(self) if IsControlKeyDown() and not InCombatLockdown() then self.dragging = true; self:StartMoving() end end)
  cur.target:SetScript("OnDragStop", function(self)
    -- (only a drag we started: a drag in combat, never started, would call a protected function - ADDON_ACTION_BLOCKED)
    if not self.dragging or InCombatLockdown() then return end
    self.dragging = nil
    self:StopMovingOrSizing(); self:SetUserPlaced(false) -- (ours to keep, not the game's layout cache)
    local l, t, s = self:GetLeft(), self:GetTop(), self:GetEffectiveScale() / UIParent:GetEffectiveScale()
    if l and t then ns.db.targetPos = { l * s, t * s } end
    Card.PlaceSecure()
  end)
  cur.target:SetSize(140, 20); cur.target:RegisterForClicks("AnyUp", "AnyDown"); cur.target:SetAttribute("type", "macro")
  Style.Nine(cur.target, "panel", "BACKGROUND", 0, 8, 0, 1, 0.47, 0.42, 0.2)
  local thl = cur.target:CreateTexture(nil, "HIGHLIGHT"); thl:SetTexture(Style.WHITE); thl:SetPoint("TOPLEFT", 3, -3); thl:SetPoint("BOTTOMRIGHT", -3, 3); thl:SetVertexColor(1, 1, 1, 0.07)
  cur.target.icon = cur.target:CreateTexture(nil, "ARTWORK"); cur.target.icon:SetTexture(Style.MEDIA .. "icon-grind"); cur.target.icon:SetSize(12, 12); cur.target.icon:SetPoint("LEFT", 7, 0)
  cur.target.icon:SetVertexColor(1, 0.55, 0.5)
  cur.target.label = Style.Text(cur.target, 10, C.text); cur.target.label:SetPoint("LEFT", cur.target.icon, "RIGHT", 5, 0); cur.target.label:SetPoint("RIGHT", -6, 0); cur.target.label:SetWordWrap(false); cur.target.label:SetJustifyV("MIDDLE")
  cur.target:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText("Click to target " .. (self.who or ""), 1, 1, 1); GameTooltip:AddLine("Works when they're close enough to see, in combat too.", 0.75, 0.8, 0.88, true); GameTooltip:AddLine("Want a key for it? Options > Keybindings, under AddOns: Forever Route Targeting.", 0.5, 0.55, 0.62, true); GameTooltip:AddLine("Ctrl+drag to move it (/fr target reset puts it back above the card).", 0.5, 0.55, 0.62, true); GameTooltip:Show() end)
  cur.target:SetScript("OnLeave", GameTooltip_Hide)
  cur.item = CreateFrame("Button", "ForeverRouteItemButton", UIParent, "SecureActionButtonTemplate"); cur.item:SetFrameStrata(f:GetFrameStrata())
  cur.item:SetSize(26, 26); cur.item:RegisterForClicks("AnyUp", "AnyDown"); cur.item:SetAttribute("type", "item")
  local ibg = cur.item:CreateTexture(nil, "BACKGROUND"); ibg:SetTexture(Style.WHITE); ibg:SetAllPoints(); ibg:SetVertexColor(0, 0, 0, 0.8)
  cur.item.icon = cur.item:CreateTexture(nil, "ARTWORK"); cur.item.icon:SetPoint("TOPLEFT", 1, -1); cur.item.icon:SetPoint("BOTTOMRIGHT", -1, 1); cur.item.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  local ihl = cur.item:CreateTexture(nil, "HIGHLIGHT"); ihl:SetTexture(Style.WHITE); ihl:SetAllPoints(); ihl:SetVertexColor(1, 1, 1, 0.15)
  cur.item:SetScript("OnEnter", function(self) if self.itemID then GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetItemByID(self.itemID); GameTooltip:Show() end end)
  cur.item:SetScript("OnLeave", GameTooltip_Hide)
  -- one more Target button for each other mob of the step (its quest item drops from several, or the objectives
  -- grouped with it name others): stacked under the first and moved with it (tester: a target for each mob)
  cur.targets = {}
  for n = 1, Card.EXTRA_TARGETS do
    local b = CreateFrame("Button", "ForeverRouteTargetButton" .. (n + 1), UIParent, "SecureActionButtonTemplate"); b:SetFrameStrata(f:GetFrameStrata())
    b:SetSize(140, 20); b:RegisterForClicks("AnyUp", "AnyDown"); b:SetAttribute("type", "macro")
    Style.Nine(b, "panel", "BACKGROUND", 0, 8, 0, 1, 0.47, 0.42, 0.2)
    local hl = b:CreateTexture(nil, "HIGHLIGHT"); hl:SetTexture(Style.WHITE); hl:SetPoint("TOPLEFT", 3, -3); hl:SetPoint("BOTTOMRIGHT", -3, 3); hl:SetVertexColor(1, 1, 1, 0.07)
    b.icon = b:CreateTexture(nil, "ARTWORK"); b.icon:SetTexture(Style.MEDIA .. "icon-grind"); b.icon:SetSize(12, 12); b.icon:SetPoint("LEFT", 7, 0); b.icon:SetVertexColor(1, 0.55, 0.5)
    b.label = Style.Text(b, 10, C.text); b.label:SetPoint("LEFT", b.icon, "RIGHT", 5, 0); b.label:SetPoint("RIGHT", -6, 0); b.label:SetWordWrap(false); b.label:SetJustifyV("MIDDLE")
    b:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText("Click to target " .. (self.who or ""), 1, 1, 1); GameTooltip:AddLine("Also drops what this step needs. Ctrl+drag the top button to move them all.", 0.6, 0.65, 0.72, true); GameTooltip:Show() end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    b:Hide()
    cur.targets[n] = b
  end
  cur.target:Hide(); cur.item:Hide()

  -- animations
  local out = cur:CreateAnimationGroup()
  local a1 = out:CreateAnimation("Alpha"); a1:SetFromAlpha(1); a1:SetToAlpha(0); a1:SetDuration(0.18); a1:SetStartDelay(0.32)
  local t1 = out:CreateAnimation("Translation"); t1:SetOffset(-16, 0); t1:SetDuration(0.18); t1:SetStartDelay(0.32)
  out:SetScript("OnFinished", function() cur:SetAlpha(0); Card.Fill(); Card.Layout(); cur.animIn:Play() end)
  cur.animOut = out
  local inn = cur:CreateAnimationGroup()
  local a2 = inn:CreateAnimation("Alpha"); a2:SetFromAlpha(0); a2:SetToAlpha(1); a2:SetDuration(0.22)
  local t2 = inn:CreateAnimation("Translation"); t2:SetOffset(16, 0); t2:SetDuration(0)
  local t3 = inn:CreateAnimation("Translation"); t3:SetOffset(-16, 0); t3:SetDuration(0.22); t3:SetSmoothing("OUT")
  inn:SetScript("OnPlay", function() cur:SetAlpha(1) end)
  inn:SetScript("OnFinished", function() cur:SetAlpha(1) end)
  cur.animIn = inn
  local pop = cur.check:CreateAnimationGroup()
  local p1 = pop:CreateAnimation("Alpha"); p1:SetFromAlpha(0); p1:SetToAlpha(1); p1:SetDuration(0.12)
  local p2 = pop:CreateAnimation("Scale"); p2:SetScaleFrom(0.4, 0.4); p2:SetScaleTo(1, 1); p2:SetDuration(0.2); p2:SetSmoothing("OUT")
  local p3 = pop:CreateAnimation("Alpha"); p3:SetFromAlpha(1); p3:SetToAlpha(0); p3:SetDuration(0.2); p3:SetStartDelay(0.32)
  cur.pop = pop

  -- timeline of the next steps
  f.line = f:CreateTexture(nil, "ARTWORK"); f.line:SetTexture(Style.WHITE); f.line:SetVertexColor(1, 1, 1, 0.09); f.line:SetWidth(1)
  f.rows = {}
  for i = 1, 5 do
    local r = CreateFrame("Button", nil, f); r:SetHeight(20)
    r.dot = r:CreateTexture(nil, "OVERLAY"); r.dot:SetTexture(Style.MEDIA .. "dot"); r.dot:SetSize(9, 9); r.dot:SetPoint("LEFT", 18.5, 0) -- centre lines up with the icon disc above
    r.text = Style.Text(r, 11, C.sub); r.text:SetPoint("LEFT", r.dot, "RIGHT", 16, 0); r.text:SetPoint("RIGHT"); r.text:SetWordWrap(false); r.text:SetJustifyV("MIDDLE")
    local hl = r:CreateTexture(nil, "HIGHLIGHT"); hl:SetTexture(Style.WHITE); hl:SetAllPoints(); hl:SetVertexColor(1, 1, 1, 0.035)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r:SetScript("OnClick", function(self, btn) ns.Engine.Look(self.index, btn) end)
    r:SetScript("OnEnter", function(self) Card.Hover(true); GameTooltip:SetOwner(self, "ANCHOR_LEFT"); GameTooltip:SetText("Click to look at this step", 1, 1, 1); GameTooltip:AddLine("Right-click: show it on the map", 0.6, 0.65, 0.72); GameTooltip:AddLine("Shift-click to jump here (skips what's before it - Undo brings it back)", 0.6, 0.65, 0.72, true); GameTooltip:Show() end)
    r:SetScript("OnLeave", function() GameTooltip:Hide(); Card.Hover(false) end)
    f.rows[i] = r
  end

  -- footer: the next zone on the left (Card.FooterText), controls on the right (shown on hover)
  f.eta = Style.Text(f, 10, C.dim); f.eta:SetWordWrap(false)
  f.ctl = CreateFrame("Frame", nil, f); f.ctl:SetSize(264, 20); f.ctl:SetAlpha(0)
  f.ctl.OnChildEnter = function() Card.Hover(true) end
  f.btn = {
    back = Style.IconButton(f.ctl, "btn-back", 20, function() ns.Engine.Back() end, "Look at the previous step"),
    fwd = Style.IconButton(f.ctl, "btn-next", 20, function() ns.Engine.Forward() end, "Next step"),
    done = Style.IconButton(f.ctl, "icon-check", 20, function() ns.Engine.MarkDone() end, "Mark this step done"),
    skip = Style.IconButton(f.ctl, "btn-skip", 20, function() ns.Engine.Skip() end, "Skip this step (a skipped quest's later steps go too)"),
    undo = Style.IconButton(f.ctl, "btn-undo", 20, function() ns.Engine.Undo() end, "Undo the last skip / done"),
    list = Style.IconButton(f.ctl, "btn-list", 20, function() ns.Fire("FR_TOGGLE_LIST") end, "The whole route  (/fr list)"),
    dungeon = Style.IconButton(f.ctl, "icon-kill", 20, function() ns.Fire("FR_TOGGLE_DUNGEONS") end, "Side trips: class quests, bonus items and dungeons  (/fr dungeons)"),
    min = Style.IconButton(f.ctl, "btn-min", 20, function() ns.db.collapsed = not ns.db.collapsed; Card.Update(); if ns.Zones then ns.Zones.Update() end end, "Collapse / expand"),
    opt = Style.IconButton(f.ctl, "btn-gear", 20, function() ns.Fire("FR_OPEN_OPTIONS") end, "Options"),
    -- "this looks wrong": the moment kept for a bug report (Moments.lua), the flag turning green a moment to say so
    flag = Style.IconButton(f.ctl, "btn-flag", 20, function(self) Card.FlagMoment(self) end, Card.FLAG_TIP),
    -- home base: a dungeon or side trip: back to your leveling path; a zone you picked or your plan: the zone picker
    -- (another zone, or your planned route where it picks up); a zone you picked that is done: your planned route's
    -- next zone (Card.Fill sets carryOn). A house in the hover bar: as a text button on the footer line it sat under
    -- the controls when you hovered the card (1.6.5)
    home = Style.IconButton(f.ctl, "btn-home", 20, function(self)
      local d = ForeverRouteData
      if ns.Engine.Finishing() then ns.Engine.SetFinishing(false) -- (finishing your quests at 60: back to the level 60 card)
      elseif d and d.dungeon then ns.LeaveDungeonRoute()
      elseif self.carryOn and ns.Paths and ns.Paths.Pick then ns.Paths.Pick(self.carryOn)
      elseif ns.Paths and ns.Paths.Show then ns.Paths.Show() end
    end, { "Change home base", "Pick another home base, or go back to your plan. Progress here is kept." }),
  }
  for _, b in pairs(f.btn) do b:HookScript("OnLeave", function() Card.Hover(false) end) end
  f.ret = Style.Button(f, "Back to current step", 140, 18, function() ns.Engine.view = nil; ns.Fire("FR_STEP", ns.Engine.Shown()) end)
  -- level 60: the route is done (Engine.Capped). This finishes the quests you hold - their objectives and hand-ins, nothing
  -- new - and a second click (or the house) goes back to the level 60 card (Engine.SetFinishing)
  f.finish = Style.Button(f, "Finish my quests", 130, 18, function() ns.Engine.SetFinishing(not ns.Engine.Finishing()) end,
    "Finish the quests in your log: their objectives and hand-ins, nothing new picked up. Click again to stop.")
  f.finish:Hide()
  f.home = f.btn.home
  f.home.label = f.home:CreateFontString(nil, "ARTWORK"); f.home.label:SetFontObject(Style.Font(10)); f.home.label:Hide() -- (its name: the tooltip's first line)
  f.home:Hide()
  -- quests in your log you won't do (not on the route, or gray by then): a nudge that opens the log check
  f.drop = Style.Button(f, "", 90, 14, function() ns.Fire("FR_TOGGLE_LOGCHECK") end, "Quests in your log no route of yours uses. Click to look them over.")
  f.drop.label:SetFontObject(Style.Font(10)); f.drop.label:SetTextColor(1, 0.55, 0.3)
  f.drop:SetScript("OnLeave", function(self) self.label:SetTextColor(1, 0.55, 0.3); GameTooltip:Hide() end)
  f.drop:Hide()
  -- options that just opened up (a level-up brought new zones): one line, See options, dismiss
  f.offer = CreateFrame("Frame", nil, f); f.offer:SetHeight(20)
  f.offer.text = Style.Text(f.offer, 10, C.gold); f.offer.text:SetPoint("LEFT", 0, 0); f.offer.text:SetWordWrap(false)
  f.offer.go = Style.Button(f.offer, "Zones", 56, 18, function() ns.Fire("FR_TOGGLE_PATHS") end, "Where to? - the zones you could go to now. Nothing changes unless you pick one.")
  f.offer.go:SetPoint("RIGHT", f.offer, "RIGHT", -20, 0)
  f.offer.x = Style.Button(f.offer, "x", 16, 16, function() ns.Offers.Dismiss() end, "Hide this until your next level")
  f.offer.x:SetPoint("RIGHT", f.offer, "RIGHT", 0, 0)
  f.offer.text:SetPoint("RIGHT", f.offer.go, "LEFT", -6, 0)
  f.offer:Hide()
  -- on a flight: a good moment to save (reload) so the planner gets your progress
  f.save = CreateFrame("Frame", nil, f); f.save:SetHeight(20)
  f.save.text = Style.Text(f.save, 10, { 0.55, 0.85, 1 }); f.save.text:SetPoint("LEFT", 0, 0); f.save.text:SetWordWrap(false)
  f.save.go = Style.Button(f.save, "Reload", 64, 18, function() Card.Save() end, "Reload (a few seconds) to load the new route.")
  f.save.go:SetPoint("RIGHT", f.save, "RIGHT", -20, 0)
  f.save.x = Style.Button(f.save, "x", 16, 16, function() if Card.planReady then Card.readyDismissed = true else Card.saveDismissed = true end; Card.Layout() end, "Not now")
  f.save.x:SetPoint("RIGHT", f.save, "RIGHT", 0, 0)
  f.save.text:SetPoint("RIGHT", f.save.go, "LEFT", -6, 0)
  f.save:Hide()
  -- after a reload into a new plan: what changed on your path and why (once per plan; the companion writes it)
  f.change = CreateFrame("Frame", nil, f); f.change:SetHeight(20); f.change:EnableMouse(true)
  f.change.text = Style.Text(f.change, 10, { 0.85, 0.8, 1 }); f.change.text:SetPoint("LEFT", 0, 0); f.change.text:SetWordWrap(false)
  f.change.ok = Style.Button(f.change, "OK", 34, 18, function()
    ns.char.changeSeen = ForeverRoutePlan and ForeverRoutePlan.generated; Card.Layout()
  end, "Got it")
  f.change.ok:SetPoint("RIGHT", f.change, "RIGHT", 0, 0)
  f.change.text:SetPoint("RIGHT", f.change.ok, "LEFT", -6, 0)
  f.change:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:AddLine("Your plan was updated", 1, 0.82, 0.3)
    GameTooltip:AddLine(Card.ChangeNote() or "", 1, 1, 1, true); GameTooltip:Show()
  end)
  f.change:SetScript("OnLeave", function() GameTooltip:Hide() end)
  f.change:Hide()
  -- a special reward not done yet (the Cozy Sleeping Bag): one line, Do it now, dismiss
  f.special = CreateFrame("Frame", nil, f); f.special:SetHeight(20)
  f.special.text = Style.Text(f.special, 10, C.gold); f.special.text:SetPoint("LEFT", 0, 0); f.special.text:SetWordWrap(false)
  f.special.go = Style.Button(f.special, "Do it now", 70, 18, function() local r = f.special.route; if r then ns.EnterDungeonRoute(r.id) end end, "Switch to this side trip now. \"Back to plan\" on the card returns you.")
  f.special.go:SetPoint("RIGHT", f.special, "RIGHT", -20, 0)
  f.special.x = Style.Button(f.special, "x", 16, 16, function() local r = f.special.route; if r then ns.char.hideSpecial = ns.char.hideSpecial or {}; ns.char.hideSpecial[r.id] = true; Card.Layout() end end, "Hide this here (it stays under Side trips)")
  f.special.x:SetPoint("RIGHT", f.special, "RIGHT", 0, 0)
  f.special.text:SetPoint("RIGHT", f.special.go, "LEFT", -6, 0)
  f.special:Hide()
  -- errands: bags nearly full / gear wearing out, with the nearest vendor that can help
  f.errand = CreateFrame("Frame", nil, f); f.errand:SetHeight(20)
  f.errand.text = Style.Text(f.errand, 10, { 0.55, 0.85, 1 }); f.errand.text:SetPoint("LEFT", 0, 0); f.errand.text:SetWordWrap(false)
  f.errand.x = Style.Button(f.errand, "x", 16, 16, function() ns.Errands.Dismiss() end, "Hide until it changes")
  f.errand.x:SetPoint("RIGHT", f.errand, "RIGHT", 0, 0)
  f.errand.text:SetPoint("RIGHT", f.errand.x, "LEFT", -6, 0)
  f.errand:Hide()
  -- a finished quest whose hand-in is close by (Engine.ReadyNearby): one line, Do it now
  f.ready = CreateFrame("Frame", nil, f); f.ready:SetHeight(20)
  f.ready.text = Style.Text(f.ready, 10, { 0.45, 0.78, 1 }); f.ready.text:SetPoint("LEFT", 0, 0); f.ready.text:SetWordWrap(false)
  f.ready.go = Style.Button(f.ready, "Do it now", 70, 18, function() local r = Card.readyNear; if r then ns.Engine.FocusOn(r.i, "you chose it: ready to hand in nearby") end end, "Show this hand-in on the card now. Your plan is kept - it comes back after.")
  f.ready.go:SetPoint("RIGHT", f.ready, "RIGHT", 0, 0)
  f.ready.text:SetPoint("RIGHT", f.ready.go, "LEFT", -6, 0)
  f.ready:Hide()
  -- a quest an item in your bags starts (ns.ItemQuests): a line (two when it needs them) and "x". The use button is
  -- the card's use-item button above it: a secure button can't sit on a row, and rows move in combat
  f.itemq = CreateFrame("Frame", nil, f); f.itemq:SetHeight(28); f.itemq:EnableMouse(true)
  f.itemq.text = Style.Text(f.itemq, 10, C.gold); f.itemq.text:SetPoint("LEFT", 0, 0); f.itemq.text:SetWordWrap(true); f.itemq.text:SetJustifyH("LEFT")
  f.itemq.x = Style.Button(f.itemq, "x", 16, 16, function() ns.ItemQuests.Dismiss() end, "Not doing it: this quest isn't offered again (the item stays in your bags)")
  f.itemq.x:SetPoint("RIGHT", f.itemq, "RIGHT", 0, 0)
  f.itemq:SetScript("OnEnter", function(self)
    local o = ns.ItemQuests and ns.ItemQuests.Current()
    if not o then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:AddLine(o.name, 1, 0.82, 0.3)
    GameTooltip:AddLine(f.cur.offerItem and "Click the item's icon above the card to start it." or "Use it from your bags to start it (the button above the card is this step's own item).", 1, 1, 1, true)
    GameTooltip:AddLine("Once you have it, its objectives and hand-in are added to your route where they cost least. " .. o.xp .. " xp.", 0.75, 0.8, 0.88, true)
    GameTooltip:Show()
  end)
  f.itemq:SetScript("OnLeave", GameTooltip_Hide)
  f.itemq:Hide()
  -- "Also hand in": a finished quest the route doesn't cover, with its NPC nearby
  f.extra = CreateFrame("Frame", nil, f); f.extra:SetHeight(20)
  f.extra.text = Style.Text(f.extra, 10, { 0.45, 0.78, 1.0 }); f.extra.text:SetPoint("LEFT", 0, 0); f.extra.text:SetPoint("RIGHT", 0, 0); f.extra.text:SetWordWrap(false)
  f.extra:Hide()

  f:SetScript("OnEnter", function() Card.Hover(true) end)
  f:SetScript("OnLeave", function() Card.Hover(false) end)
  f:SetScript("OnHide", function() if InCombatLockdown() then Card.needPlace = true else cur.target:Hide(); cur.item:Hide(); for _, b in ipairs(cur.targets) do b:Hide() end end end)
  f:SetScript("OnShow", function() C_Timer.After(0, function() Card.PlaceSecure() end) end)

  Style.Scaled(f, "scale") -- the Forever Route scale x the card's own
  Card.ApplyPos() -- at its saved place for this scale, or the default place if that's off the screen
  C_Timer.After(0, function() Card.ApplyPos() end)
end

-- the "N won't do" link: at the right of the footer, or - while you hover the card and its controls take that spot -
-- at the left, where the footer line fades out. It used to hide on hover, so the mouse on its way to click it
-- made it vanish (tester)
-- the rows under the card's step (each shown by Card.Layout when it has something to say)
function Card.ExtraRows()
  return { home = f.home, offer = f.offer, errand = f.errand, ready = f.ready, itemq = f.itemq, special = f.special, extra = f.extra, save = f.save }
end
function Card.PlaceDrop(hover)
  if not f or not f.drop then return end
  f.drop:ClearAllPoints()
  -- (after "Back to my path" / "Change zone" when it is there: at the footer line's start it sat on that button - tester)
  local full, short = f.dropText or "", f.dropCount and tostring(f.dropCount) or ""
  f.drop.label:SetText(full); f.drop:SetWidth(f.drop.label:GetStringWidth() + 12)
  local show = f.dropWanted and true or false
  if hover then
    f.drop:SetPoint("LEFT", f.eta, "LEFT", -6, 0)
    -- the room before the controls: "13 won't do" ran under them (beside "Change zone" - tester). Too narrow: the
    -- count alone (its tooltip says what it is), against the controls' left edge - always there to click (hidden for
    -- want of room, it vanished as the mouse went to it - tester)
    local ctlLeft, ctlBtn
    for _, b in pairs(f.btn) do if b:IsShown() and b:GetLeft() and (not ctlLeft or b:GetLeft() < ctlLeft) then ctlLeft, ctlBtn = b:GetLeft(), b end end
    local etaLeft = f.eta:GetLeft()
    if ctlLeft and etaLeft and f.drop:GetWidth() > ctlLeft - (etaLeft - 6) - 4 then
      f.drop.label:SetText(short); f.drop:SetWidth(f.drop.label:GetStringWidth() + 12)
      f.drop:ClearAllPoints(); f.drop:SetPoint("RIGHT", ctlBtn, "LEFT", -4, 0)
      f.drop:SetFrameLevel(math.max(f.drop:GetFrameLevel(), f.ctl:GetFrameLevel() + 2))
    end
  else f.drop:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD + 6, f.dropY or 0) end
  f.drop:SetShown(show)
end
function Card.Hover(on)
  if not f then return end
  if not on then
    C_Timer.After(0.2, function() if f and not f:IsMouseOver() and f.ctl:GetAlpha() > 0 then Card.hovering = false; UIFrameFadeOut(f.ctl, 0.2, f.ctl:GetAlpha(), 0); UIFrameFadeIn(f.eta, 0.2, f.eta:GetAlpha(), 1); Card.PlaceDrop(false) end end)
    return
  end
  -- (the link moves left whenever the controls are up: back over the card before they had faded, it stayed under them -
  -- '9 won't do' on top of the buttons, tester)
  Card.hovering = true
  if f.ctl:GetAlpha() < 1 then UIFrameFadeIn(f.ctl, 0.12, f.ctl:GetAlpha(), 1); UIFrameFadeOut(f.eta, 0.12, f.eta:GetAlpha(), 0) end
  Card.PlaceDrop(true)
end

-- "where next?" option rows: zone, XP/h and the zones that follow; the open option is marked, the fastest gets a star
local function choiceRow(k)
  local cur = f.cur
  cur.optRows = cur.optRows or {}
  local r = cur.optRows[k]
  if r then return r end
  r = CreateFrame("Button", nil, cur); r:SetHeight(40)
  r.bgParts = Style.Nine(r, "panel", "BACKGROUND", 0, 8, 0, 1, 1, 1, 0.05)
  r.edge = r:CreateTexture(nil, "ARTWORK"); r.edge:SetTexture(Style.WHITE); r.edge:SetWidth(2); r.edge:SetPoint("TOPLEFT", 2, -5); r.edge:SetPoint("BOTTOMLEFT", 2, 5)
  local hl = r:CreateTexture(nil, "HIGHLIGHT"); hl:SetTexture(Style.WHITE); hl:SetPoint("TOPLEFT", 2, -2); hl:SetPoint("BOTTOMRIGHT", -2, 2); hl:SetVertexColor(1, 0.82, 0.36, 0.08)
  r.name = Style.Text(r, 13, C.text, "OUTLINE"); r.name:SetPoint("TOPLEFT", 12, -6); r.name:SetWordWrap(false)
  r.fast = Style.Pill(r, "PLAN", C.good)
  r.sel = Style.Pill(r, "SELECTED", C.gold)
  r.rate = Style.Text(r, 11, C.gold); r.rate:SetPoint("TOPRIGHT", -10, -7); r.rate:SetJustifyH("RIGHT")
  r.lvl = Style.Text(r, 10, C.dim); r.lvl:SetPoint("TOPRIGHT", r.rate, "BOTTOMRIGHT", 0, -3); r.lvl:SetJustifyH("RIGHT")
  r.next = Style.Text(r, 10, C.dim); r.next:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -3); r.next:SetPoint("RIGHT", r.lvl, "LEFT", -6, 0); r.next:SetWordWrap(false)
  r:SetScript("OnClick", function(self) if self.zrow and ns.Paths and ns.Paths.Pick then ns.Paths.Pick(self.zrow) end end)
  r:SetScript("OnEnter", function(self)
    Card.Hover(true)
    local z = self.zrow
    if not z then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText(z.zone, 1, 1, 1)
    GameTooltip:AddLine(z.best and "Back to plan: where your plan goes next" or "Make it your home base", 0.5, 0.55, 0.62, true)
    GameTooltip:Show()
  end)
  r:SetScript("OnLeave", function() GameTooltip:Hide(); Card.Hover(false) end)
  cur.optRows[k] = r
  return r
end

local function fillChoice()
  local cur = f.cur
  for _, r in ipairs(cur.optRows or {}) do r:Hide() end
  local ch = cur.choice
  if not ch then return end
  -- next home bases (a home base done for now): zone, XP left, the level it gets you to, a chain it continues
  if ch.rows then
    for k, z in ipairs(ch.rows) do
      local r = choiceRow(k)
      r.zrow = z
      local zc = Style.ZoneColor(z.zone)
      r.name:SetText(Style.ShortZone(z.zone)); r.name:SetTextColor(zc[1], zc[2], zc[3])
      r.fast:ClearAllPoints(); r.fast:SetPoint("LEFT", r.name, "RIGHT", 7, 0); r.fast:SetShown(z.best and true or false)
      r.sel:Hide()
      local P = ns.Paths
      r.rate:SetText(z.xpLeft and z.xpLeft > 0 and P and P.Short and ("~" .. P.Short(z.xpLeft) .. " XP") or "")
      local lv = z.xpLeft and z.xpLeft > 0 and P and P.Levels and P.Levels(z.xpLeft)
      local L, m = (UnitLevel and UnitLevel("player")) or 1, (UnitXPMax and UnitXPMax("player")) or 0
      local at = lv and (L + (m > 0 and ((UnitXP and UnitXP("player")) or 0) / m or 0) + lv)
      r.lvl:SetText(lv and lv >= 0.05 and string.format("to %.1f", math.min(60, math.floor(at * 10) / 10)) or "")
      local away = z.tripSecs and P and P.Away and P.Away(z.tripSecs) or nil
      local reason = z.continues and ("continues " .. z.continues) or (z.handIns and z.handIns > 0 and (z.handIns .. " hand-in" .. (z.handIns == 1 and "" or "s") .. " waiting")) or nil
      r.next:SetText((away and reason) and (away .. " · " .. reason) or away or reason or "")
      local c = z.best and C.good or C.dim
      r.edge:SetVertexColor(c[1], c[2], c[3], z.best and 0.9 or 0.3)
      for _, part in ipairs(r.bgParts or {}) do part:SetVertexColor(1, 1, 1, 0.04) end
      r:Show()
    end
    return
  end
  local best = 0
  for _, o in ipairs(ch.c.options) do best = math.max(best, o.xph or 0) end
  for k, o in ipairs(ch.c.options) do
    local r = choiceRow(k)
    r.opt, r.owner, r.key = o, ch.owner, ch.key
    local here = (o.route and ForeverRouteData and ForeverRouteData.id == o.route) or (o.main and ForeverRouteData == ch.owner)
    local zc = Style.ZoneColor(o.zone)
    r.name:SetText(o.zone); r.name:SetTextColor(zc[1], zc[2], zc[3])
    local isFast = (o.xph or 0) >= best
    -- keep the name and badges clear of the XP/h figure: shorten the name, then drop a badge if still too wide
    local room = (r:GetWidth() or 280) - 110
    local badges = (isFast and 54 or 0) + (here and 64 or 0)
    if r.name:GetStringWidth() + badges > room then r.name:SetText(Style.ShortZone(o.zone)) end
    if r.name:GetStringWidth() + badges > room and here then isFast = false end
    r.fast:ClearAllPoints(); r.fast:SetPoint("LEFT", r.name, "RIGHT", 7, 0); r.fast:SetShown(isFast)
    r.sel:ClearAllPoints(); r.sel:SetPoint("LEFT", isFast and r.fast or r.name, "RIGHT", isFast and 4 or 7, 0); r.sel:SetShown(here and true or false)
    r.rate:SetText(o.xph and string.format("%.1fk xp/h", o.xph / 1000) or "")
    -- the zones after this one (two of them fit), and where the plan ends on the right
    local rest = {}
    for z in (o.next or ""):gmatch("[^>]+") do rest[#rest + 1] = z:gsub("^%s+", ""):gsub("%s+$", "") end
    table.remove(rest, 1)
    r.next:SetText(#rest > 0 and ("then " .. rest[1] .. (rest[2] and (" > " .. rest[2]) or "") .. (rest[3] and " ..." or "")) or "")
    r.lvl:SetText(o.endLevel and ("ends level " .. o.endLevel) or "")
    local c = here and C.gold or C.dim
    r.edge:SetVertexColor(c[1], c[2], c[3], here and 0.95 or 0.3)
    for _, part in ipairs(r.bgParts or {}) do part:SetVertexColor(1, 1, 1, here and 0.075 or 0.035) end
    r:Show()
  end
end

local function setNote(text, color)
  local c = color or C.sub
  f.cur.note:SetText(text or ""); f.cur.note:SetTextColor(c[1], c[2], c[3])
end

-- a travel step's note minus the planner's generic travel advice ("Fly, or ride if there is no flight path yet."):
-- once the addon has a live trip from the flight paths you know, that sentence only contradicts it. What follows
-- it ("Next leg: Ashenvale 22+") and any hand-written instruction stay. nil when nothing is left.
-- the step's note, with what the game says about its gear reward (Quests.lua RewardNote)
function Card.Note(s) return s and (ns.Quests and ns.Quests.RewardNote and ns.Quests.RewardNote(s) or s.note) end
function Card.OwnNote(s)
  local n = Card.Note(s)
  if not n then return nil end
  n = n:gsub("^Fly, or ride[^.]*%.%s*", "")
  return n ~= "" and n or nil
end

-- The trip the card leads with, when reaching step s means more than a walk: a travel step's live trip, any trip of
-- several legs, one that starts with a flight, a boat, a portal or the hearthstone, and "sit tight" on a flight or a boat.
-- The card's title is then the leg you're on ("Fly to Westfall", not "Travel to Stranglethorn Vale" over a numbered list
-- of every leg: "no one is going to read all of this" - the player), its detail where it ends ("then on to Stranglethorn
-- Vale"), and the other legs are in the "?" (UI/Explain.lua). A ride straight to the step keeps the step's own title.
-- -> trip, legs; nil
local LEG_KIND = { fly = "fly", via = "fly", onflight = "fly", ride = "ride", boat = "boat", aboard = "boat", hearth = "hearth" }
local TRIP_LONG = { fly = true, boat = true, hearth = true, spell = true, via = true }
function Card.TripHead(s)
  if not (s and s.k ~= "hearth" and ns.Engine.TravelFor) then return nil end
  if ns.Engine.view and s.k ~= "fly" then return nil end
  local trip = ns.Engine.TravelFor(s)
  local legs = trip and (trip.legs or { trip })
  if not (legs and legs[1]) then return nil end
  if s.k == "fly" or #legs > 1 or trip.how == "aboard" or TRIP_LONG[legs[1].how] then return trip, legs end
  return nil
end
-- the headline: the leg you're on, its verb in the leg's colour -> kind, title, plain headline
function Card.TripTitle(legs)
  local l1 = legs[1]
  local kind = Style.KIND[LEG_KIND[l1.how] or "travel"] or Style.KIND.travel
  local head = (ns.Travel and ns.Travel.LegSay(l1)) or l1.text or ""
  local verb, rest = head:match("^(%S+)%s+(.+)$")
  return kind, verb and (Style.Hex(kind.color) .. verb .. "|r " .. rest) or (Style.Hex(kind.color) .. head .. "|r"), head
end
-- the line under it: where the trip ends. A travel step: "then on to Stranglethorn Vale" (nothing when the headline
-- already goes there); a quest step: "then Accept Hearts of the Lost in Wetlands"
function Card.TripGoal(s, legs, head)
  if s.k == "fly" then
    local place = s.boat and ((s.text or ""):match("^Boat to (.+)$") or s.dest) or s.dest or s.text
    if not place or (#legs == 1 and (head or ""):find(place, 1, true)) then return nil end
    return "then on to " .. place
  end
  local what = plain((Card.Describe(s)))
  local pm = ns.State.Position()
  local zone = (s.zone and s.m and pm ~= s.m and not what:find(s.zone, 1, true)) and (" in " .. Style.ShortZone(s.zone)) or ""
  return "then " .. what .. zone
end
-- the card's lines for the trip under its headline, one short line each: a flight path to pick up first, what the leg
-- you're on warns of, why you go (Explain.CardLine) and, on a long trip, the leg after it, dimmed. headed = the title is
-- the leg (Card.TripHead); not headed (a ride straight to the step), the leg leads the lines.
function Card.TripLines(i, trip, headed)
  local legs = trip.legs or { trip }
  local l1 = legs[1]
  local lines = {}
  if not headed then lines[#lines + 1] = ns.Travel.LegSay(l1) .. "." end
  if l1.fp and l1.fp.npc then
    lines[#lines + 1] = "|cffffd25aGet the flight path from " .. l1.fp.npc .. " first" .. ((l1.fp.here and l1.fp.yd) and (" (" .. Style.Distance(l1.fp.yd) .. ")") or " (on the way)") .. "|r"
  end
  local extra = ns.Travel.LegExtra(l1)
  if extra then lines[#lines + 1] = (l1.hostile and Style.Hex(C.warn) or "|cff8e99ad") .. extra:sub(1, 1):upper() .. extra:sub(2) .. ".|r" end
  local why = ns.Explain and ns.Explain.CardLine(i)
  if why then lines[#lines + 1] = "|cffffd25a" .. why .. "|r" end
  if headed and legs[3] then lines[#lines + 1] = "|cff8a93a6Next: " .. ns.Travel.LegSay(legs[2]) .. "|r" end
  return lines
end

local function objectiveBar(bar, s, o, kind, idx)
  bar.live = { s = s, kind = kind, idx = idx } -- (Card.Counts redraws it from this)
  if o and o.need and o.need > 0 then
    -- the count is shown on the right: drop it from the text, whether it comes first ("0/1 Thing") or last ("Thing: 0/1")
    local label = o.text:gsub(":%s*%d+%s*/%s*%d+%s*$", ""):gsub("^%s*%d+%s*/%s*%d+%s*", "")
    bar:Set(o.have / o.need, kind.color, label, string.format("%d/%d", o.have, o.need))
  else
    bar:Set(o and o.finished and 1 or 0, kind.color, plain((Card.Describe(s))), "")
  end
  bar:Show()
end

-- Inside a dungeon: the game gives no coordinates in there, so no plan step can be pointed at. The card shows the
-- dungeon and what your quest log has for it instead (Dungeon.lua): each quest with a live bar per objective, the
-- finished ones ticked; quests picked up inside; and the ones you could have brought but didn't. The plan's own step
-- is the first line of the timeline below. Walking out brings the normal card back.
Card.DUNGEON_BARS = 12 -- bars at most; quests past that are one line each in the note
local TICK = "|T" .. Style.MEDIA .. "icon-check:12|t "
local function namesOf(list, max)
  local t, seen, u = {}, {}, {}
  for _, e in ipairs(list) do if not seen[e.name] then seen[e.name] = true; u[#u + 1] = e end end
  list = u
  for k, e in ipairs(list) do
    if k > max then t[#t + 1] = string.format("+%d more", #list - max); break end
    t[#t + 1] = e.name .. (e.from and (" |cff8e99ad(" .. e.from .. ")|r") or "")
  end
  return table.concat(t, ", ")
end
function Card.FillDungeon(name, id, bar, look)
  local cur = f.cur
  local st = ns.Dungeon.State(id)
  local kind = Style.KIND.obj
  look(kind.color, "icon-kill")
  cur.dungeon = { name = name, id = id, done = st.done, total = st.total }
  cur.titleText:SetText(Style.Hex(Style.ZoneColor(name)) .. name .. "|r")
  local left = 0
  for _, q in ipairs(st.quests) do if not q.ready then left = left + 1 end end
  if #st.quests == 0 then cur.detail:SetText("Nothing in your quest log is done in here")
  elseif left == 0 then cur.detail:SetText(string.format("All %d quest%s for here done", #st.quests, #st.quests == 1 and "" or "s"))
  else cur.detail:SetText(string.format("%d quest%s to do in here%s", left, left == 1 and "" or "s", #st.quests > left and string.format("  ·  %d done", #st.quests - left) or "")) end
  cur.dist:SetText("")
  local lines, over = {}, {}
  local function head(text)
    local n = cur.nbars + 1 -- sits above the next bar
    local h = cur.heads[n]
    if not h then h = Style.Text(cur, 11, C.text); h:SetWordWrap(false); h:SetJustifyH("LEFT"); cur.heads[n] = h end
    h:SetText(text); cur.headAt[n] = h
  end
  for _, q in ipairs(st.quests) do
    local title = Style.Hex(C.gold) .. q.name .. "|r"
    if q.ready then
      lines[#lines + 1] = TICK .. "|cff5cdc7a" .. q.name .. "|r |cff8e99ad- done|r"
    elseif cur.nbars + math.max(1, #q.objectives) > Card.DUNGEON_BARS then
      local n = 0
      for _, o in ipairs(q.objectives) do if not o.finished then n = n + 1 end end
      over[#over + 1] = q.name .. (n > 0 and string.format(" |cff8e99ad(%d left)|r", n) or "")
    else
      head(title)
      if #q.objectives == 0 then local b = bar(); b:Set(0, kind.color, "See your quest log", ""); b:Show() end
      for _, o in ipairs(q.objectives) do
        local b = bar()
        if o.need > 0 then
          local label = o.text:gsub(":%s*%d+%s*/%s*%d+%s*$", ""):gsub("^%s*%d+%s*/%s*%d+%s*", "")
          b:Set(o.finished and 1 or o.have / o.need, kind.color, label, string.format("%d/%d", o.have, o.need))
        else
          b:Set(o.finished and 1 or 0, kind.color, o.text, "")
        end
        b:Show()
      end
    end
  end
  if #over > 0 then table.insert(lines, 1, "Also: " .. table.concat(over, ", ")) end
  if #st.inside > 0 then lines[#lines + 1] = Style.Hex(C.gold) .. "Picked up in here:|r " .. namesOf(st.inside, 4) end
  if #st.missed > 0 then lines[#lines + 1] = "|cff8a93a6Not picked up:|r " .. namesOf(st.missed, 4) end
  setNote(table.concat(lines, "\n"), C.sub)
  f.title:SetText("|cffff7a6b" .. name:upper() .. "|r  |cff8a93a6DUNGEON|r")
  Card.UpdateProgress()
  Card.SetButtons(nil)
end

function Card.Fill()
  if not f then return end
  local cur = f.cur
  local i = ns.Engine.Shown()
  for _, b in ipairs(cur.bars) do b:Hide(); b.live = nil end
  -- (pairs: the quest titles are kept by the number of the bar they sit over - 1, 4, 7 - and ipairs stopped at the
  -- first gap, leaving old titles ("Past Due") floating over the dungeon card - tester)
  for _, h in pairs(cur.heads) do h:Hide() end
  cur.headAt = {}
  local wasDungeon = cur.dungeon
  cur.dungeon = nil
  cur.doneData, cur.doneLvl, cur.celebrate = nil, nil, nil -- (set again below while the plan stays finished: Card.UpdateInner)
  cur.nbars = 0
  cur.choice = nil; for _, r in ipairs(cur.optRows or {}) do r:Hide() end
  cur.map:Hide(); cur.nope:Hide(); cur.notOffered:Hide(); cur.notNow:Hide(); cur.fq:Hide(); cur.why:Hide(); cur.noChain:Hide()
  local function bar() cur.nbars = cur.nbars + 1; local b = cur.bars[cur.nbars]; if not b then b = Style.Bar(cur); cur.bars[cur.nbars] = b end; return b end
  local function look(color, glyph)
    cur.disc:SetVertexColor(color[1], color[2], color[3]); cur.halo:SetVertexColor(color[1], color[2], color[3], 0.35)
    cur.accent:SetVertexColor(color[1], color[2], color[3], 0.9); cur.icon:SetTexture(Style.MEDIA .. glyph)
  end
  local data = ns.Demo and ns.Demo.active and ns.Demo.data or ForeverRouteData
  -- inside a dungeon the card is about the dungeon (not while you look at another step, or in the demo)
  if not ns.Engine.view and not (ns.Demo and ns.Demo.active) and ns.Dungeon then
    local dname, did = ns.Dungeon.Inside()
    if did then Card.FillDungeon(dname, did, bar, look); return end
  end
  if wasDungeon then Card.Header(); Card.UpdateProgress() end -- back out: the plan's own header again
  if not data then
    look(C.dim, "icon-note"); cur.titleText:SetText("No route loaded"); cur.detail:SetText("/reload to load the plan for your race and class."); setNote("")
    Card.SetButtons(nil); return
  end
  -- a zone you picked with only quests left that wait (a level, an earlier quest): done for now - the card sat on a
  -- waiting pick-up instead and never said so (tester)
  local WAITING = { wait = true, blocked = true, later = true }
  local forNow = data.zoneRoute and i and not ns.Engine.view and WAITING[ns.Engine.Status(i)] or false
  -- (the plan the same, when nothing on it is to do now - Engine.forNow: a level 59 at its last training was shown
  -- "Nothing to learn until level 60" with three zones' quests open - mutate --play)
  local planForNow = not forNow and i and not ns.Engine.view and ns.Engine.forNow and not (data.zoneRoute or data.dungeon or data.special or data.branch)
    and WAITING[ns.Engine.Status(i)] or false
  -- your best few zones now, to pick the next home base from (here: the zone you stand in too)
  local function nextBases(here)
    local opts = {}
    local zc = ns.ZoneChoices and ns.ZoneChoices()
    if zc then
      local rows = {}
      for _, r in ipairs(zc.rows or {}) do if (r.route or r.planned) and (here or not r.here) then rows[#rows + 1] = r end end
      table.sort(rows, function(a, b)
        if (a.best and 1 or 0) ~= (b.best and 1 or 0) then return a.best and true or false end
        local ra, rb = ns.ZoneRate and ns.ZoneRate(a), ns.ZoneRate and ns.ZoneRate(b)
        if ra and rb and ra ~= rb then return ra > rb end
        return (a.xpLeft or 0) > (b.xpLeft or 0)
      end)
      for k = 1, math.min(3, #rows) do opts[#opts + 1] = rows[k] end
    end
    return opts
  end
  -- (at level 60 the plan is done, whatever steps are left - Engine.Capped: no more questing, no next home base to level
  -- in. "to 60.0" zone rows, "opens at level 60" were the plan-finished card at the cap; the replay oracle read NO-STEP)
  local maxed = ((UnitLevel and UnitLevel("player")) or 1) >= ns.Engine.MAX_LEVEL
  local POINTER = " Dungeons and quests you skipped are on the route window."
  if planForNow then
    look(C.good, "icon-check")
    -- (the step waiting stays the plan's: it comes back as the card's step once it opens)
    local why, _, lv = ns.Engine.NotYet(i)
    -- (zone rows only: the plan's own row is where you are)
    local opts = {}
    for _, r in ipairs(nextBases(true)) do if r.route and (r.questsLeft or 0) > 0 then opts[#opts + 1] = r end end
    cur.titleText:SetText("Route done for now")
    cur.detail:SetText(((why == "level" and lv) and ("Its next step opens at level " .. lv .. ". ") or "Its next steps wait for earlier quests. ")
      .. (#opts > 0 and "Pick your next home base:" or "Other zones: Where to? on the route window."))
    if #opts > 0 then cur.choice = { rows = opts }; fillChoice() end
    setNote("")
    Card.SetButtons(nil); return
  end
  if not i or forNow then
    look(C.good, "icon-check")
    if data.dungeon then cur.titleText:SetText((data.dungeonName or "Dungeon") .. " route done"); cur.detail:SetText("Everything for it is handed in. \"Back to plan\" carries on leveling.")
    elseif data.zoneRoute then
      -- a zone you picked, done: "Carry on" goes where your planned route picks up; the route list has the other zones.
      -- Only once it has stayed done a few seconds: stops are added just after a login or a route change (a hand-in
      -- you finished, a side quest), and "done" can be true for a moment before they are
      Card.zoneDoneSince = Card.zoneDoneSince or (GetTime and GetTime()) or 0
      -- (and where to go next: your best few zones now - the zone you work from is yours to pick, the card says when it's
      -- time to pick again)
      local later, openAt, byLevel = 0, nil, true
      if forNow then
        for j, t in ipairs(steps()) do
          if t.k == "accept" and WAITING[ns.Engine.Status(j)] then
            later = later + 1
            if t.minLevel and t.minLevel > ((UnitLevel and UnitLevel("player")) or 1) then openAt = math.min(openAt or 99, t.minLevel) else byLevel = false end
          end
        end
      end
      local opts = nextBases(false)
      cur.titleText:SetText((Style.ShortZone(data.zoneName or "Zone")) .. (forNow and " done for now" or " done"))
      local wait = ""
      if forNow and later > 0 then
        wait = later .. (later == 1 and " quest here opens " or " quests here open ") .. ((byLevel and openAt) and ("at " .. openAt) or "later") .. ". "
      end
      cur.detail:SetText(wait .. (#opts > 0 and "Pick your next home base:" or "Other zones: Where to? on the route window."))
      -- (clickable: the names alone could not be picked - persona review)
      if #opts > 0 then cur.choice = { rows = opts }; fillChoice() end
      if C_Timer and not Card.zoneDoneTick then Card.zoneDoneTick = true; C_Timer.After(3.5, function() Card.zoneDoneTick = nil; if ns.Card.Layout then ns.Card.Layout() end end) end
    elseif not i and ns.Engine.planDone and not (data.special or data.branch) then
      -- the plan finished: at 60, done (no rows - nothing left to level); below it, your next home bases
      -- (Card.UpdateInner fills it once: refreshes standing here change nothing on it)
      cur.doneData, cur.doneLvl, cur.doneFin = data, (UnitLevel and UnitLevel("player")) or 1, ns.Engine.Finishing()
      if maxed then
        -- (level 60: celebrate - the route is done. "Finish my quests" below, Card.Layout)
        cur.celebrate = true
        cur.titleText:SetText(Style.Hex(C.gold) .. "Level 60 - you made it!|r")
        cur.detail:SetText(cur.doneFin and "Congratulations! The quests you held are done too." or "Congratulations! Your leveling route is done." .. POINTER)
      else
        local opts = {}
        for _, r in ipairs(nextBases(true)) do if r.route and (r.questsLeft or 0) > 0 then opts[#opts + 1] = r end end
        cur.titleText:SetText("Route complete")
        cur.detail:SetText("You've finished your plan. " .. (#opts > 0 and "Pick your next home base:" or "Other zones: Where to? on the route window."))
        if #opts > 0 then cur.choice = { rows = opts }; fillChoice() end
      end
    else cur.titleText:SetText("Route complete"); cur.detail:SetText("That's the end of the plan.") end
    setNote("")
    Card.SetButtons(nil); return
  end
  Card.zoneDoneSince = nil -- (a step to show: the zone you picked is not done)
  local s = steps()[i]
  local kind = Style.Kind(s)
  local title, detail = Card.Describe(s)
  -- a trip: the leg you are on is the step you're on ("Fly to Westfall", then where it ends under it) - "Accept Hearts
  -- of the Lost" standing at the Stormwind flight master read as "why pick up quests?" (tester), and "Travel to
  -- Stranglethorn Vale" over three numbered legs didn't say what to do now (the player)
  local headTrip, headLegs = Card.TripHead(s)
  if headTrip then
    local head
    kind, title, head = Card.TripTitle(headLegs)
    detail = Card.TripGoal(s, headLegs, head)
  end
  look(kind.color, kind.icon)
  local status = ns.Engine.Status(i)
  local group = ns.Engine.Group(i)
  local multi = s.k == "obj" and #group > 0
  if multi then title = Style.Hex(kind.color) .. "Do these here|r" end
  cur.titleText:SetText(title)
  local bits = {}
  if detail and not multi then bits[#bits + 1] = detail end
  -- (the zone only when the header names another: "Redridge Mountains" under "OUT IN REDRIDGE" wrapped the coordinates)
  -- (a trip: not the far step's zone and coordinates - the detail says where it ends)
  do local sc = section(i); if s.zone and not headTrip and not (sc and sc.zone == s.zone) then bits[#bits + 1] = Style.ShortZone(s.zone) end end
  -- (an unknown step's spot is only its place in the order: no coordinates, no map button)
  if s.x and s.y and not s.unknown and not headTrip then bits[#bits + 1] = string.format("|cff8e99ad%.0f, %.0f|r", s.x * 100, s.y * 100) end
  -- the walking path knows the floor heights: say when the stop is upstairs (a tower top) or below (a cellar, a cave)
  -- (only indoors - outdoors a height difference is a hill, the same rule as the arrow)
  if s.z and s.z0 and math.abs(s.z - s.z0) >= 6 and ns.Arrow and ns.Arrow.Indoors and ns.Arrow.Indoors() then
    bits[#bits + 1] = string.format("|cff8fd3ff%s %d yd|r", s.z > s.z0 and "up" or "down", math.floor(math.abs(s.z - s.z0) + 0.5))
  end
  cur.detail:SetText(table.concat(bits, "  ·  "))
  cur.map:SetShown((s.m and s.x and not s.unknown) or s.k == "fly" or false)
  cur.nope:SetShown((s.q and s.q > 0 and not ns.Engine.view) and true or false)
  cur.notNow:SetShown((not ns.Engine.view and ns.Engine.planned and i ~= ns.Engine.planned and ns.Next and ns.Next.CanDismiss and ns.Next.CanDismiss(i)) and true or false)
  cur.notOffered:SetShown((s.k == "accept" and s.q and s.q > 0 and not ns.Engine.view and not ns.State.OnQuest(s.q)) and true or false)
  if s.k == "obj" and s.unknown then
    -- work the quest data lists none of: the game's own lines for the quest, as the quest log has them (none: one bar
    -- that says to look there)
    local q = ns.State.Quest(s.q)
    local objs = q and q.on and q.objectives or {}
    if #objs == 0 then local b = bar(); b:Set(0, kind.color, "See your quest log", ""); b:Show() end
    for n, o in ipairs(objs) do
      if o.need and o.need > 0 then objectiveBar(bar(), s, o, kind, n)
      else local b = bar(); b:Set(o.finished and 1 or 0, kind.color, o.text, ""); b:Show() end
    end
  elseif s.k == "obj" then
    objectiveBar(bar(), s, ns.Engine.ObjectiveFor(s), kind)
    for _, j in ipairs(group) do local g = steps()[j]; objectiveBar(bar(), g, ns.Engine.ObjectiveFor(g), Style.Kind(g)) end
  elseif s.k == "grind" then
    local need = UnitXPMax("player"); local b = bar(); b:Set(UnitXP("player") / need, kind.color, "Level " .. UnitLevel("player"), string.format("%d/%d", UnitXP("player"), need)); b:Show()
  end
  -- the step's own note: its status, a full quest log, its warnings, or how to get there
  local function stepNote()
    -- the thing to collect is in your bank: the quest only counts what's in your bags (the bank, a rested-XP stash) -
    -- take it out rather than farm it again
    if s.k == "obj" and s.item and ns.GetItemCount then
      local okA, all = pcall(ns.GetItemCount, s.item, true)
      local okB, bags = pcall(ns.GetItemCount, s.item, false)
      local banked = (okA and okB and tonumber(all) and tonumber(bags)) and (all - bags) or 0
      if banked > 0 then return string.format("You have %d in your bank: take %s out - the quest only counts what's in your bags.", banked, banked == 1 and "it" or "them"), C.gold end
    end
    if status == "blocked" then
      return "This quest isn't in your log. Accept it first, or skip - its later steps go too.", C.bad
    elseif status == "notready" then
      local left = {}
      local q = ns.State.Quest(s.q)
      for _, o in ipairs(q and q.objectives or {}) do if not o.finished then left[#left + 1] = o.text end end
      return "Not finished: " .. (#left > 0 and table.concat(left, ", ") or "objectives left"), C.warn
    elseif status == "later" and ns.Engine.NotYet(i) == "objectives" then
      -- a hand-in whose work (no place in the quest data) you skipped: it comes back when the quest is ready
      return "Finish this one as you go. It comes back when it's ready.", C.sub
    elseif status == "later" then
      return "Finish it inside the dungeon next time you run it.", C.sub
    elseif status == "wait" then
      -- (training: the trainer has nothing for you below the stop's level - not "not offered", a quest's words)
      local tl = s.k == "train" and ns.Engine.TrainFrom and ns.Engine.TrainFrom(i)
      if tl then return string.format("Nothing to learn until level %d.", tl) .. ((Card.Note(s) and ("  " .. Card.Note(s))) or ""), C.warn end
      local lv = s.minLevel or s.until_
      local red = ns.Engine.TooHigh and ns.Engine.TooHigh(s) -- (red to you: back within 4 levels of it)
      if red and (not lv or red > lv) then lv = red end
      if not lv and s.q and ns.QUEST_PRE and ns.QUEST_PRE[s.q] then
        local pre = ns.QUEST_PRE[s.q]
        for _, p in ipairs(pre.g or pre.s or {}) do
          if not ns.State.IsCompleted(p) then
            local n = ns.Engine.QuestName and ns.Engine.QuestName(p) or ("quest " .. p)
            return "Needs " .. n .. " handed in first. It comes back then.", C.warn
          end
        end
      end
      return (lv and string.format("Needs level %d.", lv) or "Not offered yet.") .. ((Card.Note(s) and ("  " .. Card.Note(s))) or ""), C.warn
    elseif s.k == "accept" and (status == "full" or ns.State.LogCount() >= ns.State.MaxLog()) then
      -- a warning on the quest itself (elites, an escort) still matters once there is room
      return string.format("Quest log full (%d/%d) - hand in or abandon something first.", ns.State.LogCount(), ns.State.MaxLog())
        .. ((s.warn and s.note) and ("\n" .. Style.Hex(C.warn) .. Card.Note(s) .. "|r") or ""), C.bad
    elseif s.k == "bonus" then
      return (s.where or "") .. (s.note and ("  |cff8e99ad" .. Card.Note(s) .. "|r") or ""), C.sub
    elseif ns.Drops and ns.Drops.Note(s) then
      -- the quest item drops far less than the plan assumed (Forever changed some rates)
      return ns.Drops.Note(s), C.warn
    elseif ns.Engine.TravelFor and ns.Engine.TravelFor(s) then
      -- the step is in another zone: how to get there from where you are
      local trip = ns.Engine.TravelFor(s)
      -- the step's own words (a hand-written "climb up onto Thoradin's Wall", "Next leg: ..."), without the
      -- planner's guess at how to travel, which the live trip replaces
      local own = Card.OwnNote(s)
      if trip.how == "aboard" and s.boat then own = nil end -- "Board the boat at the pier": done, you are on it
      own = own and ((s.warn and Style.Hex(C.warn) or "|cff8e99ad") .. own .. "|r")
      -- why go: what there is to do there, and where the route goes after (a zone change said only "accept this
      -- quest" with the trip folded in - tester)
      -- what to do now and why go, a short line each (Card.TripLines); every leg in full is in the "?"
      local lines = Card.TripLines(i, trip, headTrip ~= nil)
      if own then lines[#lines + 1] = own end
      return table.concat(lines, "\n"), C.sub
    elseif s.k == "fly" and s.to and not s.boat and ns.Engine.TravelPlan then
      -- from the flight paths you actually have, not the planner's guess
      local plan = ns.Engine.TravelPlan(s)
      local dest = s.dest or s.text or "there"
      local where = plan and plan.stop and (plan.stop.npc or plan.stop.name) or nil
      if not plan then return "You have the " .. dest .. " flight path - fly there.", C.sub
      elseif plan.ride and ns.Engine.KnowsFlightIn(dest) then return "Ride there - " .. (where or "your first stop") .. " is " .. (plan.yards and Style.Distance(plan.yards) or "close") .. " away, quicker than flying.", C.sub
      elseif plan.via then return "No " .. dest .. " flight path yet: fly to " .. plan.viaName .. ", then ride the rest (the arrow takes over when you land).", C.warn
      else return "Ride there" .. (where and (" - " .. where .. " is the first stop") or "") .. " (no closer flight path you know).", C.sub end
    end
    return Card.Note(s), s.warn and C.warn or C.sub
  end
  if ns.Engine.view then
    setNote("Just looking - your progress isn't changed.", C.sub)
  else
    local text, color = stepNote()
    -- a quest newer than the original game: the quest data for those is younger and can miss what unlocks them
    if s.k == "accept" and Card.IsNewQuest(s.q) then cur.fq:Show() end
    if s.chainStart and ns.Stitch and ns.Stitch.Refuse then cur.noChain:Show() end
    -- the same mobs nearer the quest giver, in fewer numbers (s.also = "Hillsbrad Foothills:16", route2.js): why the
    -- plan farms them further away - "it wants me in Alterac though they're clearly in Hillsbrad" (tester)
    local also = Card.AlsoNote(s)
    if also then text = (text and text ~= "") and (text .. "\n" .. also) or also end
    -- live reordering picked this step because you are at it: that is exactly when its warnings and the full-log
    -- alert matter, so they stay, and the plan's own next step is a dim line under them
    -- a hand-in run here: say it - the moment the questing was for
    local run = ns.Next and ns.Next.Batch and ns.Next.Batch(i)
    if run then
      local rl = string.format("|cffffd100Hand-in run here: %d quests, about %s XP|r", run.n, BreakUpLargeNumbers and BreakUpLargeNumbers(run.xp) or tostring(run.xp))
      text = (text and text ~= "") and (rl .. "\n" .. text) or rl
    end
    local planned = ns.Engine.planned
    if planned and i ~= planned and steps()[planned] then
      -- a short tag, not a sentence (the whole reason and the plan's step are its tooltip - persona review)
      local why = ns.Next and ns.Next.Enabled() and ns.Next.Reason(i) or ""
      local tag = ns.Next and ns.Next.Enabled() and ns.Next.Tag and ns.Next.Tag(i) or nil
      cur.why.label:SetText(tag or "picked from where you are")
      cur.why:SetWidth(cur.why.label:GetStringWidth() + 10)
      cur.why.tip = why ~= "" and (why:sub(1, 1):upper() .. why:sub(2)) or "Picked up from where you are"
      cur.why.tip2 = "Your plan's next step: " .. Card.Plain((Card.Describe(steps()[planned])))
      cur.why:Show()
    end
    -- (the options' "Step notes" off: hints go, warnings stay)
    if ns.db.cardNotes == false and color ~= C.warn and color ~= C.bad then text = "" end
    setNote(text, color)
  end
  cur.choice = nil
  fillChoice()
  Card.SetButtons(s)
end

-- The Target button's macro (also its key, Options > Keybindings > AddOns): target the NPC by name, then put a star on
-- it with the game's own /tm - marking from addon code (/run ... SetRaidTarget) is a protected action on Forever
-- (ADDON_ACTION_FORBIDDEN, no star). "/tm 0" then "/tm 1": /tm 1 alone toggles a star that's already there off, and
-- the button fires on key down and up.
Card.MARK = 1 -- the star
function Card.TargetMacro(who)
  local m = "/cleartarget\n/target " .. who .. "\n/targetexact " .. who
  if ns.db and ns.db.markTarget ~= false then m = m .. "\n/tm 0\n/tm " .. Card.MARK end
  return m
end
-- the option changed: the macro follows (out of combat; the card refills the button then)
ns.On("FR_SETTINGS", function() if Card.SetButtons and ns.Engine and ns.Engine.Shown and ForeverRouteData then local i = ns.Engine.Shown(); if i then pcall(Card.SetButtons, ForeverRouteData.steps[i]) end end end)

-- the other mobs of step s worth a Target button of their own: the ones its text names ("Collect 10 Turtle Meat
-- (Snapjaw, Cranky Benj)") and the targets of the objectives done at the same spot, without the first (who)
Card.EXTRA_TARGETS = 3
function Card.OtherTargets(s, who)
  local out, seen = {}, { [who or ""] = true }
  local function add(n) n = n and n:gsub("^%s+", ""):gsub("%s+$", ""); if n and n ~= "" and not seen[n] and #out < Card.EXTRA_TARGETS then seen[n] = true; out[#out + 1] = n end end
  if not (s and s.k == "obj" and who) then return out end
  local inner = (s.text or ""):match("%(([^()]+)%)%s*$")
  if inner then for n in inner:gmatch("[^,]+") do add(n) end end
  local i = ns.Engine.Shown and ns.Engine.Shown()
  if i and ForeverRouteData and ForeverRouteData.steps[i] == s and ns.Engine.Group then
    for _, j in ipairs(ns.Engine.Group(i)) do add(ForeverRouteData.steps[j].target) end
  end
  return out
end

function Card.SetButtons(s)
  local cur = f.cur
  local who = s and (s.target or ((s.k == "accept" or s.k == "turnin" or s.k == "bind" or s.k == "fp" or s.k == "train") and s.npc))
  local item = s and s.k ~= "bonus" and s.item -- books are looted, not used
  -- no item of the step's own: the button starts the quest an item in your bags offers (ns.ItemQuests)
  local offer = not item and not ns.Engine.view and ns.db.cardItemQuests ~= false and ns.ItemQuests and ns.ItemQuests.Current()
  if offer then item = offer.item end
  cur.offerItem = offer and true or false
  cur.wantTarget, cur.wantItem = who, item
  setSecure(function()
    if who then cur.target:SetAttribute("macrotext", Card.TargetMacro(who)); cur.target.who = who; cur.target.label:SetText(who)
    else cur.target:SetAttribute("macrotext", ""); cur.target.who = nil end -- the key does nothing on a step with no one to target
    local others = Card.OtherTargets(s, who)
    cur.wantOthers = #others
    for n, b in ipairs(cur.targets) do
      local o = others[n]
      b.who = o; b:SetAttribute("macrotext", o and Card.TargetMacro(o) or ""); b.label:SetText(o or "")
    end
    if item then
      cur.item:SetAttribute("item", "item:" .. item); cur.item.itemID = item
      cur.item.icon:SetTexture((ns.GetItemIcon and ns.GetItemIcon(item)) or 134400)
    end
  end)
end

-- The card hangs from its top: anchored by its middle (as it was, and as a drag can leave it), every change of
-- height moved its top - and the Target button, which sits above that top and can't move in combat, was left out of
-- place. Out of combat only (the card's anchor is ours, but it carries the secure buttons' place with it). A card
-- never dragged hangs from its top too (Card.DEFAULT_POS), and a place saved by an older version is made one.
-- Its place is kept in the game's own units (what it measures at scale 1), never in the card's scaled ones: the game
-- multiplies a frame's offsets by its scale, so a place saved at one scale and set again at a bigger one put the card
-- off the screen ("I fucked with the scale and now the card is just gone"). { "ABS", left, top } in UIParent units.
function Card.AnchorTop()
  if not f or InCombatLockdown() then return end
  local l, t = f:GetLeft(), f:GetTop()
  if not (l and t) then return end
  local s = f:GetScale() or 1
  ns.db.cardPos = { "ABS", l * s, t * s }
  Card.ApplyPos()
end
-- set the card at its saved place for its current scale; off the screen (or no place yet), the default place
Card.DEFAULT_POS = { "TOPRIGHT", "RIGHT", -60, 230 }
function Card.ApplyPos()
  if not f or InCombatLockdown() then return end
  local p, s = ns.db.cardPos, f:GetScale() or 1
  f:ClearAllPoints()
  if type(p) == "table" and p[1] == "ABS" and tonumber(p[2]) and tonumber(p[3]) then
    f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", p[2] / s, p[3] / s)
  elseif type(p) == "table" and p[1] and p[2] then
    f:SetPoint(p[1], UIParent, p[2], tonumber(p[3]) or 0, tonumber(p[4]) or 0) -- an older save: where it was...
    if f:GetLeft() and f:GetTop() then return Card.AnchorTop() end -- ...hung from its top from now on
  else
    local d = Card.DEFAULT_POS; f:SetPoint(d[1], UIParent, d[2], d[3], d[4])
  end
  if not Card.OnScreen() then Card.ResetPos(true) end
end
-- is enough of the card on the screen to grab? (a corner of it, in screen units)
function Card.OnScreen()
  local l, t, r, b = f:GetLeft(), f:GetTop(), f:GetRight(), f:GetBottom()
  if not (l and t and r and b) then return true end
  local s = f:GetEffectiveScale() / UIParent:GetEffectiveScale()
  local W, H = UIParent:GetWidth(), UIParent:GetHeight()
  return r * s > 40 and l * s < W - 40 and t * s > 40 and b * s < H - 20
end
-- back to the default place (/fr card reset; or by itself when it was off the screen)
function Card.ResetPos(quiet)
  if not f or InCombatLockdown() then return end
  ns.db.cardPos = nil
  f:ClearAllPoints(); local d = Card.DEFAULT_POS; f:SetPoint(d[1], UIParent, d[2], d[3], d[4])
  if not quiet then f:Show(); ns.Print("Card back at its place, at the normal size.") elseif ns.Why then ns.Why("card", "the card was off the screen: put back at its place") end
  C_Timer.After(0, Card.PlaceSecure)
end
-- the scale changed: the same place on the screen at the new scale
ns.On("FR_SETTINGS", function() C_Timer.After(0, function() if f then Card.ApplyPos(); Card.PlaceSecure() end end) end)

-- Where the Target button goes when you haven't put it somewhere yourself: just above the card's top edge, its left
-- side on the card's (the use-item button next to it). It is beside the card, never on it, so no row of the card can
-- run under it, and it does not depend on how tall the card is. No room above (the card at the top of the screen):
-- left of the card's top corner, or right of it.
-- -> x, y of the Target button's bottom-left corner in UIParent units, and "above" / "left" / "right"
Card.SECURE_GAP, Card.TARGET_W, Card.TARGET_H, Card.ITEM_SIZE = 4, 140, 20, 26
function Card.SecureSpot(withItem)
  if not f then return nil end
  local l, t, r = f:GetLeft(), f:GetTop(), f:GetRight()
  if not (l and t and r) then return nil end
  -- the card's units -> the screen's (UIParent's): the buttons are UIParent's children, at the card's scale
  local S = f:GetEffectiveScale() / UIParent:GetEffectiveScale()
  local gap = Card.SECURE_GAP * S
  local w = (Card.TARGET_W + (withItem and Card.SECURE_GAP + Card.ITEM_SIZE or 0)) * S
  local h = (withItem and Card.ITEM_SIZE or Card.TARGET_H) * S
  local W, H = UIParent:GetWidth() or 0, UIParent:GetHeight() or 0
  l, t, r = l * S, t * S, r * S
  if H <= 0 or t + gap + h <= H then return l, t + gap, "above" end
  if l - gap - w >= 0 then return l - gap - w, t - h, "left" end
  if W <= 0 or r + gap + w <= W then return r + gap, t - h, "right" end
  return l, t + gap, "above" -- (nowhere beside it either: the screen clamp keeps it in sight)
end
function Card.PlaceSecure()
  if not f then return end
  local cur = f.cur
  if InCombatLockdown() then Card.needPlace = true; return end
  Card.needPlace = false
  local x, y, where = Card.SecureSpot(cur.wantItem and true or false)
  if not (f:IsShown() and not ns.db.collapsed and (cur.wantTarget or cur.wantItem) and x and not ns.Engine.view) then cur.target:Hide(); cur.item:Hide(); for _, b in ipairs(cur.targets) do b:Hide() end cur.secureAt = nil; return end
  -- on the card's layer, a level above it and everything on it
  local lvl = f:GetFrameLevel() + 20
  for _, b in ipairs({ cur.item, cur.target, unpack(cur.targets) }) do b:SetScale(f:GetScale()); b:SetFrameStrata(f:GetFrameStrata()); b:SetFrameLevel(lvl) end
  -- places are worked out in UIParent units; the game multiplies a frame's offsets by its scale, so they are set
  -- divided by the buttons' own
  local S = cur.target:GetEffectiveScale() / UIParent:GetEffectiveScale()
  -- where you dragged it (Ctrl+drag: its top-left corner), else above the card
  local tp = ns.db.targetPos
  if type(tp) == "table" and tonumber(tp[1]) and tonumber(tp[2]) then x, y, where = tp[1], tp[2] - Card.TARGET_H * S, "dragged" end
  cur.secureAt = where
  cur.target:ClearAllPoints(); cur.target:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x / S, y / S)
  cur.target:SetShown(cur.wantTarget and true or false)
  -- the other mobs' buttons: a column under the first (above the card they'd cover it: they go up instead)
  local up = where ~= "dragged"
  for n, b in ipairs(cur.targets) do
    b:ClearAllPoints(); b:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x / S, (y + (up and n or -n) * (Card.TARGET_H + 2) * S) / S)
    b:SetShown((cur.wantTarget and (cur.wantOthers or 0) >= n) and true or false)
  end
  -- the use-item button: next to the Target button, or in its place on a step with no one to target
  local ix = cur.wantTarget and x + (Card.TARGET_W + Card.SECURE_GAP) * S or x
  cur.item:ClearAllPoints(); cur.item:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", ix / S, y / S)
  cur.item:SetShown(cur.wantItem and true or false)
end
-- /fr target reset: forget where you dragged the Target button; it goes back above the card. In combat it can't be
-- moved (the game forbids it): it goes back when the fight ends, and says so - it used to say "back on the card" and
-- stay where it was.
function Card.ResetTarget()
  ns.db.targetPos = nil
  if not f then return end
  if InCombatLockdown() then Card.needPlace = true; ns.Print("Target button: it can't move during a fight. It goes back above the card when the fight ends."); return end
  Card.PlaceSecure()
  local cur = f.cur
  if cur.target:IsShown() or cur.item:IsShown() then ns.Print("Target button back above the card.")
  else ns.Print("Target button: it will be above the card the next time a step has someone to target.") end
end
ns.On("PLAYER_REGEN_ENABLED", function()
  if pendingSecure then local fn = pendingSecure; pendingSecure = nil; fn() end
  if f and Card.needPlace then Card.PlaceSecure() end
end)

Card.LINK_H = 14 -- the height of the small "not now" link
function Card.Layout()
  if not f then return end
  local cur = f.cur
  local x0 = 50
  -- give text explicit widths so wrapped heights are measured correctly
  local inner = (f:GetWidth() or ns.db.cardWidth) - 2 * PAD
  -- the tool row under the distance, from the right: Map, then the quest icons. The title and the detail line keep
  -- clear of it (the title runs beside it when it takes two lines).
  local toolW, tx = 0, 0
  if cur.map:IsShown() then toolW = Card.MAP_W; tx = Card.MAP_W + Card.TOOL_GAP end
  for _, b in ipairs({ cur.notOffered, cur.nope }) do
    if b:IsShown() then
      b:ClearAllPoints(); b:SetPoint("TOPRIGHT", cur, "TOPRIGHT", -tx, -18)
      toolW = tx + Card.TOOL; tx = toolW + Card.TOOL_GAP
    end
  end
  cur.titleText:SetWidth(inner - x0 - math.max(DIST_W, toolW) - 4); cur.detail:SetWidth(inner - x0 - math.max(44, toolW + 6)); cur.note:SetWidth(inner - x0)
  local y = cur.titleText:GetStringHeight() + 4 + ((cur.detail:GetText() or "") ~= "" and cur.detail:GetStringHeight() or 0)
  y = math.max(y, 38)
  for k = 1, cur.nbars or 0 do
    local b = cur.bars[k]
    local h = cur.headAt and cur.headAt[k]
    if h then h:ClearAllPoints(); h:SetPoint("TOPLEFT", cur, "TOPLEFT", x0, -(y + 9)); h:SetPoint("RIGHT"); h:Show(); y = y + 9 + 11 end
    b:ClearAllPoints(); b:SetPoint("TOPLEFT", cur, "TOPLEFT", x0, -(y + 8)); b:SetPoint("RIGHT")
    y = y + 8 + 18
  end
  -- "not now": a row of its own under the title, detail and bars, from the text's left edge, as wide as its words.
  -- (Nothing of the Target / use-item buttons here: they float above the card - Card.PlaceSecure.)
  cur.linkRows = 0
  local nn = cur.notNow
  if nn:IsShown() then
    local sw = nn.label:GetStringWidth() or 0
    nn:SetWidth(math.min(inner - x0, sw > 0 and math.ceil(sw) + 14 or 60))
    cur.linkRows = 1; y = y + 7
    nn:ClearAllPoints(); nn:SetPoint("TOPLEFT", cur, "TOPLEFT", x0, -y)
    y = y + Card.LINK_H
  end
  local prevLink = nn:IsShown() and nn or nil
  for _, tagBtn in ipairs({ cur.why, cur.fq, cur.noChain }) do
    if tagBtn:IsShown() then
      tagBtn:ClearAllPoints()
      if prevLink then tagBtn:SetPoint("LEFT", prevLink, "RIGHT", 8, 0)
      else
        cur.linkRows = 1; y = y + 7
        tagBtn:SetPoint("TOPLEFT", cur, "TOPLEFT", x0, -y)
        y = y + Card.LINK_H
      end
      prevLink = tagBtn
    end
  end
  if (cur.note:GetText() or "") ~= "" then
    cur.note:ClearAllPoints(); cur.note:SetPoint("TOPLEFT", cur, "TOPLEFT", x0, -(y + 7))
    y = y + 7 + cur.note:GetStringHeight()
  end
  if cur.choice then
    for k = 1, #(cur.choice.rows or (cur.choice.c and cur.choice.c.options) or {}) do
      local r = cur.optRows[k]
      r:ClearAllPoints(); r:SetPoint("TOPLEFT", cur, "TOPLEFT", x0 - 6, -(y + (k == 1 and 10 or 5))); r:SetPoint("RIGHT", cur, "RIGHT", 0, 0)
      y = y + (k == 1 and 10 or 5) + 40
    end
  end
  cur:SetHeight(y)
  local top = 40 + y + 14
  f.line:Hide()
  if ns.db.collapsed then
    for _, r in ipairs(f.rows) do r:Hide() end
    f.eta:Hide(); f.ret:Hide(); f.drop:Hide(); f.dropWanted = nil
    for _, b in pairs(f.btn) do b:Hide() end
    -- (and every row under the card: the reminders, offers and Change home base stayed below a collapsed card - tester)
    for _, row in pairs(Card.ExtraRows()) do row:Hide() end
    f.ctl:ClearAllPoints(); f.ctl:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD + 4, -top + 6)
    f.btn.min:Show(); f.btn.min:ClearAllPoints(); f.btn.min:SetPoint("RIGHT", f.ctl, "RIGHT")
    f:SetHeight(top + 8)
    C_Timer.After(0, Card.PlaceSecure)
    return
  end
  -- (the plan from its own place, not from the step on the card: a hand-in filed 20 levels ahead on the card listed
  -- the level-59 steps after it - code review. The card's step itself isn't listed again)
  local shownI = ns.Engine.Shown()
  local base = ns.Engine.PlanAt and ns.Engine.PlanAt() or shownI
  local up = {}
  for _, j in ipairs(ns.Engine.Upcoming(base and base ~= shownI and base - 1 or shownI, 9)) do if j ~= shownI and #up < 8 then up[#up + 1] = j end end
  local grouped = {}; for _, j in ipairs(ns.Engine.Group(ns.Engine.Shown() or 0)) do grouped[j] = true end
  local rows = {}
  if cur.dungeon and ns.Engine.Shown() then rows[1] = ns.Engine.Shown() end -- the plan's step, for when you're out again
  for _, j in ipairs(up) do if not grouped[j] and #rows < (ns.db.showNext or 3) then rows[#rows + 1] = j end end
  for k, r in ipairs(f.rows) do
    local i = rows[k]
    if i then
      local s = steps()[i]; local kind = Style.Kind(s)
      r.index = i
      r.dot:SetVertexColor(kind.color[1], kind.color[2], kind.color[3], 0.9)
      -- objectives coming up show your live count, so half-done ones are obvious
      local o = s.k == "obj" and ns.Engine.ObjectiveFor(s)
      local cnt = o and o.need and o.need > 0 and string.format("  |cff8a93a6%d/%d|r", o.have or 0, o.need) or ""
      r.base, r.cnt = (Card.Describe(s)), cnt
      r.text:SetText(r.base .. cnt); r.text:SetAlpha(1 - (k - 1) * 0.2)
      r:ClearAllPoints(); r:SetPoint("TOPLEFT", f, "TOPLEFT", PAD - 4, -top); r:SetPoint("RIGHT", -PAD, 0); r:Show()
      top = top + 20
    else r:Hide() end
  end
  if #rows > 0 then
    -- vertical line from under the icon disc down to the last timeline dot
    local lastCentre = top - 10 -- top already moved past the last row
    f.line:Show(); f.line:ClearAllPoints()
    f.line:SetPoint("TOP", cur.disc, "BOTTOM", 0, -4)
    f.line:SetHeight(math.max(1, lastCentre - (40 + 38 + 4)))
  end
  top = top + 8
  local lv, offer = nil, nil
  if ns.Offers and not ns.Engine.view and ns.db.cardOffers ~= false then lv, offer = ns.Offers.Current() end
  f.offer:SetShown(offer and true or false)
  if offer then
    f.offer.text:SetText(offer.text)
    f.offer.go:SetShown(true)
    f.offer:ClearAllPoints(); f.offer:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -top); f.offer:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
    top = top + 22
  end
  local extra = ns.Extras and not ns.Engine.view and ns.Extras.Line()
  f.extra:SetShown(extra and true or false)
  if extra then
    f.extra.text:SetText(extra)
    f.extra:ClearAllPoints(); f.extra:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -top); f.extra:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
    top = top + 22
  end
  local cn = Card.ChangeNote()
  f.change:SetShown(cn and true or false)
  if cn then
    f.change.text:SetText("Plan updated: " .. cn)
    f.change:ClearAllPoints(); f.change:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -top); f.change:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
    top = top + 22
  end
  local sv, svBtn = Card.SaveNudge()
  f.save:SetShown(sv and true or false)
  if sv then
    f.save.text:SetText(sv)
    f.save.go.label:SetText(svBtn or "Reload")
    f.save:ClearAllPoints(); f.save:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -top); f.save:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
    top = top + 22
  end
  local inside = ns.Dungeon and ns.Dungeon.Inside and select(2, ns.Dungeon.Inside())
  local sp = (not ns.Engine.view and not inside and not (ForeverRouteData and ForeverRouteData.dungeon)) and Card.SpecialOffer() or nil
  f.special:SetShown(sp and true or false)
  if sp then
    f.special.route = sp.route
    f.special.text:SetText(sp.text)
    f.special:ClearAllPoints(); f.special:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -top); f.special:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
    top = top + 22
  end
  local errand = ns.Errands and not ns.Engine.view and ns.Errands.Current()
  f.errand:SetShown(errand and true or false)
  if errand then
    f.errand.text:SetText(errand)
    f.errand:ClearAllPoints(); f.errand:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -top); f.errand:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
    top = top + 22
  end
  local rd = not ns.Engine.view and Card.readyNear
  f.ready:SetShown(rd and true or false)
  if rd then
    f.ready.text:SetText(string.format("Ready nearby: %s%s, %d yd", rd.name or "a quest", rd.npc and (" to " .. rd.npc) or "", math.floor(rd.d + 0.5)))
    f.ready:ClearAllPoints(); f.ready:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -top); f.ready:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
    top = top + 22
  end
  local iq = not ns.Engine.view and ns.db.cardItemQuests ~= false and ns.ItemQuests and ns.ItemQuests.Current()
  f.itemq:SetShown(iq and true or false)
  if iq then
    -- (an explicit width, so the wrapped height is measured right: the "x" takes the last 22)
    f.itemq.text:SetWidth((f:GetWidth() or ns.db.cardWidth) - 2 * PAD - 22)
    f.itemq.text:SetText(ns.ItemQuests.Text(iq, not f.cur.offerItem))
    f.itemq:ClearAllPoints(); f.itemq:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -top); f.itemq:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
    local h = math.max(20, math.ceil((f.itemq.text:GetStringHeight() or 0) + 4))
    f.itemq:SetHeight(h)
    top = top + h + 2
  end
  local nd = ns.LogCheck and ns.LogCheck.dropCount or 0
  -- (a small link at the right of the footer, not a row of its own: it took a lot of room - tester)
  f.dropWanted = nd > 0 and not ns.Engine.view
  f.drop:SetShown(f.dropWanted)
  if f.dropWanted then
    f.dropText, f.dropCount = string.format("%d off-route", nd), nd
    f.drop.label:SetText(f.dropText)
    f.drop:SetWidth(f.drop.label:GetStringWidth() + 12)
  end
  local viewing = ns.Engine.view ~= nil
  f.ret:SetShown(viewing)
  if viewing then f.ret:ClearAllPoints(); f.ret:SetPoint("TOPLEFT", PAD, -top); top = top + 24 end
  -- level 60: "Finish my quests" on the celebration, "Stop finishing quests" while you finish them (Engine.SetFinishing)
  local fin = ns.Engine.Finishing()
  local showFin = not viewing and (cur.celebrate or fin) and true or false
  f.finish:SetShown(showFin)
  if showFin then
    f.finish.label:SetText(fin and "Back to level 60" or "Finish my quests")
    f.finish:ClearAllPoints(); f.finish:SetPoint("TOPLEFT", PAD, -top); top = top + 24
  end
  f.dropY = -top - 2
  f.eta:Show(); f.eta:ClearAllPoints(); f.eta:SetPoint("TOPLEFT", PAD, -top - 4); f.eta:SetPoint("RIGHT", f, "RIGHT", -PAD - (f.dropWanted and f.drop:GetWidth() + 4 or 0), 0)
  local d = ForeverRouteData
  -- (on your plan too: the zone your plan works is your home base, and "Change home base" is how you pick another -
  -- a tester saw "home base" nowhere until they had picked one)
  local onDungeon = d and (d.dungeon or d.zoneRoute or not d.special)
  f.home:SetShown(onDungeon and true or false)
  f.home.carryOn = nil
  if onDungeon then
    local label = ns.Engine.Finishing() and "Back to level 60" or d.dungeon and "Back to plan" or "Change home base"
    -- a zone you picked, done for a few seconds (Card.Fill): carry on where your planned route picks up
    if d.zoneRoute and Card.zoneDoneSince and ns.ZoneChoices then -- (at once: a label changing under your cursor after 3 s - review)
      local best = ns.ZoneChoices().best
      if best then f.home.carryOn = best; label = "Back to plan: " .. Style.ShortZone(best.zone) end
    end
    f.home.label:SetText(label)
    f.home.tip = { label, ns.Engine.Finishing() and "Stop finishing the quests you hold: back to the level 60 card."
      or d.dungeon and "Leave this side trip and carry on with your plan. Progress here is kept."
      or f.home.carryOn and "Your planned route picks up there. Progress here is kept."
      or "Pick another home base, or go back to your plan. Progress here is kept." }
  end
  Card.PlaceDrop(Card.hovering or f.ctl:GetAlpha() > 0.5) -- (hovering: at the left, the controls have the right; after the home button is set)
  f.ctl:ClearAllPoints(); f.ctl:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD + 4, -top + 1)
  local x = 0
  for _, name in ipairs({ "opt", "min", "dungeon", "list", "undo", "skip", "done", "fwd", "back", "flag", "home" }) do
    local b = f.btn[name]
    local show = true
    if name == "home" then show = onDungeon and true or false end
    if name == "undo" then show = #ns.char.history > 0 end
    if name == "fwd" then show = viewing end
    if name == "flag" then show = not viewing end -- (the card looked at, not the route's answer: nothing to flag)
    if (name == "done" or name == "skip") and (viewing or cur.dungeon) then show = false end -- (in a dungeon the card's step isn't the one on show)
    b:SetShown(show)
    if show then b:ClearAllPoints(); b:SetPoint("RIGHT", f.ctl, "RIGHT", -x, 0); x = x + 23 end
  end
  -- the decision log: each card row the moment it appears or changes, with its text
  Card.lastRow = Card.lastRow or {}
  for name, row in pairs({ save = f.save, special = f.special, offer = f.offer, errand = f.errand, extra = f.extra, itemq = f.itemq }) do
    local txt = row:IsShown() and row.text and row.text:GetText() or nil
    -- compare without numbers, so a distance or count ticking down is not a new entry
    local sig = txt and txt:gsub("%d", "")
    if sig and sig ~= Card.lastRow[name] and ns.Why then ns.Why("card", name .. ": " .. txt:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
    Card.lastRow[name] = sig
  end
  f:SetHeight(top + 26)
  C_Timer.After(0, Card.PlaceSecure)
end

-- saving = reloading the UI: the only time the game writes addon data, which the planner reads
local loadedAt = GetTime()
Card.SAVE_AFTER = 300 -- seconds played since the last reload before a flight suggests saving
function Card.Save()
  if InCombatLockdown and InCombatLockdown() then ns.Print("Not in combat - save once it's over."); return end
  ReloadUI()
end
-- the companion's signal: a valid (silent) sound file means a new plan is installed and waiting for a reload
Card.READY_FILE = "Interface\\AddOns\\ForeverRoute\\signal\\ready.wav"
Card.READY_GRACE = 60 -- right after a reload the companion hasn't cleared the old signal yet
function Card.CheckReady()
  if GetTime() - loadedAt < Card.READY_GRACE then return end
  if InCombatLockdown and InCombatLockdown() then return end
  -- "a plan newer than yours": a file named after the stamp of the plan you have loaded
  local g = ForeverRoutePlan and ForeverRoutePlan.generated
  if not g then return end
  local file = Card.READY_FILE:gsub("ready%.wav$", "newer-" .. g .. ".wav")
  local ok, will, handle = pcall(PlaySoundFile, file, "Master")
  if ok and handle and StopSound then pcall(StopSound, handle) end
  local ready = (ok and will) and true or false
  if ready ~= Card.planReady then
    Card.planReady = ready
    if ready then Card.readyDismissed = nil; ns.Print("A new route is ready - reload when it suits you (the card has a button)."); if ns.Why then ns.Why("ready", "the companion marked your plan (" .. tostring(ForeverRoutePlan and ForeverRoutePlan.generated) .. ") as out of date: a newer plan changes what is ahead of you") end end
    if f then Card.Layout() end
  end
end
ns.On("FR_LOADED", function() ns.NewTicker(10, ns.Guard("ready", Card.CheckReady)) end)
-- the companion's note on what changed in this plan (once per plan, until you press OK)
function Card.ChangeNote()
  local p = ForeverRoutePlan
  if not (p and type(p.changeNote) == "string" and p.changeNote ~= "") then return nil end
  if ns.char and ns.char.changeSeen == p.generated then return nil end
  return p.changeNote
end
function Card.SaveNudge()
  if Card.planReady and not Card.readyDismissed then return "New route ready - reload to get it", "Reload" end
  -- (no "save and replan on a flight": the companion only collects now - nothing replans from a save)
  return nil
end
ns.On("PLAYER_CONTROL_LOST", function() Card.saveDismissed = nil; C_Timer.After(1, function() if f then Card.Layout() end end) end)
ns.On("PLAYER_CONTROL_GAINED", function() C_Timer.After(0.5, function() if f then Card.Layout() end end) end)

-- the next stop of a special route you can do now: an accept you don't have yet, an objective of one in your log that
-- isn't finished (where the work is, not the quest giver who won't take it yet), or the hand-in once it is ready
function Card.SpecialNext(r)
  for _, s in ipairs(ns.Steps(r)) do
    if s.q and s.q > 0 and s.m and s.x and not s.unknown and not ns.State.IsCompleted(s.q) then
      if s.k == "accept" and not ns.State.OnQuest(s.q) then return s end
      if ns.State.OnQuest(s.q) then
        local ready = ns.State.QuestReady(s.q)
        if s.k == "turnin" then
          if ready then return s end
          -- not ready and no objective stop we could point at: nothing to do here yet (and the steps after it are
          -- likely its follow-ups, whose givers won't offer them yet either)
          return nil
        end
        if s.k == "obj" and not ready then
          local o = ns.Engine.ObjectiveFor(s)
          if not (o and o.finished) then return s end
        end
      end
    end
  end
end
local HBDc = LibStub("HereBeDragons-2.0")
-- the first special-reward side trip you haven't finished or hidden: { route, text }
function Card.SpecialOffer()
  local m = ns.State.Position()
  -- a stop near you first (worth the detour now), then the rest in plan order (class quests before the bag)
  local list, near = {}, {}
  for _, r in ipairs(ns.DungeonRoutes and ns.DungeonRoutes() or {}) do if r.special then local nx = Card.SpecialNext(r); if nx and m and nx.m == m then near[#near + 1] = r else list[#list + 1] = r end end end
  for _, r in ipairs(list) do near[#near + 1] = r end
  for _, r in ipairs(near) do
    if r.special and (UnitLevel("player") or 1) >= (tonumber(r.needsLevel) or 1) then
      local total, done = 0, 0
      for q in pairs(ns.QuestIds(r)) do if q > 0 then total = total + 1; if ns.State.IsCompleted(q) then done = done + 1 end end end
      if total > 0 and done < total then
        local name = r.dungeonName or r.title
        local nx = Card.SpecialNext(r)
        -- its next stop is on this map: worth a detour, shown even if the row was hidden
        if nx and m and nx.m == m then
          local px, py, pinst = HBDc:GetPlayerWorldPosition()
          local wx, wy, winst = HBDc:GetWorldCoordinatesFromZone(nx.x, nx.y, nx.m)
          local d = (px and wx and pinst == winst) and math.sqrt((px - wx) ^ 2 + (py - wy) ^ 2) or nil
          return { route = r, near = true, text = name .. ": next stop here" .. (d and (", " .. ns.Style.Distance(d)) or "") .. " - worth a detour" }
        end
        if not (ns.char.hideSpecial and ns.char.hideSpecial[r.id]) then
          return { route = r, text = name .. "  |cff8a93a6" .. (done > 0 and string.format("%d/%d done", done, total) or (r.tag or "side trip")) .. "|r" }
        end
      end
    end
  end
end
-- arriving in a zone with the next stop: one chat line
local lastSpecialMap
function Card.SpecialArrive()
  local m = ns.State.Position()
  if not m or m == lastSpecialMap then return end
  lastSpecialMap = m
  local o = Card.SpecialOffer()
  if o and o.near then ns.Print((o.route.dungeonName or o.route.title) .. ": a stop for it is in this zone. \"Do it now\" is on the card.") end
end
ns.On("ZONE_CHANGED_NEW_AREA", function() C_Timer.After(2, function() pcall(Card.SpecialArrive); if f then Card.Fill(); Card.Layout() end end) end)

function Card.UpdateProgress()
  if not f then return end
  -- inside a dungeon: its quests' objectives, done of all
  local dg = f.cur and f.cur.dungeon
  if dg then
    f.count:SetText(dg.total > 0 and string.format("%d/%d", dg.done, dg.total) or "")
    f.progFill:SetWidth(math.max(0.001, (f.prog:GetWidth() or 0) * (dg.total > 0 and dg.done / dg.total or 0)))
    return
  end
  -- progress through this zone (a fresh plan doesn't reset it to nothing; the whole plan is in /fr list)
  local done, total, zone = ns.Engine.LegProgress()
  -- (who picked this zone: you - your home base - or your plan)
  local d = ForeverRouteData
  local who = d and not d.dungeon and not d.special and "Base: " or "" -- (your plan's zone is your home base too)
  f.count:SetText(total > 0 and string.format("%s%d/%d", zone and (who .. Style.ShortZone(zone) .. "  ") or "", done, total) or "")
  f.progFill:SetWidth(math.max(0.001, (f.prog:GetWidth() or 0) * (total > 0 and done / total or 0)))
end

-- "Going to Alterac Mountains: 2 quests (Soothing Turtle Bisque, Alterac Granite), then Hillsbrad Foothills" - for a
-- step in another zone than yours
function Card.WhyGo(i)
  local z = ns.Engine.ZonesAhead and ns.Engine.ZonesAhead(i, 2)
  local a, b = z and z[1], z and z[2]
  if not a or a.zone ~= (steps()[i] or {}).zone then return nil end
  -- (short: the travel line above already names the zone - "Going to Stranglethorn Vale for 2 quests (...)" said it
  -- a third time - tester)
  local what = a.quests > 0 and string.format("%d quest%s there: %s", a.quests, a.quests == 1 and "" or "s", table.concat(a.names, ", ", 1, math.min(2, #a.names)) .. (#a.names > 2 and ", ..." or "")) or "Grinding there"
  return string.format("|cffffd25a%s%s|r", what, b and (" · then " .. Style.ShortZone(b.zone)) or "")
end

-- the capitals' maps, both factions (Stormwind, Ironforge, Darnassus, Orgrimmar, Thunder Bluff, the Undercity)
Card.CAPITAL_MAPS = { [1453] = true, [1455] = true, [1457] = true, [1454] = true, [1456] = true, [1458] = true }

-- "A few in Hillsbrad Foothills too (16 there) - the plan farms the bigger group here" for an objective step whose
-- mobs also stand, fewer of them, where the quest is given or handed in
function Card.AlsoNote(s)
  if not (s and s.k == "obj" and type(s.also) == "string") then return nil end
  local zone, n = s.also:match("^(.-):(%d+)$")
  if not zone or zone == s.zone then return nil end
  return string.format("|cff8e99adA few in %s too (%s there) - the plan farms the bigger group%s|r", zone, n, s.zone and (" in " .. s.zone) or " here")
end

function Card.Header()
  local i = ns.Engine.Shown()
  local sec = i and section(i)
  local dname = ForeverRouteData and ForeverRouteData.dungeon and (ForeverRouteData.dungeonName or ForeverRouteData.title)
  -- (the zone once: a title that names it - "Out in Redridge Mountains", "Hillsbrad Foothills: Loremaster Dibbs" - with its short
  -- name, and no zone after it; "OUT IN REDRIDGE MOUNTAINS  Redridge Mou..." said it twice and was cut off - review)
  local t, z = sec and sec.title, sec and sec.zone
  -- (a stop in another zone than its stretch - a hand-in pulled in on the way: that zone, not the stretch's - "OUT IN
  -- STRANGLETHORN" over a hand-in in Duskwood, tester)
  local st = i and steps()[i]
  if st and st.zone and z and st.zone ~= z and not dname then t, z = "On the way: " .. st.zone, st.zone end
  local named = t and z and t:lower():find(z:lower(), 1, true)
  if named then
    local a2 = t:lower():find(z:lower(), 1, true)
    -- (a hub's "Zone: NPC, NPC": the progress on the right names the zone, so just the people - "ELWYNN FOREST: MARSHAL
    -- MCBRIDE, BR..." was cut off against it)
    if a2 == 1 and t:sub(#z + 1, #z + 1) == ":" then t = t:sub(#z + 2):gsub("^%s+", "")
    else t = t:sub(1, a2 - 1) .. Style.ShortZone(z) .. t:sub(a2 + #z) end
  end
  -- (a side trip's section that only repeats its name - "VOIDWALKER (WARLOCK 10)  Special: Voidwalker (warlock 10)")
  if dname and t and t:lower():find(dname:lower(), 1, true) then t = "" end
  f.title:SetText((dname and ("|cffff7a6b" .. dname:upper() .. "|r  ") or "") .. (sec and (t:upper() .. (not dname and not named and z and z ~= sec.title and ("  |cff8a93a6" .. Style.ShortZone(z) .. "|r") or "")) or (ForeverRouteData and ForeverRouteData.title or "Forever Route")))
end
-- The footer line: when you leave this zone and for where - "Next zone: Duskwood, after 4 quests here". It said the
-- level the plan had you at for this step and the plan's last level ("planned for level 33 · plan goes to level 43"),
-- which a player can't act on: "meaningless and confusing" (tester). Empty on a travel step (the card's own lines
-- say where it goes and why) and on a dungeon route; "Last zone on this plan" when nothing comes after.
function Card.FooterText(i)
  local data = ForeverRouteData
  local s = i and steps()[i]
  if not (s and s.zone and data and not data.dungeon and ns.Engine.ZonesAhead) then return "" end
  -- (the card showing a stop pulled forward out of the plan's order: count from the plan's own next step - the footer said
  -- "Next zone: Wetlands" while Where to? had Hillsbrad)
  local base = (i == ns.Engine.Shown() and ns.Engine.planned) or i
  local bs = steps()[base] or s
  local z = ns.Engine.ZonesAhead(base, 2)
  local here, nxt = z[1], z[2]
  if not (here and here.zone == bs.zone) then return "" end
  if not nxt and data.zoneRoute then
    local nz = ns.PlannedNextZone and ns.PlannedNextZone()
    if nz then local n = here.quests or 0; return "Then " .. Style.ShortZone(nz) .. " (your plan)" .. (n > 0 and string.format(", after %d quest%s here", n, n == 1 and "" or "s") or "") end
  end
  if not nxt then return "Last zone on this plan" end
  local n = here.quests or 0
  return "Next zone: " .. Style.ShortZone(nxt.zone) .. (n > 0 and string.format(", after %d quest%s here", n, n == 1 and "" or "s") or "")
end
-- A count moved ("Gnoll Paws: 3/8", State.lua FR_PROGRESS): only the bars and counts on the card change - its text,
-- height and buttons stay. The whole card took 3 ms to redo on every kill; this is a few bars.
function Card.Counts()
  if not f then return end
  local cur = f.cur
  if cur.dungeon or (cur.animOut and cur.animOut:IsPlaying()) then return Card.Update(false) end
  for n = 1, cur.nbars or 0 do
    local b = cur.bars[n]
    local L = b and b.live
    if L then
      local o
      if L.idx then local q = ns.State.Quest(L.s.q); o = q and q.on and q.objectives[L.idx] else o = ns.Engine.ObjectiveFor(L.s) end
      local sig = o and ((o.have or 0) .. "/" .. (o.need or 0) .. (o.finished and "f" or "") .. (o.text or "")) or ""
      if sig ~= b.liveSig then b.liveSig = sig; objectiveBar(b, L.s, o, L.kind, L.idx) end
    end
  end
  for _, r in ipairs(f.rows or {}) do
    local s = r:IsShown() and r.index and r.base and steps()[r.index]
    if s and s.k == "obj" then
      local o = ns.Engine.ObjectiveFor(s)
      local cnt = o and o.need and o.need > 0 and string.format("  |cff8a93a6%d/%d|r", o.have or 0, o.need) or ""
      if cnt ~= r.cnt then r.cnt = cnt; r.text:SetText(r.base .. cnt) end
    end
  end
end

function Card.Update(animate)
  if not f then return end
  local t0 = debugprofilestop and debugprofilestop()
  ns.Engine.ReadPass(function() Card.UpdateInner(animate) end)
  if t0 and ns.Time then ns.Time("card", debugprofilestop() - t0) end
end
-- (timed: what a card redraw costs in your game shows in /fr report)
function Card.UpdateInner(animate)
  local i = ns.Engine.Shown()
  -- (inside a dungeon the header is the dungeon's: Card.FillDungeon)
  if not (f.cur.dungeon and ns.Dungeon and ns.Dungeon.Inside()) then Card.Header() end
  Card.UpdateProgress()
  f.eta:SetText(ns.db.cardZones ~= false and Card.FooterText(i) or "")
  local cur = f.cur
  if animate then
    cur.animOut:Stop(); cur.animIn:Stop(); cur.pop:Stop()
    cur.pop:Play(); cur.animOut:Play()
  elseif not cur.animOut:IsPlaying() then
    -- (the plan finished and still is - same plan, same level, no step looked at, not in a dungeon or the demo: the card
    -- already says so. Every refresh fired FR_STEP and redid it)
    local data = ForeverRouteData
    local same = not i and cur.doneData and cur.doneData == data and ns.Engine.planDone and not ns.Engine.view
      and not (ns.Demo and ns.Demo.active) and cur.doneLvl == ((UnitLevel and UnitLevel("player")) or 1)
      and not (ns.Dungeon and select(2, ns.Dungeon.Inside())) and cur.doneFin == ns.Engine.Finishing()
    if not same then Card.Fill(); Card.Layout() end
  end
end

ns.On("FR_LOADED", function() build(); f:SetShown(not ns.db.hidden); Card.Update() end)
ns.On("FR_STEP_DONE", function() if f then Card.Update(true) end end)
ns.On("FR_STEP", function() Card.Update(false) end)
ns.On("FR_CARD", function() Card.Update(false) end)
ns.On("FR_ZONETRIPS", function() if f and Card.zoneDoneSince then Card.Update(false) end end) -- (the next bases' trips are in)
ns.On("FR_PROGRESS", function() Card.Counts() end) -- (a count moved: "Gnoll Paws: 3/8")
ns.On("FR_DUNGEON", function() if f then Card.Update(false) end end) -- walked into or out of a dungeon
ns.On("FR_XP", function() local s = ns.Engine.CardAt() and steps()[ns.Engine.CardAt()]; if f and s and s.k == "grind" and not f.cur.animOut:IsPlaying() then Card.Fill(); Card.Layout() end end)
ns.On("FR_TOGGLE", function() ns.db.hidden = not ns.db.hidden; f:SetShown(not ns.db.hidden) end)
ns.On("FR_SETTINGS", function() if f then Style.ApplyScale(); f:SetWidth(ns.db.cardWidth); Card.Update() end end)
-- leg = the arrow points at a waypoint on the way (the flight master, the pier), not the step: say which, so
-- "40 yd" next to a step a zone away is not read as the distance to the step
-- (a ride points at the first place on the road there - a zone crossing, or a town on the way: "via")
local LEG_WORD = { fly = "FM ", via = "FM ", boat = "dock ", ride = "via " }
ns.On("FR_DISTANCE", function(yards, arrived, leg)
  if not f then return end
  local prefix = leg and LEG_WORD[leg] and ("|cff8a93a6" .. LEG_WORD[leg] .. "|r") or ""
  f.cur.dist:SetText(arrived and "|cff5cdc7ain the area|r" or (yards and (prefix .. Style.Distance(yards)) or ""))
end)
ns.On("PLAYER_REGEN_DISABLED", function() if f and ns.db.combatFade and f:IsShown() then UIFrameFadeOut(f, 0.25, f:GetAlpha(), 0.35) end end)
ns.On("PLAYER_REGEN_ENABLED", function() if f and f:GetAlpha() < 1 then UIFrameFadeIn(f, 0.25, f:GetAlpha(), 1) end end)

-- the "ready nearby" line: looked at every two seconds where you stand (its own check, apart from the live reordering);
-- the card redraws only when what it would say changes
Card.readyNear = nil
function Card.CheckReadyNearby()
  if not (f and f:IsShown()) then return end
  local px, py, pinst = HBDc:GetPlayerWorldPosition()
  local r = ns.Engine.ReadyNearby and ns.Engine.ReadyNearby(px, py, pinst) or nil
  if r and r.i == ns.Engine.Shown() then r = nil end
  local was = Card.readyNear
  Card.readyNear = r
  -- (the distance shown moves with you: redraw when it changed by 10 yd, or another quest or none)
  if (was and was.i) ~= (r and r.i) or (was and r and math.abs(was.d - r.d) >= 10) then Card.Layout() end
end
if C_Timer and C_Timer.NewTicker then ns.NewTicker(2, ns.Guard("ready nearby", Card.CheckReadyNearby)) end
