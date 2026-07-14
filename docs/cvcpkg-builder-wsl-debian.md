# cvcpkg Builder on WSL2 (Debian)

Standalone provisioning guide for running a cvcpkg remote builder inside a
Debian WSL2 instance on a Windows host.

This produces a `linux/x86_64` builder (optionally with a `wasm` cross
target) that lives on a Windows box. It does **not** produce native
`windows/x86_64` artifacts — for those, use the native Windows path
(`sandipaws` / `phm-win11`) documented in
[cvcpkg-remote-builders.md](cvcpkg-remote-builders.md).

The builder is the same three moving parts as every other Linux builder:

1. A CMake + Ninja + C/C++ toolchain.
2. `cvcpkg` on `PATH`, running `cvcpkg builder run …`.
3. Kept alive by **systemd** and reachable over **SSH** so `deploy-prod.yml`
   can `git pull` + `pip install` + restart it.

WSL2 can do all three, but two things need extra plumbing that a normal VM
does not: **headless start across Windows reboots** and **LAN-reachable
SSH** (WSL2 sits behind a NAT with its own IP).

---

## 1. Install the distro

```powershell
wsl --install -d Debian
wsl --set-version Debian 2      # ensure WSL2 (real kernel), not WSL1
```

## 2. Enable systemd + configure the mount

Inside the Debian shell, create `/etc/wsl.conf`:

```ini
[boot]
systemd=true

[automount]
enabled=true
options="metadata,uid=1000,gid=1000,umask=022"   # Linux perms on Windows mounts

[network]
hostname=cvcpkg-wsl-01
```

Then from PowerShell:

```powershell
wsl --shutdown
```

Reopen the distro and verify: `systemctl is-system-running` should print
`running` (or `degraded`, which is fine). The `metadata` automount option
matters — without it every file under `/mnt/c` is `0777` root-owned, which
breaks anything that checks file modes.

## 3. Toolchain + cvcpkg

Package versions below are from `libcvc-deps/BUILDING.md`.

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  build-essential cmake ninja-build patchelf pkg-config \
  python3 python3-pip python3-venv \
  git pipx \
  openssh-server openssh-client \
  openssl libssl-dev

pipx ensurepath
pipx install cvcpkg
# or, for dev against a checkout:  cd libcvc-deps && pip install -e '.[progress]'
```

### OpenSSL and OpenSSH

The apt line above installs **both** the SSH and the OpenSSL pieces:

| Package | Provides | Why |
|---------|----------|-----|
| `openssh-server` | `sshd` | Lets `deploy-prod.yml` reach the builder (§4). |
| `openssh-client` | `ssh`, `scp` | Outbound git-over-SSH, remote fetches during builds. |
| `openssl` | `openssl` CLI + runtime `libssl` | TLS client tooling; runtime for anything linking system OpenSSL. |
| `libssl-dev` | `libssl`/`libcrypto` headers + `.so` | **Build/link dependency** for a library we plan to add later. |

> Note the two OpenSSLs in play. The line above installs the **system**
> OpenSSL (`libssl-dev`) so host tooling and any system-linked library can
> find headers and `libcrypto`/`libssl`. cvcpkg recipes that need OpenSSL
> build their **own** copy from source into the cvcpkg prefix (OpenSSL's
> recipe uses GNU Make — see `libcvc-deps/BUILDING.md`), independent of the
> system package. Both can coexist; just be explicit in a recipe's
> `find_package`/`CMAKE_PREFIX_PATH` about which one you intend to link.

Version bar (from BUILDING.md): GCC ≥ 13, CMake ≥ 3.16 **and < 4.x** (Boost
1.86 CMake compat), Ninja ≥ 1.10, Python ≥ 3.10.

| Debian release | GCC | CMake | Notes |
|----------------|-----|-------|-------|
| 13 (trixie)    | 14  | 3.31  | Clears every bar out of the box. |
| 12 (bookworm)  | 12  | 3.25  | GCC 12 < 13 — pull `gcc-13` from bookworm-backports if a recipe needs it. |

Both releases are safely under the CMake 4.x ceiling.

**Build user.** The fleet convention is a `tfx` service user (the systemd unit
in §6 uses `User=tfx` and `/home/tfx/.local/bin/cvcpkg`). Set the distro's
default WSL user to `tfx` at first launch, or create it and run the toolchain
install / `pipx install` as that user so `cvcpkg` lands on its `PATH`. If you
keep a different username, change `User=` and the `ExecStart`/`PATH` in the
unit to match.

**Sanity check** the toolchain before registering:

```bash
gcc --version && cmake --version && ninja --version
python3 --version && cvcpkg --version
openssl version && pkg-config --modversion libssl   # confirms libssl-dev headers
```

## 4. SSH server + client

WSL2 port 22 is **not** the host's port 22 — the distro is NAT'd with its own
IP. Pick one of three ways to make the deploy workflow able to reach sshd.
**Option C is usually the best fit for WSL**: the builder dials *out* to a
relay, so it works through NAT with no host-side port-forward and no
dependence on the ever-changing WSL IP.

**Option A — mirrored networking (simplest, Windows 11 22H2+).**
In `%UserProfile%\.wslconfig` on the Windows side:

```ini
[wsl2]
networkingMode=mirrored
```

`wsl --shutdown`, reopen. The distro now shares the host IP; `ssh tfx@<host>`
reaches sshd directly on port 22.

**Option B — host port-forward (older Windows).**
The WSL2 IP changes on every boot, so resolve it dynamically. Put this in the
boot task (step 6) so it re-runs each start:

```powershell
$ip = (wsl hostname -I).Trim().Split()[0]
netsh interface portproxy delete v4tov4 listenport=2222 listenaddress=0.0.0.0 2>$null
netsh interface portproxy add v4tov4 listenport=2222 listenaddress=0.0.0.0 connectport=22 connectaddress=$ip
New-NetFirewallRule -DisplayName "WSL sshd" -Direction Inbound -LocalPort 2222 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue
```

Register the builder in the deploy target list on port 2222.

**Option C — reverse SSH tunnel to a LAN relay (recommended for WSL).**
The builder polls a reachable SSH host on the remote LAN (the *relay*) and,
once it can connect, holds open a reverse tunnel (`ssh -R`) that publishes its
local sshd on a port of the relay. Users/CI on the relay's LAN then reach the
builder by connecting to that port on the relay — no inbound path into WSL is
needed, and the outbound dial survives NAT and WSL IP churn.

```
   remote LAN user ──▶ relay.lan:2222 ──[reverse tunnel]──▶ WSL builder localhost:22
```

*Relay-side prerequisite:* to let LAN peers (not just the relay itself) use the
forwarded port, the relay's `/etc/ssh/sshd_config` must allow a non-loopback
bind — set `GatewayPorts clientspecified` (or `yes`) and reload sshd.
Otherwise the `-R` bind is loopback-only and reachable just from the relay.

*Config lives in one env file* so the same script and unit work unchanged
across every builder — only this file differs per host. Create
`/etc/cvcpkg/tunnel.env` (root-owned, `chmod 600`):

```ini
# /etc/cvcpkg/tunnel.env — reverse-tunnel config for this builder
CVCPKG_RELAY_HOST=relay.lan       # reachable SSH host on the remote LAN
CVCPKG_RELAY_USER=tfx
CVCPKG_RELAY_PORT=22              # the relay's sshd port
CVCPKG_REMOTE_BIND=0.0.0.0:2222  # where users connect ON the relay
CVCPKG_LOCAL_SSHD=localhost:22   # this WSL instance's sshd
CVCPKG_POLL_SECS=5
```

*Shortest form — `autossh`* (`sudo apt-get install -y autossh`), which does the
poll-and-reconnect for you. For a quick manual test, source the env file first:

```bash
set -a; . /etc/cvcpkg/tunnel.env; set +a
autossh -M 0 -f -NT \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
  -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new \
  -p "$CVCPKG_RELAY_PORT" \
  -R "$CVCPKG_REMOTE_BIND:$CVCPKG_LOCAL_SSHD" \
  "$CVCPKG_RELAY_USER@$CVCPKG_RELAY_HOST"
```

*Dependency-free equivalent* — a short poller that waits for the relay, then
holds the tunnel and reconnects if it drops. Save as
`/home/tfx/bin/cvcpkg-tunnel.py`:

```python
#!/usr/bin/env python3
"""Poll a LAN relay's sshd; while reachable, hold a reverse tunnel that
publishes this WSL builder's local sshd on the relay for remote-LAN users.

Config comes from the environment (see /etc/cvcpkg/tunnel.env); the defaults
below only apply when a var is unset, so the same script ships to every host.
"""
import os, socket, subprocess, time

RELAY_HOST = os.environ.get("CVCPKG_RELAY_HOST", "relay.lan")
RELAY_USER = os.environ.get("CVCPKG_RELAY_USER", "tfx")
RELAY_PORT = int(os.environ.get("CVCPKG_RELAY_PORT", "22"))
REMOTE_BIND = os.environ.get("CVCPKG_REMOTE_BIND", "0.0.0.0:2222")
LOCAL_SSHD = os.environ.get("CVCPKG_LOCAL_SSHD", "localhost:22")
POLL_SECS = int(os.environ.get("CVCPKG_POLL_SECS", "5"))

def reachable(host, port, timeout=3):
    try:
        with socket.create_connection((host, port), timeout):
            return True
    except OSError:
        return False

while True:
    if not reachable(RELAY_HOST, RELAY_PORT):
        time.sleep(POLL_SECS)
        continue
    # -N: no shell, -T: no tty; keepalives tear down dead tunnels;
    # ExitOnForwardFailure so a stale bind can't leave us "up" but useless.
    subprocess.call([
        "ssh", "-NT",
        "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3",
        "-o", "ExitOnForwardFailure=yes", "-o", "StrictHostKeyChecking=accept-new",
        "-R", f"{REMOTE_BIND}:{LOCAL_SSHD}",
        "-p", str(RELAY_PORT), f"{RELAY_USER}@{RELAY_HOST}",
    ])
    time.sleep(POLL_SECS)   # ssh returned => tunnel dropped; re-poll
```

Either way, the builder needs **key-based** auth to the relay (so the loop is
non-interactive): `ssh-keygen -t ed25519`, then append the pubkey to the
relay's `~tfx/.ssh/authorized_keys`. Users then reach the builder with:

```bash
ssh -p 2222 tfx@relay.lan     # lands on the WSL builder's sshd
```

Run the tunnel under systemd so it starts with the distro and restarts on
drop (companion to the builder unit in §6):

```ini
# /etc/systemd/system/cvcpkg-tunnel.service
[Unit]
Description=cvcpkg WSL reverse SSH tunnel to LAN relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=tfx
EnvironmentFile=/etc/cvcpkg/tunnel.env
ExecStart=/usr/bin/python3 /home/tfx/bin/cvcpkg-tunnel.py
# or, with autossh (systemd expands ${VAR} from EnvironmentFile):
# ExecStart=/usr/bin/autossh -M 0 -NT \
#   -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes \
#   -p ${CVCPKG_RELAY_PORT} \
#   -R ${CVCPKG_REMOTE_BIND}:${CVCPKG_LOCAL_SSHD} \
#   ${CVCPKG_RELAY_USER}@${CVCPKG_RELAY_HOST}
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now cvcpkg-tunnel
```

Inside the distro, generate host keys, enable sshd, install the deploy key:

```bash
sudo ssh-keygen -A
sudo systemctl enable --now ssh
mkdir -p ~/.ssh && chmod 700 ~/.ssh
# append the deploy workflow's public key to ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

## 5. Mount a Windows directory

WSL auto-mounts fixed drives under `/mnt` already, so `C:\builds` is at
`/mnt/c/builds` (with Linux perms thanks to the `metadata` option). For a
tidier path or a specific drive:

```bash
sudo mkdir -p /srv/winbuilds
sudo mount --bind /mnt/c/builds /srv/winbuilds
# or an explicit drvfs mount:
# sudo mount -t drvfs 'D:\cvcpkg' /srv/winbuilds -o metadata,uid=1000,gid=1000
```

To make a bind/drvfs mount survive a distro restart, add it to `/etc/fstab`
(systemd honors fstab under WSL):

```
C:\builds  /srv/winbuilds  drvfs  metadata,uid=1000,gid=1000,umask=022  0  0
```

> ⚠️ **Do not put `--work-dir` on the Windows mount.** `/mnt/c` is 9P/DrvFs:
> slow, and it does not honor Unix permissions/symlinks the way builds expect
> — CMake/Ninja and `patchelf` will crawl or misbehave. Keep `--work-dir` on
> native ext4 (`/tmp/cvcpkg-builder`) and use the Windows mount only to hand
> finished artifacts back to Windows.

## 6. Persistence (two layers)

**Inside the distro** — a normal systemd unit, identical to star-00/star-01:

```ini
# /etc/systemd/system/cvcpkg-builder.service
[Unit]
Description=cvcpkg builder agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=tfx
Environment=PATH=/home/tfx/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/home/tfx/.local/bin/cvcpkg builder run \
    --server https://cvcpkg.org \
    --token cvctok_<builder-token> \
    --name cvcpkg-wsl-01 \
    --max-jobs 4 \
    --work-dir /tmp/cvcpkg-builder \
    --cross-platform wasm
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now cvcpkg-builder
journalctl -u cvcpkg-builder -f
```

(Drop `--cross-platform wasm` if this builder should not take wasm jobs.)

**On the Windows side** — WSL2 does not boot with Windows, and it shuts the
distro down when the last process exits. A Scheduled Task at boot starts WSL
(which brings up systemd → sshd → `cvcpkg-builder`; systemd keeps them alive):

```powershell
schtasks /create /tn "wsl-cvcpkg-boot" /sc onstart /ru SYSTEM /rl highest ^
  /tr "wsl -d Debian -u root -e /bin/true"
```

Running as `SYSTEM` mirrors `phm-win11`'s `schtasks /RU SYSTEM` so it runs
without an interactive login. If you used port-forward Option B, fold the
`netsh portproxy` refresh into a small script and point the task at that
instead of `/bin/true`.

## 7. Register + verify

Use a **publisher**-role token (the `builders` token, or a fresh one via
`cvcpkg-server token create --role publisher`). Then confirm the builder
appears in the fleet:

```bash
curl -H "Authorization: Bearer $TOKEN" https://cvcpkg.org/v1/builders | python3 -m json.tool
cvcpkg builds monitor --server https://cvcpkg.org --token $TOKEN
```

Add its SSH target (host + port + user) to the builder loop in
`deploy-prod.yml` so it gets pulled/reinstalled/restarted with everyone else.

---

## Cleanup & reclaiming disk

WSL2 stores the distro in a virtual disk (`ext4.vhdx`). Two distinct
problems: **junk inside the distro**, and the **vhdx never shrinking on its
own** even after you delete files.

### Inside the distro — free space

```bash
# cvcpkg build scratch + cache (safe; rebuilt on demand)
rm -rf /tmp/cvcpkg-builder/*
rm -rf ~/.cache/cvcpkg

# apt caches
sudo apt-get clean
sudo apt-get autoremove --purge -y

# old journald logs (keep last 2 days)
sudo journalctl --vacuum-time=2d

# see what is using space
sudo du -h -d1 / 2>/dev/null | sort -h | tail -20
```

The cvcpkg cache under `~/.cache/cvcpkg` is the usual culprit on a busy
builder — the same disk pressure that forces the BSD builders to clear
`/root/.cache/cvcpkg` in `deploy-prod.yml`.

### Shrink the vhdx (reclaim space back to Windows)

Deleting files inside the distro frees space **for the distro** but does not
give it back to the host — the `.vhdx` only grows. To compact it, shut WSL
down and run `Optimize-VHD` (Hyper-V) or `diskpart`:

```powershell
wsl --shutdown

# Find the vhdx path (per-distro, under the package dir):
#   %LOCALAPPDATA%\Packages\TheDebianProject...\LocalState\ext4.vhdx

# Option A — Hyper-V module (Windows Pro/Enterprise):
Optimize-VHD -Path "$env:LOCALAPPDATA\Packages\<DebianPkg>\LocalState\ext4.vhdx" -Mode Full

# Option B — diskpart (any Windows edition):
diskpart
#   select vdisk file="C:\Users\<you>\AppData\Local\Packages\<DebianPkg>\LocalState\ext4.vhdx"
#   attach vdisk readonly
#   compact vdisk
#   detach vdisk
#   exit
```

On recent WSL you can instead enable automatic reclaim in `%UserProfile%\.wslconfig`:

```ini
[experimental]
autoMemoryReclaim=gradual
sparseVhd=true            # new distros; keeps the vhdx sparse so it self-shrinks
```

`sparseVhd` only applies to newly created disks. To convert an existing one:
`wsl --manage Debian --set-sparse true` (after `wsl --shutdown`).

### Nuke and re-provision

If the instance is beyond saving, unregister it — this deletes the vhdx and
all its state, fully reclaiming the disk — then rebuild from step 1:

```powershell
wsl --shutdown
wsl --unregister Debian     # DESTRUCTIVE: wipes the distro and its vhdx
wsl --install -d Debian
```

For a repeatable rebuild, export a clean baseline once and re-import instead
of re-running the whole setup:

```powershell
wsl --export Debian D:\wsl\cvcpkg-debian-baseline.tar
# later:
wsl --import cvcpkg-wsl D:\wsl\cvcpkg-wsl D:\wsl\cvcpkg-debian-baseline.tar
```

---

## Quick reference

| Task | Command |
|------|---------|
| Builder logs | `journalctl -u cvcpkg-builder -f` |
| Restart builder | `sudo systemctl restart cvcpkg-builder` |
| Restart sshd | `sudo systemctl restart ssh` |
| WSL IP (Option B) | `wsl hostname -I` |
| Shut WSL down | `wsl --shutdown` (from Windows) |
| Free build cache | `rm -rf ~/.cache/cvcpkg /tmp/cvcpkg-builder/*` |
| Compact vhdx | `Optimize-VHD -Path <ext4.vhdx> -Mode Full` (after `wsl --shutdown`) |
| Destroy distro | `wsl --unregister Debian` |
