# Syncthing pair sync: macOS laptop ↔ Linux VPS

A practical, agent-friendly guide for setting up **bidirectional file sync** between a macOS laptop and one or more Linux VPS servers using [Syncthing](https://syncthing.net/).

This repo is intentionally written so a coding agent can:

1. understand the desired topology,
2. make safe assumptions,
3. run a setup script with little or no human steering,
4. avoid accidental full-mesh sync.

## What this repo solves

If you have:

- one **macOS laptop**,
- one or more **Linux servers**,
- SSH access already configured,
- and you want files added on the laptop to appear on a server and vice versa,

this repo gives you:

- a clear how-to,
- a safe topology recommendation,
- a Linux bootstrap script,
- and a one-shot setup script you run from the Mac.

---

## Recommended topology

### Pair-only sync

For most laptop + server workflows, the safest setup is **pair-only sync**:

- `laptop ⇄ server-a`
- `laptop ⇄ server-b`

This means each server syncs with the laptop, **but not with each other**.

### Why this matters

In Syncthing:

> **one folder ID = one sync cluster**

If you share the same Syncthing folder with multiple devices, changes can propagate across the whole cluster.

So if you do this:

- laptop shares folder `work-sync` with `server-a`
- laptop also shares the same folder `work-sync` with `server-b`

then:

- files from `server-a` can reach `server-b` via the laptop
- files from `server-b` can reach `server-a` via the laptop

That is a **3-way mesh**, even if the laptop feels like the “hub”.

### Correct pattern for pair-only sync

Use a **different folder ID and path per server pair**.

Example:

- `server-a-connect`
  - laptop: `~/shares/server-a`
  - server: `/home/user/shares/server-a`
- `server-b-connect`
  - laptop: `~/shares/server-b`
  - server: `/home/user/shares/server-b`

This gives you:

- laptop ⇄ `server-a`
- laptop ⇄ `server-b`
- no server ⇄ server propagation

---

## Assumptions

This repo assumes:

- macOS laptop already has Syncthing installed
- Syncthing has been launched at least once on the Mac
- SSH config is already in place
- remote Linux user can run `sudo -n` non-interactively
- remote server uses `systemd`
- Python 3 exists on the Mac and Linux server

The setup script supports common Linux package managers:

- `apt-get`
- `dnf`
- `pacman`
- `zypper`

Ubuntu/Debian is the main tested path.

---

## Files in this repo

- `scripts/install-syncthing-linux.sh`
  - installs and starts Syncthing on a Linux server
- `scripts/setup-mac-linux-pair.sh`
  - run from the Mac to create a laptop ⇄ server Syncthing pair

---

## Quick start

### 1. Install and launch Syncthing on the Mac

If you installed the macOS Syncthing app, launch it once so the config directory exists.

Common config location:

- `~/Library/Application Support/Syncthing`

### 2. Make sure your SSH alias works

Examples:

```bash
ssh server-a hostname
ssh server-b hostname
```

If you use a custom SSH config file:

```bash
ssh -F ~/.ssh/config server-a hostname
```

### 3. Create a pair for the first server

```bash
./scripts/setup-mac-linux-pair.sh \
  --ssh-config ~/.ssh/config \
  --ssh-host server-a \
  --folder-id server-a-connect \
  --label server-a-connect \
  --local-path ~/shares/server-a \
  --remote-path /home/user/shares/server-a
```

### 4. Create a second pair for another server

```bash
./scripts/setup-mac-linux-pair.sh \
  --ssh-config ~/.ssh/config \
  --ssh-host server-b \
  --folder-id server-b-connect \
  --label server-b-connect \
  --local-path ~/shares/server-b \
  --remote-path /home/user/shares/server-b
```

That’s it.

---

## What the setup script does

`scripts/setup-mac-linux-pair.sh` runs from the Mac and performs these steps:

1. detects the local Syncthing binary and config dir
2. checks SSH connectivity to the remote host
3. installs Syncthing on the Linux server if missing
4. enables the remote user service:
   - `systemctl --user enable --now syncthing.service`
5. enables linger so Syncthing survives logout:
   - `sudo loginctl enable-linger $USER`
6. creates the local and remote sync folders
7. reads the device IDs for the Mac and the Linux server
8. adds each device to the other device list
9. creates a pair-only folder config on both sides
10. installs safe `.stignore` rules on both endpoints
11. refuses to continue if the requested folder already contains unexpected third-party devices

That last safety check is important: it prevents accidentally turning a pair into a mesh.

---

## Why use `.stignore`

For transfer folders, you usually want to sync actual content but skip OS/editor junk.

This repo writes the following safe defaults:

```gitignore
.DS_Store
._*
Thumbs.db
ehthumbs.db
*.swp
*.swo
*~
```

These ignore rules are installed on **each endpoint**, because `.stignore` is local Syncthing config, not a normal shared content file you should rely on propagating.

---

## How an agent should use this repo

If an agent is asked to “set up pair sync between my Mac and Linux server”, it should:

1. verify SSH works for the target alias
2. choose a **new folder ID** for that pair
3. choose a **dedicated local path** and **dedicated remote path**
4. run `scripts/setup-mac-linux-pair.sh`
5. verify the pair by creating a file on one side and checking it appears on the other
6. if there are multiple servers, repeat with a **different folder ID and path** per server

### Important agent rule

Never reuse the same Syncthing folder ID for two different server pairs unless full cross-server propagation is desired.

---

## Verification checklist

After setup, verify:

### On the Mac

```bash
/Applications/Syncthing.app/Contents/Resources/syncthing/syncthing \
  cli --home "$HOME/Library/Application Support/Syncthing" \
  config folders list
```

### On the server

```bash
ssh <alias> 'syncthing cli config folders list'
```

### End-to-end test

Create a file on the Mac:

```bash
echo "hello from mac" > ~/shares/server-a/test-from-mac.txt
```

Check on the server:

```bash
ssh <alias> 'ls -la /home/user/shares/server-a/test-from-mac.txt'
```

Then do the reverse:

```bash
ssh <alias> 'echo "hello from server" > /home/user/shares/server-a/test-from-server.txt'
ls -la ~/shares/server-a/test-from-server.txt
```

---

## Troubleshooting

### 1. Port-forward conflicts from SSH config

If your SSH config defines `LocalForward` entries, they can interfere with automation.

This repo’s setup script uses:

- `-o ClearAllForwardings=yes`
- `-o ControlMaster=no`
- `-o ControlPath=none`

to avoid inherited SSH multiplexing and forwarding surprises.

### 2. Syncthing installed but not connecting

Check:

- remote service is running:

```bash
ssh <alias> 'systemctl --user status syncthing.service --no-pager'
```

- linger is enabled:

```bash
ssh <alias> 'loginctl show-user "$USER" -p Linger'
```

### 3. Folder unexpectedly syncs across multiple servers

You likely reused the same folder ID in more than one pair.

Fix by:

- creating a new folder ID per pair
- using separate local paths
- using separate remote paths

### 4. macOS app path differs

The scripts try to use:

- `/Applications/Syncthing.app/Contents/Resources/syncthing/syncthing`

If you installed Syncthing another way, ensure `syncthing` is on `PATH` or adapt the script.

---

## Security notes

- Syncthing traffic is end-to-end authenticated and encrypted between devices.
- SSH is only used here for bootstrap and configuration automation.
- Avoid exposing the Syncthing GUI publicly; keep it bound to localhost on servers.

---

## Suggested repo usage patterns

### One laptop + one server

Use one pair:

- folder ID: `server-connect`
- laptop path: `~/shares/server`
- remote path: `/home/user/shares/server`

### One laptop + many servers

Use one pair per server:

- `server-a-connect` → `~/shares/server-a`
- `server-b-connect` → `~/shares/server-b`
- `server-c-connect` → `~/shares/server-c`

This preserves isolation.

---

## Example: exact commands for two servers

```bash
./scripts/setup-mac-linux-pair.sh \
  --ssh-config ~/.ssh/config \
  --ssh-host server-a \
  --folder-id server-a-connect \
  --label server-a-connect \
  --local-path ~/shares/server-a \
  --remote-path /home/user/shares/server-a

./scripts/setup-mac-linux-pair.sh \
  --ssh-config ~/.ssh/config \
  --ssh-host server-b \
  --folder-id server-b-connect \
  --label server-b-connect \
  --local-path ~/shares/server-b \
  --remote-path /home/user/shares/server-b
```

---

## If you want a full mesh instead

If you explicitly want all devices to receive everything, then you can reuse the same folder ID on all of them.

Just do that intentionally.

For most laptop + VPS workflows, pair-only sync is the safer default.
