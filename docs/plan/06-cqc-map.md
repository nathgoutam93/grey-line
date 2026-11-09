# Step 6: First CQC map

## Goal

`cqc_1`: a compact map built for the round mode:
- one objective building with soft interior walls, several entrances and doors;
- outdoor approaches with cover;
- role spawns far apart.

All walls are tile-based (hard, reinforced or soft), so destruction, fog of war and server vision work with no hand-maintained occluder copies.

## Design decisions (already made; don't change without asking)

1. **Map source is an ASCII layout plus a generator.**
   - The layout lives in `scenes/maps/cqc_1/layout.txt`.
   - `tools/build_map.gd` turns it into `scenes/maps/cqc_1/cqc_1.tscn`.
   - Agents and humans edit the text grid and re-run the generator. Never hand-edit the generated `.tscn`.
   - Regenerating must be deterministic.
2. **Every wall is a tile** in one `DestructibleWalls` layer (HARD tiles for the boundary and exterior structure). There are no `StaticBody2D` polygons and no `GeneratedOccluders` copies (that's how `map_1` works, and it's error-prone).
3. **Metrics** (16 px cells; player capsule radius 18):

   | Element | Size |
   |---|---|
   | Corridor | ≥ 6 cells wide (96 px) |
   | Doorway | 4 cells (64 px), matching the door length |
   | Room | ≥ 12×12 cells |
   | Map | about 200×130 cells (3200×2080 px) |
   | Longest open sight line | ≤ 90 cells (1440 px, inside the 1536 px vision range) |
4. **Objective building:**
   - about 50×35 cells;
   - entrances: 3 doors and 2 soft wall sections that are meant to be breached;
   - the objective room is in the interior with 2 approaches;
   - defender spawns are inside or right next to the building; attacker spawns are ≥ 1400 px from the objective, outside.
5. **Cover** outdoors uses existing props (`scenes/props/*`), placed by the generator as instances (they carry their own collision; they are not tiles).

## Layout legend (`layout.txt`)

One character per cell; all rows must be the same width.

| Char | Meaning |
|---|---|
| `.` | floor |
| `#` | HARD wall |
| `R` | REINFORCED wall |
| `S` | SOFT wall |
| `-` | door, horizontal (spans 4 cells: put `-` in all 4) |
| `\|` | door, vertical (4 cells) |
| `a` | attacker spawn point (cell centre) |
| `d` | defender spawn point |
| `O` | objective zone (the bounding box of all `O` cells becomes one `ObjectiveZone`) |
| `c` | crate prop |
| `v` | car prop |
| `t` | truck prop (top-left anchor; leave the area free of walls) |

## Architecture

`tools/build_map.gd` (`extends SceneTree`, run with `godot --headless -s tools/build_map.gd -- --layout=scenes/maps/cqc_1/layout.txt --out=scenes/maps/cqc_1/cqc_1.tscn`):

1. Load `scenes/maps/_template/round_map_template.tscn`: a hand-made template containing the fixed structure, copied once from `map_1_rounds.tscn` (step 5) with the level content removed:
   - `World` root;
   - `FowMaskView` (with `Level`, `LOS`, `Camera2D`, but no `GeneratedOccluders`);
   - `Map/Floor`, `Map/DestructibleWalls` (empty, with the generated TileSet), `Map/Doors`, `Map/Props`, `Map/SpawnPoints/AttackerSpawns`, `Map/SpawnPoints/DefenderSpawns`;
   - `CanvasLayer` (fog sprite);
   - `RoundGameMode` instance;
   - `PlayerSpawner`, `PickupSpawner`, `ProjectileSpawner`;
   - `DestructionService`.
2. Parse the layout and fill:
   - `DestructibleWalls.set_cell(cell, 0, atlas_coords_for(material))` for wall characters;
   - door instances (`scenes/props/door/door.tscn`) at each 4-cell run (centre position; rotation 90° for `|`);
   - spawn `Node2D`s;
   - one `ObjectiveZone` instance sized to the `O` bounding box;
   - prop instances;
   - floor: one `ColorRect`/`Sprite2D` covering the map, or a floor `TileMapLayer` (any tile; visual only).
3. Set owners so everything is saved (`node.owner = root` for each created node), then `PackedScene.pack(root)` and `ResourceSaver.save`.
4. Set the `FowMaskView` size and `LOS` settings as in the template.

## Tasks

1. **Template scene** `scenes/maps/_template/round_map_template.tscn`.
   - Copy `map_1_rounds.tscn`, then delete `Map/Level` children, `FowMaskView/Level/GeneratedOccluders` and the map sprite.
   - Add the empty `Map/DestructibleWalls` (with the tileset from step 4), `Map/Doors`, `Map/Props`, `Map/Floor` and the two spawn containers.
   - **Check:** the scene loads (unit suite).
2. **Generator** `tools/build_map.gd` (above).
   - It must exit non-zero with a clear message on: ragged rows, unknown characters, door runs not exactly 4, 0 or more than 1 objective region, or fewer than 5 spawns per role.
   - **Check:** generate a tiny `tests/fixtures/mini_layout.txt` (about 30×20) to `tests/fixtures/mini_map.tscn` and load it in a unit test.
3. **The layout** `scenes/maps/cqc_1/layout.txt` following the metrics above. Start from this outline and refine:
   - a HARD boundary;
   - the objective building in the centre-east, with an exterior of `R` and `S` (two `S` sections facing the attackers), three doors (north, west, south), and soft interior walls dividing it into 4–6 rooms;
   - the objective room in the middle, reachable from two interior doors;
   - attackers spawn on the far west edge; defenders spawn inside the building's east rooms;
   - outdoor props as cover between them.
4. **Generate `cqc_1.tscn`;** add it to the lobby `MAPS` list (step 5 task 9) as "CQC 1".
5. **Map validation test.** Add `tests/unit/map_validation_tests.gd` (or extend the unit suite) for every map in `MultiplayerSession.MAPS` that uses `RoundGameMode`:
   - the required nodes exist;
   - ≥ 5 spawn points per role;
   - each spawn point is `spot_free` (radius 24) after one physics frame;
   - exactly one `ObjectiveZone`;
   - all `DestructibleWalls` cells use a known material;
   - attacker spawns are ≥ 1400 px from the objective centre;
   - the generated scene is up to date: re-running the generator in memory produces the same cell list as the saved scene.
6. **Tuning pass** (manual, with 2 humans + bots): adjust the layout for sight lines and timings, then regenerate.
   - Write down the "time from attacker spawn to objective" (target 15–20 s at running speed) in the PR.

## Edge cases

- **Doors on the map edge or overlapping walls:** the generator errors.
- **Props overlapping walls:** the generator warns, and validation catches blocked spawns.
- **Size:** keep the total tile count reasonable; a 200×130 grid is 26k cells, which is fine for `TileMapLayer`.

## Manual playtest

Two humans plus bots, full rounds on `cqc_1`:
- attackers can breach the soft sections;
- defenders can hold the objective;
- sound tells you where pushes come from;
- no spawn is visible from the other spawn;
- no stuck spots (walk along every wall).

## Commit plan

1. `feat: add round map template and ASCII map generator` (tasks 1–2).
2. `feat: add cqc_1 map` (tasks 3–4).
3. `test: validate round maps` (task 5).
4. Tuning commits as needed (`tweak: cqc_1 …`).
