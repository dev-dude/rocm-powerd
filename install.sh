#!/usr/bin/env bash
# Install script for rocm-powerd
set -euo pipefail

PREFIX=/usr/local
BINDIR="$PREFIX/bin"
SYSTEMD_DIR=/etc/systemd/system
SERVICE_NAME=rocm-powerd.service

echo "Installing rocm-powerd to ${BINDIR} and systemd unit to ${SYSTEMD_DIR}"

if [[ $EUID -ne 0 ]]; then
  echo "This installer requires root. Re-run with sudo." >&2
  exit 1
fi

mkdir -p "$BINDIR"
install -m 0755 gpu-auto-mode.sh "$BINDIR/gpu-auto-mode.sh"
install -m 0755 ai-mode.sh "$BINDIR/ai-mode.sh"
install -m 0755 idle-mode.sh "$BINDIR/idle-mode.sh"

mkdir -p /etc/rocm-powerd
if [[ ! -f /etc/rocm-powerd/rocm-powerd.toml ]]; then
  cp rocm-powerd.toml.example /etc/rocm-powerd/rocm-powerd.toml
  echo "Copied example config to /etc/rocm-powerd/rocm-powerd.toml"
fi

install -m 0644 systemd/rocm-powerd.service "$SYSTEMD_DIR/$SERVICE_NAME"

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

echo "Installation complete. Service enabled and started."