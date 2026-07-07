#!/usr/bin/env bash
# Uninstall script for rocm-powerd
set -euo pipefail

PREFIX=/usr/local
BINDIR="$PREFIX/bin"
SYSTEMD_DIR=/etc/systemd/system
SERVICE_NAME=rocm-powerd.service

if [[ $EUID -ne 0 ]]; then
  echo "This uninstaller requires root. Re-run with sudo." >&2
  exit 1
fi

systemctl disable --now "$SERVICE_NAME" || true
rm -f "$SYSTEMD_DIR/$SERVICE_NAME"
rm -f "$BINDIR/gpu-auto-mode.sh" "$BINDIR/ai-mode.sh" "$BINDIR/idle-mode.sh"
rm -rf /etc/rocm-powerd
systemctl daemon-reload

echo "Uninstalled rocm-powerd and removed configuration."
