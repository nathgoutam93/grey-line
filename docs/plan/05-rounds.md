# Step 5: Round-based attack/defend mode

## Goal

A new game mode, separate from deathmatch:
- **two teams, one life per round**;
- one team **attacks** and the other **defends** an objective room;
- a short freeze at round start (no planning: a few seconds to get set, then go);
- rounds end on elimination, objective capture or time-out;
- sides swap at half-time;
- the match is won by the first team to reach `rounds_to_win`.

Walls, doors and players reset every round.

## Design decisions (already made; don't change without asking)

| Topic | Decision |
|---|---|
| Teams vs roles | Teams are fixed for the match: `Teams.ALPHA` / `Teams.BRAVO` (step 2). **Roles** (`ATTACK` / `DEFEND`) are assigned per half. `attacking_team` is the team attacking this round. |
| Phases | `WAITING` (fewer than 1 player per team) → `FREEZE` (5 s, can't move or fire) → `LIVE` (120 s) → `ROUND_END` (5 s) → next `FREEZE`, or `MATCH_END` |
| Win conditions | Elimination (a team has no living players) → the other team. Time-out → **defenders**. Objective → attackers. |
| Objective | An `ObjectiveZone` (Area2D, group `objective`). Attackers win by keeping **≥1 attacker and 0 defenders** inside for `objective_hold_seconds` (10 s) in total during the round. Progress pauses while contested, never decays, and resets each round. It's deliberately simple, and not a bomb. |
| Respawn | None during LIVE. Every player is re-spawned fresh (full health, default loadout) at their role's spawns at the start of each FREEZE. |
| Spectating | The dead spectate a living teammate. The server sends the dead viewer's packet *from the spectated teammate's view*, so there's no extra information. |
| Halves | Swap roles after `rounds_to_win - 1` rounds. First to `rounds_to_win` (default 4) wins. |
| Economy | **None in v1** (fixed loadouts). Note it as a possible later step. |
| Timers | Replicated as **end ticks**, never per-second RPCs. |

## Architecture

The pattern used by round-based shooters: a server-side state machine with phases and end times. Clients receive phase changes as events and run their countdown locally from the end tick.

```
RoundGameMode (components/round_mode/round_mode.gd, group "game_mode")
├─ Spawning     MatchPlayerSpawner (reused; gains respawn_everyone() and role-based spawns)
├─ Scoreboard   MatchScoreboard (reused; team_scores = round wins in this mode)
└─ UI (CanvasLayer built like deathmatch_game_mode.tscn: timer, round score, objective bar, result overlay)

Server, on every NetworkTick:
  match phase:
    FREEZE   -> when tick >= phase_end_tick: LIVE
    LIVE     -> check elimination / objective / tick >= phase_end_tick
    ROUND_END-> when tick >= phase_end_tick: next round (FREEZE) or MATCH_END
  each phase change: _phase_event.rpc(phase, server_tick_now, phase_end_tick, round_index, attacking_team, team_scores)
Client:
  local_end_tick = NetworkTick.tick + (phase_end_tick - server_tick_now)   # computed on receipt
  timer label   = ceil((local_end_tick - NetworkTick.tick) / tick_rate)
```

**Locking players during FREEZE.**
- `PlayerController.actions_locked: bool`.
- `MovementCompoent.simulate` uses `move = Vector2.ZERO` when locked (aim still turns).
- `PlayerNetSync._apply_input_actions` skips fire, reload, switch, drop and interact when locked.

Set it on the server by the mode, and on clients from the phase event, so owner prediction agrees. A small mismatch at unlock is corrected by the normal reconciliation.

**Spectating.**
- Server: `spectate_target := {peer_id: target_peer_id}`. `WorldSnapshotService._find_player_node(peer)` falls back to the spectate target when the viewer has no living player.
- Client: when the local player is dead, the camera and `MaskViewProvider.viewport.player` / `player_camera` follow the target.
- `request_spectate_next()` RPC (any_peer, validated) cycles through living teammates.

## Contracts

`components/round_mode/round_mode.gd`:

```gdscript
extends Node
class_name RoundGameMode
enum Phase { WAITING, FREEZE, LIVE, ROUND_END, MATCH_END }
enum Role { ATTACK, DEFEND }
@export var rounds_to_win := 4
@export var freeze_seconds := 5.0
@export var round_seconds := 120.0
@export var round_end_seconds := 5.0
@export var objective_hold_seconds := 10.0
@export var friendly_fire := false
var phase: Phase
var round_index := 0
var attacking_team: int            # Teams.ALPHA or Teams.BRAVO
var objective_progress := 0.0      # 0..1, server; replicated at 5 Hz while it changes
func role_of(team: int) -> Role
func is_actions_locked() -> bool   # phase in [WAITING, FREEZE, ROUND_END, MATCH_END]
@rpc("authority", "call_local", "reliable", 2) func _phase_event(phase: int, server_tick: int, end_tick: int, round_index: int, attacking_team: int, team_scores: Dictionary, winner_team: int)
@rpc("authority", "call_local", "unreliable", 2) func _objective_progress_event(progress: float)
```

`MatchPlayerSpawner` additions:
- `spawn_point_for(peer_id)` now uses the **role** when a `RoundGameMode` is present. Spawn containers: `SpawnPoints/AttackerSpawns` and `SpawnPoints/DefenderSpawns`. In team deathmatch, ALPHA uses `AttackerSpawns` and BRAVO uses `DefenderSpawns`.
- `respawn_everyone()` (server):
  - set `spawning_enabled = false`;
  - free every player node;
  - wait one frame;
  - set `spawning_enabled = true`;
  - `spawn_player` for every connected peer and bot;
  - set `spawning_enabled = false` again until the next round (so deaths during LIVE don't respawn).

Map requirements for round maps (enforced by the step 6 validation test):
- `SpawnPoints/AttackerSpawns` and `SpawnPoints/DefenderSpawns` (≥ 5 points each);
- exactly one `ObjectiveZone`;
- a `DestructionService`;
- a `RoundGameMode` instance.

## Tasks

1. **Generic game-mode lookup.**
   - Both game modes join group `game_mode`.
   - In `tests/net/net_test_base.gd`, change `game_mode()` to `get_tree().get_first_node_in_group("game_mode")`.
   - Replace any `find_child("DeathmatchGameMode")` use.
   - **Check:** the full suite passes.
2. **Action lock** (`actions_locked` on the player; the movement and action gating described above).
   - **Check:** unit test: a locked player's `simulate` with move input doesn't move, but rotation follows `aim_dir`.
3. **`RoundGameMode` skeleton**: phases, ticking on `NetworkTick.tick_started` (server), `_phase_event`, and client timer computation.
   - The scene `components/round_mode/round_game_mode.tscn` is built like `deathmatch_game_mode.tscn` (copy its UI layer), with `Spawning` and `Scoreboard` children.
   - **Check:** host-only manual run: phases cycle with the timer.
4. **Role-based spawns and `respawn_everyone()`** (above). FREEZE start calls `respawn_everyone()` and `DestructionService.reset_all()` (step 4).
5. **Win conditions**: elimination, time-out and objective.
   - `ObjectiveZone` scene `components/round_mode/objective_zone.tscn`: an `Area2D` on layer 3 with mask 2 (player collision), plus a visual.
   - The server counts live players per role inside it each tick.
   - On a round win: `team_scores[winner] += 1`, then ROUND_END.
6. **Halves and match end.** Swap `attacking_team` when `round_index == rounds_to_win - 1` (0-based count of finished rounds). MATCH_END shows the result overlay and returns to the lobby, as in deathmatch.
7. **Spectating** (server fallback in `WorldSnapshots`; client camera, mask and `request_spectate_next`).
8. **HUD**: round score (ALPHA x – y BRAVO), your role (ATTACK/DEFEND), the countdown, and the objective progress bar (visible only while > 0).
9. **Dev map.**
   - Create `scenes/maps/map_1/map_1_rounds.tscn`: copy `map_1.tscn` and replace the `DeathmatchGameMode` instance with `RoundGameMode`.
   - Split `SpawnPoints` into `AttackerSpawns` (sp_1–sp_3) and `DefenderSpawns` (sp_4–sp_6). Add one `ObjectiveZone` in an open area.
   - Add a lobby map picker: a button that cycles through a `MAPS` list in `MultiplayerSession`, host only, using the existing `set_selected_map_scene_path`.
   - **Check:** the unit suite loads `map_1_rounds.tscn`.
10. **Tests.** `tests/net/rounds_test.gd` (add to `ALL_SUITES`):
    - Add a `map` option to `net_test_base`: when `--map=<path>` is passed, call `set_selected_map_scene_path` before `start_match`. Update `run_tests.sh` to pass it for this suite.
    - Use the host, the client and one bot. Shorten timers on the server right after the mode spawns (`freeze_seconds = 2`, `round_seconds = 6`, `objective_hold_seconds = 2`, `rounds_to_win = 2`).

    Checks:
    - `freeze_blocks_movement`: the client holds `move_up` during FREEZE → its server position is unchanged.
    - `elimination_ends_round`: the host kills every opponent → ROUND_END, with the correct winner and score 1–0 on the client.
    - `no_respawn_during_live`: the dead player has no live player node until the next FREEZE.
    - `round_reset`: destroy 2 cells (fixture from step 4) during LIVE → restored next round; everyone alive at role spawns with full health.
    - `timeout_goes_to_defenders`: nobody acts → the defenders win when the time runs out.
    - `objective_capture`: the attacker bot stands in the zone alone → the attackers win after the hold time.
    - `sides_swap_and_match_ends`: after the half the roles flip; the first to 2 wins MATCH_END and the client shows its result.
    - `client_timer_matches_server`: the client's displayed seconds are within 1 of the server's.

## Edge cases

- **A player disconnects during LIVE:** counts as dead for elimination. Their team may be eliminated.
- **WAITING:** if a team has no players at FREEZE start, stay in WAITING (no round starts) and show "Waiting for players".
- **A death in FREEZE** (for example a leftover frag): treat it like LIVE (no respawn).
- **A late joiner during a round:** the existing rule disconnects joiners after `match_started`. Keep it; mid-match joining is out of scope.
- **ROUND_END:** players can still move but can't damage each other (`actions_locked`).

## Manual playtest

Two players and a bot, on `map_1_rounds`:
- freeze, then go;
- kill everyone → round won;
- next round everyone is back and the walls are restored;
- capture the objective as attacker;
- let the time run out as defender;
- the halves swap;
- the match ends at 4 rounds;
- spectating a teammate works when dead.

## Commit plan

1. `refactor: look up the game mode by group` (task 1).
2. `feat: lock movement and actions per game phase` (task 2).
3. `feat: add round-based attack/defend game mode` (tasks 3–6).
4. `feat: spectate teammates while dead` (task 7).
5. `feat: round HUD and dev rounds map with lobby map picker` (tasks 8–9).
6. `test: add rounds network suite` (task 10).
