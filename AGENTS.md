# Repository Guidelines

## Project Structure & Module Organization
- `project.godot` is the Godot 4.6 project entry; main scene is wired from there.
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
- No automated test framework is currently configured for game logic.
- Validate changes with focused manual playtests: main menu -> host/join lobby -> start match -> verify replication, combat, and UI sync.
- For networking changes, run at least two clients (host + one client) before opening a PR.

## Commit & Pull Request Guidelines
- Recent commits are short, imperative summaries; optional prefixes like `fix:` are common. Keep subject lines specific.
- One logical change per commit (avoid mixing gameplay, UI, and asset churn).
- PRs should include: what changed, why, manual test steps/results, and screenshots/videos for visible UI/FX updates.
- Link related issue/task IDs when available.
