# Step 4: Destructible walls and doors

## Goal

Interior walls are built from **destructible cells** that bullets, explosions and melee can break. Holes open sight lines (fog of war, both client and server), movement paths and sound. **Doors** can be opened quietly, kicked open loudly, or destroyed. Everything is server-authoritative and replicated to every peer, including late joiners.

This step is split into sub-phases, 4A–4F. Do them in order; each ends in a working, tested state.

## Design decisions (already made; don't change without asking)

| Topic | Decision |
|---|---|
| Granularity | A grid of **16 px cells** (`TileMapLayer`). No free-form polygon fracturing. |
| Materials | `SOFT` (drywall, wood): bullets, melee and explosives. `REINFORCED`: explosives only. `HARD`: indestructible. Existing exterior walls stay as they are (static, indestructible). |
| HP | SOFT 40, REINFORCED 150 (`max_hp` per tile in TileSet custom data) |
| Bullets | Damage the first cell they hit and stop there (no penetration in v1; see 4F). Wall damage per weapon: `Weapon.wall_damage` (new field, default 10). |
| Explosions | Frags deal **200 max wall damage**, scaled by distance (user-approved). Damage every cell within the radius whose centre has line of sight to the blast (hard walls shield). The same check is applied to **player damage**, which fixes the current bug where frags hurt through walls. Player damage retains its existing values and includes teammates and the thrower. |
| Melee | Knife hits damage SOFT cells (`melee_wall_damage` 20) and doors (a kick, see 4D). |
| Doors | States `CLOSED`, `OPEN`, `BROKEN`. Interact toggles CLOSED/OPEN (quiet: 250 px noise). Doors have HP 60; melee does 60 (one kick breaks them). Broken doors are permanently open (loud: 900 px noise). Explosions break them. |
| Sound | v1: hearing radius is attenuated by intact walls between listener and source (raycast). v2 (later): a portal graph like Siege's propagation nodes. |
| Round reset | Walls and doors can be fully restored (used by step 5). |

## Architecture

```
Map scene
├─ Map/DestructibleWalls        DestructibleWalls (TileMapLayer): collision layer 1 (Environment), occlusion OFF in the main world
├─ Map/Doors/<door nodes>       Door (StaticBody2D layer 1 + Interactable)
├─ DestructionService           Node: server-side HP, damage rules, replication (fixed path => RPC-safe)
└─ FowMaskView/Level
   ├─ (existing occluders)
   ├─ DestructibleWallsMirror   TileMapLayer created at runtime by DestructibleWalls: same cells, occlusion ON, invisible, no collision
   └─ door occluders            LightOccluder2D per door, created at runtime by Door
```

- **Why a mirror layer:** the client's fog of war is drawn by the `LOS` light inside the `FowMaskView` SubViewport. Light occluders only affect lights in the same canvas, so wall occluders must exist *inside* that viewport. This is the same pattern the smoke mask already uses: `smoke_projectile.gd` adds a mask copy under `FowMaskView/Level`.
- **Server line of sight:** `VisibilityQuery` and weapons raycast against physics layer 1. Because erased cells lose their collision, holes automatically open server-side sight lines.
  - **Call `update_internals()` after erasing on the server,** so raycasts later in the same tick see the hole. The engine otherwise applies the change at the end of the frame (see `TileMapLayer.update_internals` in the docs).
- **Channel 3:** the ENet peers are created with `create_server(port, max_players)` / `create_client(address, port)`, which use the default channel count (0 = ENet's maximum), so channel 3 is available. The destruction test confirms it; if it fails with an invalid-channel error, pass an explicit `max_channels` (for example 4) to both calls.
- **Replication (event + state).**
  - **Events:** destroyed cells are batched per tick and sent as one reliable RPC on **channel 3**.
  - **State:** a full dump on request (late join and resync).
  - This is the standard pattern for block and grid worlds: incremental updates plus a full state for newcomers.
- **Snapshot vs hole timing:** the server may report an enemy as VISIBLE through a fresh hole slightly before the hole event reaches a client (different channels). That's harmless: until the client erases the cell, its own fog of war still occludes that enemy.

## Contracts

`components/destruction/destruction_material.gd`:

```gdscript
extends RefCounted
class_name DestructionMaterial
const SOFT := 0
const REINFORCED := 1
const HARD := 2
const KIND_BULLET := 0
const KIND_EXPLOSIVE := 1
const KIND_MELEE := 2
static func can_damage(material: int, kind: int) -> bool
    # SOFT: all kinds; REINFORCED: EXPLOSIVE only; HARD: none
static func sound_factor(material: int) -> float   # SOFT 0.6, REINFORCED 0.4, HARD 0.35
```

`components/destruction/destructible_walls.gd`:

```gdscript
extends TileMapLayer
class_name DestructibleWalls
const GROUP := &"destructible_walls"
func cell_at_world(world_pos: Vector2) -> Vector2i
func cell_from_hit(hit: Dictionary) -> Vector2i        # uses get_coords_for_body_rid(hit.rid); falls back to cell_at_world(hit.position - hit.normal * 1.0)
func cell_material(cell: Vector2i) -> int              # TileSet custom data "material"; -1 if empty
func cell_max_hp(cell: Vector2i) -> int                # custom data "max_hp"
func has_wall(cell: Vector2i) -> bool
func destroy_cells(cells: Array[Vector2i]) -> void     # erase in self + mirror, then update_internals() on both
func restore_all() -> void                             # tile_map_data = _original_data (self + mirror)
func destroyed_cells() -> Array[Vector2i]              # cells present originally but empty now
```

`components/destruction/destruction_service.gd` (node `DestructionService` at the map root):

```gdscript
extends Node
class_name DestructionService
const RPC_CHANNEL_DESTRUCTION := 3
signal cells_destroyed(cells: Array[Vector2i])
# server
func apply_cell_damage(walls: DestructibleWalls, cell: Vector2i, amount: int, kind: int) -> void
func apply_explosion(center: Vector2, radius: float, max_damage: int) -> void   # cells + doors
func reset_all() -> void                                                        # walls restore + doors CLOSED + broadcast
# replication
@rpc("authority", "call_remote", "reliable", 3) func _cells_destroyed_event(walls_path: NodePath, cells: PackedVector2Array)
@rpc("any_peer", "call_remote", "reliable", 3)  func request_state()
@rpc("authority", "call_remote", "reliable", 3) func _full_state(walls_state: Dictionary, door_states: Dictionary)
@rpc("authority", "call_remote", "reliable", 3) func _reset_event()
```

Use `PackedVector2Array` on the wire (Vector2i arrays aren't a packed type); convert with `Vector2i(v)`. `walls_state` is `{walls_path: PackedVector2Array of destroyed cells}`.

`scenes/props/door/door.gd`:

```gdscript
extends StaticBody2D
class_name Door
enum State { CLOSED, OPEN, BROKEN }
const GROUP := &"doors"
@export var max_hp := 60
func on_interact(player: PlayerController) -> void       # server only: CLOSED <-> OPEN
func apply_damage(amount: int, kind: int, source: PlayerController) -> void   # server only
func set_state_local(state: State) -> void               # applies collision, occluder, sprite on this peer
@rpc("authority", "call_remote", "reliable", 3) func _state_event(state: int)
```

`Weapon` resource: add `@export var wall_damage := 10` and `@export var melee_wall_damage := 20` (melee weapons). **Also add both to `Weapon.to_dict()` and `Weapon.new_from_dict()` (use `dict.get(key, default)` there)**: weapon pickups copy weapon data through these, and a dropped weapon would otherwise lose the values.

## Tasks

### 4A: Destructible grid foundation

1. **Material helper** (`DestructionMaterial`).
   - **Check:** unit tests for `can_damage`.
2. **TileSet generator.** Write `tools/build_destructible_tileset.gd` (`extends SceneTree`, run with `godot --headless -s tools/build_destructible_tileset.gd`). It **generates** `resources/destruction/destructible_walls_tileset.tres` and placeholder textures in code, so no hand-editing of TileSet resources is needed:
   - `tile_size = Vector2i(16, 16)`;
   - physics layer 0: `collision_layer = 1`, `collision_mask = 0`;
   - occlusion layer 0;
   - custom data layers `material` (int) and `max_hp` (int);
   - one atlas source from a generated 48×16 PNG (`resources/destruction/walls_atlas.png`) with three tiles (SOFT light grey, REINFORCED dark grey, HARD black). Each tile gets a full-square collision polygon, a full-square occluder polygon and custom data.

   Commit the generated `.tres` and `.png`. Re-running the tool must be deterministic.
3. **`DestructibleWalls` node.** In `_ready`:
   - add to `GROUP`;
   - set `occlusion_enabled = false` (the main world doesn't need occluders);
   - store `_original_data = tile_map_data`;
   - create the mirror: a new `TileMapLayer` with the same `tile_set` and `tile_map_data`, `collision_enabled = false`, `occlusion_enabled = true`, `modulate = Color(1, 1, 1, 0)`, added under `MaskViewProvider.viewport.get_node("Level")` at the same `global_transform` (skip if no viewport, for example on a dedicated server);
   - remove the mirror in `_exit_tree`.

   **Check:** unit test `test_destructible_walls_destroy_and_restore`: build a layer in code with the generated tileset, place 3 SOFT cells, destroy 1, and assert `has_wall` is false, the mirror cell is empty and a raycast passes through; `restore_all` brings it back.
4. **`DestructionService` node** added to `map_1.tscn` (root child, empty state). The game mode looks it up as `get_tree().get_first_node_in_group("destruction_service")`.

### 4B: Server damage and replication

5. **Server HP and damage.**
   - `_cell_hp := {}` keyed by `"%s|%d,%d" % [walls_path, x, y]`, or one nested dict per walls node.
   - `apply_cell_damage` checks `DestructionMaterial.can_damage`, subtracts, and at ≤ 0: `walls.destroy_cells([cell])`, appends to `_pending[walls_path]` and emits `cells_destroyed`.
   - **Server only;** clients return early.
6. **Batch flush.** In `_physics_process` (it runs after `NetworkTick`, like `WorldSnapshots`): for each walls path with pending cells, call `_cells_destroyed_event.rpc(path, cells_as_packed)`, then clear. Clients apply with `destroy_cells`.
7. **State sync.**
   - **Clients:** call `request_state.rpc_id(1)` once the map is ready (in `_ready` with `call_deferred`, and again from `MatchPlayerSpawner._setup_player` for the local player, to cover races).
   - **Server:** reply with `_full_state.rpc_id(sender, …)` built from `destroyed_cells()` and door states.
   - **Clients:** apply idempotently (destroying an already-empty cell is a no-op).
8. **Reset.** `reset_all()` (server) → `restore_all()` on every walls node, doors → CLOSED, then `_reset_event.rpc()`. Used in step 5.

### 4C: Damage sources

9. **Bullets.** In `WeaponInstance._shoot_raycast`, on the server only: if `occlusion_result.collider is DestructibleWalls` (and the shot didn't hit a hurtbox first), compute `walls.cell_from_hit(occlusion_result)` and call `service.apply_cell_damage(walls, cell, data.wall_damage, KIND_BULLET)`. Melee weapons (knife, `uses_ammo == false`) use `melee_wall_damage` and `KIND_MELEE`.
   - **The bullet trail and impact already stop at the wall** (no change).
10. **Explosions.** In `FragProjectile` (server):
    - first call `service.apply_explosion(global_position, explosion_radius, wall_damage)`;
    - then, for player damage, **skip players whose centre has no clear line of sight from the blast** (raycast mask 1, after the cell destruction above). This fixes damage through walls.
    - `apply_explosion` iterates cells in the radius's bounding box (convert with `cell_at_world`), checks the cell centre's line of sight with a raycast that ignores the target cell itself (stop if the hit cell == target cell), and scales damage by `1 - distance / radius`.
11. **Tests (unit).**
    - `test_bullet_damage_rules`: a SOFT cell takes 4 bullet hits of 10 → destroyed; a REINFORCED cell doesn't change.
    - `test_explosion_shielded_by_hard_wall`: a cell behind a HARD cell is untouched.

### 4D: Doors

12. **Door scene** `scenes/props/door/door.tscn`:
    - `StaticBody2D` (`collision_layer = 1`) with a 64×8 `CollisionShape2D`;
    - a `Sprite2D` (placeholder);
    - an `Interactable` child (existing component, an `Area2D` on layer 3 that detects players);
    - the `door.gd` script.

    `_ready`: add to `GROUP`; create the mask occluder (a `LightOccluder2D` with a 64×8 polygon) under `FowMaskView/Level` at the same transform.
13. **Door logic.**
    - `set_state_local`: CLOSED → `collision_layer = 1`, occluder visible, closed sprite. OPEN/BROKEN → `collision_layer = 0`, occluder hidden, open/broken sprite. Changing `collision_layer` takes effect immediately for server raycasts.
    - `on_interact` (server): toggle CLOSED↔OPEN, then `player.net_sync.report_noise(250, 0.4)`, then `_state_event.rpc(state)`.
    - `apply_damage`: at ≤ 0 → BROKEN, then `report_noise(900, 1.0)` on the source player, then broadcast.
    - **Interaction plumbing:** `PlayerNetSync._remote_interact` currently runs `on_interact` on *every* peer. Change it so the server alone calls `owner_ref.on_interact(player)`; clients do nothing (the door broadcasts its state).
    - **Check that weapon pickups still work** (`WeaponPickup.on_interact` is already server-only).
14. **Kick.**
    - In `WeaponInstance._shoot_raycast`, when the occlusion collider is a `Door` (server): `door.apply_damage(melee ? 60 : data.wall_damage, kind, player)`.
    - Explosions: `apply_explosion` also damages doors in range (with a line-of-sight check).
15. **Door state in the full state dump** (`_full_state` door states keyed by the door's path relative to the map root).
16. **Tests.**
    - Unit `test_door_states`: interact toggles; damage breaks; BROKEN ignores interact.
    - Network suite `doors` (next section).

### 4E: Sound through walls (v1)

17. **Attenuation.**
    - Add `static func occlusion_factor(from: Vector2, to: Vector2, space) -> float` to `VisibilityQuery`. Walk the segment with repeated raycasts (mask 1). For each hit, multiply by the material factor: `DestructibleWalls` cell → `DestructionMaterial.sound_factor`; a closed `Door` → 0.7; any other static body → 0.35. Continue from just past the hit (`hit.position + dir * 17.0`); stop after 4 hits or at `to`.
    - `can_hear` uses `radius * occlusion_factor(...)`.
    - **Check:** unit tests: one SOFT wall makes an 800 px footstep inaudible at 500 px (0.6 × 800 = 480 < 500). At 450 px one SOFT wall remains audible, but two stacked walls do not (0.6² × 800 = 288 < 450). Removing the cells restores hearing immediately.
18. **(Optional) Client muffling.**
    - Create an audio bus `Occluded` with a low-pass filter.
    - `PlayerController._process` (proxies only, every 0.1 s): compute `occlusion_factor` from the local player to this player, and route this player's `AudioStreamPlayer2D`s to `Occluded` when < 1.0, `Master` otherwise.

### 4F: Later (do not do now; noted so nobody re-designs it)

- **Bullet penetration of SOFT walls:** after damaging a cell, continue the ray from behind it with 50% damage, max 1 wall.
- **Damage stages** (cracks) as visual-only events.
- **Portal-graph sound propagation** (Siege-style): when the raycast attenuation feels wrong in tight maps.

## Network test suites to add

`tests/net/destruction_test.gd` (add to `ALL_SUITES`):
- **Fixture:** `tests/fixtures/test_wall.tscn`, a `DestructibleWalls` node with a vertical line of 12 SOFT cells.
- The host tells the client (via `send("spawn_fixture", pos)`) to instance it under `Map` with the name `TestWall` at the same position. Both sides do this, so paths match.
- Place the client and the host on opposite sides.

Checks:
- `intact_wall_blocks_vision`: the client sees the host as CULLED (the host is silent).
- `destroyed_cells_replicate`: the host destroys 3 cells via `apply_cell_damage` (enough damage) → within 0.5 s the client's fixture reports those cells empty.
- `hole_opens_server_sight`: the host stands at the hole → the client sees it VISIBLE.
- `late_state_resync`: the client calls `request_state` → its `destroyed_cells()` equals the server's.
- `reset_restores_walls`: the host calls `reset_all()` → the client's fixture has all 12 cells again.

`tests/net/doors_test.gd`:
- Fixture `tests/fixtures/test_door.tscn` (one `Door`), spawned the same way.

Checks:
- `closed_door_blocks_vision` → CULLED.
- `interact_opens_quietly`: the host interacts (server call) → the client door state is OPEN, the host becomes VISIBLE, and the noise radius is 250.
- `kick_breaks_loudly`: the bot (step 1) with a knife attacks the closed door → state BROKEN on the client, and the client, standing 600 px away out of sight, hears the source (AUDIBLE).

## Manual playtest

- Shoot a wall until a hole appears: you can see and shoot through it, and the enemy behind it appears.
- Frag a wall: big hole. Reinforced walls survive bullets but not frags.
- Frags no longer hurt you through a hard wall.
- Open a door quietly vs kick it (loud).
- A client joining after holes were made sees the same holes.

## Commit plan

1. `feat: add destructible wall grid with fog-of-war mirror` (4A).
2. `feat: server-authoritative wall damage and replication` (4B).
3. `feat: bullets, melee and explosions damage walls; frags respect line of sight` (4C).
4. `feat: add doors with quiet open, kick and breach` (4D).
5. `feat: attenuate hearing through walls` (4E, task 17; task 18 separately if done).
6. `test: add destruction and doors network suites`.
