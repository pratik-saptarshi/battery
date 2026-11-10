#!/bin/bash
# Observational probe: prints how the current battery.sh behaves on the fixtures,
# without asserting anything. Used to record tests/BASELINE.txt on the unmodified
# code (fix/fail-loud-no-charge-key @ f4e342f, v1.3.4). All execution goes through
# tests/harness.sh.
#
# Usage: BATTERY_TEST_TMPDIR=/some/scratch/dir tests/baseline.sh

# shellcheck source=tests/harness.sh
source "$(dirname "$0")/harness.sh"
trap bt_teardown_all EXIT

say() { printf '%s\n' "$*"; }

say "== B1 maintain 74 on the macOS 27 fixture (no CH0B/CH0C/CHTE key)"
bt_setup smc_macos27.txt ioreg.txt
bt_run 30 maintain 74
say "rc=$BT_RC"
say "LaunchAgent created: $([ -f "$T/home/Library/LaunchAgents/battery.plist" ] && echo yes || echo no)"
say "pid file written: $([ -s "$T/home/.battery/battery.pid" ] && echo yes || echo no)"
say "maintain.percentage: $(cat "$T/home/.battery/maintain.percentage" 2>/dev/null)"
bt_wait_for 15 "$T/home/.battery/battery.log" "Charge at or above 74%"
say "smc writes: $(tr '\n' ';' <"$T/smc_writes.log")"
say "daemon log claims 'Charge at or above': $(grep -c 'Charge at or above' "$T/home/.battery/battery.log" 2>/dev/null)"
say "daemon log attempted no charge-control write (it never decides is_charging=enabled)"
bt_stop_daemons
bt_teardown

say ""
say "== B2 maintain_synchronous 74 on the macOS 27 fixture (watch for 3 s)"
bt_setup smc_macos27.txt ioreg.txt
BT_SLEEP_MAX=0.2 bt_start_bg maintain_synchronous 74
command sleep 3
say "log lines claiming 'Charge at or above': $(grep -c 'Charge at or above' "$T/out")"
say "smc writes to CH0B/CH0C/CHTE: $(grep -c -E '^(CH0B|CH0C|CHTE) ' "$T/smc_writes.log")"
say "smc writes in total: $(wc -l <"$T/smc_writes.log" | tr -d ' ')"
say "last 4 output lines:"
tail -n 4 "$T/out"
bt_teardown

say ""
say "== B3 status on the macOS 27 fixture with a stored maintain percentage"
bt_setup smc_macos27.txt ioreg.txt
mkdir -p "$T/home/.battery"
echo "424242 active" >"$T/home/.battery/battery.pid"
echo "74" >"$T/home/.battery/maintain.percentage"
bt_run 30 status
say "rc=$BT_RC"
say "$(grep -E 'Battery at|maintained at' "$T/out")"
bt_run 30 status_csv
say "status_csv: $BT_OUT"
bt_teardown

say ""
say "== B4 maintain stop on the macOS 27 fixture"
bt_setup smc_macos27.txt ioreg.txt
bt_run 30 maintain stop
say "rc=$BT_RC"
say "$(grep -E 'Killing running maintain|Unable to|maintained at|NOT LIMITING' "$T/out")"
bt_teardown

say ""
say "== B5 maintain 74 on the synthetic macOS 26 fixture (CHTE present)"
bt_setup smc_macos26.txt ioreg.txt
bt_run 30 maintain 74
say "rc=$BT_RC"
say "LaunchAgent created: $([ -f "$T/home/Library/LaunchAgents/battery.plist" ] && echo yes || echo no)"
bt_wait_for 15 "$T/smc_writes.log" "CHTE -w 01000000"
bt_stop_daemons
say "smc writes: $(head -n 6 "$T/smc_writes.log" | tr '\n' ';')"
bt_teardown

say ""
say "== B6 maintain_synchronous 74 on the synthetic legacy fixture (CH0B/CH0C present)"
bt_setup smc_legacy.txt ioreg.txt
BT_SLEEP_MAX=0.2 bt_start_bg maintain_synchronous 74
bt_wait_for 15 "$T/smc_writes.log" "CH0C -w 02"
say "smc writes: $(head -n 8 "$T/smc_writes.log" | tr '\n' ';')"
bt_teardown

say ""
say "== B7 CHTE answers 'Error:' instead of 'no data'"
bt_setup smc_macos27.txt ioreg.txt
sed -i '' 's/^CHTE	.*/CHTE	Error: SMCReadKey() = e00002c1/' "$T/fx/smc.txt"
BT_SLEEP_MAX=0.2 bt_start_bg maintain_synchronous 74
command sleep 2
say "loop still running: $(kill -0 "$BT_BG_PID" 2>/dev/null && echo yes || echo no)"
say "CHTE reads: $(grep -c '^read CHTE$' "$T/smc_reads.log")"
say "charge-control writes: $(grep -c -E '^(CH0B|CH0C|CHTE) ' "$T/smc_writes.log")"
bt_teardown
