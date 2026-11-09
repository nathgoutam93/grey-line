extends Node
class_name PlayerNetSync

## Networking for one PlayerController (child node `NetSync` in player.tscn).
##
## Roles, decided per network tick:
## - Server: applies queued owner inputs (one frame per tick), simulates,
##   keeps state history for lag compensation, executes combat/inventory
##   actions and broadcasts them via the _remote_* RPCs below.
## - Owning client: stamps inputs with the tick they should reach the server
##   (steered by lead feedback), predicts movement and fire/reload/switch,
##   sends the last INPUT_REDUNDANCY frames, reconciles position and ammo
##   against snapshots.
## - Other clients (proxies): interpolate snapshots, follow the fog-of-war
##   presence the server sends, hold actions until a culled proxy is located.
##
## World snapshots are batched by WorldSnapshots (world_snapshot_service.gd),
## which calls get_owner_snapshot_fields / apply_snapshot / set_net_presence.

## What this client knows about a remote player (set by WorldSnapshots):
## VISIBLE - in view, drawn normally.
## AUDIBLE - hidden, but making noise in hearing range: position is still
##           updated so footsteps/shots play from the right place, not drawn.
## CULLED  - not sent at all: not drawn, position is stale.
enum NetPresence { VISIBLE, AUDIBLE, CULLED }

const HISTORY_SECONDS := 1.0
# Snapshots arrive every WorldSnapshotService.SEND_INTERVAL_TICKS (2), so render
# remote players one send interval plus 2 ticks of jitter buffer behind.
const DEFAULT_INTERP_DELAY_TICKS := 4
# Max rewind = one-way latency + interpolation delay; 12 ticks = 200 ms.
const MAX_LAG_COMP_REWIND_TICKS := 12
const TICK_OFFSET_SMOOTHING := 0.1
const RPC_CHANNEL_UI := 2

# Every input packet carries the last N frames so a single lost packet does not
# drop movement or one-shot actions (drop/switch/interact).
const INPUT_REDUNDANCY := 4
# How many ticks early we want owner inputs to reach the server. The server
# reports the measured lead back in snapshots and the client steers toward it.
const TARGET_INPUT_LEAD_TICKS := 2
const INITIAL_INPUT_LEAD_TICKS := 4
const INPUT_OFFSET_SMOOTHING := 0.1
const INPUT_OFFSET_SNAP_TICKS := 6.0
# The whole-tick offset used for stamping only moves once the smoothed offset
# is this far from it. Without it, a smoothed value hovering around x.5 flips
# the rounding every few ticks: each flip skips (delaying that tick's input,
# e.g. a shot) or fills a tick.
const INPUT_OFFSET_HYSTERESIS := 0.75
const MAX_INPUT_GAP_FILL_TICKS := 3
# Server rejects frames stamped further than this ahead of its own tick.
const MAX_INPUT_LEAD_TICKS := 30
const MAX_INPUT_BUFFER_SIZE := 120
## Remote actions (fire, reload, switch...) that reach a CULLED proxy are held
## until its position arrives, so their sounds don't play from a stale spot.
const DEFERRED_ACTION_TIMEOUT_TICKS := 6

@export var player: PlayerController

# Owner client state
var _input_buffer: Dictionary = {}
var _predicted_positions: Dictionary = {}
var _predicted_weapon_states: Dictionary = {}
var _send_history: Array = []
var _input_tick_offset := 0.0 # smoothed target
var _stamp_offset := 0 # whole ticks actually used for stamping
var _has_input_lead_sample := false
var _last_lead_sample_tick := 0
var _last_stamped_tick := 0
var _carry_actions: PlayerInputFrame = null

# Server state
var bot_brain: BotBrain = null
## Server: the owner dropped out of the match; the body stands still, keeps
## its aim and can be killed (see MultiplayerSession.player_dropped).
var owner_dropped := false
var _input_queue: Dictionary = {}
var _last_input: PlayerInputFrame
var _last_applied_input_tick := 0
var _last_authoritative_input_tick := 0
var _lead_sample_tick := 0
var _lead_sample_value := 0
var _last_processed_tick := 0
var _lag_compensation_tick := 0
var _state_history := StateHistoryBuffer.new()
# Timed noise from equipment sounds (see report_noise).
var _noise_radius := 0.0
var _noise_until_tick := 0

# Shared / proxy state
var net_footsteps := false
var _reconciler := ClientReconciler.new()
var _interpolator := RemoteInterpolator.new()
var _tick_offset := 0.0
var _last_received_snapshot_tick := 0
## Client: snapshots accepted for this player (diagnostics and tests).
var snapshots_received := 0
## Server-issued identity of this spawned life; rejects input left over from a previous round.
var life_id := 0
var _is_firing_net := false
var _last_reload_request_tick := -1
var _net_presence := NetPresence.VISIBLE
var _snap_next_snapshot := false
var _deferred_actions: Array[Callable] = []
var _deferred_wait_ticks := 0
var _flushing_deferred := false

func _ready() -> void:
	if player == null:
		player = get_parent() as PlayerController
	_state_history.configure(int(NetworkTick.tick_rate * HISTORY_SECONDS))
	_interpolator.interpolation_delay_ticks = DEFAULT_INTERP_DELAY_TICKS
	# Connected before the player's own tick handler (children are ready
	# first) and before equipment (created a frame later), so each tick runs:
	# net input/simulation -> player footsteps -> weapons.
	if not NetworkTick.tick_started.is_connected(_on_network_tick):
		NetworkTick.tick_started.connect(_on_network_tick)

## Clears all per-life state (called from PlayerController.reset_for_respawn).
func reset_state() -> void:
	_input_buffer.clear()
	_predicted_positions.clear()
	_predicted_weapon_states.clear()
	_send_history.clear()
	_has_input_lead_sample = false
	_last_lead_sample_tick = 0
	_last_stamped_tick = 0
	_carry_actions = null
	_input_queue.clear()
	_last_input = null
	owner_dropped = false
	_last_applied_input_tick = 0
	_last_authoritative_input_tick = 0
	_lead_sample_tick = 0
	_lead_sample_value = 0
	_last_processed_tick = 0
	_lag_compensation_tick = 0
	_noise_radius = 0.0
	_noise_until_tick = 0
	_last_received_snapshot_tick = 0
	_is_firing_net = false
	_last_reload_request_tick = -1
	_interpolator.snapshot_buffer.clear()
	_net_presence = NetPresence.VISIBLE
	net_footsteps = false
	_snap_next_snapshot = false
	_deferred_actions.clear()

func is_server_role() -> bool:
	return multiplayer.is_server()

func is_owner_role() -> bool:
	return player.owner_peer_id == multiplayer.get_unique_id()

func is_proxy() -> bool:
	return not is_server_role() and not is_owner_role()

func _is_predicting_owner() -> bool:
	return is_owner_role() and not multiplayer.is_server()

# --- per-tick ---------------------------------------------------------------

func _on_network_tick(tick: int) -> void:
	if player.is_dead:
		return
	if is_server_role():
		_server_tick(tick)
	elif is_owner_role():
		_record_predicted_weapon_state()
		_owner_tick(tick)
	else:
		_proxy_tick(_estimated_server_tick(tick))

func _owner_tick(local_tick: int) -> void:
	if not is_instance_valid(player.player_input) or not is_instance_valid(player.movement_component):
		return
	# Stamp with the server tick at which this input should *arrive*, i.e.
	# ahead of the server by one-way latency + TARGET_INPUT_LEAD_TICKS. The
	# offset is steered by lead feedback from the server (see snapshots).
	if absf(_input_tick_offset - float(_stamp_offset)) >= INPUT_OFFSET_HYSTERESIS:
		_stamp_offset = roundi(_input_tick_offset)
	var stamp := local_tick + _stamp_offset
	var frame := player.player_input.build_input_frame(stamp)
	frame.stamp_offset = float(_stamp_offset)
	# What we are rendering remote players at; used by server lag compensation.
	frame.view_tick = maxi(_estimated_server_tick(local_tick) - DEFAULT_INTERP_DELAY_TICKS, 0)
	if _carry_actions != null:
		frame.merge_actions_from(_carry_actions)
		_carry_actions = null

	if _last_stamped_tick > 0 and stamp <= _last_stamped_tick:
		# Clock is being pulled back: skip this tick (no prediction, nothing
		# sent) but keep any presses for the next frame.
		if frame.has_one_shot_actions():
			_carry_actions = frame
		return

	if _last_stamped_tick > 0:
		var gap := stamp - _last_stamped_tick
		if gap > 1 and gap <= MAX_INPUT_GAP_FILL_TICKS:
			# Clock moved forward: fill skipped ticks so client and server
			# simulate the same number of steps.
			for fill_tick in range(_last_stamped_tick + 1, stamp):
				_predict_owner_frame(frame.copy_continuous(fill_tick))
	_predict_owner_frame(frame)
	WorldSnapshots.submit_player_input.rpc_id(1, life_id, _send_history.duplicate())

func _predict_owner_frame(frame: PlayerInputFrame) -> void:
	_input_buffer[frame.tick] = frame
	_apply_input_actions(frame)
	PlayerSimulation.simulate(player, player.movement_component, frame)
	_predicted_positions[frame.tick] = player.global_position
	_last_stamped_tick = frame.tick
	_send_history.append(frame.to_packed())
	while _send_history.size() > INPUT_REDUNDANCY:
		_send_history.pop_front()
	if _input_buffer.size() > MAX_INPUT_BUFFER_SIZE:
		# No acks arriving; drop the oldest entries so memory stays bounded.
		var cutoff := frame.tick - MAX_INPUT_BUFFER_SIZE
		for key in _input_buffer.keys():
			if int(key) < cutoff:
				_input_buffer.erase(key)
		for key in _predicted_positions.keys():
			if int(key) < cutoff:
				_predicted_positions.erase(key)

func _server_tick(tick: int) -> void:
	if not is_instance_valid(player.movement_component):
		return
	# Consume every queued frame that is due. Normally that is exactly the
	# frame for this tick; if frames arrived late, use the newest for movement
	# and fold the older ones' one-shot actions into it so none are lost.
	var due_ticks: Array[int] = []
	for key in _input_queue.keys():
		if int(key) <= tick:
			due_ticks.append(int(key))
	due_ticks.sort()
	var frame: PlayerInputFrame = null
	for due_tick in due_ticks:
		var queued := _input_queue[due_tick] as PlayerInputFrame
		_input_queue.erase(due_tick)
		if frame != null:
			queued.merge_actions_from(frame)
		frame = queued

	if owner_dropped:
		var idle := PlayerInputFrame.new()
		idle.tick = tick
		idle.view_tick = tick
		if _last_input != null:
			idle.aim_dir = _last_input.aim_dir
		frame = idle
		_last_applied_input_tick = tick
		_last_input = frame
	elif bot_brain != null:
		frame = bot_brain.build_input_frame(tick)
		_last_applied_input_tick = tick
		_last_input = frame
	elif frame != null:
		_last_applied_input_tick = frame.tick
		_last_input = frame
	elif is_owner_role() and is_instance_valid(player.player_input):
		# Host's own player: sample input directly.
		frame = player.player_input.build_input_frame(tick)
		frame.view_tick = tick
		_last_applied_input_tick = tick
		_last_input = frame
	elif _last_input != null:
		# Input for this tick is missing: keep moving with the last known
		# input, but never repeat one-shot actions (drop/switch/interact).
		frame = _last_input.copy_continuous(_last_input.tick)
	else:
		return

	_last_authoritative_input_tick = _last_applied_input_tick
	var view_tick := frame.view_tick if frame.view_tick >= 0 else tick
	var min_allowed_lag_comp_tick := maxi(tick - MAX_LAG_COMP_REWIND_TICKS, 0)
	_lag_compensation_tick = clampi(view_tick, min_allowed_lag_comp_tick, tick)
	_apply_input_actions(frame)
	PlayerSimulation.simulate(player, player.movement_component, frame)
	_last_processed_tick = tick
	_state_history.store(tick, player.global_transform)

func _proxy_tick(server_tick: int) -> void:
	if not _deferred_actions.is_empty():
		_deferred_wait_ticks += 1
		if _deferred_wait_ticks >= DEFERRED_ACTION_TIMEOUT_TICKS:
			# Out of hearing range: the position will not come; run anyway so
			# weapon state stays in step.
			_flush_deferred_actions()
	var render_tick := server_tick - _interpolator.interpolation_delay_ticks
	if _interpolator.snapshot_buffer.size() < 2:
		_interpolator.apply_latest(player, render_tick)
		return
	_interpolator.interpolate(player, render_tick)

# --- input actions ----------------------------------------------------------

func _apply_input_actions(frame: PlayerInputFrame) -> void:
	player.is_slow_walking = frame.slow_walk_held
	player.current_shot_intent = frame.shot_intent
	if player.actions_locked:
		cancel_locked_actions()
		return

	# The owning client predicts fire/reload/switch immediately; the server
	# (authoritative) executes everything and broadcasts via _remote_* RPCs,
	# which the predicting owner ignores. Drop/interact stay server-driven.
	if _is_predicting_owner():
		_predict_owner_actions(frame)
		return
	if not is_server_role():
		return

	if frame.reload_pressed and frame.tick > _last_reload_request_tick:
		_last_reload_request_tick = frame.tick
		_remote_reload.rpc()
	if frame.switch_prev_pressed:
		_remote_switch_weapon_previous.rpc()
	if frame.switch_next_pressed:
		_remote_switch_weapon.rpc()
	if frame.slot_select >= 0:
		_remote_switch_weapon_slot.rpc(frame.slot_select)
	if frame.drop_pressed:
		_remote_drop_weapon.rpc()
	if frame.interact_pressed:
		var target_path: NodePath = NodePath("")
		if player.interactables.size() > 0 and player.interactables[0]:
			target_path = player.interactables[0].get_path()
		_remote_interact.rpc(target_path)

	if frame.fire_held and not _is_firing_net:
		_is_firing_net = true
		# Become audible before the first shot so listeners get our position
		# in the next snapshot (their proxies hold the shot until then).
		var current_item := player.get_current_equipment()
		if current_item:
			report_noise(current_item.get_use_noise_radius(), 0.5)
		_remote_start_fire.rpc(frame.shot_intent)
	elif not frame.fire_held and _is_firing_net:
		_is_firing_net = false
		_remote_stop_fire.rpc()

func cancel_locked_actions() -> void:
	_is_firing_net = false
	_deferred_actions.clear()

func _predict_owner_actions(frame: PlayerInputFrame) -> void:
	if frame.reload_pressed and frame.tick > _last_reload_request_tick:
		_last_reload_request_tick = frame.tick
		_do_reload()
	var equipment := player.equipment_manager
	if equipment != null:
		if frame.switch_prev_pressed:
			equipment.switch_to_previous_item()
		if frame.switch_next_pressed:
			equipment.switch_to_next_item()
		if frame.slot_select >= 0:
			equipment.switch_to_slot(frame.slot_select)
	if frame.fire_held and not _is_firing_net:
		_is_firing_net = true
		_do_start_fire(frame.shot_intent)
	elif not frame.fire_held and _is_firing_net:
		_is_firing_net = false
		_do_stop_fire()

func server_receive_input(packed_frames: Array, sender_id: int) -> void:
	if not is_server_role():
		return
	if sender_id != player.owner_peer_id:
		return
	var server_tick := NetworkTick.tick
	var newest_tick := -1
	for i in range(mini(packed_frames.size(), INPUT_REDUNDANCY)):
		var frame := PlayerInputFrame.from_packed(packed_frames[i])
		if frame == null:
			continue
		newest_tick = maxi(newest_tick, frame.tick)
		if frame.tick <= _last_applied_input_tick:
			continue # already applied (redundant copy) or superseded
		if frame.tick > server_tick + MAX_INPUT_LEAD_TICKS:
			continue # absurdly far ahead; lead feedback will pull the client back
		if _input_queue.has(frame.tick):
			continue
		_input_queue[frame.tick] = frame
	if newest_tick > _lead_sample_tick:
		_lead_sample_tick = newest_tick
		# Frames for `server_tick` itself have already missed this tick, so a
		# lead of 0 or less means the input arrived late.
		_lead_sample_value = clampi(newest_tick - server_tick, -1000, 1000)

# --- snapshots --------------------------------------------------------------

## Server only: fields sent to this player's owner in each world snapshot:
## [ack_tick, lead_tick, input_lead, weapon_slot, weapon_ammo]. Frame
## `lead_tick` arrived `input_lead` ticks before the server needed it.
func get_owner_snapshot_fields() -> Array:
	var slot := -1
	var ammo := PackedInt32Array()
	if player.equipment_manager != null:
		slot = player.equipment_manager.get_target_slot()
		ammo = player.equipment_manager.capture_weapon_ammo()
	return [_last_authoritative_input_tick, _lead_sample_tick, _lead_sample_value, slot, ammo]

## Client only: called by WorldSnapshots for this player's entry in a batched
## world snapshot.
func apply_snapshot(snapshot: Dictionary) -> void:
	var server_tick := int(snapshot.get("tick", 0))
	if server_tick <= 0:
		return
	if server_tick <= _last_received_snapshot_tick:
		return
	_last_received_snapshot_tick = server_tick
	snapshots_received += 1
	_update_tick_offset(server_tick)
	if is_owner_role():
		var ack_tick := int(snapshot.get("ack_tick", 0))
		_apply_input_lead_feedback(int(snapshot.get("lead_tick", 0)), int(snapshot.get("input_lead", 0)))
		_reconciler.reconcile(
			player,
			snapshot.get("position", player.global_position),
			snapshot.get("velocity", player.velocity),
			ack_tick,
			_input_buffer,
			_predicted_positions,
			player.movement_component
		)
		_reconcile_weapon_state(
			ack_tick,
			int(snapshot.get("weapon_slot", -1)),
			snapshot.get("weapon_ammo", PackedInt32Array())
		)
		return
	if _snap_next_snapshot:
		# Back from CULLED: jump to the real position instead of sliding from
		# the stale one (which would also fake a burst of footsteps).
		_snap_next_snapshot = false
		player.global_position = snapshot.get("position", player.global_position)
		player.rotation = float(snapshot.get("rotation", player.rotation))
		player.reset_footstep_tracking()
	_interpolator.push_snapshot(snapshot)
	if not _deferred_actions.is_empty():
		_flush_deferred_actions()

func _apply_input_lead_feedback(lead_tick: int, lead: int) -> void:
	if lead_tick <= 0 or lead_tick <= _last_lead_sample_tick:
		return
	var sampled := _input_buffer.get(lead_tick, null) as PlayerInputFrame
	if sampled == null:
		return
	_last_lead_sample_tick = lead_tick
	# Absolute target derived from the offset that frame was stamped with, so
	# feedback that is still in flight after a correction does not overshoot.
	var target := sampled.stamp_offset + float(TARGET_INPUT_LEAD_TICKS - lead)
	if not _has_input_lead_sample or absf(target - _input_tick_offset) > INPUT_OFFSET_SNAP_TICKS:
		_input_tick_offset = target
		_stamp_offset = roundi(target)
		_has_input_lead_sample = true
	else:
		_input_tick_offset = lerpf(_input_tick_offset, target, INPUT_OFFSET_SMOOTHING)

## Owner client: weapon state ([mag, reserve] per weapon slot) after the
## weapons ticked for a stamped input tick. Weapons tick after this node in
## each NetworkTick, so the state is captured at the start of the next tick
## and filed under the last stamped tick.
func _record_predicted_weapon_state() -> void:
	if _last_stamped_tick <= 0 or player.equipment_manager == null:
		return
	_predicted_weapon_states[_last_stamped_tick] = player.equipment_manager.capture_weapon_ammo()
	if _predicted_weapon_states.size() > MAX_INPUT_BUFFER_SIZE:
		var cutoff := _last_stamped_tick - MAX_INPUT_BUFFER_SIZE
		for key in _predicted_weapon_states.keys():
			if int(key) < cutoff:
				_predicted_weapon_states.erase(key)

## Owner client: the server's ammo for `ack_tick` is the truth. Shift the
## current ammo (and the newer predictions) by however far our prediction for
## that tick was off, the same way position is reconciled. Also follow the
## server's weapon slot once no switch of ours is still on its way to it.
func _reconcile_weapon_state(ack_tick: int, server_slot: int, server_ammo: PackedInt32Array) -> void:
	var equipment := player.equipment_manager
	if equipment == null or ack_tick <= 0:
		return
	var predicted: Variant = _predicted_weapon_states.get(ack_tick, null)
	for key in _predicted_weapon_states.keys():
		if int(key) < ack_tick:
			_predicted_weapon_states.erase(key)
	if predicted != null:
		var predicted_ammo: PackedInt32Array = predicted
		if predicted_ammo.size() == server_ammo.size():
			var deltas := PackedInt32Array()
			deltas.resize(server_ammo.size())
			var any_delta := false
			for i in range(0, server_ammo.size(), 2):
				# Skip slots that are empty on either side (pickup/drop in flight).
				if server_ammo[i] < 0 or predicted_ammo[i] < 0:
					continue
				deltas[i] = server_ammo[i] - predicted_ammo[i]
				deltas[i + 1] = server_ammo[i + 1] - predicted_ammo[i + 1]
				any_delta = any_delta or deltas[i] != 0 or deltas[i + 1] != 0
			if any_delta:
				equipment.apply_weapon_ammo_deltas(deltas)
				for key in _predicted_weapon_states.keys():
					var entry: PackedInt32Array = _predicted_weapon_states[key]
					for i in range(mini(entry.size(), deltas.size())):
						if entry[i] >= 0:
							entry[i] += deltas[i]
					_predicted_weapon_states[key] = entry

	if server_slot < 0 or server_slot == equipment.get_target_slot():
		return
	for key in _input_buffer.keys():
		if int(key) <= ack_tick:
			continue
		var frame := _input_buffer[key] as PlayerInputFrame
		if frame != null and (frame.switch_next_pressed or frame.switch_prev_pressed or frame.slot_select >= 0):
			return # our own switch has not reached the server yet
	if equipment.get_item_in_slot(server_slot) != null:
		equipment.equip_slot(server_slot)

# --- fog-of-war presence (proxies) ------------------------------------------

## Local presentation: clients use received packets; the host uses its own
## filtered packet without changing authoritative simulation or world state.
func set_net_presence(presence: NetPresence) -> void:
	if presence == NetPresence.CULLED:
		net_footsteps = false
	if presence == _net_presence:
		return
	var was_culled := _net_presence == NetPresence.CULLED
	_net_presence = presence
	if presence == NetPresence.CULLED:
		_interpolator.snapshot_buffer.clear()
	elif was_culled:
		_snap_next_snapshot = true
	refresh_visibility()

## Proxies are drawn only while alive and VISIBLE.
func refresh_visibility() -> void:
	player.visible = not player.is_dead and _net_presence == NetPresence.VISIBLE

## Returns true if `action` was queued instead of run now. Only remote proxies
## that the server is not currently sending (CULLED) queue; the queue keeps
## order, so later actions wait behind earlier ones.
func _defer_until_located(action: Callable) -> bool:
	if _flushing_deferred or multiplayer.is_server() or is_owner_role():
		return false
	if _deferred_actions.is_empty() and _net_presence != NetPresence.CULLED:
		return false
	if _deferred_actions.is_empty():
		_deferred_wait_ticks = 0
	_deferred_actions.append(action)
	return true

func _flush_deferred_actions() -> void:
	_flushing_deferred = true
	while not _deferred_actions.is_empty():
		var action: Callable = _deferred_actions.pop_front()
		action.call()
		if action.get_method() == &"_remote_start_fire" and not _deferred_actions.is_empty():
			# Let the weapon tick once before anything else (e.g. stop_fire)
			# runs, so a quick tap still fires a shot.
			_flushing_deferred = false
			NetworkTick.tick_started.connect(_on_deferred_flush_tick, CONNECT_ONE_SHOT)
			return
	_flushing_deferred = false

func _on_deferred_flush_tick(_tick: int) -> void:
	if is_inside_tree():
		_flush_deferred_actions()

# --- noise (server) ---------------------------------------------------------

## Server only: the player is making a sound that carries `max_distance` for
## `seconds`. Players within range keep receiving their position (as AUDIBLE)
## even when they can't see them.
func report_noise(max_distance: float, seconds: float) -> void:
	if max_distance <= 0.0:
		return
	var until_tick := NetworkTick.tick + int(ceil(seconds * float(NetworkTick.tick_rate)))
	if NetworkTick.tick >= _noise_until_tick:
		_noise_radius = max_distance
	else:
		_noise_radius = maxf(_noise_radius, max_distance)
	_noise_until_tick = maxi(_noise_until_tick, until_tick)

## Authoritative footstep rule, independent of weapon speed multipliers.
func is_making_footstep_noise() -> bool:
	return not player.is_dead and not player.is_slow_walking \
		and player.velocity.length() > PlayerController.FOOTSTEP_SPEED_THRESHOLD

## Server only: how far the player can be heard right now.
func get_noise_radius() -> float:
	if player.is_dead:
		return 0.0
	var radius := 0.0
	if NetworkTick.tick < _noise_until_tick:
		radius = _noise_radius
	# Same rule the client uses to play footsteps.
	if player.footstep_player and is_making_footstep_noise():
		radius = maxf(radius, player.footstep_player.max_distance)
	return radius

# --- clock / lag compensation -----------------------------------------------

func get_history_transform(tick: int) -> Variant:
	return _state_history.get_transform_for_tick(tick)

func get_lag_compensation_tick() -> int:
	if _lag_compensation_tick > 0:
		return _lag_compensation_tick
	return _last_processed_tick

func sync_server_tick(server_tick: int) -> void:
	if server_tick <= 0:
		return
	_tick_offset = float(server_tick - NetworkTick.tick)
	# Rough starting guess; the first lead sample from the server replaces it.
	_input_tick_offset = _tick_offset + float(INITIAL_INPUT_LEAD_TICKS)
	_stamp_offset = roundi(_input_tick_offset)
	_has_input_lead_sample = false

func _estimated_server_tick(local_tick: int) -> int:
	return int(round(float(local_tick) + _tick_offset))

func _update_tick_offset(authoritative_server_tick: int) -> void:
	var target_offset := float(authoritative_server_tick - NetworkTick.tick)
	_tick_offset = lerpf(_tick_offset, target_offset, TICK_OFFSET_SMOOTHING)

# --- replicated actions (server -> everyone) --------------------------------

## Server only: give the pickup at `pickup_path` to this player on every peer.
func request_pickup(pickup_path: NodePath) -> void:
	_remote_pickup.rpc(pickup_path)

@rpc("authority", "call_local", "unreliable", RPC_CHANNEL_UI)
func _remote_interact(target_path: NodePath):
	if player.actions_locked or not multiplayer.is_server() or target_path == NodePath(""):
		return
	var interactable := get_node_or_null(target_path) as Interactable
	if interactable != null:
		interactable.on_interact(player)

@rpc("authority", "call_local", "reliable", RPC_CHANNEL_UI)
func _remote_start_fire(shot_intent: int = PlayerController.ShotIntent.BODY):
	if _is_predicting_owner():
		return # already started locally when the input was sampled
	if _defer_until_located(_remote_start_fire.bind(shot_intent)):
		return
	_do_start_fire(shot_intent)

func _do_start_fire(shot_intent: int) -> void:
	if player.actions_locked:
		return
	if shot_intent != PlayerController.ShotIntent.BODY and shot_intent != PlayerController.ShotIntent.HEAD:
		shot_intent = PlayerController.ShotIntent.BODY
	player.current_shot_intent = shot_intent
	var current_item := player.get_current_equipment()
	if current_item:
		current_item.start_use()

@rpc("authority", "call_local", "reliable", RPC_CHANNEL_UI)
func _remote_stop_fire():
	if _is_predicting_owner():
		return
	if _defer_until_located(_remote_stop_fire):
		return
	_do_stop_fire()

func _do_stop_fire() -> void:
	var current_item := player.get_current_equipment()
	if current_item:
		current_item.stop_use()

@rpc("authority", "call_local", "reliable", RPC_CHANNEL_UI)
func _remote_reload():
	if _is_predicting_owner():
		return
	if _defer_until_located(_remote_reload):
		return
	_do_reload()

func _do_reload() -> void:
	if player.actions_locked:
		return
	var weapon := player.get_current_equipment() as WeaponInstance
	if weapon:
		weapon.reload()

@rpc("authority", "call_local", "reliable", RPC_CHANNEL_UI)
func _remote_switch_weapon():
	if player.actions_locked:
		return
	if _is_predicting_owner():
		return
	if _defer_until_located(_remote_switch_weapon):
		return
	if player.equipment_manager != null:
		player.equipment_manager.switch_to_next_item()

@rpc("authority", "call_local", "reliable", RPC_CHANNEL_UI)
func _remote_switch_weapon_previous():
	if player.actions_locked:
		return
	if _is_predicting_owner():
		return
	if _defer_until_located(_remote_switch_weapon_previous):
		return
	if player.equipment_manager != null:
		player.equipment_manager.switch_to_previous_item()

@rpc("authority", "call_local", "reliable", RPC_CHANNEL_UI)
func _remote_switch_weapon_slot(slot: int):
	if player.actions_locked:
		return
	if _is_predicting_owner():
		return
	if _defer_until_located(_remote_switch_weapon_slot.bind(slot)):
		return
	if player.equipment_manager != null:
		player.equipment_manager.switch_to_slot(slot)

@rpc("authority", "call_local", "reliable", RPC_CHANNEL_UI)
func _remote_drop_weapon():
	if player.actions_locked:
		return
	if _defer_until_located(_remote_drop_weapon):
		return
	_predicted_weapon_states.clear() # weapon instances change
	if player.equipment_manager != null:
		player.equipment_manager.drop_current_item()

@rpc("authority", "call_local", "reliable", RPC_CHANNEL_UI)
func _remote_pickup(pickup_path: NodePath):
	_predicted_weapon_states.clear() # weapon instances change
	var weapon_pickup := _resolve_pickup_node(pickup_path)
	if weapon_pickup == null:
		push_warning("Pickup node not found for path: %s" % [String(pickup_path)])
		return
	if player.equipment_manager != null and player.equipment_manager.pickup_weapon(weapon_pickup):
		weapon_pickup.queue_free()

func _resolve_pickup_node(pickup_path: NodePath) -> WeaponPickup:
	var scene_root := get_tree().current_scene
	if scene_root:
		var map_node := scene_root.find_child("Map", true, false)
		if map_node:
			var from_map := map_node.get_node_or_null(pickup_path) as WeaponPickup
			if from_map:
				return from_map

	var from_root := get_tree().root.get_node_or_null(pickup_path) as WeaponPickup
	if from_root:
		return from_root

	var pickup_name := String(pickup_path).get_file()
	if pickup_name == "":
		return null

	if scene_root:
		return scene_root.find_child(pickup_name, true, false) as WeaponPickup

	return null
