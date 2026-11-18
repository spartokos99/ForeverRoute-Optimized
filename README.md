# Forever Route

**Optimized fork (`1.6.8-opt.1`)** of [noopz/ForeverRoute](https://github.com/noopz/ForeverRoute).
The card, arrow, map styling and saved settings are unchanged. This fork reduces repeated quest-state reads,
whole-plan progress scans and stationary route recalculations; it does not replace the routing algorithm.

Leveling routes for WoW Forever, 1 to 60, for all 56 race and class combinations, Alliance and Horde. A step card, an
arrow and map pins tell you what to accept, kill, hand in and train, and how to get to the next zone. Install it and
play: your plan loads by itself, quests you've already done are skipped, and it works at any level.

![The human paladin plan, 1 to 60](docs/img/journey.gif)

## The card

**The next thing to do, always on screen.** It reads your quest log live, counts kills and loot, ticks steps off as you
play, and fits in hand-ins you finished early when you pass by. Skip a quest or a dungeon and the route keeps up.

![The card, step by step](docs/img/card.gif)

## Pick your own zone

**Bored of a zone? Pick another.** "Where to?" (the route window, or `/fr paths`) lists the zones you could go to
now, with the XP each still has for you and the level that gets you to. Pick one and the route takes you there. If a
zone's quests need an earlier part you haven't done, those steps come first when they're close by, and a chain you
carry that's about to turn gray is pointed out before you leave. PLANNED NEXT takes you back to your plan, wherever
you wandered.

![Picking a zone](docs/img/where-to.gif)

## How the plans are made

Routes aren't hand-written. A planner builds them from the quest data and the game's own terrain, and every plan is
played from 1 to 60 by simulated players before it ships - including ones that wander off to other zones.

**It picks the next zone** by planning out every zone that fits your level:

![Choosing the next zone](docs/img/planner-choice.gif)

**It keeps the quests worth doing**, and says why the rest were cut or left for later:

![Picking a zone's quests](docs/img/quest-pick.gif)

**It finds the fastest way there** across one network of roads, boats, the tram, flights, class teleports and the
Skyborne skyship:

![Finding a trip](docs/img/travel.gif)

**Every plan, checked** - hours to 60, no grinding:

![Every plan, checked](docs/img/plans.gif)

## Getting started

For this fork, close WoW and copy the contents of `addon\ForeverRoute-Optimized` into
`Interface\AddOns\ForeverRoute`, replacing the existing Forever Route files. The installed folder must be named
`ForeverRoute` to match its `.toc` file and the starter plans' dependency. Also copy your character's
`ForeverRoute_Starter_*` folder (or all starter plans) into `Interface\AddOns`. Back up your existing addon and
SavedVariables first; do not delete SavedVariables. Do not install the repository folder itself as an addon.

The original, unoptimized upstream release is available on CurseForge and [upstream Releases](https://github.com/noopz/ForeverRoute/releases).
The plan for your race and class loads by itself and starts you on the best part of it for your level and where you
are. Open any flight master's map once so the addon knows your flight paths.

| Command | What it does |
|---|---|
| `/fr` | Show or hide the card |
| `/fr list` | The whole route |
| `/fr paths` | Where to? - the zones you could go to now |
| `/fr dungeons` | Side trips: class quests, bonus items, dungeons |
| `/fr skip` · `/fr back` · `/fr undo` | Move through the steps by hand |
| `/fr logcheck` | Quests in your log the route won't use |
| `/fr why` | Why the addon did what it just did |
| `/fr perf` | Observed refresh/progress average and maximum timings; no forced recalculations |
| `/fr report` | Copy a bug report to paste to us (anonymous) |
| `/fr news` | What changed in recent versions |
| `/fr options` | Settings |

What changed in each release: [CHANGELOG.md](CHANGELOG.md). Something look wrong? `/fr report` and an issue here.

## Performance changes and verification

The recurring expensive paths included full progress scans, the solver's five-second stationary retry, and timed
full-list rebuilds. Quest updates now retain unchanged cache entries, settle bursts once and distinguish objective
counts from readiness/membership changes. Progress totals are cached with event-driven invalidation; quest-local
changes update affected steps and their dependencies, while structural changes still invalidate conservatively.
Card/map updates share status reads, and nearby-extra text no longer broadcasts a full step change.

`/fr perf` now observes actual work rather than running ten engine refreshes as a benchmark. Before any work has been
sampled it says "not sampled yet". Reports retain event/timer call counts and average/max durations; event timings
include their listeners and nested events, so they must not be added together as exclusive CPU times.

Run the headless checks from the repository root with Lua 5.1:

```powershell
lua tests\performance.lua
```

Alternatively, with Node.js, install the portable test tools outside the repository:

```powershell
$tools = Join-Path $env:TEMP "foreverroute-lua-tools"
npm install --prefix $tools --no-save fengari-node-cli luaparse
& "$tools\node_modules\.bin\fengari.cmd" -e 'local ok, err = xpcall(function() dofile([[tests\performance.lua]]) end, debug.traceback); if not ok then print(err); os.exit(1) end'
$env:NODE_PATH = "$tools\node_modules"
node tests\syntax.cjs
```

The explicit exit wrapper makes Lua assertion failures fail the Fengari command. Fengari is not WoW's Lua runtime;
the separate parser check enforces Lua 5.1 syntax for all addon and test files.

Checks compare cached totals with uncached engine statuses across objective completion/regression, turn-in,
abandonment, collapsed/legacy logs, burst events, XP/items/cooldowns, manual actions and route switches. They also
exercise the actual small-route solver, stationary/movement scheduling, passive diagnostics and UI invalidation
with fake frames (not visual rendering). Performance gates require **zero quest API calls and zero status reads
for unchanged warm progress**, at most 12 status reads after one quest completes on the 3,000-step synthetic route,
and no repeated solves while standing for 60 simulated seconds.

Example measurements in the Node/Fengari fixture:

| Shipped plan | Steps | Uncached progress reference | Warm cached progress |
|---|---:|---:|---:|
| Human paladin | 2,739 | ~1,150 ms | ~0.03 ms |
| Orc warrior | 2,443 | ~540 ms | ~0.03 ms |

These compare the same engine's uncached reference and cached reads in one mocked run, **not in-game frame times**.
The first read after full invalidation still evaluates the plan. Unchanged log events still check the active
quests' objectives and readiness (41 quest API calls for 20 active quests in this fixture), but no longer scan
the whole route or discard its quest cache.

Verify on the Forever client after installation: stand still for a minute, move between quest givers, update and
finish an objective, abandon/reaccept a quest, and switch routes with the list open. Check card, arrow and pins,
then collect `/fr perf` and `/fr report` if stalls remain. This repository's checks cannot establish that the
reported freezes are eliminated on your client.

This repository holds the addon and its built-in plans. The planner that builds the plans and its simulator are not
public.

Forever Route by noopz. [CC BY-NC-SA 4.0](LICENSE): share and adapt it with credit, never sell it. The quest data it is
built from is GPL-3.0 (QuestieDB); see [NOTICE](NOTICE). Contributions: [CONTRIBUTING.md](CONTRIBUTING.md).
