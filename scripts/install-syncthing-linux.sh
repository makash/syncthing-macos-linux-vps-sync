#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Install and start Syncthing for the current Linux user.

Usage:
  install-syncthing-linux.sh [--remote-path /absolute/path]

What it does:
  - installs Syncthing if missing
  - enables and starts systemd user service
  - enables linger so service survives logout
  - optionally creates a sync directory
  - prints the local device ID

Assumptions:
  - Linux host uses systemd
  - current user can run sudo -n
EOF
}

REMOTE_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote-path)
      REMOTE_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

install_syncthing() {
  if command -v syncthing >/dev/null 2>&1; then
    return 0
  fi

  if ! sudo -n true >/dev/null 2>&1; then
    echo "This script requires passwordless sudo (sudo -n)." >&2
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

  echo "Could not detect a supported package manager." >&2
  exit 1
}

need_cmd systemctl
need_cmd loginctl
need_cmd python3

install_syncthing

systemctl --user daemon-reload || true
systemctl --user enable --now syncthing.service
sudo loginctl enable-linger "$USER"

if [[ -n "$REMOTE_PATH" ]]; then
  mkdir -p "$REMOTE_PATH"
fi

if syncthing device-id >/dev/null 2>&1; then
  syncthing device-id
else
  syncthing --device-id
fi
