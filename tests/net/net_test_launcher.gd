extends Node

## Entry scene for network tests: puts the requested scenario
## (tests/net/<name>_test.gd) at /root/NetTest, outside the current scene, so
## it keeps running when MultiplayerSession switches to the lobby and map.

func _ready() -> void:
	var test_name := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--net-test="):
			test_name = arg.trim_prefix("--net-test=")
	var path := "res://tests/net/%s_test.gd" % test_name
	if test_name == "" or not ResourceLoader.exists(path):
		printerr("TEST FAIL [launcher] unknown --net-test=%s" % test_name)
		get_tree().quit(1)
		return
	var scenario := Node.new()
	scenario.set_script(load(path))
	scenario.name = "NetTest" # same path on host and client, so it can RPC
	get_tree().root.add_child.call_deferred(scenario)
