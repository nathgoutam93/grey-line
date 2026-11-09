#!/usr/bin/env bash
# Headless test suite: unit tests, then host+client network scenarios.
#
#   tests/run_tests.sh                 # everything
#   tests/run_tests.sh unit sync       # only these suites
#
# Suites: unit, sync, visibility, firing, match, bots, teams, destruction, doors, rounds, cqc, host_visibility.
# Godot binary: $GODOT, else godot4 / godot on PATH, else the macOS app.
# Logs go to $TEST_LOG_DIR (default: a new temp dir), printed at the end.
# Tests run with --ephemeral-profile, so your saved profile is never touched,
# and use ports 3300-3399 so a running game (port 3000) is not disturbed.
set -u

cd "$(dirname "$0")/.."

find_godot() {
	if [ -n "${GODOT:-}" ]; then echo "$GODOT"; return; fi
	for candidate in godot4 godot; do
		if command -v "$candidate" >/dev/null 2>&1; then command -v "$candidate"; return; fi
	done
	if [ -x /Applications/Godot.app/Contents/MacOS/Godot ]; then
		echo /Applications/Godot.app/Contents/MacOS/Godot; return
	fi
	echo ""
}

GODOT_BIN="$(find_godot)"
if [ -z "$GODOT_BIN" ]; then
	echo "Godot not found: set GODOT=/path/to/godot" >&2
	exit 2
fi

LOG_DIR="${TEST_LOG_DIR:-$(mktemp -d -t greyline-tests.XXXXXX)}"
mkdir -p "$LOG_DIR"
ALL_SUITES=(unit sync visibility firing match bots teams destruction doors rounds cqc host_visibility)
if [ "$#" -gt 0 ]; then SUITES=("$@"); else SUITES=("${ALL_SUITES[@]}"); fi

failed=()
passed=()

# Run a command with a time limit; prints its exit code (124 on timeout).
run_with_timeout() {
	local seconds="$1"; shift
	"$@" &
	local pid=$!
	local waited=0
	while kill -0 "$pid" 2>/dev/null; do
		if [ "$waited" -ge "$seconds" ]; then
			kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null
			wait "$pid" 2>/dev/null
			return 124
		fi
		sleep 1
		waited=$((waited + 1))
	done
	wait "$pid"
}

summarize() { # $1 = log file
	grep -E "^TEST (PASS|FAIL|SUMMARY)" "$1" | sed 's/^/    /'
}

echo "Godot: $GODOT_BIN ($("$GODOT_BIN" --version 2>/dev/null))"
echo "Logs:  $LOG_DIR"
echo "Importing project..."
"$GODOT_BIN" --headless --path . --import >"$LOG_DIR/import.log" 2>&1

port=3300
for suite in "${SUITES[@]}"; do
	if [ "$suite" = "unit" ]; then
		echo "== unit"
		run_with_timeout 120 "$GODOT_BIN" --headless --path . res://tests/unit/unit_tests.tscn -- --ephemeral-profile >"$LOG_DIR/unit.log" 2>&1
		code=$?
		summarize "$LOG_DIR/unit.log"
		if [ "$code" -eq 0 ]; then passed+=(unit); else failed+=("unit(exit $code)"); fi
		continue
	fi
	if [ ! -f "tests/net/${suite}_test.gd" ]; then
		echo "Unknown suite: $suite" >&2
		failed+=("$suite(unknown)")
		continue
	fi
	echo "== $suite (host + client on port $port)"
	args=(--headless --path . res://tests/net/net_test.tscn -- --ephemeral-profile "--net-test=$suite" "--port=$port")
	if [ "$suite" = "rounds" ]; then
		args+=(--map=res://scenes/maps/map_1/map_1_rounds.tscn)
	elif [ "$suite" = "cqc" ]; then
		args+=(--map=res://scenes/maps/cqc_1/cqc_1.tscn)
	fi
	run_with_timeout 120 "$GODOT_BIN" "${args[@]}" --role=host >"$LOG_DIR/$suite.host.log" 2>&1 &
	host_runner=$!
	sleep 1
	run_with_timeout 120 "$GODOT_BIN" "${args[@]}" --role=client >"$LOG_DIR/$suite.client.log" 2>&1
	client_code=$?
	wait "$host_runner"
	host_code=$?
	summarize "$LOG_DIR/$suite.host.log"
	summarize "$LOG_DIR/$suite.client.log"
	if [ "$host_code" -eq 0 ] && [ "$client_code" -eq 0 ]; then
		passed+=("$suite")
	else
		failed+=("$suite(host exit $host_code, client exit $client_code)")
	fi
	port=$((port + 2))
done

echo
echo "Passed: ${passed[*]:-none}"
if [ "${#failed[@]}" -gt 0 ]; then
	echo "FAILED: ${failed[*]}"
	echo "Logs:   $LOG_DIR"
	exit 1
fi
echo "All suites passed."
