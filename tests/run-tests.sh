#!/bin/bash
# End-to-end tests for pbus, in a temporary prefix and without privileges.
# Usage: tests/run-tests.sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 pdulvp <pdulvp@laposte.net>

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
SELF=$(id -un)

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
max_payload=1048576
EOT

# ------------------------------------------------------------- version ---
VERSION_FILE=$(cat "$ROOT/VERSION")
check "VERSION exists and is not empty" '[[ -n $VERSION_FILE ]]'
check "pbus reports the version from VERSION" '[[ $("$PBUS" version) == "pbus $VERSION_FILE" ]]'
check "pbusd reports the same version" '[[ $("$PBUSD" --version) == "pbusd $VERSION_FILE" ]]'
check "no placeholder leaks into the output" '[[ $("$PBUS" version) != *@VERSION@* ]]'

# The source tree reads VERSION through the unsubstituted placeholder, while
# an installed tree reads what make wrote into it. Only staging a real install
# exercises the second path, where a careless substitution once turned the
# fallback on and reported "dev".
if command -v make >/dev/null; then
	STAGE="$WORK/stage"
	make -C "$ROOT" install DESTDIR="$STAGE" >/dev/null 2>&1
	check "an installed tree reports the same version" '
		[[ $(PBUS_LIB="$STAGE/usr/lib/pbus" "$STAGE/usr/bin/pbus" version) == "pbus $VERSION_FILE" ]]'
	check "the installed man page carries the version" '
		zcat "$STAGE/usr/share/man/man1/pbus.1.gz" | head -1 | grep -q "pbus $VERSION_FILE"'
	check "the installed tree ships pbus-notify" '[[ -x "$STAGE/usr/bin/pbus-notify" ]]'
	check "the installed tree ships its man page" '[[ -f "$STAGE/usr/share/man/man1/pbus-notify.1.gz" ]]'
	check "the installed tree ships the MIT licence" '
		grep -q "MIT License" "$STAGE/usr/share/doc/pbus/LICENSE"'
	check "the Debian copyright file is DEP-5 with the MIT text" '
		grep -q "^License: MIT$" "$STAGE/usr/share/doc/pbus/copyright" &&
		grep -q "^ Permission is hereby granted" "$STAGE/usr/share/doc/pbus/copyright" &&
		grep -q "^ \.$" "$STAGE/usr/share/doc/pbus/copyright"'
	# The licence text is the last thing in the copyright file, so its tail
	# must be LICENSE itself, indented. This checks the DEP-5 transformation,
	# not drift: the copyright file is generated from LICENSE at install
	# time, so there is no second copy that could drift from it.
	check "copyright is LICENSE indented for DEP-5" '
		diff <(sed -e "s/^\$/./" -e "s/^/ /" "$ROOT/LICENSE") \
		     <(tail -n "$(wc -l < "$ROOT/LICENSE")" "$STAGE/usr/share/doc/pbus/copyright") >/dev/null'
	check "the installed changelog carries the version" '
		zcat "$STAGE/usr/share/doc/pbus/changelog.Debian.gz" | head -1 | grep -q "pbus ($VERSION_FILE)"'
fi

# --------------------------------------------------------- pbus-notify ---
NOTIFY="$ROOT/bin/pbus-notify"
check "pbus-notify is executable" '[[ -x $NOTIFY ]]'
check "pbus-notify --help exits 0" '"$NOTIFY" --help >/dev/null'
check "pbus-notify rejects no argument" '! "$NOTIFY" >/dev/null 2>&1'
check "pbus-notify exits 1 on an unknown user" '
	"$NOTIFY" -u nosuchuser x >/dev/null 2>&1; (( $? == 1 ))'
check "pbus-notify exits 5 for another user when not root" '
	if (( EUID == 0 )); then true; else
		"$NOTIFY" -u daemon x >/dev/null 2>&1; (( $? == 5 )); fi'
check "pbus-notify rejects a bad urgency" '
	"$NOTIFY" -U shouting x >/dev/null 2>&1; (( $? == 2 ))'
# Sending for real would pop a window on whoever runs the suite, so it is
# opt-in: PBUS_TEST_NOTIFY=1 tests/run-tests.sh
if [[ -n ${PBUS_TEST_NOTIFY:-} && -S /run/user/$(id -u)/bus ]]; then
	check "pbus-notify reaches the session bus" '"$NOTIFY" "pbus test suite" "this popup is expected"'
fi

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
"$PBUS" register-listener release --id site -u "$SELF" /bin/sh -c "echo \"\$PBUS_PAYLOAD\" > $WORK/out/site.txt" >/dev/null
check "register-listener succeeds" '[[ -f "$PBUS_ETC/listeners.d/site.listener" ]]'
check "list-listeners shows the listener" '[[ $("$PBUS" list-listeners) == *site* ]]'
check "test shows what would be triggered" '[[ $("$PBUS" test release) == *site* ]]'

# ------------------------------------------------- identity of a listener ---
check "register-listener without -u is refused" '
	! "$PBUS" register-listener release --id nouser /bin/true >/dev/null 2>&1'
check "register-listener with -u root is accepted" '
	"$PBUS" register-listener release --id asroot -u root /bin/true >/dev/null 2>&1'
"$PBUS" unregister-listener asroot >/dev/null 2>&1

"$PBUS" register-listener release --id whoami -u "$SELF" /bin/sh -c "id -un > $WORK/out/whoami.txt; echo \$USER >> $WORK/out/whoami.txt" >/dev/null
"$PBUS" emit release -q
wait_file "$WORK/out/whoami.txt" 50
check "a listener runs as the user it names" '
	[[ $(head -1 "$WORK/out/whoami.txt") == "$SELF" ]]'
check "USER matches who the command actually runs as" '
	[[ $(sed -n 2p "$WORK/out/whoami.txt") == "$SELF" ]]'
check "naming our own account does not log an ignored user=" '
	! grep -q "ignoring user=$SELF" "$PBUS_LOG"'
"$PBUS" unregister-listener whoami >/dev/null

# A file written by hand, as the documentation says it may be: no user=, so
# the daemon must refuse it and still fire the listeners that are complete.
cat >"$PBUS_ETC/listeners.d/legacy.listener" <<EOF
id=legacy
event=release
command=/bin/sh -c "touch $WORK/out/legacy.txt"
workdir=/
timeout=30
enabled=1
EOF
rm -f "$WORK/out/site.txt" "$WORK/out/legacy.txt"
"$PBUS" emit release --payload "sibling" -q
check "a listener with no user= is refused at dispatch" '
	sleep 1; [[ ! -e "$WORK/out/legacy.txt" ]]'
check "the refusal is logged" 'grep -q "\[legacy\] no user= set" "$PBUS_LOG"'
check "a sibling listener on the same event still fires" '
	wait_file "$WORK/out/site.txt" 50'
check "test warns that such a listener will not run" '
	[[ $("$PBUS" test release) == *"will NOT run"* ]]'
check "list-listeners shows (unset) rather than root" '
	[[ $("$PBUS" list-listeners) == *"(unset)"* ]]'
rm -f "$PBUS_ETC/listeners.d/legacy.listener"

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
	"$PBUS" register-listener release --id slow -u "$SELF" /bin/sh -c "sleep 5" >/dev/null
	s=$SECONDS; "$PBUS" emit release -q >/dev/null 2>&1; (( SECONDS - s < 3 ))'
"$PBUS" unregister-listener slow >/dev/null

# -------------------------------------------------------- glob pattern ---
"$PBUS" register-event release.site --no-key >/dev/null
"$PBUS" register-listener "release.*" --id glob -u "$SELF" /bin/sh -c "echo \$PBUS_EVENT > $WORK/out/glob.txt" >/dev/null
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
"$PBUS" register-listener release --id big -u "$SELF" /bin/sh -c "wc -c > $WORK/out/big.txt" >/dev/null
head -c 20000 /dev/zero | tr '\0' 'a' >"$WORK/out/big-payload"
"$PBUS" emit release --payload-file "$WORK/out/big-payload" -q
check "a 20 KiB payload goes through the spool" 'wait_file "$WORK/out/big.txt" 80'
check "the payload arrives whole on stdin" '[[ $(tr -d " " < "$WORK/out/big.txt" 2>/dev/null) == 20000 ]]'
check "the spool is emptied afterwards" '[[ -z $(ls -A "$PBUS_RUN/spool") ]]'
check "the staging directory is emptied too" '[[ -z $(ls -A "$PBUS_RUN/stage") ]]'
check "the staging directory is root-only" '[[ $(stat -c %a "$PBUS_RUN/stage") == 700 ]]'

# Over MAX_ARG_STRLEN: setting PBUS_PAYLOAD would make execve fail with E2BIG
# and the command would never run, so it is left out and stdin carries it.
"$PBUS" register-listener release --id huge -u "$SELF" \
	/bin/sh -c "wc -c > $WORK/out/huge.txt; echo \"[\${PBUS_PAYLOAD-unset}]\" > $WORK/out/huge-env.txt; echo \$PBUS_PAYLOAD_SIZE > $WORK/out/huge-size.txt" >/dev/null
"$PBUS" disable big >/dev/null
head -c 140000 /dev/zero | tr '\0' 'a' >"$WORK/out/huge-payload"
"$PBUS" emit release --payload-file "$WORK/out/huge-payload" -q
check "a 140 KB payload still reaches the command" 'wait_file "$WORK/out/huge.txt" 100'
check "it arrives whole on standard input" '
	[[ $(tr -d " " < "$WORK/out/huge.txt" 2>/dev/null) == 140000 ]]'
check "PBUS_PAYLOAD is left out of the environment" '
	[[ $(cat "$WORK/out/huge-env.txt" 2>/dev/null) == "[unset]" ]]'
check "PBUS_PAYLOAD_SIZE still reports the real size" '
	[[ $(cat "$WORK/out/huge-size.txt" 2>/dev/null) == 140000 ]]'
check "the omission is logged" 'grep -q "PBUS_PAYLOAD omitted" "$PBUS_LOG"'
"$PBUS" unregister-listener huge >/dev/null
"$PBUS" enable big >/dev/null

# ------------------------------------------- a spool file that is not one ---
# The spool is world-writable by design, so its files cannot be trusted. Both
# of these are planted the way their emitter could plant them, then announced
# on the bus as if they were an ordinary payload.
spool_emit() {
	printf 'PBUS2\t%s\t%s\t%s\t%s\t0\t@spool\n' "release" \
		"$(cat "$WORK/keys/release")" "$1" "$(date +%s)" >"$PBUS_RUN/bus"
	sleep 0.6
}
echo "a secret the daemon should not read" >"$WORK/out/secret.txt"
rm -f "$WORK/out/big.txt"
ln -s "$WORK/out/secret.txt" "$PBUS_RUN/spool/aaaaaaaaaaaaaaaa"
spool_emit aaaaaaaaaaaaaaaa
check "a symlink left in the spool is refused" '
	grep -q "is a symbolic link, refused" "$PBUS_LOG"'
check "the file it pointed at was not delivered" '
	[[ ! -s "$WORK/out/big.txt" ]] || ! grep -q "should not read" "$WORK/out/big.txt"'
check "the refused link is cleaned up" '
	[[ ! -e "$PBUS_RUN/spool/aaaaaaaaaaaaaaaa" && ! -e "$PBUS_RUN/stage/aaaaaaaaaaaaaaaa" ]]'

rm -f "$WORK/out/big.txt"
ln "$WORK/out/secret.txt" "$PBUS_RUN/spool/bbbbbbbbbbbbbbbb"
spool_emit bbbbbbbbbbbbbbbb
check "a hard link left in the spool is refused" '
	grep -q "is a hard link to another file, refused" "$PBUS_LOG"'
check "the hard link is cleaned up" '
	[[ ! -e "$PBUS_RUN/stage/bbbbbbbbbbbbbbbb" ]]'

# ---------------------------------------------------- the payload cap ---
sed -i "s|^max_payload=.*|max_payload=4096|" "$PBUS_ETC/pbus.conf"
"$PBUS" reload >/dev/null 2>&1 || kill -HUP "$DAEMON_PID"
sleep 0.4
rm -f "$WORK/out/big.txt"
head -c 20000 /dev/zero | tr '\0' 'b' >"$WORK/out/capped-payload"
"$PBUS" emit release --payload-file "$WORK/out/capped-payload" -q
check "a payload beyond max_payload is trimmed" '
	wait_file "$WORK/out/big.txt" 80 && [[ $(tr -d " " < "$WORK/out/big.txt") == 4096 ]]'
check "the trim is logged" 'grep -q "payload truncated to 4096 bytes" "$PBUS_LOG"'
sed -i "s|^max_payload=.*|max_payload=1048576|" "$PBUS_ETC/pbus.conf"
"$PBUS" reload >/dev/null 2>&1 || kill -HUP "$DAEMON_PID"
sleep 0.4

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

# ------------------------------------------------------ payload pattern ---
"$PBUS" register-event shaped -d "payload must look like a version" \
	--payload-pattern '^v[0-9]+(\.[0-9]+)*$' --save >/dev/null
check "register-event stores the pattern" '
	grep -q "payload_pattern=\^v" "$PBUS_ETC/events.d/shaped.event"'
check "an uncompilable pattern is refused at registration" '
	! "$PBUS" register-event broken --payload-pattern "^(unclosed" >/dev/null 2>&1'
check "test prints the pattern" '[[ $("$PBUS" test shaped) == *"must match"* ]]'

"$PBUS" register-listener shaped --id shaped -u "$SELF" \
	/bin/sh -c "cat > $WORK/out/shaped.txt" >/dev/null
"$PBUS" emit shaped --payload "v1.2.3" -q
check "a payload matching the pattern reaches the listener" '
	wait_file "$WORK/out/shaped.txt" 50 && [[ $(cat "$WORK/out/shaped.txt") == "v1.2.3" ]]'

rm -f "$WORK/out/shaped.txt"
"$PBUS" emit shaped --payload '--use-compress-program=./p.sh' -q >"$WORK/out/shapedbad" 2>&1
SHAPED_RC=$?
check "emit exits 6 on a payload the pattern refuses" '(( SHAPED_RC == 6 ))'
check "emit says the payload was the problem" '
	grep -q "does not match the pattern" "$WORK/out/shapedbad"'
check "the refused payload never reaches the listener" '
	sleep 0.5; [[ ! -e "$WORK/out/shaped.txt" ]]'
check "the refusal is logged without the payload" '
	grep -q "payload refused for event shaped" "$PBUS_LOG" &&
	! grep -q "use-compress-program" "$PBUS_LOG"'

# A pattern the shell cannot compile must refuse, not wave the payload past.
sed -i "s|^payload_pattern=.*|payload_pattern=^(unclosed|" "$PBUS_ETC/events.d/shaped.event"
"$PBUS" emit shaped --payload "v1.2.3" -q >/dev/null 2>&1
BROKEN_RC=$?
check "an unusable pattern denies the emission" '(( BROKEN_RC != 0 ))'
check "the configuration fault is logged" '
	grep -q "payload_pattern is not a usable expression" "$PBUS_LOG"'
check "no listener ran for the denied emission" '
	sleep 0.5; [[ ! -e "$WORK/out/shaped.txt" ]]'

# ^$ is how an event says it carries no payload at all.
sed -i "s|^payload_pattern=.*|payload_pattern=^$|" "$PBUS_ETC/events.d/shaped.event"
"$PBUS" emit shaped -q >/dev/null 2>&1
EMPTY_RC=$?
check "an empty payload passes ^\$" '(( EMPTY_RC == 0 ))'
"$PBUS" emit shaped --payload "anything" -q >/dev/null 2>&1
ANY_RC=$?
check "^\$ refuses any payload" '(( ANY_RC == 6 ))'
"$PBUS" unregister-event shaped --purge-listeners >/dev/null

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
