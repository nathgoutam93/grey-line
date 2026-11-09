# Host fog regression

The host retained every authoritative player node without applying its own
visibility packet. Character body polygons also lost the fog material at the
intermediate `polygons` node, bypassing the exact visual cone even when the server
allowed a target through its wider replication margin.

The host now applies the same packet visibility rules to local presentation,
including teammate spectating and sessions with no remote clients. Authoritative
movement, damage and replication continue for hidden actors. Body polygons inherit
the fog material; allied bodies remain unmasked.

## Automated coverage

Run `tests/run_tests.sh unit host_visibility` for the no-client host regression,
material inheritance and two-process visibility scenario. The network scenario
checks hidden enemies behind cover, visible allies, independent client visibility,
hidden movement/damage, audible-only enemies, cover breaking, private teammate sight,
spectator sight and no remaining teammate vision.

Run the `host_visibility` scenario without `--headless` to add rendered pixel
checks. Start host and client using `res://tests/net/net_test.tscn`, passing
`-- --ephemeral-profile --net-test=host_visibility --port=3372 --role=host`
or `--role=client`. Optional `--capture-dir=/tmp/greyline-host-fog` saves checkpoints.

Local graphical host/client verification passed all 14 checks: the enemy body
changed 2,223 pixels when in view, zero pixels outside the exact cone (but inside
the server's replication margin), and the allied body changed 2,136 pixels outside
the cone. The graphical fixture centres its camera on each target while keeping
the host's vision origin and aim fixed.

## Remaining manual check

Repeat on separate machines through the normal host/join lobby flow: move an enemy
behind cover and out of the host's cone, breach cover, then spectate an ally after
death. Verify enemies appear only within the active view and allies stay visible.
The local automated graphical run does not replace that separate-machine playtest.
