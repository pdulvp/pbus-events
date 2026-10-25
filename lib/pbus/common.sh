#!/bin/bash
# pbus - shared library, sourced by both the CLI and the daemon.
# Nothing outside bash, coreutils and util-linux.

PBUS_VERSION="0.1.0"
PBUS_PROTO="PBUS2"

# Every path can be overridden from the environment, so a complete instance
# can run inside a temporary directory, unprivileged, for the test suite.
: "${PBUS_ETC:=/etc/pbus}"
: "${PBUS_VAR:=/var/lib/pbus}"
: "${PBUS_RUN:=/run/pbus}"
: "${PBUS_LOG:=/var/log/pbus/pbus.log}"

PBUS_CONF="$PBUS_ETC/pbus.conf"
PBUS_EVENTS_DIR="$PBUS_ETC/events.d"
PBUS_LISTENERS_DIR="$PBUS_ETC/listeners.d"
PBUS_AUTH_DIR="$PBUS_VAR/auth"
PBUS_FIFO="$PBUS_RUN/bus"
PBUS_SPOOL="$PBUS_RUN/spool"
PBUS_REPLY="$PBUS_RUN/reply"
PBUS_PIDFILE="$PBUS_RUN/pbusd.pid"

# Defaults, overridden by pbus.conf.
PBUS_LOG_LEVEL="info"
PBUS_MAX_JOBS="16"
PBUS_DEFAULT_TIMEOUT="900"

# Longest line we will write to the pipe. PIPE_BUF is 4096 bytes on Linux;
# below that, concurrent writes are atomic. Leave room for the header, and
# send larger payloads through the spool instead.
PBUS_MAX_LINE=3500

# ------------------------------------------------------------------ log ---

pbus_log_level_num() {
	case "$1" in
		debug) echo 10 ;;
		info)  echo 20 ;;
		warn)  echo 30 ;;
		error) echo 40 ;;
		*)     echo 20 ;;
	esac
}

# pbus_log <level> <message...>
pbus_log() {
	local level="$1"; shift
	local want cur
	want=$(pbus_log_level_num "$level")
	cur=$(pbus_log_level_num "$PBUS_LOG_LEVEL")
	(( want < cur )) && return 0
	local line
	printf -v line '%(%Y-%m-%dT%H:%M:%S%z)T %-5s %s' -1 "$level" "$*"
	if [[ -n ${PBUS_LOG_TO_STDERR:-} ]]; then
		printf '%s\n' "$line" >&2
		return 0
	fi
	if ! printf '%s\n' "$line" >>"$PBUS_LOG" 2>/dev/null; then
		printf '%s\n' "$line" >&2
	fi
}

pbus_die() {
	printf 'pbus: %s\n' "$*" >&2
	exit 1
}

pbus_warn() {
	printf 'pbus: %s\n' "$*" >&2
}

# -------------------------------------------------------- key=value files --

# pbus_kv_get <file> <key>: print the value, nothing if absent.
# Split happens on the first "="; a value may contain spaces and "=", but no
# newline.
pbus_kv_get() {
	local file="$1" key="$2" line k v
	[[ -r $file ]] || return 1
	while IFS= read -r line || [[ -n $line ]]; do
		[[ $line =~ ^[[:space:]]*(#|$) ]] && continue
		k=${line%%=*}
		v=${line#*=}
		k=${k//[[:space:]]/}
		[[ $k == "$key" ]] || continue
		printf '%s\n' "$v"
		return 0
	done <"$file"
	return 1
}

# pbus_kv_set <file> <key> <value>: replace the line, or append it.
pbus_kv_set() {
	local file="$1" key="$2" value="$3" tmp line k found=0
	tmp="$file.tmp.$$"
	: >"$tmp" || return 1
	if [[ -r $file ]]; then
		while IFS= read -r line || [[ -n $line ]]; do
			k=${line%%=*}
			k=${k//[[:space:]]/}
			if [[ $k == "$key" && ! $line =~ ^[[:space:]]*# ]]; then
				printf '%s=%s\n' "$key" "$value" >>"$tmp"
				found=1
			else
				printf '%s\n' "$line" >>"$tmp"
			fi
		done <"$file"
	fi
	(( found )) || printf '%s=%s\n' "$key" "$value" >>"$tmp"
	mv -f "$tmp" "$file"
}

# pbus_kv_load <file> <name of an associative array>
pbus_kv_load() {
	local file="$1"
	local -n _dest="$2"
	local line k v
	[[ -r $file ]] || return 1
	while IFS= read -r line || [[ -n $line ]]; do
		[[ $line =~ ^[[:space:]]*(#|$) ]] && continue
		[[ $line == *=* ]] || continue
		k=${line%%=*}
		v=${line#*=}
		k=${k//[[:space:]]/}
		[[ -n $k ]] || continue
		_dest["$k"]="$v"
	done <"$file"
	return 0
}

pbus_load_conf() {
	[[ -r $PBUS_CONF ]] || return 0
	local -A c=()
	pbus_kv_load "$PBUS_CONF" c
	[[ -n ${c[log_level]:-} ]]      && PBUS_LOG_LEVEL="${c[log_level]}"
	[[ -n ${c[log_file]:-} ]]       && PBUS_LOG="${c[log_file]}"
	[[ -n ${c[max_jobs]:-} ]]       && PBUS_MAX_JOBS="${c[max_jobs]}"
	[[ -n ${c[default_timeout]:-} ]] && PBUS_DEFAULT_TIMEOUT="${c[default_timeout]}"
	return 0
}

# ----------------------------------------------------------- validation ---

pbus_valid_name() {
	[[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$ ]]
}

pbus_valid_pattern() {
	[[ $1 =~ ^[A-Za-z0-9*?][A-Za-z0-9._:*?@-]{0,63}$ ]]
}

# -------------------------------------------------------------- secrets ---

pbus_random_hex() {
	local n="${1:-24}"
	od -An -tx1 -N"$n" /dev/urandom | tr -d ' \n'
}

pbus_gen_key() {
	printf 'pbk_%s\n' "$(pbus_random_hex 24)"
}

# pbus_hash <salt> <key>
pbus_hash() {
	printf '%s:%s' "$1" "$2" | sha256sum | cut -d' ' -f1
}

# Constant-time comparison of two hex strings.
pbus_equal_ct() {
	local a="$1" b="$2" i diff=0
	(( ${#a} != ${#b} )) && return 1
	for (( i = 0; i < ${#a}; i++ )); do
		[[ ${a:i:1} == "${b:i:1}" ]] || (( diff++ ))
	done
	(( diff == 0 ))
}

# printf "%-Ns" pads by bytes; ${#s} counts characters. Padding by character
# keeps the columns straight when a field carries non-ASCII text.
pbus_pad() {
	local s="$1" w="$2" n
	n=$(( w - ${#s} ))
	(( n < 0 )) && n=0
	printf '%s%*s' "$s" "$n" ""
}

# Quote one argument for the shell, favouring readability: leave a harmless
# argument alone, wrap anything else in single quotes.
pbus_shquote() {
	local s="$1" q="'"
	case "$s" in
		'') printf "''"; return ;;
		*[!A-Za-z0-9._:/@%+=-]*) ;;
		*) printf '%s' "$s"; return ;;
	esac
	s=${s//$q/$q\\$q$q}
	printf '%s%s%s' "$q" "$s" "$q"
}

# ---------------------------------------------------------------- paths ---

pbus_event_file()    { printf '%s/%s.event\n' "$PBUS_EVENTS_DIR" "$1"; }
pbus_auth_file()     { printf '%s/%s.auth\n' "$PBUS_AUTH_DIR" "$1"; }
pbus_listener_file() { printf '%s/%s.listener\n' "$PBUS_LISTENERS_DIR" "$1"; }

pbus_event_exists()  { [[ -f $(pbus_event_file "$1") ]]; }

pbus_list_event_names() {
	local f n
	shopt -s nullglob
	for f in "$PBUS_EVENTS_DIR"/*.event; do
		n=${f##*/}
		printf '%s\n' "${n%.event}"
	done
	shopt -u nullglob
}

pbus_list_listener_ids() {
	local f n
	shopt -s nullglob
	for f in "$PBUS_LISTENERS_DIR"/*.listener; do
		n=${f##*/}
		printf '%s\n' "${n%.listener}"
	done
	shopt -u nullglob
}

pbus_timestamp() {
	printf '%(%Y-%m-%dT%H:%M:%S%z)T\n' -1
}

pbus_daemon_pid() {
	local pid
	[[ -r $PBUS_PIDFILE ]] || return 1
	read -r pid <"$PBUS_PIDFILE" || return 1
	[[ $pid =~ ^[0-9]+$ ]] || return 1
	[[ -d /proc/$pid ]] || return 1
	printf '%s\n' "$pid"
}
