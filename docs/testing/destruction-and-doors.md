# Destruction and doors validation

> Walls are now indestructible; doors and breakable crates are the destructibles. Older notes below about wall breaches describe the previous design.

Step 4 uses 16 px cells: SOFT has 40 HP, REINFORCED 150 HP, and HARD is indestructible. Frags use the approved **200 maximum wall damage**, with distance falloff. Player blast damage retains its previous values and includes teammates and the thrower when exposed.

## Automated coverage

Run `tests/run_tests.sh` twice before completing the step. The pre-commit hook also runs the full staged snapshot.

| Suite | Checks added for Step 4 |
|---|---|
| `unit` | Every wall material rejects damage, exact ray-to-cell mapping, immediate collision/fog removal, restore, wall state full-state/reset, pickup serialization, real bullet/knife hits breaking crates but not walls, blast shielding, reinforced walls surviving frags, same-blast exposure through a broken crate, crate HP/fog linking/full state/reset, door states/combat/full state, pickup interaction, multiple nearby players, hearing materials/stacking/holes/doors/hit limit |
| `visibility` | Distant footsteps suppressed by hard cover; nearby footsteps still audible through cover |
| `destruction` | Client authority guard, intact-crate culling, crate break (collision, sprite, fog) replicated within 30 network ticks, sight where the crate stood, repeated full state repairing a missed break, reset restoring HP, collision and fog |
| `doors` | Client authority guard, closed-door culling, quiet server interaction, normal puppet knife input breaking a door, hidden source AUDIBLE at 600 px with 900 px noise, full-state repair, HP/collision/fog reset |
| Existing suites | Movement sync, firing prediction/ammo, scoring/respawn, puppets, teams and teammate frag damage remain covered |

## Rendered loopback checks

Both new scenarios were also run with two graphical Godot processes on the same Mac. Captured client frames were inspected: an intact wall masks the centre of the view, a breach reveals the opponent, and opening a door removes its shadow and reveals the opponent. The graphical scenarios also pass their network assertions. Screenshot encoding is kept outside the replication timing measurement.

To reproduce with two terminals, use an available Godot executable in place of `godot4`:

```sh
# Terminal 1: host
godot4 --path . res://tests/net/net_test.tscn -- --ephemeral-profile --net-test=destruction --port=3350 --role=host

# Terminal 2: client; saves intact, breached, resynced and reset frames
godot4 --path . res://tests/net/net_test.tscn -- --ephemeral-profile --net-test=destruction --port=3350 --role=client --capture-dir=/tmp/greyline-step4
```

Use `--net-test=doors --port=3352` on both peers for closed/open/broken/reset door frames. These scenarios arrange the fixtures automatically and exit when their checks finish. The shipped map retains its static exterior; the CQC layout is Step 6.

## Remaining manual validation

A host/client playtest on **two separate machines** has not been performed in this environment. The remaining checklist is the Step 4 manual playtest: shoot and frag soft/reinforced walls, verify hard cover shields players, compare quiet opening with a loud kick, and verify a joining client receives existing breaches. Forced full-state resync is covered automatically; a real late-joining connection and gameplay feel still need that manual check.
