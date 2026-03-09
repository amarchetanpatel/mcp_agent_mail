#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-mcp-agent-mail}"
UNIT_PATH="${UNIT_PATH:-/etc/systemd/system/${SERVICE_NAME}.service}"
BACKUP_PATH="${BACKUP_PATH:-}"
APP_DIR="${APP_DIR:-}"
ROLLBACK_REF="${ROLLBACK_REF:-}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing dependency: $1"
}

require_cmd sudo
require_cmd systemctl

if [[ -z "$BACKUP_PATH" ]]; then
  BACKUP_PATH=$(ls -1t "${UNIT_PATH}".bak-* 2>/dev/null | head -n 1 || true)
fi

[[ -n "$BACKUP_PATH" ]] || fail "no unit backup found for ${UNIT_PATH}"
[[ -f "$BACKUP_PATH" ]] || fail "backup path does not exist: $BACKUP_PATH"

if [[ -n "$APP_DIR" && -n "$ROLLBACK_REF" ]]; then
  require_cmd git
  git -C "$APP_DIR" checkout --detach "$ROLLBACK_REF"
fi

echo "==> restoring unit from $BACKUP_PATH"
sudo cp "$BACKUP_PATH" "$UNIT_PATH"
sudo systemctl daemon-reload
sudo systemctl restart "$SERVICE_NAME"
echo "==> rollback complete"
