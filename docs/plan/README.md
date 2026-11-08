# GreyLine roadmap: real-time PvP CQC

This folder is the build plan for turning GreyLine into a **real-time PvP close-quarters (CQC) tactical shooter**:
- top-down 2D;
- two teams, attack/defend rounds, one life per round;
- destructible walls and doors;
- **sound as information** as the core identity.

There is **no planning phase and there are no AI opponents.** Bots exist only as development and practice tools.

Each step file is written so that an implementing agent can follow it task by task without re-deriving the design. Read this file first, then only the step you are working on.

## Steps (do them in order)

| # | Step | File | Depends on |
|---|---|---|---|
| 1 | Bot puppets (test infrastructure) | [01-bot-puppets.md](01-bot-puppets.md) | — |
| 2 | Teams and team vision | [02-teams.md](02-teams.md) | 1 |
| 3 | Silent slow-walk | [03-silent-slow-walk.md](03-silent-slow-walk.md) | 1 |
| 4 | Destructible walls and doors | [04-destruction-and-doors.md](04-destruction-and-doors.md) | 1, 2 |
| 5 | Round-based attack/defend mode | [05-rounds.md](05-rounds.md) | 2, 4 |
| 6 | First CQC map | [06-cqc-map.md](06-cqc-map.md) | 4, 5 |
| 7 | Practice bots (optional) | [07-practice-bots.md](07-practice-bots.md) | 1, 5 |

**Why bots come first:** the user listed bots last as a "nice to have". But steps 2, 4 and 5 all need **three or more players** in their automated tests (for example: a teammate sees an enemy that you can't). A *puppet* bot is a server-side player driven by a script, with no AI. It takes about one day of work and makes every later test possible without a third Godot process. Smarter practice bots stay at the end, as step 7.

## Architecture you are building on (read before any step)

These are already in the code (branch `fix/netcode-input-sync`, PR #1). Do not redesign them; extend them.

| Piece | Where | What it does |
|---|---|---|
| Server authority | everywhere | The server decides movement, hits, damage, ammo, inventory and visibility. Clients send only input. |
| `NetworkTick` | `scripts/network/network_tick_clock.gd` (autoload) | Fixed 60 Hz simulation tick. Every gameplay system steps on `NetworkTick.tick_started`. **Handlers run in connection order:** a player's `NetSync` runs before the player's own handler, which runs before its equipment. |
| `PlayerInputFrame` | `scripts/network/data/player_input_frame.gd` | One tick of input. Packed wire format `to_packed()`/`from_packed()`; **if you add a field, update `PACKED_SIZE`, `to_packed`, `from_packed` and the validation**. |
| `PlayerNetSync` | `scenes/player/_scripts/player_net_sync.gd` (child `NetSync` of `player.tscn`) | Per-player netcode: input stamping and prediction (owner), the input queue and simulation (server), interpolation and fog-of-war presence (proxies), and the replicated action RPCs (`_remote_*`). |
| `WorldSnapshots` | `scripts/network/world_snapshot_service.gd` (autoload) | Every 2 ticks: one packed packet per peer. It contains only the players that peer can see or hear. Packet layout is the `P_*` constants. |
| `VisibilityQuery` | `scripts/network/server/visibility_query.gd` | Server-side line of sight (110° cone, 1536 px, walls on physics layer 1, smoke circles) and hearing (`net_sync.get_noise_radius()`). |
| Noise | `PlayerNetSync.report_noise()` / `get_noise_radius()` | Any sound a player makes has a radius and a duration; listeners inside the radius receive the player as **AUDIBLE** (positioned, but not drawn). |
| Game mode | `components/deathmatch/` | `deathmatch.gd` (rules and flow), `match_player_spawner.gd` (`Spawning`), `match_scoreboard.gd` (`Scoreboard`). |
| Session | `scripts/network/multiplayer_session.gd` (autoload) | Host/join, lobby data (`player_names`, `player_avatar_ids`), and starting the match. ENet throttle is disabled per peer. |
| Tests | `tests/` | `tests/run_tests.sh`: `unit` plus two-process network scenarios (`sync`, `visibility`, `firing`, `match`). The pre-commit hook runs them on the staged snapshot. |

Physics layers (`project.godot`):
1. `Environment`
2. `PlayerCollision`
3. `PickupArea`
4. `PlayerHead`
5. `PlayerBody`
6. `Projectile`

RPC channels used:
- 0: input (unreliable)
- 1: world (snapshots unreliable, setup and health reliable)
- 2: UI/actions (reliable)

New reliable state such as destruction uses **channel 3** (see step 4).

## Rules for the implementing agent

1. **Read `AGENTS.md`.** Godot 4.7, GDScript with static types (`var x: int`, `:=`), `snake_case`. Match the indentation of the file you edit (tabs in almost every gameplay script).
2. **One task at a time.** Every step is split into numbered tasks. Finish each task, then run its check (usually `tests/run_tests.sh unit` or one suite), before moving on. Never start the next task while a test is failing.
3. **Run the full suite before each commit:** `tests/run_tests.sh`. The pre-commit hook will also do this. Never commit with `SKIP_TESTS=1` unless the step file says so explicitly.
4. **One logical change per commit.** Each step file ends with a commit plan; follow it. The commit message is imperative and specific, explaining *what* and *why*.
5. **Keep `.uid` files.** New scripts get a `.gd.uid`. Run `godot --headless --path . --import` once after adding scripts; it creates them. Commit them with the script.
6. **Editing `.tscn` by hand is allowed but must be careful:**
   - add an `[ext_resource]` line with a new unique `id`;
   - give each new `[node]` a `unique_id=` (a random 9–10 digit number that does not already appear in the file: check with `grep`);
   - keep `parent=` paths exact;
   - after editing, run the unit suite (it loads the main scenes).
   - Prefer building simple UI in code over large scene edits.
7. **Never trust the client.** Anything that changes the game (damage, doors, team switches, destruction) happens on the server and is replicated. Validate every `any_peer` RPC with `multiplayer.get_remote_sender_id()`.
8. **Do not:**
   - add AI opponents, planning phases or pause;
   - send per-second timer RPCs (send end ticks instead);
   - add new `has_method`/`call("…")` lookups (use types);
   - poll with `get_node("/root/…")` for autoloads (use the autoload name);
   - skip tests;
   - weaken an existing test to make it pass.
9. **If a design question isn't answered in the step file, stop and ask** rather than inventing gameplay rules.
10. **Known pitfalls** (all hit during PR #1):
    - `move_and_slide()` uses the render-frame delta outside physics frames. Always move through `MovementCompoent.simulate()`.
    - The RPC node path must be identical on every peer. Spawn replicated nodes under `Map` through a `MultiplayerSpawner`, or create them at fixed paths.
    - Autoloads are created in `project.godot` order. `PlayerProfile` does not exist yet during `MultiplayerSession._ready`.
    - The owning client predicts fire, reload and switch and ignores the server's `_remote_*` echo for itself. New predicted actions must follow the same pattern.
    - Any test that measures latency must count `NetworkTick.tick`, not physics frames.

## Definition of done (every step)

- All tasks done, and the new tests listed in the step exist and pass.
- `tests/run_tests.sh` passes **twice in a row** (catches flakiness).
- The manual playtest checklist in the step was run with a host and one client. Note the results in the PR description.
- `AGENTS.md` is updated if the step adds a convention, a test suite or an action.
- Commits follow the step's commit plan.

## References (why these designs)

- **Server-side fog of war, sending only what a player could see or will soon see:**
  - Riot's VALORANT write-up, [Demolishing Wallhacks with VALORANT's Fog of War](https://technology.riotgames.com/node/108). It is based on League of Legends' fog of war. GreyLine's `WorldSnapshots` + `VisibilityQuery` already follow this model; steps 2 and 4 extend it.
  - Open-source example of the same idea: [CornerCulling](https://github.com/87andrewh/CornerCulling).
- **Sound through destructible spaces:** Rainbow Six Siege splits maps into spaces linked by connection points (doors, windows, destructible walls) and routes sound along the best current path. See [Game Developer deep dive](https://gamedeveloper.com/design/game-design-deep-dive-dynamic-audio-in-destructible-levels-in-i-rainbow-six-siege-i-) and [Ubisoft status report](https://www.ubisoft.com/en-us/game/rainbow-six/siege/news-updates/HyDyYTuRkWtyYQ3WDFeEL/rainbow-six-siege-status-report). Step 4 starts with a simpler raycast attenuation and leaves the portal graph as a later upgrade.
- **Destructible grid in Godot:** `TileMapLayer` has per-cell collision (`collision_enabled`) and light occlusion (`occlusion_enabled`), `erase_cell()`, `get_coords_for_body_rid()`, and `update_internals()` to apply changes immediately. See [TileMapLayer docs](https://docs.godotengine.org/en/4.4/classes/class_tilemaplayer.html).
- **Round flow:** freeze, live and end phases with server-driven timers; the common structure of round-based tactical shooters ([round phases as exposed by CS2 game-state integration](https://docs.rs/cs2-gsi/0.1.1/src/cs2_gsi/model/round.rs.html), [`mp_freezetime`](https://csdb.gg/commands/mp_freezetime)).
- **Bots that feed the same input pipeline as humans,** so the server simulates them exactly like players. This is how classic server-side shooter bots work: the bot produces the same per-tick input command a client would send.
