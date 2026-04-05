#!/usr/bin/env bash
set -euo pipefail

SAFE_STIGNORE_CONTENT=$'.DS_Store\n._*\nThumbs.db\nehthumbs.db\n*.swp\n*.swo\n*~\n'

usage() {
  cat <<'EOF'
Create a Syncthing pair between a macOS laptop and one Linux server.

Run this script from macOS.

Required arguments:
  --ssh-host <alias>         SSH host alias
  --folder-id <id>           Syncthing folder ID, unique per pair
  --label <label>            Human label for the folder
  --local-path <path>        Local macOS folder path
  --remote-path <path>       Remote Linux folder path (absolute)

Optional arguments:
  --ssh-config <path>        Alternate SSH config file
  --remote-name <name>       Friendly device name for remote (defaults to ssh host)
  --no-stignore              Skip writing safe default .stignore files
  -h, --help                 Show help

Example:
  ./scripts/setup-mac-linux-pair.sh \
    --ssh-config ~/.ssh/config \
    --ssh-host server-a \
    --folder-id server-a-connect \
    --label server-a-connect \
    --local-path ~/shares/server-a \
    --remote-path /home/user/shares/server-a
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

json_device() {
  python3 - "$1" "$2" <<'PY'
import json, sys
print(json.dumps({
  "deviceID": sys.argv[1],
  "name": sys.argv[2],
  "addresses": ["dynamic"],
  "compression": "metadata",
  "paused": False,
  "autoAcceptFolders": False,
}))
PY
}

json_membership() {
  python3 - "$1" <<'PY'
import json, sys
print(json.dumps({
  "deviceID": sys.argv[1],
  "introducedBy": "",
  "encryptionPassword": "",
}))
PY
}

json_folder() {
  python3 - "$@" <<'PY'
import json, sys
folder_id, label, path, local_id, remote_id = sys.argv[1:6]
print(json.dumps({
  "id": folder_id,
  "label": label,
  "filesystemType": "basic",
  "path": path,
  "type": "sendreceive",
  "devices": [
    {"deviceID": local_id, "introducedBy": "", "encryptionPassword": ""},
    {"deviceID": remote_id, "introducedBy": "", "encryptionPassword": ""},
  ],
  "rescanIntervalS": 3600,
  "fsWatcherEnabled": True,
  "fsWatcherDelayS": 10,
  "ignorePerms": False,
  "autoNormalize": True,
  "minDiskFree": {"value": 1, "unit": "%"},
  "versioning": {"type": "", "params": {}, "cleanupIntervalS": 3600, "fsPath": "", "fsType": "basic"},
  "copiers": 0,
  "pullerMaxPendingKiB": 0,
  "hashers": 0,
  "order": "random",
  "ignoreDelete": False,
  "scanProgressIntervalS": 0,
  "pullerPauseS": 0,
  "pullerDelayS": 1,
  "maxConflicts": 10,
  "disableSparseFiles": False,
  "paused": False,
  "markerName": ".stfolder",
  "copyOwnershipFromParent": False,
  "modTimeWindowS": 0,
  "maxConcurrentWrites": 16,
  "disableFsync": False,
  "blockPullOrder": "standard",
  "copyRangeMethod": "standard",
  "caseSensitiveFS": False,
  "junctionsAsDirs": False,
  "syncOwnership": False,
  "sendOwnership": False,
  "syncXattrs": False,
  "sendXattrs": False,
  "xattrFilter": {"entries": [], "maxSingleEntrySize": 1024, "maxTotalSize": 4096},
}))
PY
}

expand_local_path() {
  python3 - "$1" <<'PY'
import os, sys
print(os.path.abspath(os.path.expanduser(sys.argv[1])))
PY
}

extract_folder_path() {
  python3 -c 'import json, sys; print(json.load(sys.stdin)["path"])'
}

extract_folder_devices() {
  python3 -c 'import json, sys; [print(dev["deviceID"]) for dev in json.load(sys.stdin)["devices"]]'
}

SSH_HOST=""
SSH_CONFIG=""
FOLDER_ID=""
LABEL=""
LOCAL_PATH=""
REMOTE_PATH=""
REMOTE_NAME=""
WRITE_STIGNORE=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-host)
      SSH_HOST="$2"
      shift 2
      ;;
    --ssh-config)
      SSH_CONFIG="$2"
      shift 2
      ;;
    --folder-id)
      FOLDER_ID="$2"
      shift 2
      ;;
    --label)
      LABEL="$2"
      shift 2
      ;;
    --local-path)
      LOCAL_PATH="$2"
      shift 2
      ;;
    --remote-path)
      REMOTE_PATH="$2"
      shift 2
      ;;
    --remote-name)
      REMOTE_NAME="$2"
      shift 2
      ;;
    --no-stignore)
      WRITE_STIGNORE=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$SSH_HOST" ]] || die "--ssh-host is required"
[[ -n "$FOLDER_ID" ]] || die "--folder-id is required"
[[ -n "$LABEL" ]] || die "--label is required"
[[ -n "$LOCAL_PATH" ]] || die "--local-path is required"
[[ -n "$REMOTE_PATH" ]] || die "--remote-path is required"
[[ "$REMOTE_PATH" = /* ]] || die "--remote-path must be absolute"

if [[ -z "$REMOTE_NAME" ]]; then
  REMOTE_NAME="$SSH_HOST"
fi

need_cmd ssh
need_cmd python3

LOCAL_PATH="$(expand_local_path "$LOCAL_PATH")"

if [[ -x "/Applications/Syncthing.app/Contents/Resources/syncthing/syncthing" ]]; then
  LOCAL_ST_BIN="/Applications/Syncthing.app/Contents/Resources/syncthing/syncthing"
elif command -v syncthing >/dev/null 2>&1; then
  LOCAL_ST_BIN="$(command -v syncthing)"
else
  die "Could not find Syncthing on macOS"
fi

if [[ -d "$HOME/Library/Application Support/Syncthing" ]]; then
  LOCAL_ST_HOME="$HOME/Library/Application Support/Syncthing"
elif [[ -d "$HOME/.config/syncthing" ]]; then
  LOCAL_ST_HOME="$HOME/.config/syncthing"
else
  die "Could not find local Syncthing config. Launch Syncthing once on the Mac first."
fi

local_cli() {
  "$LOCAL_ST_BIN" cli --home "$LOCAL_ST_HOME" "$@"
}

SSH_CMD=(ssh)
if [[ -n "$SSH_CONFIG" ]]; then
  SSH_CMD+=(-F "$SSH_CONFIG")
fi
SSH_CMD+=(-o ClearAllForwardings=yes -o ControlMaster=no -o ControlPath=none)

remote_cmd() {
  "${SSH_CMD[@]}" "$SSH_HOST" "$@"
}

remote_bash() {
  "${SSH_CMD[@]}" "$SSH_HOST" bash -s -- "$@"
}

echo "==> Checking SSH connectivity to $SSH_HOST"
remote_cmd hostname >/dev/null

echo "==> Installing/starting Syncthing on remote if needed"
remote_bash "$REMOTE_PATH" <<'REMOTE'
set -euo pipefail
REMOTE_PATH="$1"

install_syncthing() {
  if command -v syncthing >/dev/null 2>&1; then
    return 0
  fi

  if ! sudo -n true >/dev/null 2>&1; then
    echo "Remote host requires passwordless sudo (sudo -n)." >&2
    exit 1
  fi

  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y syncthing
    return 0
  fi

  if command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y syncthing
    return 0
  fi

  if command -v pacman >/dev/null 2>&1; then
    sudo pacman -Sy --noconfirm syncthing
    return 0
  fi

  if command -v zypper >/dev/null 2>&1; then
    sudo zypper --non-interactive install syncthing
    return 0
  fi

  echo "Unsupported package manager on remote host." >&2
  exit 1
}

install_syncthing
systemctl --user daemon-reload || true
systemctl --user enable --now syncthing.service
sudo loginctl enable-linger "$USER"
mkdir -p "$REMOTE_PATH"
REMOTE

if "$LOCAL_ST_BIN" --home "$LOCAL_ST_HOME" device-id >/dev/null 2>&1; then
  LOCAL_DEVICE_ID="$($LOCAL_ST_BIN --home "$LOCAL_ST_HOME" device-id)"
else
  LOCAL_DEVICE_ID="$($LOCAL_ST_BIN --home "$LOCAL_ST_HOME" --device-id)"
fi

REMOTE_DEVICE_ID="$(remote_bash <<'REMOTE'
set -euo pipefail
if syncthing device-id >/dev/null 2>&1; then
  syncthing device-id
else
  syncthing --device-id
fi
REMOTE
)"
REMOTE_DEVICE_ID="${REMOTE_DEVICE_ID//$'\r'/}"

[[ -n "$LOCAL_DEVICE_ID" ]] || die "Failed to determine local device ID"
[[ -n "$REMOTE_DEVICE_ID" ]] || die "Failed to determine remote device ID"

echo "==> Local device ID:  $LOCAL_DEVICE_ID"
echo "==> Remote device ID: $REMOTE_DEVICE_ID"

mkdir -p "$LOCAL_PATH"

if local_cli config folders list | grep -qx "$FOLDER_ID"; then
  existing_path="$(local_cli config folders "$FOLDER_ID" dump-json | extract_folder_path)"
  existing_path="$(expand_local_path "$existing_path")"
  [[ "$existing_path" == "$LOCAL_PATH" ]] || die "Local folder $FOLDER_ID already exists at $existing_path, expected $LOCAL_PATH"

  while IFS= read -r dev; do
    [[ -n "$dev" ]] || continue
    case "$dev" in
      "$LOCAL_DEVICE_ID"|"$REMOTE_DEVICE_ID") ;;
      *) die "Local folder $FOLDER_ID already contains third-party device $dev; refusing to create a mesh." ;;
    esac
  done < <(local_cli config folders "$FOLDER_ID" dump-json | extract_folder_devices)
else
  local_cli config folders add-json "$(json_folder "$FOLDER_ID" "$LABEL" "$LOCAL_PATH" "$LOCAL_DEVICE_ID" "$REMOTE_DEVICE_ID")"
fi

if ! local_cli config devices list | grep -qx "$REMOTE_DEVICE_ID"; then
  local_cli config devices add-json "$(json_device "$REMOTE_DEVICE_ID" "$REMOTE_NAME")"
fi

if ! local_cli config folders "$FOLDER_ID" devices list | grep -qx "$REMOTE_DEVICE_ID"; then
  local_cli config folders "$FOLDER_ID" devices add-json "$(json_membership "$REMOTE_DEVICE_ID")"
fi

echo "==> Configuring remote device and folder"
remote_bash "$FOLDER_ID" "$LABEL" "$REMOTE_PATH" "$LOCAL_DEVICE_ID" "$REMOTE_DEVICE_ID" "$REMOTE_NAME" <<'REMOTE'
set -euo pipefail
FOLDER_ID="$1"
LABEL="$2"
REMOTE_PATH="$3"
LOCAL_DEVICE_ID="$4"
REMOTE_DEVICE_ID="$5"
REMOTE_NAME="$6"

json_device() {
  python3 - "$1" "$2" <<'PY'
import json, sys
print(json.dumps({
  "deviceID": sys.argv[1],
  "name": sys.argv[2],
  "addresses": ["dynamic"],
  "compression": "metadata",
  "paused": False,
  "autoAcceptFolders": False,
}))
PY
}

json_membership() {
  python3 - "$1" <<'PY'
import json, sys
print(json.dumps({
  "deviceID": sys.argv[1],
  "introducedBy": "",
  "encryptionPassword": "",
}))
PY
}

json_folder() {
  python3 - "$@" <<'PY'
import json, sys
folder_id, label, path, local_id, remote_id = sys.argv[1:6]
print(json.dumps({
  "id": folder_id,
  "label": label,
  "filesystemType": "basic",
  "path": path,
  "type": "sendreceive",
  "devices": [
    {"deviceID": remote_id, "introducedBy": "", "encryptionPassword": ""},
    {"deviceID": local_id, "introducedBy": "", "encryptionPassword": ""},
  ],
  "rescanIntervalS": 3600,
  "fsWatcherEnabled": True,
  "fsWatcherDelayS": 10,
  "ignorePerms": False,
  "autoNormalize": True,
  "minDiskFree": {"value": 1, "unit": "%"},
  "versioning": {"type": "", "params": {}, "cleanupIntervalS": 3600, "fsPath": "", "fsType": "basic"},
  "copiers": 0,
  "pullerMaxPendingKiB": 0,
  "hashers": 0,
  "order": "random",
  "ignoreDelete": False,
  "scanProgressIntervalS": 0,
  "pullerPauseS": 0,
  "maxConflicts": 10,
  "disableSparseFiles": False,
  "disableTempIndexes": False,
  "paused": False,
  "weakHashThresholdPct": 25,
  "markerName": ".stfolder",
  "copyOwnershipFromParent": False,
  "modTimeWindowS": 0,
  "maxConcurrentWrites": 2,
  "disableFsync": False,
  "blockPullOrder": "standard",
  "copyRangeMethod": "standard",
  "caseSensitiveFS": False,
  "junctionsAsDirs": False,
  "syncOwnership": False,
  "sendOwnership": False,
  "syncXattrs": False,
  "sendXattrs": False,
  "xattrFilter": {"entries": [], "maxSingleEntrySize": 1024, "maxTotalSize": 4096},
}))
PY
}

extract_folder_path() {
  python3 -c 'import json, sys; print(json.load(sys.stdin)["path"])'
}

extract_folder_devices() {
  python3 -c 'import json, sys; [print(dev["deviceID"]) for dev in json.load(sys.stdin)["devices"]]'
}

expand_path() {
  python3 - "$1" <<'PY'
import os, sys
print(os.path.abspath(os.path.expanduser(sys.argv[1])))
PY
}

if ! syncthing cli config devices list | grep -qx "$LOCAL_DEVICE_ID"; then
  syncthing cli config devices add-json "$(json_device "$LOCAL_DEVICE_ID" "mac-laptop")"
fi

if syncthing cli config folders list | grep -qx "$FOLDER_ID"; then
  existing_path="$(syncthing cli config folders "$FOLDER_ID" dump-json | extract_folder_path)"
  existing_path="$(expand_path "$existing_path")"
  [[ "$existing_path" == "$REMOTE_PATH" ]] || {
    echo "Remote folder $FOLDER_ID already exists at $existing_path, expected $REMOTE_PATH" >&2
    exit 1
  }

  while IFS= read -r dev; do
    [[ -n "$dev" ]] || continue
    case "$dev" in
      "$LOCAL_DEVICE_ID"|"$REMOTE_DEVICE_ID") ;;
      *) echo "Remote folder $FOLDER_ID already contains third-party device $dev; refusing to create a mesh." >&2; exit 1 ;;
    esac
  done < <(syncthing cli config folders "$FOLDER_ID" dump-json | extract_folder_devices)
else
  syncthing cli config folders add-json "$(json_folder "$FOLDER_ID" "$LABEL" "$REMOTE_PATH" "$LOCAL_DEVICE_ID" "$REMOTE_DEVICE_ID")"
fi

if ! syncthing cli config folders "$FOLDER_ID" devices list | grep -qx "$LOCAL_DEVICE_ID"; then
  syncthing cli config folders "$FOLDER_ID" devices add-json "$(json_membership "$LOCAL_DEVICE_ID")"
fi
REMOTE

if [[ "$WRITE_STIGNORE" -eq 1 ]]; then
  echo "==> Writing safe .stignore on both endpoints"
  printf '%s' "$SAFE_STIGNORE_CONTENT" > "$LOCAL_PATH/.stignore"
  remote_bash "$REMOTE_PATH" <<'REMOTE'
set -euo pipefail
REMOTE_PATH="$1"
cat > "$REMOTE_PATH/.stignore" <<'EOF'
.DS_Store
._*
Thumbs.db
ehthumbs.db
*.swp
*.swo
*~
EOF
REMOTE
fi

echo "==> Pair created successfully"
echo "    Mac path:    $LOCAL_PATH"
echo "    Remote path: $REMOTE_PATH"
echo "    Folder ID:   $FOLDER_ID"
echo "    Remote host: $SSH_HOST"
