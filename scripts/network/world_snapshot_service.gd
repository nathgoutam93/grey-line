extends Node
class_name WorldSnapshotService

## Server: every SEND_INTERVAL_TICKS, packs player state into one compact
## packet per peer (instead of one RPC per player per tick). Each peer is only
## told about players it can see (VisibilityQuery) or hear (noise radius), so a
## modified client cannot reveal the whole map. Heard-but-unseen players are
## flagged audio-only: the client keeps them hidden but moves them, so their
## footsteps and shots still play from the right place.
## Client: unpacks the packet, sets each remote player's NetPresence and hands
## each entry to its PlayerController.
##
## Autoloaded as `WorldSnapshots` so the RPC path is identical on every peer.
## Runs in _physics_process, after NetworkTick (earlier autoload), so all
## players have already simulated the tick being sent.

## 2 ticks at 60 Hz = 30 snapshots per second.
const SEND_INTERVAL_TICKS := 2
const RPC_CHANNEL_WORLD := 1

# Packet layout (Array):
const P_TICK := 0
const P_IDS := 1 # PackedInt32Array of owner peer ids
const P_POSITIONS := 2 # PackedVector2Array
const P_VELOCITIES := 3 # PackedVector2Array
const P_ROTATIONS := 4 # PackedFloat32Array
const P_ACK_TICK := 5 # receiver's own player: last applied input tick
const P_LEAD_TICK := 6 # receiver's own player: input lead sample tick
const P_INPUT_LEAD := 7 # receiver's own player: input lead in ticks
const P_FLAGS := 8 # PackedByteArray, per entry: FLAG_VISIBLE or 0 (audio only)
const P_WEAPON_SLOT := 9 # receiver's own player: selected (or switching-to) slot
const P_WEAPON_AMMO := 10 # receiver's own player: PackedInt32Array [mag, reserve] per weapon slot
const PACKET_SIZE := 11

const FLAG_VISIBLE := 1
## Keep sending a player as visible this long after it leaves view, so the
## client never hides something its own fog of war is still fading out.
const VISIBLE_GRACE_TICKS := 15

# peer_id -> { target owner id -> last tick it was visible to that peer }
var _last_visible_tick := {}

var _last_sent_tick := 0
## Server: packets sent per peer id (diagnostics and tests). At most one per
## physics frame, so under load it can be fewer than one per send interval.
var packets_sent := {}

func _physics_process(_delta: float) -> void:
	if not _is_server():
		return
	var tick := NetworkTick.tick
	if tick - _last_sent_tick < SEND_INTERVAL_TICKS:
		return
	_last_sent_tick = tick
	var peers := multiplayer.get_peers()
	if peers.is_empty():
		return
	var players := _live_players()
	if players.is_empty():
		return # lobby / between matches
	var smoke := VisibilityQuery.collect_smoke_blockers(get_tree())
	for key in _last_visible_tick.keys():
		if not peers.has(key):
			_last_visible_tick.erase(key)
	for peer_id in peers:
		_receive_world_snapshot.rpc_id(peer_id, _packet_for_peer(tick, players, peer_id, smoke))
		packets_sent[peer_id] = int(packets_sent.get(peer_id, 0)) + 1

## Builds the packet a given peer would receive right now (also used by tooling).
func build_packet(peer_id: int) -> Array:
	var smoke := VisibilityQuery.collect_smoke_blockers(get_tree())
	return _packet_for_peer(NetworkTick.tick, _live_players(), peer_id, smoke)

func _packet_for_peer(tick: int, players: Array[PlayerController], peer_id: int, smoke: Array) -> Array:
	var ids := PackedInt32Array()
	var positions := PackedVector2Array()
	var velocities := PackedVector2Array()
	var rotations := PackedFloat32Array()
	var flags := PackedByteArray()
	var ack_tick := 0
	var lead_tick := 0
	var input_lead := 0
	var weapon_slot := -1
	var weapon_ammo := PackedInt32Array()

	# The viewer may be dead (hidden, about to despawn): it still sees and
	# hears from where it fell. With no player node at all, nothing is sent.
	var viewer := _find_player_node(peer_id)
	if viewer != null:
		if not _last_visible_tick.has(peer_id):
			_last_visible_tick[peer_id] = {}
		var seen: Dictionary = _last_visible_tick[peer_id]
		for target in players:
			var flag := -1
			if target == viewer:
				flag = FLAG_VISIBLE
				var owner_fields := target.net_sync.get_owner_snapshot_fields()
				ack_tick = owner_fields[0]
				lead_tick = owner_fields[1]
				input_lead = owner_fields[2]
				weapon_slot = owner_fields[3]
				weapon_ammo = owner_fields[4]
			elif VisibilityQuery.can_see(viewer, target, smoke):
				seen[target.owner_peer_id] = tick
				flag = FLAG_VISIBLE
			elif tick - int(seen.get(target.owner_peer_id, -100000)) <= VISIBLE_GRACE_TICKS:
				flag = FLAG_VISIBLE
			elif VisibilityQuery.can_hear(viewer, target):
				flag = 0
			if flag < 0:
				continue
			ids.append(target.owner_peer_id)
			positions.append(target.global_position)
			velocities.append(target.velocity)
			rotations.append(target.rotation)
			flags.append(flag)
	return [tick, ids, positions, velocities, rotations, ack_tick, lead_tick, input_lead, flags, weapon_slot, weapon_ammo]

func _find_player_node(peer_id: int) -> PlayerController:
	for node in get_tree().get_nodes_in_group("Player"):
		var player := node as PlayerController
		if player != null and player.is_inside_tree() and player.owner_peer_id == peer_id:
			return player
	return null

func _live_players() -> Array[PlayerController]:
	var result: Array[PlayerController] = []
	for node in get_tree().get_nodes_in_group("Player"):
		var player := node as PlayerController
		if player == null or not player.is_inside_tree() or player.is_dead:
			continue
		result.append(player)
	return result

@rpc("authority", "call_remote", "unreliable", RPC_CHANNEL_WORLD)
func _receive_world_snapshot(packet: Array) -> void:
	if _is_server():
		return
	if packet.size() != PACKET_SIZE:
		return
	var tick := int(packet[P_TICK])
	var ids: PackedInt32Array = packet[P_IDS]
	var positions: PackedVector2Array = packet[P_POSITIONS]
	var velocities: PackedVector2Array = packet[P_VELOCITIES]
	var rotations: PackedFloat32Array = packet[P_ROTATIONS]
	var flags: PackedByteArray = packet[P_FLAGS]
	var count := ids.size()
	if positions.size() != count or velocities.size() != count or rotations.size() != count or flags.size() != count:
		return

	# Player nodes are named after their owner's peer id by the spawner.
	var by_name := {}
	for node in get_tree().get_nodes_in_group("Player"):
		var player := node as PlayerController
		if player != null:
			by_name[String(player.name)] = player

	var local_peer_id := multiplayer.get_unique_id()
	var present := {}
	for i in range(count):
		var player := by_name.get(str(ids[i]), null) as PlayerController
		if player == null or not is_instance_valid(player):
			continue
		present[player] = true
		if ids[i] != local_peer_id:
			player.net_sync.set_net_presence(PlayerNetSync.NetPresence.VISIBLE if flags[i] == FLAG_VISIBLE else PlayerNetSync.NetPresence.AUDIBLE)
		var snapshot := {
			"tick": tick,
			"position": positions[i],
			"velocity": velocities[i],
			"rotation": rotations[i],
		}
		if ids[i] == local_peer_id:
			snapshot["ack_tick"] = int(packet[P_ACK_TICK])
			snapshot["lead_tick"] = int(packet[P_LEAD_TICK])
			snapshot["input_lead"] = int(packet[P_INPUT_LEAD])
			snapshot["weapon_slot"] = int(packet[P_WEAPON_SLOT])
			snapshot["weapon_ammo"] = packet[P_WEAPON_AMMO] as PackedInt32Array
		player.net_sync.apply_snapshot(snapshot)

	# Everyone the server left out is neither seen nor heard.
	for player in by_name.values():
		if present.has(player) or player.is_local_player or String(player.name) == str(local_peer_id):
			continue
		player.net_sync.set_net_presence(PlayerNetSync.NetPresence.CULLED)

func _is_server() -> bool:
	var peer := multiplayer.multiplayer_peer
	# is_server() logs an error every call once the connection has closed.
	if peer == null or peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return false
	return multiplayer.is_server()
