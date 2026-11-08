extends Node
class_name WorldSnapshotService

## Server: every SEND_INTERVAL_TICKS, packs the state of every live player into
## one compact packet per peer (instead of one RPC per player per tick).
## Client: unpacks the packet and hands each entry to its PlayerController.
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
const PACKET_SIZE := 8

var _last_sent_tick := 0

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
		return
	var shared := _pack_players(players)
	for peer_id in peers:
		_receive_world_snapshot.rpc_id(peer_id, _packet_for_peer(tick, shared, players, peer_id))

## Builds the packet a given peer would receive right now (also used by tooling).
func build_packet(peer_id: int) -> Array:
	var players := _live_players()
	return _packet_for_peer(NetworkTick.tick, _pack_players(players), players, peer_id)

func _packet_for_peer(tick: int, shared: Array, players: Array[PlayerController], peer_id: int) -> Array:
	var ack_tick := 0
	var lead_tick := 0
	var input_lead := 0
	for player in players:
		if player.owner_peer_id == peer_id:
			var owner_fields := player.get_owner_snapshot_fields()
			ack_tick = owner_fields[0]
			lead_tick = owner_fields[1]
			input_lead = owner_fields[2]
			break
	return [tick, shared[0], shared[1], shared[2], shared[3], ack_tick, lead_tick, input_lead]

func _pack_players(players: Array[PlayerController]) -> Array:
	var ids := PackedInt32Array()
	var positions := PackedVector2Array()
	var velocities := PackedVector2Array()
	var rotations := PackedFloat32Array()
	for player in players:
		ids.append(player.owner_peer_id)
		positions.append(player.global_position)
		velocities.append(player.velocity)
		rotations.append(player.rotation)
	return [ids, positions, velocities, rotations]

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
	var count := ids.size()
	if positions.size() != count or velocities.size() != count or rotations.size() != count:
		return

	# Player nodes are named after their owner's peer id by the spawner.
	var by_name := {}
	for node in get_tree().get_nodes_in_group("Player"):
		var player := node as PlayerController
		if player != null:
			by_name[String(player.name)] = player

	var local_peer_id := multiplayer.get_unique_id()
	for i in range(count):
		var player := by_name.get(str(ids[i]), null) as PlayerController
		if player == null or not is_instance_valid(player):
			continue
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
		player.apply_snapshot(snapshot)

func _is_server() -> bool:
	return multiplayer.multiplayer_peer != null and multiplayer.is_server()
