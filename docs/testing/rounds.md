# Attack/defend rounds validation

The host selects **Map 1 Rounds** with **Change map** in the lobby. The existing deathmatch map remains available. Defaults are a 5-second freeze, 120-second round, 10-second accumulated objective hold and first to four round wins. Teams stay fixed; attack/defend roles swap after three finished rounds. There is no economy in this version; fresh lives receive the default loadout.

## Automated coverage

Run `tests/run_tests.sh unit rounds` for focused coverage, or `tests/run_tests.sh` for all regression suites. The pre-commit hook also tests the exact staged snapshot.

The Step 5 regression run passes 133 checks: 48 unit and 85 network checks on Godot 4.7.2. The rounds scenario also passes all 12 checks with two graphical peers.

| Coverage | Checks |
|---|---|
| Unit | Generic mode lookup; movement/action locks with aim preserved; walking but no damage during ROUND_END; fresh role spawns, health, ammo and wall reset; elimination scoring; contested/empty objective pause without decay; halftime and match end; default first-to-four match on real server ticks; spectator visibility, grace history, camera and teammate cycling; dev map/objective clearance; host-only map picker |
| Input lifecycle | Persistent channel-0 input ingress rejects missing/dead players, another player's life and stale input from a previous life. Spectators cannot drive their camera target. Only the server despawns dead players. |
| `rounds` network suite | Host map picker and replicated selection; rejected client selection; predicted and server freeze movement; dead remote client spectating an ally; no live-round respawn; elimination and replicated round score; full-health/ammo/role spawn and breached-cell reset; timer agreement; defender timeout; client objective bar; bot capture; halftime and first-to-two results on both peers |

The network scenario uses 2-second freeze, 6-second live rounds, 2-second capture and first to two wins. A temporary second puppet gives the remote client an ally to spectate in the opening round; it is removed after that round, and the remaining match uses the host, client and one puppet. Puppets stay scripted test tools without AI behavior.

## Rendered loopback checks

The scenario also runs in two graphical Godot processes on one Mac. Client checkpoints show the lobby, freeze, teammate spectating, fresh round, role change, objective progress and defeat overlay; the host checkpoint shows spectating the capturing teammate. Screenshot encoding happens after the client reports state, outside timer comparisons.

To reproduce, use two terminals and an available Godot executable in place of `godot4`:

```sh
# Host
godot4 --path . res://tests/net/net_test.tscn -- --ephemeral-profile --net-test=rounds --map=res://scenes/maps/map_1/map_1_rounds.tscn --port=3360 --role=host --capture-dir=/tmp/greyline-step5

# Client
godot4 --path . res://tests/net/net_test.tscn -- --ephemeral-profile --net-test=rounds --map=res://scenes/maps/map_1/map_1_rounds.tscn --port=3360 --role=client --capture-dir=/tmp/greyline-step5
```

Captured frames go to `/tmp/greyline-step5/rounds-<role>-<checkpoint>.png`. While dead, use **F** or **Next teammate** to cycle living allies; the server supplies only that teammate's view.

## Remaining manual validation

A host/client playtest on **two separate machines** has not been performed in this environment. Run the Step 5 checklist at the default first-to-four setting: freeze/unlock, elimination, fresh lives and restored destruction, attacker capture, defender timeout, halftime, final result/return flow and teammate spectating. The dev map preserves the original three spawns per role; the CQC layout and five spawns per role are Step 6.
