# Repository Guidelines

## Roadmap
- GreyLine is becoming a real-time PvP close-quarters tactical shooter: teams, attack/defend rounds, destructible walls and doors, and sound as information. There is no planning phase and there are no AI opponents.
- The step-by-step build plan is in `docs/plan/`. Read `docs/plan/README.md` first (architecture, rules for implementing agents, definition of done), then only the step you are working on. Do the steps in order and follow each step's tasks, tests and commit plan rather than re-designing.

## Project Structure & Module Organization
- `project.godot` is the Godot 4.7 project entry; main scene is wired from there.
- `scenes/` contains playable scenes and feature flows (`main_menu`, `lobby`, `player`, `maps`, `ui`, `weapon`, `utilities`).
- `components/` holds reusable gameplay/UI components (health, movement, camera shake, weapon manager, fog of war, etc.).
- `scripts/` contains global/shared logic, including networking (`scripts/network/*`), profile data, and utilities.
- `resources/` stores typed data resources (`*.gd` resource classes, `*.tres` weapon/equipment/sound configs).
- `assets/`, `materials/`, and `shaders/` contain art/audio/render assets. `addons/` contains editor/runtime plugins.

## Build, Test, and Development Commands
- `godot4 --path . --editor`: Open the project in the Godot editor.
- `godot4 --path .`: Run the game using `run/main_scene`.
- `godot4 --headless --path . --export-release "Linux" dist/GreyLine.x86_64`: Build Linux export (preset in `export_presets.cfg`).
- `godot4 --headless --path . --export-release "Windows Desktop" dist/GreyLine.zip`: Build Windows export.

## Coding Style & Naming Conventions
- Follow existing GDScript style in this repo: typed variables where practical, `snake_case` for funcs/vars, `PascalCase` for `class_name` types.
- Keep scene and resource file names lowercase with underscores (for example `player_hud.tscn`, `weapon_sounds.gd`).
- Indentation is mixed historically (tabs and spaces); match the surrounding file instead of reformatting unrelated code.
- Keep `.gd.uid` files tracked with their corresponding scripts/scenes.

## Testing Guidelines
- Run the headless suite before opening a PR: `tests/run_tests.sh` (all suites, about 80 s) or `tests/run_tests.sh unit sync` for a subset. It finds Godot via `$GODOT`, `godot4`/`godot` on PATH, or the macOS app, and exits non-zero on any failure (logs path is printed).
- Pre-commit hook (no CI; tests run locally): enable once per clone with `git config core.hooksPath .githooks`. `.githooks/pre-commit` runs the suite on the *staged* snapshot (mirrored into `.git/precommit-tree`) whenever game files (`.gd`, `.tscn`, `.tres`, `.gdshader`, `.cfg`, `project.godot`) are staged, and aborts the commit on failure. `GREYLINE_PRECOMMIT_SUITES="unit sync"` runs a subset; `SKIP_TESTS=1 git commit ...` or `--no-verify` skips it.
- Suites: `unit` (`tests/unit/unit_tests.gd`: input frames, team rules/spawns/visuals and FFA fallback, bot brain frames, history, interpolation, reconciliation, one-tick movement, ammo sync, server vision/hearing) and two-process host+client scenarios in `tests/net/`: `sync` (input clock, prediction, snapshots), `visibility` (fog of war + audio presence and silent slow-walk), `firing` (owner prediction, ammo/slot reconciliation), `match` (kills, respawn, team score limit and results), `bots` (puppet replication, movement, scoring, respawn and removal), `teams` (lobby assignment/switch validation, teammate visibility, enemy vision, friendly fire and team scoring).
- Tests pass `--ephemeral-profile` (profile stays in memory, never saved) and use ports 3300+, so they don't touch your profile or a running game. `tests/` is excluded from exports.
- New network scenario: add `tests/net/<name>_test.gd` extending `net_test_base.gd` (override `run_host`/`run_client`; the client reports with `send()`, the host checks with `check()`), then add `<name>` to `ALL_SUITES` in `tests/run_tests.sh`.
- Host-side network tests can `await add_bot()` during a match, then script its `BotBrain` with `bot(id)`. Bots use negative ids and the normal server input pipeline; `MultiplayerSession.add_bot()` / `remove_bot(id)` also work in the lobby. Debug hosts have Add bot / Remove bot buttons beside Start.
- Network scenarios can override `run_host_lobby()` for checks before the match starts and use `find_wall_setup()` for visibility arrangements. `MultiplayerSession.set_team(id, team)` is server-only and can arrange test teams mid-match; client requests are restricted to balanced lobby switches. Maps can provide `SpawnPoints/AttackerSpawns` (Alpha) and `DefenderSpawns` (Bravo), with flat spawn points as fallback. Set the game mode's `teams_enabled` to false for FFA, or `friendly_fire` to true to permit teammate weapon damage. Frag explosions always damage both teams and the thrower within their radius, regardless of that setting.
- The lobby renders separate Alpha/Bravo rosters through `LobbyView`; five players balance 3–2, and roster rows are not capped at five. The `teams` suite verifies the five-player split on host and client. For a graphical fixture screenshot, run the unit scene without `--headless` and pass `-- --ephemeral-profile --lobby-preview=/tmp/greyline-lobby.png`.
- Slow-walk silences footsteps on the server, owner and proxies, including movement from knockback; equipment noise stays audible. World snapshot flags are bits: `FLAG_VISIBLE = 1`, `FLAG_FOOTSTEPS = 2`, and `FLAG_SPOTTED = 4` is reserved. Touch players toggle Walk under HUD Controls; its position is saved in the touch-layout settings.
- Destructible walls use 16 px TileMapLayer cells and a collision-free fog mirror under `FowMaskView/Level`. Regenerate the committed tileset with `godot4 --headless --path . -s tools/build_destructible_tileset.gd -- --ephemeral-profile`. The map-root `DestructionService` owns cell HP and reliable channel 3 updates; wall paths are relative to its parent. Clients request full state at map readiness and local player setup; `reset_all()` restores cells and clears partial damage on the server and peers. Existing static exterior walls stay indestructible.
- Weapons stop at the first wall cell: bullets deal `wall_damage` (default 10), knives `melee_wall_damage` (20); both fields survive pickup serialization. Frags deal 200 maximum wall damage with distance falloff. Wall damage resolves before player blast line-of-sight checks; intact environment cover blocks blast damage and knockback, while exposed teammates and the thrower still take damage.
- Still do a focused manual playtest for gameplay/feel changes: main menu -> host/join lobby -> start match -> verify replication, combat, and UI sync, with at least two clients (host + one client) on separate machines for networking changes.

## Commit & Pull Request Guidelines
- Recent commits are short, imperative summaries; optional prefixes like `fix:` are common. Keep subject lines specific.
- One logical change per commit (avoid mixing gameplay, UI, and asset churn).
- PRs should include: what changed, why, manual test steps/results, and screenshots/videos for visible UI/FX updates.
- Link related issue/task IDs when available.
