# pbus

An event dispatcher for Debian: scripts and commands register against an event
name, and are launched when that event is emitted. Listeners keep no process
waiting on anything — the daemon starts them. In practice, a cron triggered by
an event rather than by the clock.

Written in bash, with nothing beyond `bash`, `coreutils` and `util-linux`.

## Installation

```sh
make deb
sudo dpkg -i build/pbus_*_all.deb
```

The service is enabled and started on install, and at every boot afterwards.

Straight install, no package:

```sh
sudo make install
sudo systemctl enable --now pbus
```

## Two minutes in

```sh
# Declare an event; the key is shown once.
sudo pbus register-event release -d "A new version was released" --save

# Register a command.
sudo pbus register-listener release --id site /usr/local/bin/update_site

# Check without running anything, then emit.
pbus test release
sudo pbus emit release --payload "v1.2.3"

# Watch what happens.
pbus log -f
```

`pbus` with no argument opens an interactive session offering the same
commands; `help` lists them.

## Commands

| Command | Purpose |
| --- | --- |
| `list-events`, `show-event <name>` | inventory of events |
| `register-event <name> [-d …] [--no-key] [--save]` | declare an event, return its key |
| `unregister-event <name> [--purge-listeners]` | remove an event |
| `rotate-key <name> [--save]` | replace the key |
| `save-key <name>` | put a key in your keyring |
| `register-listener <event> [options] <command…>` | subscribe a command |
| `list-listeners`, `show-listener <id>` | inventory of listeners |
| `unregister-listener <id>`, `enable <id>`, `disable <id>` | manage listeners |
| `emit <event> [--payload …]` | emit an event, and report the daemon's verdict |
| `test <event>` | show what would run |
| `status`, `log [-f]`, `reload` | operations |

Useful `register-listener` options: `--id`, `--user`, `--workdir`,
`--timeout`, `--description`, `--disabled`.

A listener's event name accepts a glob pattern: `release.*` catches
`release.site` as well as `release.doc`.

## Did it actually fire?

`pbus emit` waits for the daemon's verdict before returning, so a refused key
is an error in your script and not merely a line in the log:

```sh
$ pbus emit release --payload v1.2.3
Event "release" accepted (id ca007bc5…), 1 listener(s) triggered.   # exit 0

$ pbus emit release --key pbk_wrong --payload v1.2.3
pbus: event "release" refused: the key is wrong (id fcf54053…)      # exit 3

$ pbus emit nosuchevent
pbus: event "nosuchevent" refused: the daemon does not know this event   # exit 4
```

| Exit | Meaning |
| --- | --- |
| 0 | accepted; the message says how many listeners were triggered |
| 1 | local error (no key found, unreadable file, no daemon on the bus) |
| 3 | the daemon refused the key |
| 4 | the daemon does not know this event |
| 5 | written to the bus, but no acknowledgement within `--ack-timeout` (5 s) |

The verdict is sent before the listeners are launched, so this costs a few
milliseconds and never waits for the work itself — a listener that sleeps for
two seconds still leaves `emit` returning in well under a tenth of a second.
`--no-wait` restores pure fire-and-forget.

## Configuration by file

Everything the CLI does is visible under `/etc/pbus`, and can be written by
hand. The files are re-read on every incoming event: no reload command is
needed.

```
/etc/pbus/pbus.conf                  log, trace level, concurrency
/etc/pbus/events.d/release.event     one file per event
/etc/pbus/listeners.d/site.listener  one file per listener
```

A listener looks like this:

```ini
id=site
event=release
command=/usr/local/bin/update_site
user=www-data
workdir=/srv/site
timeout=1800
enabled=1
description=Rebuild and publish the site
```

## What a triggered command receives

| Variable | Content |
| --- | --- |
| `PBUS_EVENT` | real name of the event (useful with glob patterns) |
| `PBUS_PAYLOAD` | payload, also fed to standard input |
| `PBUS_EVENT_ID` | id of the emission, repeated in the log |
| `PBUS_TS` | timestamp of the emission |
| `PBUS_LISTENER` | identifier of the listener |

Standard output and standard error go to `/var/log/pbus/pbus.log`, prefixed
with the listener's id.

## Keys and security

`register-event` draws a random 192-bit key and shows it once: on disk, only a
salted SHA-256 hash is kept, under `/var/lib/pbus/auth/`, readable by root
only. The emitter presents the key, the daemon hashes it and compares in
constant time. `rotate-key` invalidates the previous one immediately.

The bus is a named pipe in mode `0622`: any user may emit, but only the daemon
reads what passes through. The key therefore travels in the clear, in a
channel nobody else can read. To keep it out of `ps`, prefer the keyring
(`pbus save-key`), `--key-file` or `PBUS_KEY` over `--key`.

An event declared with `--no-key` accepts any local emission: keep it for
events without consequence.

Commands run as root unless the listener sets `user`, in which case the daemon
drops privileges with `setpriv`. A listener is therefore as powerful as a line
in root's crontab: write access to `/etc/pbus/listeners.d` must stay with
administrators.

## Why not D-Bus

D-Bus assumes a session or system bus and service activation, for no gain
here: the point is precisely to start processes that are listening to nothing.
A named pipe is enough, adds no dependency, and writes under 4096 bytes to it
are atomic — concurrent emissions are safe with no lock. Larger payloads go
through a spool in `/run/pbus`.

## Worked examples

`examples/prel-release.md` walks through "a release is published, the site
updates itself", including passing the key explicitly and running a listener
as a specific user.

## Licence

MIT — see [LICENSE](LICENSE). The package carries it twice over: as
`/usr/share/doc/pbus/copyright` in the machine-readable DEP-5 form Debian
expects, generated from `LICENSE` at build time so the two cannot drift, and
as a plain copy at `/usr/share/doc/pbus/LICENSE`.

## Development

```sh
tests/run-tests.sh   # 63 end-to-end tests, unprivileged, under /tmp
make deb             # builds the package with dpkg-deb
make version         # prints the version
```

The version lives in one place, the `VERSION` file at the root of the
repository, which is what `prel` reads. `make` substitutes it into
`lib/pbus/common.sh`, both manual pages and the Debian changelog as it
installs, so nothing else carries a hardcoded number. Run straight from a
source tree, `common.sh` finds its placeholder unsubstituted and reads
`VERSION` itself, so `pbus version` is right without a build.

The tests start a full daemon in a temporary directory: every path
(`PBUS_ETC`, `PBUS_VAR`, `PBUS_RUN`, `PBUS_LOG`, `PBUS_LIB`, `PBUS_KEYSTORE`)
can be overridden from the environment.
