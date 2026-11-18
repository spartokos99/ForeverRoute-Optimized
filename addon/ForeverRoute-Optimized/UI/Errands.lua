-- Errand reminders: one line on the card when it matters - bags nearly full (sell) -
-- with the nearest vendor that can do it on this map (from Vendors.lua, generated from the quest database).
-- Hidden again once it's sorted, or dismissed until things change.
local _, ns = ...
local Errands = {}
ns.Errands = Errands
local HBD = LibStub("HereBeDragons-2.0")

local BAG_LOW, DURABILITY_LOW = 3, 0.25

function Errands.FreeSlots()
  local free, getFree = 0, (C_Container and C_Container.GetContainerNumFreeSlots) or GetContainerNumFreeSlots
  if not getFree then return nil end
  for bag = 0, 4 do local ok, n = pcall(getFree, bag); if ok and type(n) == "number" then free = free + n end end
  return free
end
function Errands.Durability()
  if not GetInventoryItemDurability then return nil end
  local low
  for slot = 1, 18 do
    local ok, cur, max = pcall(GetInventoryItemDurability, slot)
    if ok and cur and max and max > 0 then local f = cur / max; if not low or f < low then low = f end end
  end
  return low
end
-- the nearest vendor on your map: name, title, yards
function Errands.Nearest()
  local m = ns.State.Position()
  local list = m and ns.VENDORS and ns.VENDORS[m]
  if not list then return nil end
  local px, py, pinst = HBD:GetPlayerWorldPosition()
  local best, bd
  for _, v in ipairs(list) do
    do
      local vx, vy, vinst = HBD:GetWorldCoordinatesFromZone(v[1], v[2], m)
      if vx and px and vinst == pinst then
        local d = math.sqrt((vx - px) ^ 2 + (vy - py) ^ 2)
        if not bd or d < bd then best, bd = v, d end
      end
    end
  end
  return best, bd
end

-- Well Fed (cooked food): about +5% kill XP. Checked out of combat only (aura data can be hidden in combat).
-- true / false, or nil when it can't tell
function Errands.WellFed()
  if InCombatLockdown and InCombatLockdown() then return nil end
  if C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName then
    local ok, a = pcall(C_UnitAuras.GetAuraDataBySpellName, "player", "Well Fed", "HELPFUL")
    if ok then return a ~= nil end
  end
  if AuraUtil and AuraUtil.FindAuraByName then
    local ok, name = pcall(AuraUtil.FindAuraByName, "Well Fed", "player", "HELPFUL")
    if ok then return name ~= nil end
  end
end
-- is this bag item Well Fed food you can eat now? Its "Use:" line says so. Not a recipe: a recipe's tooltip includes
-- the tooltip of the dish it teaches, "well fed" and all (recipes are item class 9; food is a consumable, class 0).
-- Not food above your level: the tooltip's "Requires Level N" (or the item's own required level) says when.
local CONSUMABLE, RECIPE = 0, 9
-- an item's class never changes: asked once per item (the bags are looked through again after every loot)
local classOf = {}
local function itemClass(itemID)
  local c = classOf[itemID]
  if c == nil then
    local getInstant = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
    c = false
    if getInstant and itemID then
      local ok, _, _, _, _, _, classID = pcall(getInstant, itemID)
      if ok and type(classID) == "number" then c = classID end
    end
    if c ~= false or not getInstant then classOf[itemID] = c end -- (not known yet: asked again next time)
  end
  return c or nil
end
-- what can be told without the item's tooltip: false (not food you can eat now), or nil (the tooltip says)
local function notFood(itemID)
  if not itemID then return nil end
  local classID = itemClass(itemID)
  if classID and classID ~= CONSUMABLE then return false end
  local level = UnitLevel and UnitLevel("player") or 1
  local getInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
  if getInfo then
    local ok, _, _, _, _, minLevel = pcall(getInfo, itemID)
    if ok and type(minLevel) == "number" and minLevel > level then return false end
  end
  return nil
end
-- what a food's tooltip says: { fed (a "Use:" line with Well Fed), need (the highest "Requires Level"), teaches (a
-- recipe), name (its first line), whole (it has a "Use:" line and nothing hidden: the item's data had come in) }
local function foodWords(tip)
  local w = { fed = false, need = 0, teaches = false, whole = false }
  local lines = tip and tip.lines
  for k = 1, (lines and #lines or 0) do
    local t = lines[k] and lines[k].leftText
    if k == 1 then w.name = t end
    if type(t) == "string" and not (issecretvalue and issecretvalue(t)) then
      if t:find("^Use: Teaches you") then w.teaches = true end
      local need = tonumber(t:match("^Requires Level (%d+)"))
      if need and need > w.need then w.need = need end
      if t:find("^Use:") then w.whole = true; if t:lower():find("well fed", 1, true) then w.fed = true end end
    elseif t ~= nil then w.secret = true
    end
  end
  if w.secret then w.whole = false end
  return w
end
local function wellFedAt(w) return w.fed and not w.teaches and w.need <= (UnitLevel and UnitLevel("player") or 1) end
function Errands.IsWellFedFood(itemID, tip)
  if notFood(itemID) == false then return false end
  return wellFedAt(foodWords(tip))
end

-- food in your bags that gives Well Fed; scanned when your bags change. A bag item's tooltip is dear to build (every
-- loot looked through the whole bags this way: a hitch on each corpse looted while not Well Fed): only food is asked
-- for its tooltip - the rest is told by its class - and each food's once: its words don't change (kept once whole;
-- your level is held against its "Requires Level" each scan). A kill step at 12 with four breads in the bags read four
-- tooltips on every loot (perf gate)
local foodCache
local wordsOf = {}
function Errands.Food()
  if foodCache ~= nil then return foodCache or nil end
  foodCache = false
  if not (C_TooltipInfo and C_TooltipInfo.GetBagItem and C_Container and C_Container.GetContainerNumSlots) then return nil end
  for bag = 0, 4 do
    local okN, n = pcall(C_Container.GetContainerNumSlots, bag)
    for slot = 1, (okN and n or 0) do
      local okI, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
      local id = okI and info and info.itemID
      if id and notFood(id) == nil then
        local w = wordsOf[id]
        if not w then
          local okT, tip = pcall(C_TooltipInfo.GetBagItem, bag, slot)
          w = okT and tip and foodWords(tip)
          if w and w.whole then wordsOf[id] = w end
        end
        if w and wellFedAt(w) then   -- else keep looking: real food may be further on
          foodCache = { name = w.name or info.itemName or "food", id = id }
          return foodCache
        end
      end
    end
  end
  return nil
end
ns.On("BAG_UPDATE_DELAYED", function() foodCache = nil end)
-- the step you're on has you killing things (Well Fed only adds kill XP)
local function killing()
  local i = ns.Engine.Shown()
  local s = i and ForeverRouteData and ForeverRouteData.steps and ForeverRouteData.steps[i]
  return s and s.k == "obj" and type(s.text) == "string" and (s.text:find("^Kill") or s.text:find("^Collect")) and true or false
end

-- warlock pet grimoires (bought from the demon trainer; Icy Veins' warlock guide): only for a demon you have, only in a
-- city with a demon trainer, once each ("Got it" marks it bought)
Errands.GRIMOIRES = {
  { name = "Sacrifice", level = 16, pet = "Voidwalker" },
  { name = "Consume Shadows", level = 18, pet = "Voidwalker" },
  -- (the demon by its summoning spell, known to either faction: the quests that teach it differ - 1739 and 1795 are the
  -- Alliance's, and a Horde warlock never had them)
  { name = "Seduction", level = 26, pet = "Succubus", spell = 712, quest = { 1739 } },
  { name = "Devour Magic", level = 30, pet = "Felhunter", spell = 691, quest = { 1795 } },
  { name = "Spell Lock", level = 36, pet = "Felhunter", spell = 691, quest = { 1795 } },
}
-- the demon trainers of the capitals with warlocks (QuestieDB: "Demon Trainer"; Thunder Bluff and Darnassus have none -
-- no Tauren or Night Elf warlocks). Orgrimmar and the Undercity were missing: Horde warlocks never got the errand
Errands.DEMON_TRAINERS = { [1453] = "Spackle Thornberry, by Gakin in the Mage Quarter", [1455] = "Jubahl Corpseseeker, in the Forlorn Cavern",
  [1454] = "Kurgul, in the Cleft of Shadow", [1458] = "Martha Strain, in the Magic Quarter" }
function Errands.Grimoire()
  local _, class = UnitClass("player")
  if class ~= "WARLOCK" then return nil end
  local m = ns.State.Position()
  local trainer = m and Errands.DEMON_TRAINERS[m]
  if not trainer then return nil end
  ns.char.grimoires = ns.char.grimoires or {}
  local lvl = UnitLevel("player") or 1
  for _, g in ipairs(Errands.GRIMOIRES) do
    local have = not g.quest
    if g.spell and ns.Is(IsSpellKnown, g.spell) then have = true end
    for _, q in ipairs(g.quest or {}) do if ns.State.IsCompleted(q) then have = true end end
    if have and lvl >= g.level and not ns.char.grimoires[g.name] then
      return string.format("Demon trainer (%s): Grimoire of %s for your %s", trainer, g.name, g.pet), "grimoire:" .. g.name
    end
  end
end

-- what to show (or nil): text, and a key so a dismissal lasts until things change
function Errands.Current()
  local free = Errands.FreeSlots()
  local needSell = free and free <= BAG_LOW
  -- (no repair reminder: other addons do that - tester)
  if not needSell then
    local gt, gk
    if ns.db.remindGrimoire ~= false then gt, gk = Errands.Grimoire() end
    if gt then return gt, gk end
    if ns.db.remindFood ~= false and killing() and Errands.WellFed() == false then
      local food = Errands.Food()
      if food and ns.char.errandDismissed ~= "food" then return "Eat " .. food.name .. " for Well Fed (about +5% kill XP)", "food" end
    end
    return nil
  end
  local key = "bags"
  if ns.char.errandDismissed == key or ns.db.remindBags == false then return nil end
  local v, d = Errands.Nearest()
  local where = v and string.format(": %s (%s), %s", v[3], v[4], ns.Style.Distance(d)) or " at the next vendor"
  -- the live solver fitted a vendor into your way (Next.lua): that one, and when
  local nv = ns.Next and ns.Next.Enabled() and ns.Next.vendor
  if nv and nv.v then
    where = string.format(": %s (%s), %s", nv.v[3], nv.v[4], nv.before == 0 and "now - it's on your way" or ("after the next " .. nv.before .. (nv.before == 1 and " stop" or " stops")))
  end
  local what = string.format("Bags: %d free - sell", free)
  return what .. where, key
end
function Errands.Dismiss()
  local _, key = Errands.Current()
  -- a grimoire's "x" means bought (or not wanted): never again; other errands come back when things change
  local g = key and key:match("^grimoire:(.+)$")
  if g then ns.char.grimoires = ns.char.grimoires or {}; ns.char.grimoires[g] = true else ns.char.errandDismissed = key end
  ns.Fire("FR_STEP", ns.Engine.Shown())
end

local last
local function check()
  local text, key = Errands.Current()
  if key ~= last then last = key; if not key then ns.char.errandDismissed = nil end; ns.Fire("FR_STEP", ns.Engine.Shown()) end
end
ns.On("BAG_UPDATE_DELAYED", check)
ns.On("UPDATE_INVENTORY_DURABILITY", check)
ns.On("FR_LOADED", function() C_Timer.After(5, check); ns.NewTicker(15, ns.Guard("errands", check)) end)
