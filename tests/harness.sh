#!/bin/bash
# shellcheck disable=SC2034
#
# Test harness for battery.sh. Sourced by tests/run.sh and tests/baseline.sh.
#
# Safety model (read before changing anything here):
#   * battery.sh is NEVER executed in place. Each test makes a temp root $T under
#     $BATTERY_TEST_TMPDIR, copies battery.sh to $T/bin/battery and rewrites every
#     system path in the copy (/usr/local/co.palokaj.battery, /usr/local/bin,
#     /private/etc/sudoers.d, /etc/paths.d) to point inside $T.
#   * Shell-function stubs for sudo, smc side effects, osascript, launchctl, curl,
#     pmset, ioreg, pgrep, pkill, kill, caffeinate, sleep, nohup, defaults, open,
#     visudo, chown, chmod and mktemp are injected into the copy right after its
#     PATH block, so they shadow the real commands for the copy and for every nested
#     $battery_binary call. The stub block is the only place that may add side
#     effects: everything else must stay read-only against the real machine.
#   * smc is a stub script ($T/bin/smc) that serves a fixture and logs every -r to
#     $T/smc_reads.log and every -w to $T/smc_writes.log. It never talks to the SMC.
#   * HOME is $T/home. The copy aborts (exit 99) if HOME is anything else.
#   * The harness aborts before running anything if the rewritten copy still names a
#     real install/system path, if it writes LaunchAgents outside $HOME, if it names
#     the real home directory, or if sudo/kill/pmset do not resolve to functions.
#   * Processes are only ever killed by PID that this harness started and recorded
#     (bt_dummy, bt_start_bg) or that the copy wrote into its own pidfiles. There is
#     no pkill/killall-by-pattern anywhere, not even during teardown.

BT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BT_FIXTURES="$BT_REPO/tests/fixtures"
BT_BASE="${BATTERY_TEST_TMPDIR:-}"
BT_REAL_HOME="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
[[ -z $BT_REAL_HOME ]] && BT_REAL_HOME="$HOME"
BT_ALL_ROOTS=()

bt_abort() {
	echo "HARNESS ABORT: $*" >&2
	bt_teardown_all
	exit 99
}

# Temp files must never land in /tmp or the real home.
case "$BT_BASE" in
	"") bt_abort "BATTERY_TEST_TMPDIR is not set (use a scratch dir under /private/tmp)" ;;
	/tmp | /tmp/*) bt_abort "BATTERY_TEST_TMPDIR must not be /tmp (use /private/tmp/...)" ;;
	"$BT_REAL_HOME" | "$BT_REAL_HOME"/*) bt_abort "BATTERY_TEST_TMPDIR is inside the real home" ;;
esac
case "$BT_BASE" in
	/private/tmp/?*) ;;
	*) bt_abort "BATTERY_TEST_TMPDIR must live under /private/tmp: $BT_BASE" ;;
esac
[[ -d "$BT_BASE" ]] || bt_abort "temp base $BT_BASE does not exist"

# The stub block injected into the copy. @BT_ROOT@ is replaced with the temp root.
bt_stub_block() {
	cat <<'STUBS'
## ---- BEGIN TEST HARNESS STUBS (injected by tests/harness.sh, never shipped) ----
BT_ROOT='@BT_ROOT@'
if [[ "$HOME" != "$BT_ROOT/home" ]]; then echo "HARNESS ABORT: HOME=$HOME is not the test home" >&2; exit 99; fi
bt_log() { echo "$*" >>"$BT_ROOT/calls.log"; }
bt_inside() { case "$1" in "$BT_ROOT"/*) return 0 ;; esac; return 1; }
sudo() {
	bt_log "sudo $*"
	local a
	while [[ "${1:-}" == -* ]]; do
		case "$1" in
			-u) shift 2 ;;
			*) shift ;;
		esac
	done
	if [[ $# -eq 0 ]]; then bt_log "BLOCKED sudo (no command): $*"; return 1; fi
	for a in "$@"; do
		case "$a" in /*) bt_inside "$a" || { bt_log "BLOCKED sudo (path outside test root): $*"; return 1; } ;; esac
	done
	case "$1" in
		"$BT_ROOT"/bin/smc | "$BT_ROOT"/bin/battery | rm | cp | mkdir | cmp | visudo | chown | chmod | launchctl | osascript) "$@" ;;
		*) bt_log "BLOCKED sudo (command not allowed): $*"; return 1 ;;
	esac
}
chown() { bt_log "chown $*"; return 0; }
chmod() { bt_log "chmod $*"; return 0; }
visudo() { bt_log "visudo $*"; return "${BT_VISUDO_RC:-0}"; }
osascript() {
	bt_log "osascript $*"
	case "$*" in *"button returned"*) echo "${BT_OSA_ANSWER:-No}" ;; esac
	return 0
}
launchctl() { bt_log "launchctl $*"; return 0; }
defaults() { bt_log "defaults $*"; echo "en_US"; }
open() { bt_log "BLOCKED open $*"; return 0; }
pgrep() { bt_log "pgrep $*"; return 1; }
pkill() { bt_log "BLOCKED pkill $*"; return 0; }
kill() {
	bt_log "kill $*"
	local a n=0
	for a in "$@"; do
		case "$a" in -*) continue ;; esac
		if [[ "$a" =~ ^[0-9]+$ ]]; then
			n=$((n + 1))
			if ! grep -qx "$a" "$BT_ROOT/killable" 2>/dev/null && ! ps -o command= -p "$a" 2>/dev/null | grep -qF "$BT_ROOT/"; then
				bt_log "BLOCKED kill $* (pid $a is not a test process)"
				return 1
			fi
		fi
	done
	[[ $n -gt 0 ]] || return 1
	builtin kill "$@"
}
mktemp() { # macOS mktemp ignores TMPDIR without a template: keep temp files in the test root
	if [[ $# -eq 0 || ($# -eq 1 && "$1" == "-d") ]]; then
		command mktemp "$@" "$BT_ROOT/tmp/tmp.XXXXXX"
	else
		command mktemp "$@"
	fi
}
caffeinate() { bt_log "caffeinate $*"; while [[ "${1:-}" == -* ]]; do shift; done; "$@"; }
sleep() {
	local d="${1:-0}" max="${BT_SLEEP_MAX:-0.05}"
	if awk "BEGIN{exit !($d > $max)}" 2>/dev/null; then d="$max"; fi
	command sleep "$d"
}
nohup() { bt_log "nohup $*"; exec "$@"; }
pmset() {
	bt_log "pmset $*"
	case "$*" in
		"-g batt") cat "$BT_ROOT/fx/pmset_batt" 2>/dev/null ;;
		"-g battlimit") cat "$BT_ROOT/fx/pmset_battlimit" 2>/dev/null ;;
		*) bt_log "BLOCKED pmset $*"; return 1 ;;
	esac
}
ioreg() {
	bt_log "ioreg $*"
	case "$*" in
		*AppleSmartBattery*) cat "$BT_ROOT/fx/ioreg.txt" 2>/dev/null ;;
		*) return 1 ;;
	esac
}
curl() { bt_log "curl $*"; return 22; }
if [[ "$(type -t sudo)" != "function" ]]; then echo "HARNESS ABORT: sudo is not stubbed" >&2; exit 99; fi
if [[ "$(type -t kill)" != "function" ]]; then echo "HARNESS ABORT: kill is not stubbed" >&2; exit 99; fi
if [[ "$(type -t pmset)" != "function" ]]; then echo "HARNESS ABORT: pmset is not stubbed" >&2; exit 99; fi
## ---- END TEST HARNESS STUBS ----
STUBS
}

bt_smc_stub() {
	cat <<'SMC'
#!/bin/bash
# smc test stub: serves $BT_ROOT/fx/smc.txt, records reads and writes. Never touches hardware.
BT_ROOT='@BT_ROOT@'
key="" mode="" val=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		-k) key="$2"; shift 2 ;;
		-r) mode=r; shift ;;
		-w) mode=w; val="$2"; shift 2 ;;
		*) echo "smc stub: unsupported argument $1" >&2; exit 2 ;;
	esac
done
[[ -z "$key" ]] && { echo "smc stub: no key given" >&2; exit 2; }
state="$BT_ROOT/smc_state/$key"
if [[ -f "$state" ]]; then
	line="$(cat "$state")"
else
	line="$(awk -F'\t' -v k="$key" '$1==k {print $2; exit}' "$BT_ROOT/fx/smc.txt")"
	[[ -z "$line" ]] && line="  $key  [    ]  no data"
fi
if [[ "$mode" == "w" ]]; then
	echo "$key -w $val" >>"$BT_ROOT/smc_writes.log"
	if [[ "$line" == *"bytes"* ]]; then
		type="$(echo "$line" | sed -E 's/^[^[]*(\[[^]]*\]).*/\1/')"
		bytes="$(echo "$val" | sed -E 's/(..)/\1 /g; s/ $//')"
		echo "  $key  $type  (bytes $bytes)" >"$state"
	fi
	exit 0
fi
echo "read $key" >>"$BT_ROOT/smc_reads.log"
echo "$line"
SMC
}

# bt_setup <smc fixture> [ioreg fixture or "empty"]
# Creates a fresh temp root in $T with a rewritten, stubbed copy of battery.sh.
bt_setup() {
	local smc_fx="$1" ioreg_fx="${2:-empty}" src="${BT_SCRIPT:-$BT_REPO/battery.sh}"
	[[ -f "$BT_FIXTURES/$smc_fx" ]] || bt_abort "missing smc fixture $smc_fx"
	T="$(command mktemp -d "$BT_BASE/bt.XXXXXX")" || bt_abort "mktemp failed"
	BT_ALL_ROOTS+=("$T")
	case "$T" in *" "*) bt_abort "temp root contains a space: $T" ;; esac
	[[ "$T/home" != "$BT_REAL_HOME" ]] || bt_abort "test HOME equals the real home"
	case "$T/home" in "$BT_REAL_HOME"/*) bt_abort "test HOME is inside the real home" ;; esac
	mkdir -p "$T/home" "$T/bin" "$T/usrlocalbin" "$T/sudoers.d" "$T/paths.d" "$T/tmp" "$T/smc_state" "$T/fx"
	: >"$T/smc_writes.log"
	: >"$T/smc_reads.log"
	: >"$T/calls.log"
	: >"$T/killable"

	cp "$BT_FIXTURES/$smc_fx" "$T/fx/smc.txt"
	if [[ "$ioreg_fx" != "empty" ]]; then
		cp "$BT_FIXTURES/$ioreg_fx" "$T/fx/ioreg.txt" || bt_abort "missing ioreg fixture $ioreg_fx"
	fi
	cp "$BT_FIXTURES/pmset_batt_ac.txt" "$T/fx/pmset_batt"
	cp "$BT_FIXTURES/pmset_battlimit_macos27.txt" "$T/fx/pmset_battlimit"

	bt_smc_stub | sed "s#@BT_ROOT@#$T#g" >"$T/bin/smc"
	command chmod 755 "$T/bin/smc"
	bt_stub_block | sed "s#@BT_ROOT@#$T#g" >"$T/stubs.sh"

	# Rewrite system paths, then inject the stubs right after the PATH block.
	# The first sed rule also rewrites the escaped pkill pattern on the uninstall path.
	sed -e 's#/usr/local/co\\\.palokaj\\\.battery#@ROOT@/bin#g' \
		-e 's#/usr/local/co\.palokaj\.battery#@ROOT@/bin#g' \
		-e 's#/usr/local/bin#@ROOT@/usrlocalbin#g' \
		-e 's#/private/etc/sudoers\.d#@ROOT@/sudoers.d#g' \
		-e 's#/etc/paths\.d/#@ROOT@/paths.d/#g' \
		"$src" | sed "s#@ROOT@#$T#g" | awk -v stubs="$T/stubs.sh" '
			{ print }
			!done && /^PATH=\/usr\/bin:\/bin:\/usr\/sbin:\/sbin$/ { while ((getline l < stubs) > 0) print l; done = 1 }
		' >"$T/bin/battery"
	command chmod 755 "$T/bin/battery"
	bt_selfcheck
}

# Hard self-checks. Any failure aborts the whole run before the copy executes.
bt_selfcheck() {
	local copy="$T/bin/battery" bad kind
	grep -q "BEGIN TEST HARNESS STUBS" "$copy" || bt_abort "stub block was not injected"
	bad="$(grep -v '^[[:space:]]*#' "$copy" | grep -n -E '/usr/local/|/opt/homebrew|/private/etc|/etc/sudoers|/etc/paths\.d|/Applications/|co\.palokaj' || true)"
	[[ -z "$bad" ]] || bt_abort "rewritten copy still references real paths:
$bad"
	bad="$(grep -v '^[[:space:]]*#' "$copy" | grep -n '/Library/LaunchAgents' | grep -v '\$HOME/Library/LaunchAgents' || true)"
	[[ -z "$bad" ]] || bt_abort "rewritten copy writes LaunchAgents outside \$HOME: $bad"
	grep -q "$BT_REAL_HOME/" "$copy" && bt_abort "rewritten copy names the real home"
	grep -qx "binfolder=\"$T/bin\"" "$copy" || bt_abort "binfolder was not rewritten to the test root"
	grep -qx 'smc_binary="$binfolder/smc"' "$copy" || bt_abort "smc_binary is not derived from the rewritten binfolder"
	grep -qx "visudo_folder=$T/sudoers.d" "$copy" || bt_abort "visudo_folder was not rewritten"
	grep -qx "path_configfile=$T/paths.d/50-battery" "$copy" || bt_abort "path_configfile was not rewritten"
	# The injected block must make the dangerous commands functions.
	kind="$(env -i HOME="$T/home" PATH=/usr/bin:/bin /bin/bash -c "source '$T/stubs.sh'; type -t sudo; type -t kill; type -t pmset" 2>&1)"
	[[ "$kind" == $'function\nfunction\nfunction' ]] || bt_abort "stubs do not shadow sudo/kill/pmset (got: $kind)"
}

# bt_run <timeout seconds> <battery args...>
# Runs the copy with a clean environment. Sets BT_RC, BT_OUT, BT_ERR, BT_TIMED_OUT.
bt_run() {
	local to="$1" pid ticks=0
	shift
	BT_TIMED_OUT=0
	env -i HOME="$T/home" USER="$(id -un)" LOGNAME="$(id -un)" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
		TMPDIR="$T/tmp" LANG=en_US.UTF-8 \
		BT_SLEEP_MAX="${BT_SLEEP_MAX:-0.05}" BT_OSA_ANSWER="${BT_OSA_ANSWER:-No}" BT_VISUDO_RC="${BT_VISUDO_RC:-0}" \
		/bin/bash "$T/bin/battery" "$@" </dev/null >"$T/out" 2>"$T/err" &
	pid=$!
	while kill -0 "$pid" 2>/dev/null; do
		if ((ticks >= to * 10)); then
			BT_TIMED_OUT=1
			kill -TERM "$pid" 2>/dev/null
			break
		fi
		command sleep 0.1
		ticks=$((ticks + 1))
	done
	wait "$pid"
	BT_RC=$?
	BT_OUT="$(cat "$T/out")"
	BT_ERR="$(cat "$T/err")"
}

# bt_start_bg <battery args...>: start the copy in the background; pid recorded in
# BT_BG_PID and in $T/killable so teardown can stop it by pid.
bt_start_bg() {
	env -i HOME="$T/home" USER="$(id -un)" LOGNAME="$(id -un)" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
		TMPDIR="$T/tmp" LANG=en_US.UTF-8 \
		BT_SLEEP_MAX="${BT_SLEEP_MAX:-0.05}" BT_OSA_ANSWER="${BT_OSA_ANSWER:-No}" BT_VISUDO_RC="${BT_VISUDO_RC:-0}" \
		/bin/bash "$T/bin/battery" "$@" </dev/null >"$T/out" 2>"$T/err" &
	BT_BG_PID=$!
	echo "$BT_BG_PID" >>"$T/killable"
}

# bt_wait_for <seconds> <file> <fixed string>: poll until the file contains the string.
bt_wait_for() {
	local to="$1" file="$2" str="$3" ticks=0
	while ! grep -qF -- "$str" "$file" 2>/dev/null; do
		((ticks >= to * 10)) && return 1
		command sleep 0.1
		ticks=$((ticks + 1))
	done
	return 0
}

# Start a harmless dummy process the copy may legitimately see killed.
bt_dummy() {
	# Started in a subshell so it is not a job of this shell (no "Terminated" noise).
	BT_DUMMY_PID="$(command sleep 300 >/dev/null 2>&1 & echo $!)"
	echo "$BT_DUMMY_PID" >>"$T/killable"
}

# Stop the daemons the copy started, using only the pids it wrote to its own pidfiles.
bt_stop_daemons() {
	local f p
	for f in "$T/home/.battery/battery.pid" "$T/home/.battery/calibrate.pid"; do
		[[ -f "$f" ]] || continue
		p="$(awk '{print $1}' "$f" 2>/dev/null)"
		if [[ "$p" =~ ^[0-9]+$ ]] && ps -o command= -p "$p" 2>/dev/null | grep -qF "$T/"; then
			builtin kill -TERM "$p" 2>/dev/null
		fi
	done
}

bt_teardown() {
	local root="${1:-$T}" f p pids=()
	[[ -n "$root" && -d "$root" ]] || return 0
	case "$root" in "$BT_BASE"/bt.*) ;; *) echo "refusing to tear down $root" >&2; return 1 ;; esac
	# Kill only pids this harness started and recorded. No pattern killing.
	for f in "$root/killable" "$root/home/.battery/battery.pid" "$root/home/.battery/calibrate.pid"; do
		[[ -f "$f" ]] || continue
		while read -r p; do
			p="${p%% *}"
			[[ "$p" =~ ^[0-9]+$ ]] && pids+=("$p")
		done <"$f"
	done
	for p in "${pids[@]}"; do
		((p > 1)) || continue
		kill -0 "$p" 2>/dev/null || continue
		if grep -qx "$p" "$root/killable" 2>/dev/null || ps -o command= -p "$p" 2>/dev/null | grep -qF "$root/"; then
			builtin kill -TERM "$p" 2>/dev/null
		fi
	done
	# Reap own children so the shell does not print "Terminated" job notices.
	for p in "${pids[@]}"; do wait "$p" 2>/dev/null; done
	command sleep 0.2
	for p in "${pids[@]}"; do
		((p > 1)) || continue
		kill -0 "$p" 2>/dev/null || continue
		if grep -qx "$p" "$root/killable" 2>/dev/null || ps -o command= -p "$p" 2>/dev/null | grep -qF "$root/"; then
			builtin kill -KILL "$p" 2>/dev/null
		fi
	done
	if [[ -z "${BT_KEEP:-}" ]]; then rm -rf "$root"; fi
}

bt_teardown_all() {
	local r
	for r in "${BT_ALL_ROOTS[@]}"; do bt_teardown "$r"; done
}

# ---- tiny assertion helpers ----
BT_PASS=0
BT_FAIL=0
BT_FAILED_NAMES=()
ok() {
	BT_PASS=$((BT_PASS + 1))
	echo "ok   - $1"
}
not_ok() {
	BT_FAIL=$((BT_FAIL + 1))
	BT_FAILED_NAMES+=("$1")
	echo "FAIL - $1"
	[[ -n "${2:-}" ]] && echo "$2" | sed 's/^/       | /'
	return 0
}
check() { # check <name> <command...>
	local name="$1"
	shift
	if "$@"; then ok "$name"; else not_ok "$name" "rc=$BT_RC out: $(echo "$BT_OUT" | tail -n 5)
err: $(echo "$BT_ERR" | tail -n 3)
smc writes: $(tail -n 5 "$T/smc_writes.log" 2>/dev/null)"; fi
}
