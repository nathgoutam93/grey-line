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
- Suites: `unit` (`tests/unit/unit_tests.gd`: input frames, bot brain frames, history, interpolation, reconciliation, one-tick movement, ammo sync, server vision/hearing) and two-process host+client scenarios in `tests/net/`: `sync` (input clock, prediction, snapshots), `visibility` (fog of war + audio presence), `firing` (owner prediction, ammo/slot reconciliation), `match` (kills, respawn, score limit), `bots` (puppet replication, movement, scoring, respawn and removal).
- Tests pass `--ephemeral-profile` (profile stays in memory, never saved) and use ports 3300+, so they don't touch your profile or a running game. `tests/` is excluded from exports.
- New network scenario: add `tests/net/<name>_test.gd` extending `net_test_base.gd` (override `run_host`/`run_client`; the client reports with `send()`, the host checks with `check()`), then add `<name>` to `ALL_SUITES` in `tests/run_tests.sh`.
- Host-side network tests can `await add_bot()` during a match, then script its `BotBrain` with `bot(id)`. Bots use negative ids and the normal server input pipeline; `MultiplayerSession.add_bot()` / `remove_bot(id)` also work in the lobby. Debug hosts have Add bot / Remove bot buttons beside Start.
- Still do a focused manual playtest for gameplay/feel changes: main menu -> host/join lobby -> start match -> verify replication, combat, and UI sync, with at least two clients (host + one client) on separate machines for networking changes.

## Commit & Pull Request Guidelines
- Recent commits are short, imperative summaries; optional prefixes like `fix:` are common. Keep subject lines specific.
- One logical change per commit (avoid mixing gameplay, UI, and asset churn).
- PRs should include: what changed, why, manual test steps/results, and screenshots/videos for visible UI/FX updates.
- Link related issue/task IDs when available.
