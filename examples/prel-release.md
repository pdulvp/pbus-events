# Example: publish a site after a release

The case in view: `prel` publishes a release, pbus triggers `update_site` in
the background, and `prel` never waits for the deployment to finish.

## Once, as administrator

```sh
# 1. Declare the event and keep the key in root's keyring.
sudo pbus register-event release.published \
     -d "A release has just been published" --save

# 2. Subscribe the site update command.
sudo pbus register-listener release.published --id update-site \
     -u www-data -w /srv/site -t 1800 \
     -d "Rebuild and publish the site" \
     /usr/local/bin/update_site

# 2. or for complex bash commands
sudo pbus register-listener release.published --id update-site \
     -u www-data -w /srv/site -t 1800 \
     -d "Rebuild and publish the site" \
     'export PATH=/home/www-data/.nvm/versions/node/xx.xx/bin:$PATH; npm run-script publish'
```

`pbus test release.published` shows what would fire, without running anything.


## Each time, from `prel`

```sh
prel release ... && pbus emit release.published --payload "$TAG" --quiet
```

`pbus emit` returns as soon as the daemon has accepted the event: the rebuild
carries on in its own detached process, and `&&` chains behave sensibly
because a refused key makes `emit` exit non-zero.

## In the triggered script

```sh
#!/bin/sh
# /usr/local/bin/update_site
set -e
event="$PBUS_EVENT"       # release.published
version="$PBUS_PAYLOAD"   # v1.2.3, also available on standard input
git -C /srv/site pull --ff-only
make -C /srv/site publish -- VERSION="$version"
```

Everything the script writes to standard output or standard error is picked up
in `/var/log/pbus/pbus.log`, prefixed with the listener's id.

### The payload is whatever the emitter typed

`$version` here is not a version number: it is a string chosen by whoever
holds the key, and this script runs as `www-data`. Quoting it keeps it one
argument, which is necessary but not sufficient — a payload beginning with a
dash is still read as an option, and for many commands one option is enough
to run a program of the emitter's choosing. Hence the `--` above, which ends
the option list and makes everything after it an operand.

Where the shape is predictable, say so once on the event and the daemon
refuses the rest before this script is even started:

```sh
sudo pbus register-event release.published \
     --payload-pattern '^v[0-9]+(\.[0-9]+)*$'
```

`pbus test release.published` prints the pattern alongside the listeners it
would trigger.

---

# Passing the key

The key exists so that not just anybody on the machine can fire your
deployment. There are four ways to hand it to `pbus emit`, in this order of
precedence.

## 1. The keyring (recommended)

`register-event --save` already wrote the key to `/etc/pbus/keys/<event>`
(mode 0600, root only). Nothing more to do:

```sh
sudo pbus emit release.published --payload v1.2.3
```

For another account, hand the key over once — it is prompted for without echo,
so it never reaches the shell history:

```sh
sudo -u deploy pbus save-key release.published
Key for "release.published": ****
Key saved to /home/deploy/.config/pbus/keys/release.published

sudo -u deploy pbus emit release.published --payload v1.2.3
```

## 2. A key file

Useful in CI, where the secret arrives as a file:

```sh
install -m 0600 /dev/null /etc/prel/release.key
printf '%s\n' "$RELEASE_KEY" > /etc/prel/release.key

pbus emit release.published -K /etc/prel/release.key --payload v1.2.3
```

## 3. The environment

```sh
PBUS_KEY="pbk_1f3c…" pbus emit release.published --payload v1.2.3
```

Every form above reports what the daemon did with the event:

```sh
$ pbus emit release.published --payload v1.2.3
Event "release.published" accepted (id ca007bc5…), 1 listener(s) triggered.

$ pbus emit release.published --key pbk_wrong --payload v1.2.3
pbus: event "release.published" refused: the key is wrong (id fcf54053…)
$ echo $?
3
```

## 4. On the command line

```sh
pbus emit release.published --key "pbk_1f3c…" --payload v1.2.3
```

This one is visible to every user on the machine through `ps`. Use it for a
quick test, not in a script.

## Lost the key?

It is not recoverable — only a salted hash is stored. Issue a new one:

```sh
sudo pbus rotate-key release.published --save
```

The previous key stops working immediately.

---

# Running a listener as a specific user

`pbusd` runs as root, so a listener runs as root by default. Add `-u` and it
does not:

```sh
sudo pbus register-listener release.published --id update-site \
     -u www-data -w /srv/site /usr/local/bin/update_site
```

which is just this line in `/etc/pbus/listeners.d/update-site.listener`:

```ini
user=www-data
```

## How the privilege drop happens

For each triggered command, the daemon builds this chain:

```
pbusd (root)
  └── setsid                                  new session, detached
       └── setpriv --reuid 33 --regid 33 --init-groups
            └── env HOME=/var/www USER=www-data PATH=… PBUS_*=…
                 └── timeout -k 5 1800
                      └── /bin/bash -c "<command>"
```

`setpriv` is a util-linux tool that drops credentials and then execs: there is
no privileged process left above the command, and no SUID step on the way
back up. The hop is skipped altogether when the named account is already the
one `pbusd` runs as — `user=root` under the service unit, or your own account
in a test instance — so the chain above loses its `setpriv` line and nothing
else changes. `--init-groups` loads the user's supplementary groups from
`/etc/group` — `--regid` actually requires one of the group options, so the
groups are never inherited from root by accident. The uid and gid come from
`getent passwd`, as do `HOME` and `SHELL`; a user unknown to the system is
refused at registration time, and again at dispatch time if it disappeared
since.

Check it from the listener itself:

```sh
sudo pbus register-listener test.whoami --id whoami -u www-data \
     /bin/sh -c 'id'
sudo pbus emit test.whoami
sudo pbus log -n 3
```

```
… info  [whoami] starting (event=test.whoami id=5b1d…)
… info  [whoami] uid=33(www-data) gid=33(www-data) groups=33(www-data)
… info  [whoami] finished in 0s (status 0)
```

## Things worth knowing

- **There is no default user.** `register-listener` refuses without `-u`, and
  a listener whose file has no `user=` is refused at dispatch with
  `no user= set: refusing to run`. Say `-u root` when root is what you want;
  that is why write access to `/etc/pbus/listeners.d` has to stay with
  administrators.
- **Give the target user a reachable working directory.** `-w /srv/site` must
  be readable by `www-data`; the daemon refuses to start the job otherwise and
  says so in the log.
- **`$PATH` is fixed**, not inherited from root's environment:
  `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`.
- **If `pbusd` is not running as root** — which happens when you run an
  instance of your own for testing — it cannot drop privileges, so it ignores
  a `user=` naming anyone else, runs the command as itself, and logs
  `ignoring user=www-data: pbusd is not running as root`. A `user=` naming the
  account it already runs as is honoured in silence.

---

# From a GitHub webhook

pbus does not listen on the network, deliberately. If a webhook has to trigger
an event, let whatever already receives that webhook call `pbus emit` — a
`ProxyPass` to a small CGI script, an action runner, or the machine that runs
`prel`. The bus stays local, which avoids exposing one more port.
