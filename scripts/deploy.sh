#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
SERVICE_NAME="${SERVICE_NAME:-mcp-agent-mail}"
APP_DIR="${APP_DIR:-$ROOT_DIR}"
ENV_FILE="${ENV_FILE:-/etc/mcp-agent-mail.env}"
UNIT_PATH="${UNIT_PATH:-/etc/systemd/system/${SERVICE_NAME}.service}"
RUN_USER="${RUN_USER:-$(id -un)}"
RUN_GROUP="${RUN_GROUP:-$(id -gn)}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8765}"
MCP_PATH="${MCP_PATH:-/api/}"
SMOKE_PROJECT_KEY="${SMOKE_PROJECT_KEY:-}"
SMOKE_AGENT_NAME="${SMOKE_AGENT_NAME:-}"
TIMESTAMP=$(date -u +"%Y%m%dT%H%M%SZ")
UNIT_BACKUP="${UNIT_PATH}.bak-${TIMESTAMP}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing dependency: $1"
}

require_cmd git
require_cmd sudo
require_cmd systemctl
require_cmd python3

[[ -d "$APP_DIR" ]] || fail "APP_DIR does not exist: $APP_DIR"
[[ -x "$APP_DIR/.venv/bin/python" ]] || fail "missing venv python: $APP_DIR/.venv/bin/python"
[[ -f "$ENV_FILE" ]] || fail "missing env file: $ENV_FILE"

git -C "$APP_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "APP_DIR is not a git work tree: $APP_DIR"
git -C "$APP_DIR" diff --quiet || fail "APP_DIR has uncommitted tracked changes"
git -C "$APP_DIR" diff --cached --quiet || fail "APP_DIR has staged but uncommitted changes"

read_env_file_cmd=(python3 -)
if [[ ! -r "$ENV_FILE" ]]; then
  read_env_file_cmd=(sudo python3 -)
fi

DB_URL=$("${read_env_file_cmd[@]}" "$ENV_FILE" <<'PY'
import sys
from pathlib import Path

env_file = Path(sys.argv[1])
database_url = ""
for raw in env_file.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, value = line.split("=", 1)
    if key.strip() == "DATABASE_URL":
        database_url = value.strip().strip('"').strip("'")
        break
print(database_url)
PY
)

[[ -n "$DB_URL" ]] || fail "DATABASE_URL missing from $ENV_FILE"
case "$DB_URL" in
  sqlite+aiosqlite:////*|sqlite:////*)
    ;;
  *)
    fail "DATABASE_URL must use an absolute SQLite path for conservative deployment safety: $DB_URL"
    ;;
esac

DB_PATH=$(python3 - "$DB_URL" <<'PY'
import sys
from sqlalchemy.engine import make_url

url = make_url(sys.argv[1])
print(url.database or "")
PY
)

[[ -n "$DB_PATH" ]] || fail "could not resolve DATABASE_URL path"
[[ -f "$DB_PATH" ]] || fail "database file does not exist: $DB_PATH"
[[ -s "$DB_PATH" ]] || fail "database file is empty: $DB_PATH"

CURRENT_REV=$(git -C "$APP_DIR" rev-parse --short=12 HEAD)

TMP_UNIT=$(mktemp)
cleanup() {
  rm -f "$TMP_UNIT"
}
trap cleanup EXIT

cat >"$TMP_UNIT" <<EOF
[Unit]
Description=MCP Agent Mail HTTP Service
After=network.target

[Service]
Type=simple
User=$RUN_USER
Group=$RUN_GROUP
WorkingDirectory=$APP_DIR
EnvironmentFile=$ENV_FILE
Environment=MCP_AGENT_MAIL_ENV_FILE=$ENV_FILE
ExecStartPre=/usr/bin/test -f $ENV_FILE
ExecStartPre=/usr/bin/test -f $DB_PATH
ExecStartPre=/usr/bin/test -x $APP_DIR/.venv/bin/python
ExecStart=$APP_DIR/.venv/bin/python -m mcp_agent_mail.http --host $HOST --port $PORT
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo "==> release commit: $CURRENT_REV"
echo "==> app dir: $APP_DIR"
echo "==> env file: $ENV_FILE"
echo "==> database: $DB_PATH"
echo "==> backing up existing unit to $UNIT_BACKUP"
if sudo test -f "$UNIT_PATH"; then
  sudo cp "$UNIT_PATH" "$UNIT_BACKUP"
fi

echo "==> installing unit"
sudo cp "$TMP_UNIT" "$UNIT_PATH"
sudo systemctl daemon-reload

rollback() {
  echo "==> smoke check failed; restoring previous unit" >&2
  if sudo test -f "$UNIT_BACKUP"; then
    sudo cp "$UNIT_BACKUP" "$UNIT_PATH"
    sudo systemctl daemon-reload
    sudo systemctl restart "$SERVICE_NAME"
  fi
}

echo "==> restarting $SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"

echo "==> running smoke checks"
if ! APP_DIR="$APP_DIR" ENV_FILE="$ENV_FILE" HOST="$HOST" PORT="$PORT" MCP_PATH="$MCP_PATH" \
  SMOKE_PROJECT_KEY="$SMOKE_PROJECT_KEY" SMOKE_AGENT_NAME="$SMOKE_AGENT_NAME" \
  "$ROOT_DIR/scripts/smoke_check.sh"; then
  rollback
  fail "deployment smoke check failed"
fi

echo "==> deployment complete"
echo "    unit: $UNIT_PATH"
echo "    backup: $UNIT_BACKUP"
