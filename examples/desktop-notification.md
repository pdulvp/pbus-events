# Example: a desktop popup when an event fires

```sh
sudo pbus register-event release.published -d "A release was published" --save
sudo pbus register-listener release.published --id popup \
     'pbus-notify -u alice "Release $PBUS_PAYLOAD published" "update_site started"'
sudo pbus emit release.published --payload v1.2.3
```

Single quotes matter: `$PBUS_PAYLOAD` must be expanded when the event fires,
not when the listener is registered. Because it is a single argument, pbus
stores it verbatim as a shell line.

## Why a plain notify-send does not work

A notification is not a screen primitive. It is a D-Bus message to a daemon
running inside a user's graphical session. `pbusd` runs as root, outside any
session, and hands listeners a fixed environment — `PATH`, `HOME`, `USER`,
`LOGNAME`, `SHELL`, `PBUS_*` and nothing else. A listener that calls
`notify-send` or `gdbus` directly gets:

```
Error connecting: Cannot autolaunch D-Bus without X11 $DISPLAY
```

Two things are missing, and `pbus-notify` supplies both.

**The address of the bus.** D-Bus falls back to `$XDG_RUNTIME_DIR/bus` when
`DBUS_SESSION_BUS_ADDRESS` is unset, so pointing `XDG_RUNTIME_DIR` at
`/run/user/<uid>` is enough; the helper sets both anyway.

**The right credentials.** The socket is world-writable, but dbus-daemon
authenticates its peer by credentials and refuses a uid that does not own the
bus. Root therefore cannot talk to alice's bus as root: it has to become
alice first. `pbus-notify` does that with `setpriv` when it runs as root for
another user, which is why the listener above works without a `user=` field.

## Choosing who gets the popup

Root has no "current desktop", so somebody has to say which user. Three ways,
in order of preference:

```sh
# 1. name the user in the command
'pbus-notify -u alice "Build finished"'

# 2. let the listener run as that user; pbusd sets USER, which is the default
sudo pbus register-listener build.done --id popup -u alice \
     'pbus-notify "Build finished"'

# 3. notify several people
'for u in alice bob; do pbus-notify -u "$u" "Build finished"; done'
```

## Options

```
pbus-notify [-u USER] [-i ICON] [-t MS] [-U low|normal|critical] <summary> [body]
```

Exit status says what went wrong, which matters because the log is the only
place a listener can complain: 0 sent, 1 unknown user, 3 that user has no
session bus (nobody logged in), 4 no notification tool installed, 5 only root
can notify another user.

A machine with nobody logged in is the normal case for a server, and the
listener will record exit 3 in `/var/log/pbus/pbus.log` rather than failing
silently:

```
warn  [popup] pbus-notify: no session bus at /run/user/1001/bus; is alice logged in to a desktop?
warn  [popup] finished in 0s (status 3)
```

## What it sends through

`notify-send` when installed (`apt install libnotify-bin`), otherwise `gdbus`,
which comes with `libglib2.0-bin` and is present on any desktop. Neither is a
hard dependency of pbus: a headless machine running pbus as an event cron has
no use for them, and `pbus-notify` says which to install when it finds
neither.
