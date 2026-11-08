# Step 7: Practice bots (optional)

## Goal

Upgrade the step 1 puppets into **practice bots** that can fill empty slots and let a solo player train:
- they navigate the map;
- they attack or defend the objective by role;
- they react to what they **legitimately** see and hear;
- they shoot with tunable reaction time and aim error.

They are **not** a single-player campaign or AI opponents as a product feature (see `README.md`). They exist for practice, testing and filling lobbies.

## Design decisions (already made; don't change without asking)

1. **Fair perception.** Bots know only what a player in their position would know. They use the server's `VisibilityQuery.can_see` and `can_hear` from their own body, so no wallhacks. The same functions protect human players, so bots exercise them constantly.
2. **Same input pipeline.** Bot behaviour only writes `BotBrain` fields (move, aim, fire, slow-walk); it never touches positions or health directly. Everything stays server-simulated and replicated as for humans.
3. **Grid navigation.**
   - Use `AStarGrid2D` over the 16 px wall grid (the map is a tile grid already).
   - When cells are destroyed, mark them walkable (`set_point_solid(cell, false)`): cheap and instant.
   - A Godot navigation mesh would need rebaking after every destruction, which is expensive.
4. **Behaviour as a small state machine,** not a behaviour tree: `HOLD`, `PUSH`, `ENGAGE`, `INVESTIGATE`, `RELOAD`. Enough for practice, and easy to read and test.
5. **Difficulty** is three numbers:
   - `reaction_ms` (default 300);
   - `aim_error_deg` (default 6);
   - `uses_slow_walk` (default true when within 600 px of the objective).

## Architecture

```
scripts/bots/
├─ bot_brain.gd            (step 1) input fields -> PlayerInputFrame
├─ bot_navigator.gd        AStarGrid2D over DestructibleWalls (+ static walls/props marked solid), path following
├─ bot_perception.gd       server-only: visible enemies, last heard position, from VisibilityQuery
└─ bot_controller.gd       state machine, runs on NetworkTick before the bot's NetSync (connect in _ready of a node added before players, or call from WorldSnapshots-like autoload order)
```

**Order within a tick:** the controller must set `BotBrain` fields *before* `PlayerNetSync._server_tick` reads them. The simplest way is to have `PlayerNetSync._server_tick` call `bot_controller.think(tick)` right before `bot_brain.build_input_frame(tick)`.

**Building the navigation grid:**
- Use the map's `DestructibleWalls` bounds.
- A cell is solid if it has a wall tile, or if a physics shape query (mask 1, cell-sized rectangle) hits a static body (props, `map_1` polygons).
- Doors: CLOSED counts as solid unless the bot's route requires it. In that case the bot stops in front of it and interacts. BROKEN/OPEN counts as walkable.
- Listen to `DestructionService.cells_destroyed` and door state changes to update the grid.

## Tasks

1. **`BotNavigator`**: grid build, `find_path(from_world, to_world) -> PackedVector2Array` (cell centres), `next_move_toward(path, position) -> Vector2` (world direction), and updates on destruction and door changes.
   - **Check:** unit test on `tests/fixtures/mini_map.tscn` (step 6): a path exists around a wall; destroying a wall cell shortens it.
2. **`BotPerception`**: each tick (server):
   - `visible_enemies` = enemies with `VisibilityQuery.can_see(bot, enemy, smoke)`;
   - `last_heard` = position and tick of the latest enemy with `can_hear(bot, enemy)`.
   - **Check:** unit test: an enemy behind a hard wall and silent is not perceived; a walking one is heard.
3. **`BotController` state machine:**
   - **PUSH** (attackers; or defenders when the objective is lost): path to the objective zone; slow-walk inside 600 px.
   - **HOLD** (defenders): go to a hold point near the objective and face the most likely entrance (a door or soft wall facing the attacker side; precompute with the navigator).
   - **ENGAGE:** enemy visible for ≥ `reaction_ms` → aim at it with ±`aim_error_deg` noise, re-rolled every 300 ms; hold fire while aimed within 3°; strafe left and right every 0.6 s.
   - **INVESTIGATE:** heard but not seen → path to `last_heard` with slow-walk; give up after 5 s.
   - **RELOAD:** magazine empty and no visible enemy.
4. **Wiring:**
   - `MultiplayerSession.add_bot(difficulty := "normal")`;
   - the round mode auto-fills empty team slots with bots when `fill_with_bots` (lobby toggle, host only) is on;
   - bots get a role-appropriate controller at each FREEZE.
5. **Tests.** `tests/net/practice_bots_test.gd`, on `cqc_1` with short rounds:
   - `attacker_bot_reaches_objective`: a lone attacker bot (no defenders alive) captures the objective within the round time.
   - `bot_engages_visible_enemy`: the host stands in the bot's view → the bot fires within `reaction_ms + 500 ms`.
   - `bot_does_not_see_through_walls`: the host is silent behind a hard wall in the bot's facing direction → the bot never enters ENGAGE.
   - `bot_investigates_noise`: the host runs (footsteps) out of sight → the bot moves toward the host's position.

## Manual playtest

- Solo host plus 3 bots per side on `cqc_1` for several rounds.
- Bots push, hold and fight. They don't wall-hack (watch them while hiding silently), they hear you running, and their difficulty knobs change how hard they are.

## Commit plan

1. `feat: grid navigation for bots` (task 1).
2. `feat: fair bot perception from server vision and hearing` (task 2).
3. `feat: practice bot state machine and lobby fill` (tasks 3–4).
4. `test: add practice bots suite` (task 5).
