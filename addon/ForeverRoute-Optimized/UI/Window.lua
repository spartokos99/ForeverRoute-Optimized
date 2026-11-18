-- The addon's windows (the route window, Where to?, side trips, the quest log check, news, options, the bug report)
-- share one shell: on the dialog layer, kept on screen, dragged anywhere, our panel look and scale, Escape closes it.
-- It was written out in each of them (the code review). Style.Window(f, name) gives frame f that shell; name is its
-- global name (Escape closes it through UISpecialFrames). Style.CloseButton(f): the "x" at the top right.
local _, ns = ...
local Style = ns.Style
local C = Style.C

function Style.Window(f, name)
  f:SetFrameStrata("DIALOG")
  f:SetClampedToScreen(true); f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
  Style.Panel(f, C.bg2); Style.Scaled(f, nil, true)
  if name then table.insert(UISpecialFrames, name) end -- Escape closes it
  return f
end

function Style.CloseButton(f)
  local close = Style.Button(f, "x", 18, 18, function() f:Hide() end, "Close")
  close:SetPoint("TOPRIGHT", -8, -8)
  return close
end
