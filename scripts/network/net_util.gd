extends RefCounted
class_name NetUtil

## True while `mp` has a peer that is connecting or connected, false once the
## connection has closed. (Godot's offline peer counts as connected, so a map
## run on its own still behaves as the server.)
static func has_active_peer(mp: MultiplayerAPI) -> bool:
	if mp == null:
		return false
	var peer := mp.multiplayer_peer
	if peer == null:
		return false
	return peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED
