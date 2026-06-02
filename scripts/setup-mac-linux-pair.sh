#!/usr/bin/env bash
set -euo pipefail

SAFE_STIGNORE_CONTENT=$'.DS_Store\n._*\nThumbs.db\nehthumbs.db\n*.swp\n*.swo\n*~\n'

usage() {
  cat <<'EOF'
Create a Syncthing pair between a macOS laptop and one Linux server user.

Run this script from macOS.

Required arguments:
  --ssh-host <alias>         SSH host alias
  --folder-id <id>           Syncthing folder ID, unique per pair
  --label <label>            Human label for the folder
  --local-path <path>        Local macOS folder path

Optional arguments:
  --ssh-config <path>        Alternate SSH config file
  --remote-user <user>       Remote Linux user to run Syncthing as
  --remote-path <path>       Remote Linux folder path (absolute)
                             Defaults to ~<remote-user>/shares/laptop when --remote-user is set
  --remote-name <name>       Friendly device name for remote
  --no-stignore              Skip writing safe default .stignore files
  -h, --help                 Show help

Examples:
  ./scripts/setup-mac-linux-pair.sh \
    --ssh-config ~/Documents/creds/config_ssh \
    --ssh-host ccrem \
    --remote-user ralph \
    --folder-id ccrem-ralph \
    --label ccrem/ralph \
    --local-path ~/shares/ccrem/ralph

  ./scripts/setup-mac-linux-pair.sh \
    --ssh-config ~/Documents/creds/config_ssh \
    --ssh-host amccrem \
    --remote-user apscralph \
    --folder-id amccrem-apscralph \
    --label amccrem/apscralph \
    --local-path ~/shares/amccrem/apscralph
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

extract_my_id() {
  python3 -c 'import json, sys; print(json.load(sys.stdin)["myID"])'
}

SSH_HOST=""
SSH_CONFIG=""
FOLDER_ID=""
LABEL=""
LOCAL_PATH=""
REMOTE_PATH=""
REMOTE_USER=""
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
    --remote-user)
      REMOTE_USER="$2"
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

if [[ -n "$REMOTE_PATH" && "$REMOTE_PATH" != /* ]]; then
  die "--remote-path must be absolute"
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
REMOTE_BOOTSTRAP_OUTPUT="$(remote_bash "$REMOTE_USER" "$REMOTE_PATH" <<'REMOTE_BOOTSTRAP'
set -euo pipefail
TARGET_USER_INPUT="$1"
REMOTE_PATH_INPUT="$2"

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

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command on remote host: $1" >&2
    exit 1
  }
}

need_cmd python3
need_cmd systemctl
need_cmd loginctl
install_syncthing

if [[ -n "$TARGET_USER_INPUT" ]]; then
  TARGET_USER="$TARGET_USER_INPUT"
else
  TARGET_USER="$USER"
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" ]] || {
  echo "Remote user not found: $TARGET_USER" >&2
  exit 1
}

TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_RUNTIME_DIR="/run/user/$TARGET_UID"
TARGET_ST_HOME="$TARGET_HOME/.config/syncthing"

if [[ -n "$REMOTE_PATH_INPUT" ]]; then
  REMOTE_PATH="$REMOTE_PATH_INPUT"
else
  REMOTE_PATH="$TARGET_HOME/shares/laptop"
fi

run_as_target() {
  sudo -n -u "$TARGET_USER" env \
    HOME="$TARGET_HOME" \
    XDG_CONFIG_HOME="$TARGET_HOME/.config" \
    "$@"
}

systemctl_target_user() {
  sudo -n -u "$TARGET_USER" env \
    HOME="$TARGET_HOME" \
    XDG_RUNTIME_DIR="$TARGET_RUNTIME_DIR" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$TARGET_RUNTIME_DIR/bus" \
    systemctl --user "$@"
}

manage_syncthing_service() {
  if [[ "$TARGET_USER" == "$USER" ]]; then
    sudo -n loginctl enable-linger "$TARGET_USER"
    sudo -n loginctl start-user "$TARGET_USER" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      [[ -S "$TARGET_RUNTIME_DIR/bus" ]] && break
      sleep 1
    done
    [[ -S "$TARGET_RUNTIME_DIR/bus" ]] || {
      echo "Timed out waiting for systemd user bus for $TARGET_USER" >&2
      exit 1
    }
    systemctl_target_user daemon-reload >/dev/null 2>&1 || true
    systemctl_target_user enable syncthing.service >/dev/null 2>&1 || true
    systemctl_target_user restart syncthing.service >/dev/null 2>&1 || systemctl_target_user start syncthing.service >/dev/null
  else
    sudo systemctl enable "syncthing@$TARGET_USER.service" >/dev/null 2>&1 || true
    sudo systemctl restart "syncthing@$TARGET_USER.service" >/dev/null 2>&1 || sudo systemctl start "syncthing@$TARGET_USER.service" >/dev/null
  fi
}

normalize_config() {
  run_as_target python3 - "$1" "$2" <<'PY'
import sys
import xml.etree.ElementTree as ET

config_path = sys.argv[1]
uid = int(sys.argv[2])
local_announce_port = 21027 + uid

tree = ET.parse(config_path)
root = tree.getroot()

options = root.find("options")
if options is None:
    raise SystemExit("Syncthing config is missing <options>")

port_node = options.find("localAnnouncePort")
if port_node is None:
    port_node = ET.SubElement(options, "localAnnouncePort")
port_node.text = str(local_announce_port)

start_browser = options.find("startBrowser")
if start_browser is None:
    start_browser = ET.SubElement(options, "startBrowser")
start_browser.text = "false"

tree.write(config_path, encoding="utf-8", xml_declaration=False)
PY
}

if [[ ! -f "$TARGET_ST_HOME/config.xml" ]]; then
  run_as_target mkdir -p "$TARGET_ST_HOME"
  run_as_target syncthing generate --home "$TARGET_ST_HOME" --no-default-folder >/dev/null
fi

normalize_config "$TARGET_ST_HOME/config.xml" "$TARGET_UID"
run_as_target mkdir -p "$REMOTE_PATH"
manage_syncthing_service

for _ in $(seq 1 30); do
  if run_as_target syncthing cli --home "$TARGET_ST_HOME" show system >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

REMOTE_DEVICE_ID="$(run_as_target syncthing cli --home "$TARGET_ST_HOME" show system | python3 -c 'import json, sys; print(json.load(sys.stdin)["myID"])')"

printf '__PI__TARGET_USER=%s\n' "$TARGET_USER"
printf '__PI__TARGET_HOME=%s\n' "$TARGET_HOME"
printf '__PI__REMOTE_PATH=%s\n' "$REMOTE_PATH"
printf '__PI__REMOTE_DEVICE_ID=%s\n' "$REMOTE_DEVICE_ID"
REMOTE_BOOTSTRAP
)"

REMOTE_ACTUAL_USER="$(printf '%s\n' "$REMOTE_BOOTSTRAP_OUTPUT" | awk -F= '/^__PI__TARGET_USER=/{print substr($0, index($0,$2))}' | tail -1)"
REMOTE_PATH="$(printf '%s\n' "$REMOTE_BOOTSTRAP_OUTPUT" | awk -F= '/^__PI__REMOTE_PATH=/{print substr($0, index($0,$2))}' | tail -1)"
REMOTE_DEVICE_ID="$(printf '%s\n' "$REMOTE_BOOTSTRAP_OUTPUT" | awk -F= '/^__PI__REMOTE_DEVICE_ID=/{print substr($0, index($0,$2))}' | tail -1)"

[[ -n "$REMOTE_ACTUAL_USER" ]] || die "Failed to determine remote target user"
[[ -n "$REMOTE_PATH" ]] || die "Failed to determine remote path"
[[ -n "$REMOTE_DEVICE_ID" ]] || die "Failed to determine remote device ID"

if [[ -z "$REMOTE_NAME" ]]; then
  if [[ "$REMOTE_ACTUAL_USER" == "$SSH_HOST" || -z "$REMOTE_USER" ]]; then
    REMOTE_NAME="$SSH_HOST"
  else
    REMOTE_NAME="$SSH_HOST-$REMOTE_ACTUAL_USER"
  fi
fi

LOCAL_DEVICE_ID="$(local_cli show system | extract_my_id)"
[[ -n "$LOCAL_DEVICE_ID" ]] || die "Failed to determine local device ID"

echo "==> Local device ID:  $LOCAL_DEVICE_ID"
echo "==> Remote device ID: $REMOTE_DEVICE_ID"
echo "==> Remote user:      $REMOTE_ACTUAL_USER"

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
remote_bash "$REMOTE_ACTUAL_USER" "$FOLDER_ID" "$LABEL" "$REMOTE_PATH" "$LOCAL_DEVICE_ID" "$REMOTE_DEVICE_ID" <<'REMOTE_CONFIG'
set -euo pipefail
TARGET_USER="$1"
FOLDER_ID="$2"
LABEL="$3"
REMOTE_PATH="$4"
LOCAL_DEVICE_ID="$5"
REMOTE_DEVICE_ID="$6"

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" ]] || {
  echo "Remote user not found: $TARGET_USER" >&2
  exit 1
}

TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_RUNTIME_DIR="/run/user/$TARGET_UID"
TARGET_ST_HOME="$TARGET_HOME/.config/syncthing"

run_as_target() {
  sudo -n -u "$TARGET_USER" env \
    HOME="$TARGET_HOME" \
    XDG_CONFIG_HOME="$TARGET_HOME/.config" \
    "$@"
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

remote_cli() {
  run_as_target syncthing cli --home "$TARGET_ST_HOME" "$@"
}

if ! remote_cli config devices list | grep -qx "$LOCAL_DEVICE_ID"; then
  remote_cli config devices add-json "$(json_device "$LOCAL_DEVICE_ID" "mac-laptop")"
fi

if remote_cli config folders list | grep -qx "$FOLDER_ID"; then
  existing_path="$(remote_cli config folders "$FOLDER_ID" dump-json | extract_folder_path)"
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
  done < <(remote_cli config folders "$FOLDER_ID" dump-json | extract_folder_devices)
else
  remote_cli config folders add-json "$(json_folder "$FOLDER_ID" "$LABEL" "$REMOTE_PATH" "$LOCAL_DEVICE_ID" "$REMOTE_DEVICE_ID")"
fi

if ! remote_cli config folders "$FOLDER_ID" devices list | grep -qx "$LOCAL_DEVICE_ID"; then
  remote_cli config folders "$FOLDER_ID" devices add-json "$(json_membership "$LOCAL_DEVICE_ID")"
fi
REMOTE_CONFIG

if [[ "$WRITE_STIGNORE" -eq 1 ]]; then
  echo "==> Writing safe .stignore on both endpoints"
  printf '%s' "$SAFE_STIGNORE_CONTENT" > "$LOCAL_PATH/.stignore"
  remote_bash "$REMOTE_ACTUAL_USER" "$REMOTE_PATH" <<'REMOTE_STIGNORE'
set -euo pipefail
TARGET_USER="$1"
REMOTE_PATH="$2"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

sudo -n -u "$TARGET_USER" env HOME="$TARGET_HOME" bash -lc 'cat > "$1/.stignore" <<"EOF"
.DS_Store
._*
Thumbs.db
ehthumbs.db
*.swp
*.swo
*~
EOF' _ "$REMOTE_PATH"
REMOTE_STIGNORE
fi

echo "==> Pair created successfully"
echo "    Mac path:      $LOCAL_PATH"
echo "    Remote path:   $REMOTE_PATH"
echo "    Remote user:   $REMOTE_ACTUAL_USER"
echo "    Folder ID:     $FOLDER_ID"
echo "    Remote device: $REMOTE_NAME"
echo "    Remote host:   $SSH_HOST"
