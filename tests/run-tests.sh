#!/bin/bash
# End-to-end tests for pbus, in a temporary prefix and without privileges.
# Usage: tests/run-tests.sh

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d /tmp/pbus-test.XXXXXX)
trap 'cleanup' EXIT

export PBUS_LIB="$ROOT/lib/pbus"
export PBUS_ETC="$WORK/etc"
export PBUS_VAR="$WORK/var"
export PBUS_RUN="$WORK/run"
export PBUS_LOG="$WORK/log/pbus.log"
export PBUS_KEYSTORE="$WORK/keys"
PBUS="$ROOT/bin/pbus"
PBUSD="$ROOT/sbin/pbusd"
DAEMON_PID=""

PASS=0
FAIL=0

cleanup() {
	[[ -n $DAEMON_PID ]] && kill "$DAEMON_PID" 2>/dev/null
	wait "$DAEMON_PID" 2>/dev/null
	[[ -n ${KEEP:-} ]] && { echo "work directory kept: $WORK"; return; }
	rm -rf "$WORK"
}

ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; (( PASS++ )); }
ko()   { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; (( FAIL++ )); }
check(){ if eval "$2"; then ok "$1"; else ko "$1"; fi; }

# Waits for a file to appear, at most N tenths of a second.
wait_file() {
	local f="$1" n="${2:-50}" i
	for (( i = 0; i < n; i++ )); do
		[[ -e $f ]] && return 0
		sleep 0.1
	done
	return 1
}

echo "pbus - end-to-end tests"
echo "directory: $WORK"
echo

mkdir -p "$WORK"/{etc,var,run,log,keys,out}
cat >"$WORK/etc/pbus.conf" <<EOT
log_level=debug
log_file=$WORK/log/pbus.log
max_jobs=4
default_timeout=30
EOT

# ------------------------------------------------------------- startup ---
"$PBUSD" --foreground &
DAEMON_PID=$!
wait_file "$PBUS_RUN/bus" 50 || { echo "the daemon did not create the pipe"; exit 1; }
check "the daemon creates the named pipe" '[[ -p "$PBUS_RUN/bus" ]]'
check "the pipe is writable by everyone" '[[ $(stat -c %a "$PBUS_RUN/bus") == 622 ]]'
check "the spool carries the sticky bit" '[[ $(stat -c %a "$PBUS_RUN/spool") == 1733 ]]'
check "status sees the daemon running" '[[ $("$PBUS" status) == *running* ]]'

# -------------------------------------------------------------- events ---
"$PBUS" register-event release -d "A new version was released" --save >"$WORK/out/reg" 2>&1
check "register-event succeeds" '[[ -f "$PBUS_ETC/events.d/release.event" ]]'
check "the key is shown once" 'grep -q "key: pbk_" "$WORK/out/reg"'
check "the key lands in the keyring" '[[ -s "$WORK/keys/release" ]]'
check "the keyring file is 0600" '[[ $(stat -c %a "$WORK/keys/release") == 600 ]]'
check "the auth file is 0600" '[[ $(stat -c %a "$PBUS_VAR/auth/release.auth") == 600 ]]'
check "the plaintext key is not kept" '! grep -qi "pbk_" "$PBUS_VAR/auth/release.auth" "$PBUS_ETC/events.d/release.event"'
check "a duplicate is refused" '! "$PBUS" register-event release >/dev/null 2>&1'
check "an invalid name is refused" '! "$PBUS" register-event "bad name" >/dev/null 2>&1'
check "list-events shows the event" '[[ $("$PBUS" list-events) == *release* ]]'

# ----------------------------------------------------------- listeners ---
"$PBUS" register-listener release --id site /bin/sh -c "echo \"\$PBUS_PAYLOAD\" > $WORK/out/site.txt" >/dev/null
check "register-listener succeeds" '[[ -f "$PBUS_ETC/listeners.d/site.listener" ]]'
check "list-listeners shows the listener" '[[ $("$PBUS" list-listeners) == *site* ]]'
check "test shows what would be triggered" '[[ $("$PBUS" test release) == *site* ]]'

# ------------------------------------------------------------ emission ---
"$PBUS" emit release --payload "v1.2.3" -q
check "the listener was triggered" 'wait_file "$WORK/out/site.txt" 50'
check "the payload reaches the command" '[[ $(cat "$WORK/out/site.txt" 2>/dev/null) == "v1.2.3" ]]'

# ----------------------------------------------------------- wrong key ---
rm -f "$WORK/out/site.txt"
"$PBUS" emit release --key "pbk_wrong" -q >"$WORK/out/badkey" 2>&1
BADKEY_RC=$?
sleep 0.5
check "a wrong key is refused" '! [[ -e "$WORK/out/site.txt" ]]'
check "the refusal is logged" 'grep -q "authentication refused" "$PBUS_LOG"'
check "emit exits 3 on a wrong key" '(( BADKEY_RC == 3 ))'
check "emit says so on stderr" 'grep -q "the key is wrong" "$WORK/out/badkey"'

# --------------------------------------------------------- missing key ---
check "emitting without a key fails" '! env -u PBUS_KEY PBUS_KEYSTORE=/nonexistent "$PBUS" emit release -q >/dev/null 2>&1'

# ------------------------------------------------------- unknown event ---
"$PBUS" emit unknown --key x -q >"$WORK/out/unknown" 2>&1
UNKNOWN_RC=$?
sleep 0.3
check "an unknown event is rejected" 'grep -q "unknown event received" "$PBUS_LOG"'
check "emit exits 4 on an unknown event" '(( UNKNOWN_RC == 4 ))'

# ------------------------------------------------------ acknowledgement ---
"$PBUS" emit release --payload ack >"$WORK/out/ack" 2>&1
ACK_RC=$?
check "emit exits 0 when accepted" '(( ACK_RC == 0 ))'
check "emit reports the listener count" 'grep -q "1 listener(s) triggered" "$WORK/out/ack"'
"$PBUS" register-event lonely --no-key >/dev/null
"$PBUS" emit lonely >"$WORK/out/lonely" 2>&1
check "emit says when nothing matched" 'grep -q "no listener matched" "$WORK/out/lonely"'
"$PBUS" emit release --key "pbk_wrong" --no-wait >/dev/null 2>&1
check "--no-wait keeps fire-and-forget" '(( $? == 0 ))'
check "emit does not wait for a slow listener" '
	"$PBUS" register-listener release --id slow /bin/sh -c "sleep 5" >/dev/null
	s=$SECONDS; "$PBUS" emit release -q >/dev/null 2>&1; (( SECONDS - s < 3 ))'
"$PBUS" unregister-listener slow >/dev/null

# -------------------------------------------------------- glob pattern ---
"$PBUS" register-event release.site --no-key >/dev/null
"$PBUS" register-listener "release.*" --id glob /bin/sh -c "echo \$PBUS_EVENT > $WORK/out/glob.txt" >/dev/null
"$PBUS" emit release.site -q
check "a glob listener is triggered" 'wait_file "$WORK/out/glob.txt" 50'
check "PBUS_EVENT carries the real name" '[[ $(cat "$WORK/out/glob.txt" 2>/dev/null) == "release.site" ]]'
check "a --no-key event needs no key" 'grep -q "event release.site received" "$PBUS_LOG"'

# ---------------------------------------------------- disabled listener ---
rm -f "$WORK/out/glob.txt"
"$PBUS" disable glob >/dev/null
"$PBUS" emit release.site -q
sleep 0.5
check "a disabled listener does not run" '! [[ -e "$WORK/out/glob.txt" ]]'
"$PBUS" enable glob >/dev/null
check "enable puts the listener back in service" '[[ $(grep -c "^enabled=1" "$PBUS_ETC/listeners.d/glob.listener") == 1 ]]'

# -------------------------------------------------------- large payload ---
"$PBUS" register-listener release --id big /bin/sh -c "wc -c > $WORK/out/big.txt" >/dev/null
head -c 20000 /dev/zero | tr '\0' 'a' >"$WORK/out/big-payload"
"$PBUS" emit release --payload-file "$WORK/out/big-payload" -q
check "a 20 KiB payload goes through the spool" 'wait_file "$WORK/out/big.txt" 80'
check "the payload arrives whole on stdin" '[[ $(tr -d " " < "$WORK/out/big.txt" 2>/dev/null) == 20000 ]]'
check "the spool is emptied afterwards" '[[ -z $(ls -A "$PBUS_RUN/spool") ]]'

# ------------------------------------------------ hostile nonce (traversal)
echo "target" >"$WORK/out/target.txt"
printf 'PBUS2\t%s\t%s\t%s\t%s\t0\t@spool\n' "release" "$(cat "$WORK/keys/release")" \
	"../../out/target.txt" "$(date -Is)" >"$PBUS_RUN/bus"
sleep 0.5
check "a non-hexadecimal nonce is rejected" 'grep -q "invalid emission id" "$PBUS_LOG"'
check "the file aimed at by the traversal is intact" '[[ -e "$WORK/out/target.txt" ]]'

# an obsolete protocol line must be ignored, not misparsed
printf 'PBUS1\trelease\tkey\tdeadbeef\tts\t-\n' >"$PBUS_RUN/bus"
sleep 0.3
check "an unknown protocol version is ignored" 'grep -q "unknown protocol" "$PBUS_LOG"'

# ------------------------------------------------------- manual editing ---
sed -i "s|^command=.*|command=/bin/sh -c \"echo manual > $WORK/out/manual.txt\"|" "$PBUS_ETC/listeners.d/site.listener"
"$PBUS" emit release -q
check "editing the file takes effect with no reload" 'wait_file "$WORK/out/manual.txt" 50'

# --------------------------------------------------------- key rotation ---
OLD=$(cat "$WORK/keys/release")
"$PBUS" rotate-key release --save >/dev/null
NEW=$(cat "$WORK/keys/release")
check "rotate-key changes the key" '[[ "$OLD" != "$NEW" ]]'
rm -f "$WORK/out/manual.txt"
"$PBUS" emit release --key "$OLD" -q >/dev/null 2>&1
sleep 0.5
check "the old key no longer works" '! [[ -e "$WORK/out/manual.txt" ]]'
"$PBUS" emit release -q
check "the new key works" 'wait_file "$WORK/out/manual.txt" 50'

# ------------------------------------------------------------- removal ---
"$PBUS" unregister-listener big >/dev/null
check "unregister-listener removes the file" '! [[ -e "$PBUS_ETC/listeners.d/big.listener" ]]'
"$PBUS" unregister-event release --purge-listeners >/dev/null
check "unregister-event removes the event" '! [[ -e "$PBUS_ETC/events.d/release.event" ]]'
check "unregister-event removes the secret" '! [[ -e "$PBUS_VAR/auth/release.auth" ]]'
check "--purge-listeners removes the listeners" '! [[ -e "$PBUS_ETC/listeners.d/site.listener" ]]'

# ------------------------------------------------------------ shutdown ---
kill "$DAEMON_PID"; wait "$DAEMON_PID" 2>/dev/null; DAEMON_PID=""
check "the daemon stops cleanly" 'grep -q "pbusd stopped" "$PBUS_LOG"'
check "the pidfile is removed" '! [[ -e "$PBUS_RUN/pbusd.pid" ]]'
check "emitting with no daemon fails fast" '! timeout 10 "$PBUS" emit release -q >/dev/null 2>&1'
check "no acknowledgement file was left behind" '[[ -z $(ls -A "$PBUS_RUN/reply" 2>/dev/null) ]]'

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
