# Step 3: Silent slow-walk

## Goal

Holding slow-walk makes your footsteps **silent**, both on the server and on every client. A silent player out of sight is therefore **not sent at all** (CULLED), while a running player is heard (AUDIBLE). This is the core "move fast or move quietly" decision.

## Current behaviour (why it needs work)

- **Server:** `PlayerNetSync.get_noise_radius()` adds `footstep_player.max_distance` whenever `velocity.length() > FOOTSTEP_SPEED_THRESHOLD`. Slow-walk speed is 125 px/s, which is above the 40 px/s threshold, so slow-walkers are heard.
- **Owner client:** `PlayerController._update_footstep_audio` plays footsteps when moving. The owner knows `is_slow_walking` (it's set from its own input frames).
- **Proxies (other clients):** they **don't know** whether a remote player is slow-walking. `is_slow_walking` is only set from input frames, which only the server and the owner see. They guess movement from position changes, so they would keep playing footsteps.

## Architecture

The server decides "is this player making footstep noise" and replicates it as a **per-entry flag bit** in the world snapshot. That is the standard approach: replicate authoritative state flags instead of letting clients infer them. Two reasons:
- It avoids fragile client-side speed thresholds (weapon speed multipliers make slow-walk and run speeds overlap).
- It keeps future rules on the server, such as "crouch-walk on metal is loud".

The flags byte becomes a **bitfield**:

| Bit | Constant | Meaning |
|---|---|---|
| 0 | `FLAG_VISIBLE = 1` | draw it (existing) |
| 1 | `FLAG_FOOTSTEPS = 2` | it is making footstep noise this tick |
| 2 | `FLAG_SPOTTED = 4` | reserved for step 2's optional task 9 |

## Tasks

1. **Server rule.**
   - Add `func is_making_footstep_noise() -> bool` to `PlayerNetSync`: not dead, `velocity.length() > PlayerController.FOOTSTEP_SPEED_THRESHOLD`, and `not player.is_slow_walking`.
   - Use it in `get_noise_radius()` instead of the bare velocity check.
   - **Check:** add a unit test to `test_hearing_follows_noise_radius`: velocity 200 with `is_slow_walking = true` → not heard.
2. **Flags become bits** in `world_snapshot_service.gd`:
   - add the constants;
   - in `_packet_for_peer`, compute `var bits := 0`, then `if visible: bits |= FLAG_VISIBLE`, then `if target.net_sync.is_making_footstep_noise(): bits |= FLAG_FOOTSTEPS`;
   - an entry is still only included when visible, audible or the viewer itself;
   - on the client, replace `flags[i] == FLAG_VISIBLE` with `(flags[i] & FLAG_VISIBLE) != 0`;
   - pass `(flags[i] & FLAG_FOOTSTEPS) != 0` to the player (next task).
3. **Client footsteps for proxies.**
   - `PlayerNetSync` gets `var net_footsteps := false` (client), set by `WorldSnapshots` for every received entry, and set to `false` when the player becomes CULLED.
   - In `PlayerController._update_footstep_audio`, decide `is_moving_now` by role:
     - **local player or server:** `_footstep_moving and not is_slow_walking` (the movement component check stays, also gated by `not is_slow_walking`);
     - **proxy:** `_footstep_moving and net_sync.net_footsteps`.
   - Add `func is_proxy() -> bool` on `PlayerNetSync` (`not is_server_role() and not is_owner_role()`) for this.
4. **Touch controls.**
   - `PlayerInputCollector.build_input_frame` currently forces `slow_walk_held = false` in touch mode.
   - Add a HUD toggle button "Walk", created in code in `hud.gd` under `Controls` (the existing touch buttons live in the scene; building this one in code avoids a scene edit). It flips a `touch_slow_walk` bool on the input collector, which is used in touch mode.
   - Persist its position like the other touch controls, if `PlayerProfile` touch layout supports it; otherwise place it at a fixed anchor.
5. **Tests.** Extend `tests/net/visibility_test.gd` after `behind_and_walking_is_audible`:
   - `behind_and_slow_walking_is_culled`: the host holds `slow_walk` and `move_left` for 0.7 s behind the client → CULLED, not drawn, no footsteps.
   - `visible_slow_walker_is_silent`: the host slow-walks in front of the client → VISIBLE, drawn, `footsteps=false`.
   - `visible_runner_has_footsteps`: the host runs in front → VISIBLE and `footsteps=true`.

   Release `slow_walk` afterwards so later scenarios are unaffected.

## Edge cases

- **A shot while slow-walking is still loud:** the shot reports its own noise (`report_noise`). Only footsteps go silent.
- **Explosion knockback** moves a slow-walker fast. With `is_slow_walking` true, it stays silent. That's acceptable; document it if a playtest flags it.
- **Snapshot delay:** proxies get the footstep bit at 30 Hz. A footstep starting or stopping lags by ≤ 1 snapshot (33 ms). That's fine.

## Manual playtest

- Two players: one slow-walks behind the other. No footsteps are heard, and the slow-walker is not drawn even at a corner.
- Switch to running: footsteps are heard.
- On touch: the Walk toggle works.

## Commit plan

1. `feat: make slow-walk silent and replicate footstep noise per player` (tasks 1–4).
2. `test: cover silent slow-walk in the visibility suite` (task 5).
