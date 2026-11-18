-- Quests priced and chains named without a plan (the design for zones and chains, stage 2): ns.QUEST_XP and
-- ns.CHAINS come from QuestData.lua (tools/gen-quest-data.js, tools/chains.js); both are unpacked the first time
-- they are asked for.
--   ns.QuestXp(q, level)  the XP quest q pays at that level (the planner's world.js questXp: full up to 5 levels
--                         below the quest, then 20% less a level, never under 10%); nil for a quest it doesn't know
--   ns.ChainOf(q)         the chain q is part of: { id, name, q = { ids in level order }, z = { area per part }, at = q's part }
local _, ns = ...

local xp -- id -> { base, level }
local function unpackXp()
  xp = {}
  for id, base, lvl in string.gmatch(ns.QUEST_XP or "", "(%d+):(%d+):(%d+)") do xp[tonumber(id)] = { tonumber(base), tonumber(lvl) } end
end

function ns.QuestXp(q, level)
  if not xp then unpackXp() end
  local e = q and xp[q]
  if not e then return nil end
  local base, ql = e[1], e[2]
  level = level or (UnitLevel and UnitLevel("player")) or ql
  local d = level - ql
  if d <= 5 then return base end
  return math.floor(base * math.max(0.1, 1 - 0.2 * (d - 5)) + 0.5)
end

-- a quest's level, from the same table (nil: not known)
function ns.QuestLevel(q)
  if not xp then unpackXp() end
  local e = q and xp[q]
  return e and e[2] or nil
end

local chainOf -- quest id -> chain
local function unpackChains()
  chainOf = {}
  for head, c in pairs(ns.CHAINS or {}) do
    local ch = { id = head, name = c.name, q = {}, z = {} }
    for id in string.gmatch(c.q or "", "%d+") do ch.q[#ch.q + 1] = tonumber(id) end
    for z in string.gmatch(c.z or "", "%d+") do ch.z[#ch.z + 1] = tonumber(z) end
    for n, id in ipairs(ch.q) do chainOf[id] = { chain = ch, at = n } end
  end
end

function ns.ChainOf(q)
  if not chainOf then unpackChains() end
  local e = q and chainOf[q]
  if not e then return nil end
  local ch = e.chain
  return { id = ch.id, name = ch.name, q = ch.q, z = ch.z, at = e.at }
end

-- One line about the chain a quest is part of, for the zone list (the design for zones and chains, 2.6):
--   "Nesingwary: 3 of 9 done, ~14k XP left, goes on in Stranglethorn Vale, gray at 44"
-- the XP is what its parts not done pay at your level; "goes on in" is the next part not done when it's in another
-- zone than this one's; "gray at" the level its next part turns gray. nil for a quest in no chain (or a chain of one).
local function short(n)
  if n >= 10000 then return string.format("%.0fk", n / 1000) elseif n >= 1000 then return string.format("%.1fk", n / 1000) end
  return tostring(math.floor(n))
end
function ns.ChainLine(q, level)
  local ch = ns.ChainOf(q)
  if not (ch and #ch.q > 1) then return nil end
  local S = ns.State
  level = level or (UnitLevel and UnitLevel("player")) or 1
  local done, xpLeft, nextAt = 0, 0, nil
  for n, id in ipairs(ch.q) do
    if S and S.IsCompleted(id) then done = done + 1
    else
      xpLeft = xpLeft + (ns.QuestXp(id, level) or 0)
      nextAt = nextAt or n
    end
  end
  local out = { ch.name .. ": " .. done .. " of " .. #ch.q .. " done" }
  if xpLeft > 0 then out[#out + 1] = "~" .. short(xpLeft) .. " XP left" end
  local names = ns.AREA_NAME or {}
  local here, there = ch.z[ch.at], nextAt and ch.z[nextAt]
  if there and there ~= here and names[there] then out[#out + 1] = "goes on in " .. names[there] end
  local ql = nextAt and ns.QuestLevel(ch.q[nextAt])
  local E = ns.Engine
  if ql and E and E.GrayAt then
    local L = level
    while L < 60 and E.GrayAt(L) < ql do L = L + 1 end
    if E.GrayAt(L) >= ql then out[#out + 1] = (L <= level and "gray now" or ("gray at " .. L)) end
  end
  return table.concat(out, ", ")
end

-- Chains you'd lose by leaving now (2.6/3: don't let wandering lose a chain silently): quests you carry on the route
-- you're on whose chain's next part turns gray within `margin` levels (default 2). -> { { q, line, grayAt } }, soonest first
function ns.ChainsAtRisk(margin)
  local d, S, E = ForeverRouteData, ns.State, ns.Engine
  if not (d and S and E and E.GrayAt) then return {} end
  margin = margin or 2
  local level = (UnitLevel and UnitLevel("player")) or 1
  local out, seen = {}, {}
  -- (your log's quests on the route, in the order they first come: ns.LogQuestsOn's one walk, shared with Where to?'s
  -- rows and kept until the log changes)
  for _, q in ipairs(ns.LogQuestsOn(d).order) do
    local ch = ns.ChainOf(q)
    if ch and not seen["c" .. ch.id] then
      local nextQ
      for n = ch.at + 1, #ch.q do if not S.IsCompleted(ch.q[n]) then nextQ = ch.q[n]; break end end
      local ql = nextQ and ns.QuestLevel(nextQ)
      if ql then
        local L = level
        while L < 60 and E.GrayAt(L) < ql do L = L + 1 end
        if E.GrayAt(L) >= ql and L <= level + margin then
          seen["c" .. ch.id] = true
          out[#out + 1] = { q = q, line = ns.ChainLine(q, level), grayAt = L }
        end
      end
    end
  end
  table.sort(out, function(a, b) return a.grayAt < b.grayAt end)
  return out
end
