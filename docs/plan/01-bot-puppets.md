# Step 1: Bot puppets (test infrastructure)

## Goal

The host can add server-side **bot players** that are simulated exactly like humans. A bot is driven by a *script*, not by AI: stand still, walk in a direction, face a direction, fire, slow-walk. Tests (and the host, in debug builds) use them to get 3+ players without extra Godot processes.

**Out of scope:** pathfinding, target selection and combat behaviour. Those are step 7.

## Architecture

**Bots feed the same input pipeline as humans.** A human client sends `PlayerInputFrame`s, which the server queues and applies in `PlayerNetSync._server_tick`. A bot produces one `PlayerInputFrame` per tick from a `BotBrain` on the server. Everything downstream (movement, weapons, damage, noise, fog of war, snapshots) is unchanged and already tested. This is how classic server-side shooter bots work: they emit the same per-tick command a client would.

**Identity:** bots get **negative** ids (`-1`, `-2`, …). Real ENet peer ids are always positive, so there is no collision.
- The player node name is `str(id)` (for example `"-1"`), exactly like humans.
- `owner_peer_id` is the negative id.
- The **multiplayer authority stays `1`** (the server), like every player.

**What bots don't do:**
- **No network peer.** `WorldSnapshots` sends packets only to `multiplayer.get_peers()`, so bots never get a packet (nothing to change).
- **No `PlayerInputCollector`.** `player_input.set_authority(id)` already disables processing when `id != multiplayer.get_unique_id()`, which is always true for a negative id, so the host's keyboard never drives a bot.

Data flow:

```
host:  MultiplayerSession.add_bot() -> bot id -1, name "Bot 1" (in player_names)
       -> MatchPlayerSpawner.spawn_player(-1)        (already generic over ids)
       -> _setup_player RPC on all peers             (unchanged)
       -> on the server only: player.net_sync.bot_brain = BotBrain.new()
each server tick: PlayerNetSync._server_tick
       -> frame = bot_brain.build_input_frame(tick)  (instead of the input queue)
```

## Contracts

`scripts/bots/bot_brain.gd`:

```gdscript
extends RefCounted
class_name BotBrain

## Scripted "puppet" input for a server-side bot. Tests and debug tools set the
## fields; build_input_frame() turns them into one tick of input.
var move := Vector2.ZERO          # same convention as PlayerInputFrame.move (x strafe, y back/forward; -y = forward)
var aim_dir := Vector2.RIGHT      # world direction to face
var fire_held := false
var slow_walk_held := false
var slot_select := -1             # one-shot: consumed by the next frame
var reload := false               # one-shot

func build_input_frame(tick: int) -> PlayerInputFrame
func face_point(from: Vector2, target: Vector2) -> void   # sets aim_dir
func stop() -> void                                         # move = 0, fire_held = false
```

`MultiplayerSession` (server only):

```gdscript
func add_bot() -> int                 # returns the new negative id; adds "Bot N" to player_names, syncs the lobby
func remove_bot(bot_id: int) -> void  # frees the player node, removes from player_names
func is_bot(peer_id: int) -> bool     # peer_id < 0
var bot_ids: Array[int]
```

`is_peer_connected(peer_id)` must return `true` for registered bots, so `MatchPlayerSpawner` respawns them.

## Tasks

1. **`BotBrain`.** Create `scripts/bots/bot_brain.gd` with the contract above.
   - `build_input_frame` sets `tick`, `move` (`limit_length(1.0)`), `aim_dir` (normalized; `Vector2.RIGHT` if zero), `fire_held`, `fire_pressed` (true only on the tick `fire_held` goes from false to true), `slow_walk_held`, `slot_select` and `reload_pressed`.
   - Then it clears the one-shots (`slot_select = -1`, `reload = false`).
   - `view_tick = tick`.
   - **Check:** add unit tests in `tests/unit/unit_tests.gd`:
     - `test_bot_brain_frame_fields`: one-shots appear once; `fire_pressed` only on the first tick of a hold.
2. **Server path in `PlayerNetSync`.**
   - Add `var bot_brain: BotBrain = null` (server only).
   - In `_server_tick`, before the "host's own player" branch: if `bot_brain != null`, build the frame from it and set `_last_applied_input_tick = tick`, `_last_input = frame`.
   - `is_owner_role()` stays false for bots on every peer, so the client paths are untouched.
   - **Check:** unit suite passes.
3. **Session API.** In `MultiplayerSession`:
   - add `bot_ids`, `add_bot()`, `remove_bot()` and `is_bot()`;
   - make `is_peer_connected()` return `true` for ids in `bot_ids`;
   - names: `"Bot %d" % -id`, avatar `DEFAULT_AVATAR_ID`;
   - `add_bot()` calls `_sync_lobby_data_to_all.rpc(...)` like a joining player;
   - if a match is running, also ask the game mode to spawn it (see task 4).
4. **Spawning.**
   - In `MatchPlayerSpawner._setup_player`: on the server, after setup, if `MultiplayerSession.is_bot(peer_id)` then `player.net_sync.bot_brain = BotBrain.new()`.
   - Add `spawn_bots()`, called from `spawn_initial_connected_players()`, which spawns every id in `MultiplayerSession.bot_ids`.
   - Add a public `spawn_player_if_missing(id)` for bots added mid-match.
   - **Check:** host a game, add a bot (task 5), start: the bot appears on host and client, stands still, and can be shot and killed. The scoreboard shows "Bot 1"; it respawns.
5. **Debug UI.**
   - In `lobby.gd`, create (in code) an "Add bot" button and a "Remove bot" button next to the start button.
   - Show them only when `OS.is_debug_build()` and on the host.
   - Bots appear in the lobby slots like players.
6. **Test helpers.** In `tests/net/net_test_base.gd` (host side):
   - `add_bot() -> int`: calls `MultiplayerSession.add_bot()` and waits until `player(id) != null`.
   - `bot(id) -> BotBrain`.
7. **Network test `bots`.** Create `tests/net/bots_test.gd`, extending the base, and add `bots` to `ALL_SUITES` in `tests/run_tests.sh`. Host:
   - add a bot;
   - move the client to an open spot (`find_open_spot`, already in the base) and put the bot in front of it;
   - script the bot to walk forward for 1 s;
   - ask the client to sample the bot.

   Checks:
   - `bot_spawns_on_client`: the client has a player node named `"-1"`.
   - `bot_moves_like_a_player`: the client sees it VISIBLE, and its position matches the server's within 40 px.
   - `bot_takes_damage_and_respawns`: the host kills it (`health_component.take_damage(500, 1)`), the scoreboard counts 1 kill and 1 death, and it respawns within 8 s.
8. **AGENTS.md:** under Testing, mention `bots` and `add_bot()`.

## Edge cases

- Removing a bot mid-match: free its player node on the server; the `MultiplayerSpawner` despawns it on clients. Remove it from `bot_ids` *first*, so `_on_player_tree_exited` doesn't respawn it.
- `MatchScoreboard._player_identifier` already goes through `MultiplayerSession.get_player_name` (works for bots).
- Ping for bots stays 0 (they never answer pings). The leaderboard shows 0 ms; that's fine.
- Bots must not trigger `_register_player_profile` or any client-only code.

## Manual playtest

Host plus one client:
- add two bots and start;
- both bots stand at spawns;
- shoot one; it dies and respawns;
- the client sees them;
- remove a bot mid-match; it disappears for both.

## Commit plan

1. `feat: add server-side bot puppets driven by scripted input` (tasks 1–5).
2. `test: add bots network suite and bot test helpers` (tasks 6–8).
