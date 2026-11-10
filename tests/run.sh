#!/bin/bash
# Regression tests for battery.sh. Plain bash 3.2, no bats.
# Every test runs a rewritten, stubbed copy of battery.sh under a temp HOME
# (see tests/harness.sh). Nothing here touches the SMC, sudo, launchd or ~/.battery.
#
# Usage: BATTERY_TEST_TMPDIR=/some/scratch/dir tests/run.sh [name-filter]

# shellcheck source=tests/harness.sh
source "$(dirname "$0")/harness.sh"
trap bt_teardown_all EXIT
FILTER="${1:-}"

run_test() {
	local fn="$1"
	[[ -n "$FILTER" && "$fn" != *"$FILTER"* ]] && return 0
	echo "# $fn"
	"$fn"
}

# ---------------------------------------------------------- harness self-tests
test_harness_refuses_foreign_home() {
	bt_setup smc_macos27.txt ioreg.txt
	mkdir -p "$T/decoy"
	env -i HOME="$T/decoy" PATH=/usr/bin:/bin /bin/bash "$T/bin/battery" version >/dev/null 2>"$T/err"
	BT_RC=$?
	check "copy exits 99 when HOME is not the test home" [ "$BT_RC" -eq 99 ]
	check "copy did not create state in the foreign HOME" [ ! -e "$T/decoy/.battery" ]
	bt_teardown
}

test_harness_selfcheck_rejects_unrewritten_copy() {
	bt_setup smc_macos27.txt ioreg.txt
	echo 'smc_binary=/usr/local/co.palokaj.battery/smc' >>"$T/bin/battery"
	(BT_ALL_ROOTS=() && bt_selfcheck) >/dev/null 2>&1
	BT_RC=$?
	check "self-check aborts on a copy naming the real smc" [ "$BT_RC" -eq 99 ]
	bt_teardown
}

test_harness_stubs_block_side_effects() {
	bt_setup smc_macos27.txt ioreg.txt
	local out
	out="$(env -i HOME="$T/home" PATH=/usr/bin:/bin /bin/bash -c "
		source '$T/stubs.sh'
		sudo /bin/echo should-not-run; echo \"sudo_rc=\$?\"
		sudo cp /nonexistent-bt-src '$T/x'; echo \"sudo_cp_rc=\$?\"
		kill -0 1; echo \"kill_rc=\$?\"
		pmset bt-noop-setter 1; echo \"pmset_rc=\$?\"
		type -t sudo; type -t kill; type -t pmset
	" 2>&1)"
	BT_OUT="$out"
	check "sudo stub refuses commands outside the allowlist" grep -q '^sudo_rc=1$' <<<"$out"
	check "sudo stub refuses absolute paths outside the test root" grep -q '^sudo_cp_rc=1$' <<<"$out"
	check "kill stub refuses non-test pids" grep -q '^kill_rc=1$' <<<"$out"
	check "pmset stub refuses setters" grep -q '^pmset_rc=1$' <<<"$out"
	check "the command echoed by sudo never ran" bash -c "! grep -q '^should-not-run' <<<\"\$1\"" _ "$out"
	check "blocked calls are logged" grep -q 'BLOCKED' "$T/calls.log"
	bt_teardown
}

test_harness_smc_stub_serves_fixture_and_logs_writes() {
	bt_setup smc_macos27.txt ioreg.txt
	check "absent key reads 'no data'" grep -q 'no data' <<<"$("$T/bin/smc" -k CHTE -r)"
	check "present key reads bytes" grep -q 'bytes 00' <<<"$("$T/bin/smc" -k CHIE -r)"
	"$T/bin/smc" -k CHIE -w 08
	check "write is logged" grep -qx 'CHIE -w 08' "$T/smc_writes.log"
	check "write is reflected in later reads" grep -q 'bytes 08' <<<"$("$T/bin/smc" -k CHIE -r)"
	check "reads are logged too" grep -qx 'read CHTE' "$T/smc_reads.log"
	bt_teardown
}

test_harness_version_runs_in_temp_home() {
	bt_setup smc_macos27.txt ioreg.txt
	bt_run 20 version
	check "version runs under the harness" [ "$BT_RC" -eq 0 ]
	check "state dir created inside the temp HOME" [ -d "$T/home/.battery" ]
	check "no sudo/pmset/kill was blocked" bash -c "! grep -q BLOCKED '$T/calls.log'"
	bt_teardown
}

# --------------------------------------------- C1: fail-loud capability gate
test_maintain_refused_without_actuator_macos27() {
	bt_setup smc_macos27.txt ioreg.txt
	bt_run 30 maintain 74
	check "maintain 74 exits non-zero on the 27 fixture" [ "$BT_RC" -ne 0 ]
	check "maintain 74 says charge limiting is unsupported" grep -q 'charge limiting unsupported on this Mac/macOS: no CH0B/CH0C/CHTE key' <<<"$BT_OUT"
	check "maintain 74 reports the native macOS limit" grep -q 'macOS charge limit active: 80% (manualChargeLimit)' <<<"$BT_OUT"
	check "maintain 74 wrote nothing to the SMC" [ ! -s "$T/smc_writes.log" ]
	check "maintain 74 created no LaunchAgent" [ ! -e "$T/home/Library/LaunchAgents/battery.plist" ]
	check "maintain 74 wrote no pid file" [ ! -e "$T/home/.battery/battery.pid" ]
	check "maintain 74 stored no percentage" [ ! -e "$T/home/.battery/maintain.percentage" ]
	check "maintain 74 stored no voltage" [ ! -e "$T/home/.battery/maintain.voltage" ]
	check "maintain 74 never started a maintenance loop" bash -c "! grep -q 'Starting battery maintenance' <<<\"\$1\"" _ "$BT_OUT"
	bt_run 30 maintain 74
	check "a second refusal exits non-zero too" [ "$BT_RC" -ne 0 ]
	check "the unsupported notification is shown at most once" [ "$(grep -c 'osascript.*not supported' "$T/calls.log")" -le 1 ]
	bt_teardown
}

test_maintain_refusal_does_not_kill_running_daemon() {
	bt_setup smc_macos27.txt ioreg.txt
	mkdir -p "$T/home/.battery"
	bt_dummy
	echo "$BT_DUMMY_PID active" >"$T/home/.battery/battery.pid"
	echo "80" >"$T/home/.battery/maintain.percentage"
	bt_run 30 maintain 74
	check "maintain 74 on 27 still exits non-zero" [ "$BT_RC" -ne 0 ]
	check "the already-running daemon pid was NOT killed" kill -0 "$BT_DUMMY_PID"
	check "the pid file was left untouched" grep -qx "$BT_DUMMY_PID active" "$T/home/.battery/battery.pid"
	check "the stored percentage was left untouched" [ "$(cat "$T/home/.battery/maintain.percentage")" == "80" ]
	check "no LaunchAgent was created" [ ! -e "$T/home/Library/LaunchAgents/battery.plist" ]
	bt_teardown
}

test_maintain_recover_refused_macos27() {
	bt_setup smc_macos27.txt ioreg.txt
	mkdir -p "$T/home/.battery"
	echo "74" >"$T/home/.battery/maintain.percentage"
	bt_run 30 maintain recover
	check "maintain recover exits non-zero on the 27 fixture" [ "$BT_RC" -ne 0 ]
	check "maintain recover reports the unsupported key" grep -q 'charge limiting unsupported' <<<"$BT_OUT"
	check "maintain recover created no LaunchAgent" [ ! -e "$T/home/Library/LaunchAgents/battery.plist" ]
	check "maintain recover did not rewrite the stored percentage" [ "$(cat "$T/home/.battery/maintain.percentage")" == "74" ]
	bt_teardown
}

test_maintain_stop_still_works_macos27() {	bt_setup smc_macos27.txt ioreg.txt
	bt_run 30 maintain stop
	check "maintain stop exits 0 on the 27 fixture" [ "$BT_RC" -eq 0 ]
	check "maintain stop still runs the stop path" grep -q 'Killing running maintain daemons' <<<"$BT_OUT"
	check "maintain stop is not refused by the capability gate" bash -c "! grep -q 'charge limiting unsupported' <<<\"\$1\"" _ "$BT_OUT"
	bt_teardown
}

test_maintain_range_and_voltage_refused_macos27() {
	bt_setup smc_macos27.txt ioreg.txt
	bt_run 30 maintain 70-80
	check "maintain 70-80 is refused on 27" [ "$BT_RC" -ne 0 ]
	check "maintain 70-80 reports the unsupported key" grep -q 'charge limiting unsupported' <<<"$BT_OUT"
	bt_run 30 maintain 11.4V
	check "maintain 11.4V is refused on 27" [ "$BT_RC" -ne 0 ]
	check "maintain 11.4V reports the unsupported key" grep -q 'charge limiting unsupported' <<<"$BT_OUT"
	check "neither form created a LaunchAgent" [ ! -e "$T/home/Library/LaunchAgents/battery.plist" ]
	check "neither form wrote to the SMC" [ ! -s "$T/smc_writes.log" ]
	bt_teardown
}

test_maintain_synchronous_refuses_without_actuator() {
	bt_setup smc_macos27.txt ioreg.txt
	bt_run 15 maintain_synchronous 74
	check "maintain_synchronous 74 exits non-zero by itself (no loop)" test "$BT_RC" -ne 0 -a "$BT_TIMED_OUT" -eq 0
	check "maintain_synchronous 74 logs the unsupported message" grep -q 'charge limiting unsupported' <<<"$BT_OUT"
	check "maintain_synchronous 74 never logs 'Charge at or above'" bash -c "! grep -q 'Charge at or above' <<<\"\$1\"" _ "$BT_OUT"
	check "maintain_synchronous 74 wrote nothing to the SMC" [ ! -s "$T/smc_writes.log" ]
	bt_run 15 maintain_synchronous recover
	check "boot-time maintain_synchronous recover exits non-zero" test "$BT_RC" -ne 0 -a "$BT_TIMED_OUT" -eq 0
	bt_run 15 maintain_voltage_synchronous 11.4 0.1
	check "maintain_voltage_synchronous exits non-zero by itself" test "$BT_RC" -ne 0 -a "$BT_TIMED_OUT" -eq 0
	bt_teardown
}

test_status_stops_claiming_maintenance_macos27() {
	bt_setup smc_macos27.txt ioreg.txt
	mkdir -p "$T/home/.battery"
	echo "424242 active" >"$T/home/.battery/battery.pid"
	echo "74" >"$T/home/.battery/maintain.percentage"
	bt_run 30 status
	check "status says NOT LIMITING" grep -q 'NOT LIMITING (no charge-control key)' <<<"$BT_OUT"
	check "status reports the native macOS limit" grep -q 'macOS charge limit active: 80% (manualChargeLimit)' <<<"$BT_OUT"
	check "status no longer claims the battery is being maintained" bash -c "! grep -q 'being maintained at' <<<\"\$1\"" _ "$BT_OUT"
	bt_run 30 status_csv
	check "status_csv keeps five comma-separated fields" [ "$(awk -F, '{print NF}' <<<"$BT_OUT")" -eq 5 ]
	check "status_csv charging state is unknown, not enabled" [ "$(cut -d, -f3 <<<"$BT_OUT")" == "unknown" ]
	bt_teardown
}

test_maintain_still_works_macos26() {
	bt_setup smc_macos26.txt ioreg.txt
	bt_run 30 maintain 74
	check "maintain 74 exits 0 on the 26 fixture" [ "$BT_RC" -eq 0 ]
	check "maintain 74 created the LaunchAgent" [ -f "$T/home/Library/LaunchAgents/battery.plist" ]
	check "maintain 74 stored the percentage" grep -qx '74' "$T/home/.battery/maintain.percentage"
	check "the loop disables charging via CHTE -w 01000000" bt_wait_for 20 "$T/smc_writes.log" "CHTE -w 01000000"
	check "no unsupported refusal on the 26 fixture" bash -c "! grep -q 'charge limiting unsupported' <<<\"\$1\"" _ "$BT_OUT"
	bt_stop_daemons
	bt_run 30 status
	check "status does not say NOT LIMITING on the 26 fixture" bash -c "! grep -q 'NOT LIMITING' <<<\"\$1\"" _ "$BT_OUT"
	bt_teardown
}

test_legacy_fixture_writes_ch0b_ch0c() {
	bt_setup smc_legacy.txt ioreg.txt
	BT_SLEEP_MAX=0.2 bt_start_bg maintain_synchronous 74
	check "legacy loop disables charging via CH0B -w 02" bt_wait_for 20 "$T/smc_writes.log" "CH0B -w 02"
	check "legacy loop also writes CH0C -w 02" bt_wait_for 5 "$T/smc_writes.log" "CH0C -w 02"
	bt_teardown
}

test_unreadable_key_is_retried_then_refused() {
	bt_setup smc_macos27.txt ioreg.txt
	# CHTE answers with an error instead of "no data": must not count as present.
	sed -i '' 's/^CHTE	.*/CHTE	Error: SMCReadKey() = e00002c1/' "$T/fx/smc.txt"
	bt_run 30 maintain_synchronous 74
	check "unknown CHTE: maintain_synchronous exits non-zero by itself" test "$BT_RC" -ne 0 -a "$BT_TIMED_OUT" -eq 0
	check "unknown CHTE: the probe was retried exactly once" [ "$(grep -c '^read CHTE$' "$T/smc_reads.log")" -eq 2 ]
	check "unknown CHTE: reported as still unreadable" grep -q 'still unreadable' <<<"$BT_OUT"
	check "unknown CHTE: treated as unsupported" grep -q 'charge limiting unsupported' <<<"$BT_OUT"
	check "unknown CHTE: no SMC writes" [ ! -s "$T/smc_writes.log" ]
	bt_teardown
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
	run_test "$t"
done

echo
echo "passed: $BT_PASS  failed: $BT_FAIL"
if ((BT_FAIL > 0)); then
	printf '  failed: %s\n' "${BT_FAILED_NAMES[@]}"
	exit 1
fi
exit 0
