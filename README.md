• Current multiplayer setup is server-authoritative ENet with LAN discovery.

  1. Session/connection layer

  - Uses ENetMultiplayerPeer (create_server / create_client) in components/multiplayer/multiplayer_manager.gd.
  - Default server port is 3000; LAN discovery uses UDP broadcast on 3001 with token GREYLINE_DISCOVERY_V1 (same file).
  - Client join flow: auto-discover host, fallback to manual IP input, then register profile via RPC _register_player_profile.
  - Networking singleton tick clock is autoloaded as NetworkTick in project.godot:22.

  2. Scene flow

  - Main scene is scenes/main_menu/main_menu.tscn; HOST/JOIN buttons call MultiplayerManager.host_game/join_game.
  - Lobby scene scenes/lobby/lobby.tscn syncs roster/map/start state through sync_lobby(...) in scenes/lobby/lobby.gd.
  - Server starts match via start_match(), loads selected map into Level, and hides lobby UI.

  3. In-match architecture

  - Map scene scenes/maps/map_1/map_1.tscn contains:
      - DeathmatchGameMode
      - PlayerSpawner, PickupSpawner, ProjectileSpawner (MultiplayerSpawners).
  - Match logic is in components/deathmatch/deathmatch.gd:
      - Server spawns players, tracks K/D/ping/timer, handles end-match, and syncs stats UI via RPCs.
  - Player netcode is in scenes/player_scripts/player_controller.gd:
      - Client owner sends input every network tick (rpc_id(1, server_receive_input, ...), unreliable).
      - Server simulates authoritative state and sends snapshots (unreliable).
      - Owner client reconciles; non-owners interpolate with small delay.
      - Combat/inventory actions are executed on server and mirrored via _remote_* RPCs.

  4. Replication details

  - Player nodes are spawned by server; authority is set to peer 1 (host/server) while owner_peer_id tracks who controls input.
  - Pickups/projectiles use MultiplayerSynchronizer configs in:
      - scenes/weapon_pickup/base_pickup.tscn
      - scenes/utilities/frag/frag_projectile.tscn
      - scenes/utilities/flashbang/flashbang_projectile.tscn
      - scenes/utilities/smoke/smoke_projectile.tscn
  - Damage is server-only and then synced (_remote_sync_health) in components/health/health.gd.
