-- Small shared helpers (the code review: each was written two to four times, and copies drift).
--   ns.Util.WPos(s)       a step's world position { x, y, instance } (cached per step), or nil (no place, or unknown)
--   ns.Util.MapName(m)    a map's name ("map <id>" when the game has none)
--   ns.Util.PlanRoute()   your plan: the path you return to, else the first main route
--   ns.Nope(q)            you said you won't do quest q (its value: true, or how)
local _, ns = ...
local Util = {}
ns.Util = Util
local HBD = LibStub("HereBeDragons-2.0")

local worldOf = setmetatable({}, { __mode = "k" })
function Util.WPos(s)
  if not (s and s.m and s.x and s.y) or s.unknown then return nil end -- (an unknown step's spot is only its place in the order)
  local w = worldOf[s]
  if w == nil then local x, y, inst = HBD:GetWorldCoordinatesFromZone(s.x, s.y, s.m); w = x and { x, y, inst } or false; worldOf[s] = w end
  return w or nil
end

function Util.MapName(m)
  local i = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(m)
  return (i and i.name) or ("map " .. tostring(m))
end

function Util.PlanRoute()
  return (ns.ResolvePath and ns.ResolvePath(ns.char and ns.char.returnTo)) or (ns.MainRoutes and ns.MainRoutes()[1])
end

function ns.Nope(q) return q and ns.char and ns.char.nope and ns.char.nope[q] end
