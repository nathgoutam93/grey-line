• Proposed Plan


  # Tick-Based Netcode Migration Plan (Godot 2D, 60 Hz, Phased)

  ## Summary

  - Difficulty: High (architecture migration, not a small refactor).
  - Why high: your current codebase is split between MultiplayerSynchronizer replication and many combat RPCs; moving to authoritative tick simulation
    affects input, movement, snapshots, combat timing, reconciliation, and spawn/death flow.
  - Effort estimate (1 engineer, part-time gameplay iteration included):
      1. Phase 1 (movement tick netcode): 3-5 days
      2. Phase 2 (tick-queued combat + lag compensation): 4-7 days
      3. Hardening/tuning/tests: 2-4 days
      4. Total: ~2-3 weeks

  ## Scope Locked (per your choices)

  - Migration strategy: Phased
  - Shooting model: Tick-queued fire
  - Tick rate: 60 Hz
  - Design rule: single-responsibility scripts, decoupled modules (no god script)

  ## Current-State Anchors (what we are replacing)

  - PlayerInput currently extends MultiplayerSynchronizer and replicates input_vector/mouse_pos.
  - MovementCompoent extends MultiplayerSynchronizer; server runs movement in _physics_process.
  - player.tscn has PlayerInput, MovementComponent, and ServerSynchronizer synchronizers.
  - Combat requests are many RPC endpoints in player_controller.gd (request_start_fire, reload, slot switch, etc.).

  ## Target Architecture (modular)

  ### New modules

  1. NetworkTickClock (autoload)

  - Responsibility: fixed network tick counter, tick duration, local clock offset estimate.
  - Emits tick_started(tick:int) at 60 Hz.
  - No gameplay logic.

  2. PlayerInputFrame (Resource)

  - Fields:
      - tick:int
      - move:Vector2
      - aim_dir:Vector2
      - fire_pressed:bool
      - fire_held:bool
      - reload_pressed:bool
      - switch_next_pressed:bool
      - switch_prev_pressed:bool
      - slot_select:int (-1 when none)
      - drop_pressed:bool
      - interact_pressed:bool
      - slow_walk_held:bool
  - This is the only client->server gameplay intent payload.

  3. LocalInputCollector (node under player)

  - Responsibility: read keyboard/touch and build PlayerInputFrame.
  - Reuses existing touch/mouse helper logic from current player_input.gd.
  - No networking, no movement.

  4. InputTransportClient

  - Responsibility: send input frames to server (reliable baseline + optional unreliable burst redundancy).
  - Maintains local sent-input ring buffer for reconciliation.
  - No simulation.

  5. InputTransportServer

  - Responsibility: per-peer input queues, validation (remote_sender_id == owner_peer_id), missing-tick fallback (last_input).
  - No movement/combat decisions.

  6. PlayerSimulation

  - Responsibility: deterministic movement + facing + gameplay command application for one tick.
  - Replaces MovementCompoent._physics_process.
  - Pure-ish API:
      - simulate_tick(player_state, input_frame, delta_tick) -> player_state
  - No RPC calls inside.

  7. ServerPlayerDriver

  - Responsibility: authoritative per-tick execution order:
      1. dequeue input for tick
      2. run PlayerSimulation
      3. queue/resolve weapon commands for this tick
      4. store history snapshot
      5. publish snapshot packet

  8. StateHistoryBuffer

  - Responsibility: ring buffer of past player states by tick (position, rotation, hurtbox transforms if needed).
  - Used for lag compensation rewind/restore only.

  9. LagCompensationService

  - Responsibility: rewind all relevant players to client_tick, perform raycast, restore.
  - No input or movement ownership.

  10. SnapshotReplicator

  - Responsibility: server sends compact snapshots; client receives.
  - Owner path -> reconciliation.
  - Proxy path -> interpolation buffer.

  11. ClientReconciler

  - Responsibility: compare authoritative state vs predicted, correct, replay buffered inputs after ack tick.

  12. RemoteInterpolator

  - Responsibility: non-owner rendering with interpolation delay (2 ticks default).

  ## Public API / Interface Changes

  1. Remove synchronizer inheritance

  - scenes/player/_scripts/player_input.gd: from extends MultiplayerSynchronizer to plain Node (or replaced by LocalInputCollector).
  - components/movement/movement.gd: from extends MultiplayerSynchronizer to plain Node simulation helper.
  - components/weapon_manager/weapon_manager.tscn: remove MultiplayerSynchronizer node type usage (keep node logic).

  2. RPC changes (replace action RPC explosion)

  - Remove/retire:
      - request_start_fire, request_stop_fire, request_reload, weapon switch/drop/interact request RPCs from player control path.
  - Add:
      - @rpc("any_peer","reliable") server_receive_input(frame:PlayerInputFrame)
      - @rpc("authority","unreliable") client_receive_snapshot(snapshot:Dictionary)
  - Optional ack:
      - snapshot includes last_processed_tick for replay boundary.

  3. Snapshot schema (authoritative server->clients)

  - tick:int
  - peer_id:int
  - position:Vector2
  - velocity:Vector2
  - rotation:float
  - weapon_state (minimal fields needed for HUD/animation consistency)
  - last_processed_input_tick:int (for owner reconcile)

  4. Player scene wiring

  - scenes/player/player.tscn:
      - Remove PlayerInput synchronizer node and ServerSynchronizer.
      - Replace with modular nodes above (collector, driver, reconciler, interpolator).

  ## Implementation Plan (decision-complete)

  1. Phase 1: Movement Tick Netcode (no combat behavior change yet)

  - Create NetworkTickClock autoload at 60 Hz.
  - Add PlayerInputFrame, LocalInputCollector, InputTransportClient, InputTransportServer.
  - Add PlayerSimulation for movement/rotation only.
  - Add server snapshot send + owner reconcile + proxy interpolate.
  - Keep current combat RPC path temporarily to reduce blast radius.
  - Remove position replication via ServerSynchronizer.
  - Acceptance gate: players move smoothly; owner prediction/reconcile stable; no synchronizer-based position updates remain.

  2. Phase 2: Tick-Queued Combat + Rewind

  - Move fire/reload/switch/drop/interact intents into PlayerInputFrame.
  - Server consumes these intents on authoritative tick in ServerPlayerDriver.
  - Convert weapon firing cadence from timer-driven request RPC dependence to tick-based scheduling:
      - weapon cooldown tracked in ticks
      - burst/auto states advanced per tick.
  - Add StateHistoryBuffer and LagCompensationService.
  - On fire tick: rewind to shooter’s input tick, raycast, apply damage, restore world.
  - Retire old request RPC endpoints from player_controller.gd.
  - Acceptance gate: hits register under latency with expected fairness; no direct action RPCs required for combat.

  3. Phase 3: Hardening and cleanup

  - Add packet-loss handling (reuse last input for gaps; clamp stale inputs).
  - Add anti-cheat sanity checks:
      - input tick monotonicity window
      - max aim delta/tick
      - movement magnitude clamp.
  - Remove dead synchronizer configs from .tscn files.
  - Add debug overlay (tick, RTT estimate, prediction error, replay count).
  - Acceptance gate: stable gameplay at 100-150 ms simulated RTT and 1-3% packet loss.

  ## File-Level Change Map

  - Modify:
      - scenes/player/player.tscn
      - scenes/player/_scripts/player_controller.gd
      - scenes/player/_scripts/player_input.gd (or replace with collector)
      - components/movement/movement.gd
      - scenes/weapon/weapon_instance.gd (tick-cooldown integration)
      - components/deathmatch/deathmatch.gd (spawn hooks to net modules)
  - Add (suggested paths):
      - scripts/network/network_tick_clock.gd
      - scripts/network/data/player_input_frame.gd
      - scripts/network/client/input_transport_client.gd
      - scripts/network/server/input_transport_server.gd
      - scripts/network/sim/player_simulation.gd
      - scripts/network/server/server_player_driver.gd
      - scripts/network/server/state_history_buffer.gd
      - scripts/network/server/lag_compensation_service.gd
      - scripts/network/client/client_reconciler.gd
      - scripts/network/client/remote_interpolator.gd
      - scripts/network/shared/snapshot_replicator.gd

  ## Test Cases and Scenarios

  1. Local deterministic tick test

  - Same input frames over N ticks produce same final position/rotation.


  3. Proxy interpolation

  4. Packet loss

  - Drop random 5-10% input packets; server reuses last input; movement remains continuous.

  - With synthetic 120 ms latency, shooter hits target at visually aligned past position.

  6. Security

  - Reject forged sender inputs (peer mismatch), old ticks, and out-of-window future ticks.

  7. Regression

  - Spawn/death/respawn, weapon swaps, reload edge cases, touch controls parity with mouse/keyboard.

  ## Assumptions and Defaults

  - Game remains 2D (your sample was 3D-style, plan adapted to current 2D codebase).
  - Server-authoritative simulation only.
  - 60 Hz tick, interpolation delay 2 ticks, ~1 second history buffer.
  - Keep ENet/Godot multiplayer backend.
  - No rollback of full world simulation; only owner client-side prediction + server rewind for hitscan.
  - Touch and mouse/keyboard both feed the same PlayerInputFrame pipeline.
