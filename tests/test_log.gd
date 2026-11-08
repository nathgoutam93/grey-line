extends RefCounted

## Shared PASS/FAIL output for the headless tests. tests/run_tests.sh relies
## on the exit code; the lines are for people reading the log.

var suite := ""
var passes := 0
var failures := 0

func _init(suite_name: String) -> void:
	suite = suite_name

func pass_test(name: String, detail: String = "") -> void:
	passes += 1
	print("TEST PASS [%s] %s%s" % [suite, name, (" - " + detail) if detail != "" else ""])

func fail(name: String, message: String) -> void:
	failures += 1
	print("TEST FAIL [%s] %s: %s" % [suite, name, message])
	push_error("TEST FAIL [%s] %s: %s" % [suite, name, message])

## Prints the summary and returns the process exit code.
func finish() -> int:
	print("TEST SUMMARY [%s] %d passed, %d failed" % [suite, passes, failures])
	return 1 if failures > 0 else 0
