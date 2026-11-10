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

# ------------------------------------- bug reproduction on the macOS 27 fixture
# These tests describe the CURRENT (unfixed) behaviour: they must pass before the
# capability gate is implemented. tests/BASELINE.txt records the same observations.
test_bug_maintain_starts_daemon_without_charge_key() {
	bt_setup smc_macos27.txt ioreg.txt
	bt_run 30 maintain 74
	check "bug: maintain 74 returns 0 despite having no charge-control key" [ "$BT_RC" -eq 0 ]
	check "bug: a LaunchAgent was created" [ -f "$T/home/Library/LaunchAgents/battery.plist" ]
	check "bug: a pid file was written" [ -s "$T/home/.battery/battery.pid" ]
	check "bug: the maintain percentage was stored" grep -qx '74' "$T/home/.battery/maintain.percentage"
	bt_stop_daemons
	bt_teardown
}

test_bug_loop_claims_charge_at_or_above_without_write() {
	bt_setup smc_macos27.txt ioreg.txt
	BT_SLEEP_MAX=0.2 bt_start_bg maintain_synchronous 74
	if bt_wait_for 15 "$T/out" "Charge at or above 74%"; then
		check "bug: the loop claims 'Charge at or above 74%'" true
	else
		not_ok "bug: the loop claims 'Charge at or above 74%'" "output: $(cat "$T/out")"
	fi
	check "bug: no charge-control SMC write was attempted" bash -c "! grep -qE '^(CH0B|CH0C|CHTE) ' '$T/smc_writes.log'"
	check "bug: the loop is still running (no capability gate)" kill -0 "$BT_BG_PID"
	check "bug: the loop sets the MagSafe LED green anyway" grep -qx 'ACLC -w 03' "$T/smc_writes.log"
	bt_teardown
}

test_bug_status_claims_maintained_without_charge_key() {
	bt_setup smc_macos27.txt ioreg.txt
	mkdir -p "$T/home/.battery"
	echo "424242 active" >"$T/home/.battery/battery.pid"
	echo "74" >"$T/home/.battery/maintain.percentage"
	bt_run 30 status
	check "bug: status claims the battery is being maintained" grep -q 'currently being maintained at 74%' <<<"$BT_OUT"
	bt_run 30 status_csv
	check "status_csv has five comma-separated fields" [ "$(awk -F, '{print NF}' <<<"$BT_OUT")" -eq 5 ]
	check "status_csv still reports charging as unknown on 27" [ "$(cut -d, -f3 <<<"$BT_OUT")" == "unknown" ]
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
