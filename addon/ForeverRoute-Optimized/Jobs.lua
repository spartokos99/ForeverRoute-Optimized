-- Work spread over frames, one queue for all of it. A job is a coroutine; the queue's driver resumes one job a frame,
-- for up to its budget in ms (ns.MaybeYield pauses it inside its long loops), in order of kind - "route" (the passes
-- after a route change and their refreshes: Engine.After), then "solve" (the live next-stop solve: Next.PickAsync) -
-- and first come first served within a kind. This is the only place that sets ns.sliceCo for the frame's slice: two
-- drivers each spending their own budget in the same frame added up.
--   ns.Jobs.Post(kind, fn, opts) -> job    opts: budget (ms a frame), arg (passed to fn), gen (the route change it is
--       for: a newer one drops it - Engine.routeGen), enter / leave (around each slice: a job's own state swapped
--       in and out), abort(job, why) (dropped or failed: put back what a half-done pass left), done(result), fail(err),
--       logAs (the error log's tag), timeAs (ns.Time's name for a slice)
--   ns.Jobs.Busy(kind), ns.Jobs.Cancel(kind), ns.Jobs.Settle(kind) (run them to their end now), ns.Jobs.Inside(kind)
-- Jobs.SYNC: a route job runs to its end inside Post (tests, the simulated players and tools/replay.js: the passes run
-- at their timers' times, as they always did, so a run's results are the same by construction).
local _, ns = ...
local Jobs = { SYNC = false, ROUTE_MS = 8 }
ns.Jobs = Jobs

local PRI = { route = 1, solve = 2, verify = 3, zonetrips = 4 }
local queue = {}
local seq = 0
local driver = CreateFrame and CreateFrame("Frame") or nil
Jobs._driver = driver -- (the perf battery ticks it)
Jobs.current = nil -- the job being resumed
Jobs._queue = queue -- (tests)

function Jobs.Mark(phase)
  local job = Jobs.current
  if not (job and job.kind == "solve" and coroutine.running() == job.co) then return nil end
  local previous = job.phase
  if previous ~= phase then
    local now = debugprofilestop()
    if previous and ns.Time then ns.Time("solve phase " .. previous, now - job.phaseAt) end
    job.phase, job.phaseAt = phase, now
  end
  return previous
end

local function sortQueue()
  table.sort(queue, function(a, b) if a.pri ~= b.pri then return a.pri < b.pri end return a.seq < b.seq end)
end
local function remove(job)
  for i, j in ipairs(queue) do if j == job then table.remove(queue, i); break end end
  job.over = true
  if #queue == 0 and driver then driver:Hide() end
end
-- (Jobs.posted(job) and Jobs.ended(job): the engine's hooks - a route job starts and ends its lock, Engine.CheckIdle)
local function ended(job) if Jobs.ended then Jobs.ended(job) end end
local function abort(job, why)
  remove(job)
  if job.abort then local ok, e = pcall(job.abort, job, why); if not ok and ns.LogError then ns.LogError("jobs", e) end end
  ended(job)
end
Jobs._stale = function(job) return job.gen ~= nil and ns.Engine ~= nil and job.gen ~= ns.Engine.routeGen end

-- one slice of job (budget ms; math.huge: to its end). -> true when the job is over
local function resume(job, budget)
  if job.over then return true end
  if Jobs._stale(job) then abort(job, "stale"); return true end
  local co0, t00, b0, cur0 = ns.sliceCo, ns.sliceT0, ns.sliceBudget, Jobs.current
  if job.enter then job.enter(job) end
  local t0 = debugprofilestop()
  ns.sliceCo, ns.sliceT0, ns.sliceBudget = job.co, t0, budget or job.budget
  Jobs.current = job
  if job.kind == "solve" then job.phaseAt = t0 end
  job.slices = (job.slices or 0) + 1
  local ok, r = coroutine.resume(job.co, job.arg)
  if job.kind == "solve" and job.phase and ns.Time then ns.Time("solve phase " .. job.phase, debugprofilestop() - job.phaseAt) end
  Jobs.current = cur0
  ns.sliceCo, ns.sliceT0, ns.sliceBudget = co0, t00, b0
  if job.timeAs and ns.Time then ns.Time(job.timeAs, debugprofilestop() - t0) end
  if job.leave then job.leave(job) end
  if job.over then return true end -- (cancelled while it ran)
  if not ok then
    abort(job, "error")
    if ns.LogError then ns.LogError(job.logAs or job.kind, r) end
    if job.fail then job.fail(r) end
    return true
  end
  if coroutine.status(job.co) == "dead" then
    remove(job)
    if job.done then job.done(r) end
    ended(job)
    return true
  end
  return false
end
Jobs._resume = resume

function Jobs.Post(kind, fn, opts)
  opts = opts or {}
  seq = seq + 1
  local job = { kind = kind, pri = PRI[kind] or 9, seq = seq, co = coroutine.create(fn), arg = opts.arg,
    budget = opts.budget or (kind == "route" and Jobs.ROUTE_MS) or 1, gen = opts.gen, enter = opts.enter, leave = opts.leave,
    abort = opts.abort, done = opts.done, fail = opts.fail, logAs = opts.logAs, timeAs = opts.timeAs }
  queue[#queue + 1] = job
  sortQueue()
  if Jobs.posted then Jobs.posted(job) end
  if Jobs.SYNC and kind == "route" then
    local g = 0
    while not resume(job, math.huge) and g < 100000 do g = g + 1 end
  elseif driver then driver:Show() end
  return job
end
function Jobs.Busy(kind)
  for _, j in ipairs(queue) do if not kind or j.kind == kind then return true end end
  return false
end
-- inside a job's slice (of that kind): coroutine.running() is that job, whether or not it may pause just now
function Jobs.Inside(kind)
  local j = Jobs.current
  return j ~= nil and (not kind or j.kind == kind) and coroutine.running() == j.co
end
function Jobs.Cancel(kind)
  for i = #queue, 1, -1 do local j = queue[i]; if j and (not kind or j.kind == kind) then abort(j, "cancel") end end
end
-- (tests and the simulated players: run the jobs of that kind to their end now)
function Jobs.Settle(kind)
  local g = 0
  while g < 100000 do
    g = g + 1
    local job
    for _, j in ipairs(queue) do if not kind or j.kind == kind then job = j; break end end
    if not job then return end
    resume(job, math.huge)
  end
end
-- a frame's slice: the first job in the queue
function Jobs.Step()
  if ns.sliceCo then error("Jobs: a slice is running already", 0) end
  local job = queue[1]
  if not job then if driver then driver:Hide() end return end
  Jobs._stepping = job
  resume(job)
  Jobs._stepping = nil
end
if driver then
  driver:Hide()
  driver:SetScript("OnUpdate", function()
    local ok, err = pcall(Jobs.Step)
    if not ok then
      local j = Jobs._stepping
      ns.sliceCo, Jobs.current, Jobs._stepping = nil, nil, nil
      local live = j and not j.over
      if live then abort(j, "error") end
      if ns.LogError then ns.LogError((j and (j.logAs or j.kind)) or "jobs", err) end
      if live and j.fail then j.fail(err) end
    end
  end)
end
