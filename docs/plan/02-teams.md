# Step 2: Teams and team vision

## Goal

Players belong to one of two teams, **Alpha** or **Bravo**:
- Teams are picked in the lobby; the server auto-balances.
- Teammates are always visible to each other.
- Weapon friendly fire is off by default. Frag explosions damage both teams and the thrower.
- Players spawn at their team's spawns.
- Deathmatch becomes **team deathmatch**: the team score is the sum of member kills, and the score limit applies to the team. This is the stepping stone to step 5 (rounds).

## Design decisions (already made; don't change without asking)

1. **Teammates are always sent and always drawn.**
   - `WorldSnapshots` always includes teammates as VISIBLE.
   - Clients draw teammates without the fog-of-war mask, with a team tint, so you always know where your team is (standard for tactical shooters).
2. **Enemies follow your own line of sight**, exactly as now. A teammate seeing an enemy does **not** make that enemy visible in your world view. That would be a wallhack against the enemy, and it would kill the "sound as information" identity. The optional task 9 adds teammate *spotting* as a HUD marker, not a body.
3. **Hearing stays per listener.** You hear what *you* can hear.
4. **The server is the authority on teams.** Clients request a team; the server decides, keeping balance within ±1.
5. **Teams are ints:** `Teams.ALPHA = 0`, `Teams.BRAVO = 1`, `Teams.NONE = -1`. Store them as `int` everywhere (Dictionary values, RPC args).
6. **A team is not a role.** Teams stay fixed for a match. In step 5 (rounds), each team *attacks* or *defends* per half, and the sides swap. So spawn containers are named by **role**: `AttackerSpawns` and `DefenderSpawns`. In team deathmatch (this step), ALPHA uses `AttackerSpawns` and BRAVO uses `DefenderSpawns`.

## Architecture

Server-side visibility per team is the League of Legends / VALORANT model (see README references), with one twist: enemies use only the viewer's own vision, while teammates are always included.

```
MultiplayerSession.player_teams {peer_id: team}       authoritative on the server, synced in lobby data
  -> MatchPlayerSpawner._setup_player(..., team)      sets PlayerController.team on every peer
  -> WorldSnapshots._packet_for_peer: teammate => FLAG_VISIBLE always
  -> WeaponInstance: Teams.can_damage(attacker, victim) before take_damage
  -> FragProjectile: server applies blast damage to all nearby players, regardless of team
  -> MatchScoreboard: per-team score; Deathmatch: team score limit
  -> client: PlayerController.apply_team_visuals() (tint, no FOW mask for teammates)
```

## Contracts

New `scripts/game/teams.gd`:

```gdscript
extends RefCounted
class_name Teams

const NONE := -1
const ALPHA := 0
const BRAVO := 1
const COLORS := {ALPHA: Color("#e8a33d"), BRAVO: Color("#3d8de8")}
const NAMES := {ALPHA: "Alpha", BRAVO: "Bravo"}

static func display_name(team: int) -> String
static func other(team: int) -> int
static func is_teammate(a: PlayerController, b: PlayerController) -> bool      # same team and team != NONE
static func can_damage(attacker_team: int, victim_team: int, attacker_id: int, victim_id: int, friendly_fire: bool) -> bool
    # self damage (attacker_id == victim_id) is always allowed (own frag); NONE vs anything is allowed (FFA)
static func pick_team_for_new_player(teams: Dictionary) -> int                 # smaller team; ties -> ALPHA
static func can_switch(teams: Dictionary, peer_id: int, wanted: int, max_per_team: int) -> bool
```

`MultiplayerSession`:
- `var player_teams := {}`.
- `get_team(peer_id) -> int`.
- `set_team(peer_id, team)` (server only; used by tests and the lobby).
- `@rpc("any_peer","call_remote","reliable",RPC_CHANNEL_UI) func request_team(team: int)`: the server validates with `Teams.can_switch` and refuses once `match_started`.
- **Signature change:** `_sync_lobby_data_to_all(names, avatars, teams, has_started)`. Update every caller (5 call sites today: `grep -n "_sync_lobby_data_to_all" scripts/network/multiplayer_session.gd`) and add `"player_teams"` to `get_lobby_sync_payload()`.
- Assign a team in `_register_player_profile` (new peers), in `host_game` (host) and in `add_bot` (bots), using `Teams.pick_team_for_new_player`.
- Remove the team in `_on_peer_disconnected` and `remove_bot`.

`PlayerController`:
- `var team: int = Teams.NONE`.
- `func apply_team_visuals(local_team: int) -> void`: a teammate (but not yourself) gets `skeletal_character.material = null` (no fog mask) and `skeletal_character.modulate = Teams.COLORS[team].lerp(Color.WHITE, 0.6)`.

`MatchPlayerSpawner._setup_player(peer_id, player_path, spawn_position, server_tick, team)`: new last arg. It sets `player.team`, then calls `apply_team_visuals` on every client for every player, using the local player's team.

The `WorldSnapshots` packet is unchanged in layout. Teammates are simply always included with `FLAG_VISIBLE`.

## Tasks

1. **`Teams` helper** with the contract above.
   - **Check:** unit tests for `can_damage` (FF off/on, self, NONE), `pick_team_for_new_player` and `can_switch`.
2. **Session team state and RPCs** (contract above).
   - The `_sync_lobby_data_to_all` signature changes; grep for all calls.
   - **Check:** the existing suites still pass (lobby sync is used by every network test).
3. **Lobby UI.**
   - In `lobby.gd`'s slot rendering, prefix names with `[A]`/`[B]` and colour the label with `Teams.COLORS`.
   - Add a "Switch team" button, built in code next to the start button, that calls `MultiplayerSession.request_team.rpc_id(1, Teams.other(my_team))`. The host calls `set_team` directly.
4. **Team spawns.**
   - Support optional children `AttackerSpawns` and `DefenderSpawns` (Node2D) under the map's `SpawnPoints`. `MatchPlayerSpawner.setup()` collects them as `_role_spawn_points`; in team deathmatch, ALPHA → `AttackerSpawns` and BRAVO → `DefenderSpawns`. If a container is missing, use the flat list (`map_1` has none, so it keeps working).
   - Pick a **free** point: no live player within 96 px. Among free points, prefer the one farthest from the nearest enemy. If none is free, use any.
   - This also fixes the existing overlap-at-spawn issue.
   - **Check:** a unit test that builds a small `SpawnPoints` tree in code and asserts that a point next to a live player is never chosen.
5. **Team on the player** (`_setup_player` gains `team`; `spawn_player` passes `MultiplayerSession.get_team(peer_id)`). Call `apply_team_visuals` for all players once the local player is known (and again when a new player is set up).
6. **Team vision on the server.**
   - In `WorldSnapshotService._packet_for_peer`: `if Teams.is_teammate(viewer, target): flag = FLAG_VISIBLE`, checked before the `can_see` branch.
   - Keep the viewer itself handled first, as now.
7. **No weapon friendly fire; explosive friendly fire stays on.**
   - Add `@export var friendly_fire := false` on the game mode (`deathmatch.gd`), readable through a small static accessor (for example, the game mode registers itself in a group `game_mode`; use `get_tree().get_first_node_in_group("game_mode")`).
   - Gate damage in `WeaponInstance._shoot_raycast` before `take_damage`.
   - Frag explosions always damage teammates, enemies and the thrower within their blast radius, regardless of `friendly_fire`. Explosion knockback also applies to both teams. Damage and knockback remain server-authoritative.
8. **Team scoring.** `MatchScoreboard`:
   - store `"team"` in each player's stats;
   - add `team_scores := {Teams.ALPHA: 0, Teams.BRAVO: 0}`, incremented on an enemy kill and broadcast with stats (add a `team_scores` arg to `_update_stats`). In step 5 the round mode uses the same dict for round wins;
   - `Deathmatch`: when `teams_enabled` (new export, default `true`), the score limit applies to `team_scores` and the winner is a *team*. `_local_match_result_text` shows VICTORY if the local player's team won.
   - Leaderboard: group rows by team, team colour on names.
9. **(Optional, ask first) Teammate spotting.**
   - Add `FLAG_SPOTTED = 4` (bit 1 is used by `FLAG_FOOTSTEPS = 2` after step 3) to `WorldSnapshotService`. An enemy that a *teammate* can see but the viewer can't is sent with only `FLAG_SPOTTED`.
   - The client sets presence `SPOTTED`: a new `NetPresence` value that is **not drawn and not audible** (no footsteps unless also audible).
   - The HUD shows a marker at its position for 1 s.
   - **Keep `FLAG_VISIBLE` comparisons as bit tests.** Step 3 turns the flags into a bitfield; spotting must preserve its footstep bit.
10. **Tests.** First move `_find_wall_setup()` from `tests/net/visibility_test.gd` into `tests/net/net_test_base.gd` as `find_wall_setup()`, and update its caller. Then create `tests/net/teams_test.gd` (uses a bot from step 1); the host sets teams explicitly with `MultiplayerSession.set_team`:
    - `teammate_always_visible`: client and bot on the same team, bot placed behind a wall (`find_wall_setup`) → the client sees it VISIBLE.
    - `enemy_still_needs_line_of_sight`: the host on the other team, behind the client and silent → CULLED.
    - `teammate_sight_does_not_reveal_enemy`: the bot (same team as the client) faces the host; the client faces away → the host stays CULLED for the client.
    - `no_friendly_fire`: the bot fires at the client (same team) for 1 s → the client's server-side health is unchanged.
    - `enemy_fire_hurts`: switch the bot to the other team; it fires → health drops.
    - `team_score_counts_enemy_kills`: the host kills the bot (an enemy) → `team_scores[host_team] == 1`.

    Also add team assertions to `match_test.gd` (the winner is a team).

## Edge cases

- **A player switches team in the lobby after a bot joined:** auto-balance is only applied on join. Manual switches are allowed while `|A − B| ≤ 1` after the switch.
- **A team becomes empty mid-match** (disconnect): the match continues. Step 5 handles round wins on elimination.
- **`map_1` has no team spawn containers:** the flat fallback must work, or every existing test breaks.
- **Free-for-all fallback:** with `teams_enabled = false`, all players have `Teams.NONE` and `can_damage` allows everything, which is the old behaviour.

## Manual playtest

Host plus two clients (or one client and a bot):
- the lobby shows teams, and switching works;
- in the match, the teammate is visible through walls with a tint;
- the enemy is only visible in line of sight;
- bullets cannot damage your teammate with `friendly_fire = false`, but frags can;
- team score is on the leaderboard;
- the match ends at the team score limit with VICTORY/DEFEAT per team.

## Commit plan

1. `feat: add teams with server-side assignment and lobby switching` (tasks 1–3).
2. `feat: team spawns, teammate visibility and no friendly fire` (tasks 4–7).
3. `feat: team scoring and team deathmatch win condition` (task 8).
4. `test: add teams network suite` (task 10).

Task 9 is a separate commit, if approved.
