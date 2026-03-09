#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
ENV_FILE="${ENV_FILE:-/etc/mcp-agent-mail.env}"

if [[ -r "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

HOST="${HOST:-${HTTP_HOST:-127.0.0.1}}"
PORT="${PORT:-${HTTP_PORT:-8765}}"
MCP_PATH="${MCP_PATH:-${HTTP_PATH:-/api/}}"
SERVICE_URL="http://${HOST}:${PORT}"
AUTH_HEADER="${HTTP_BEARER_TOKEN:-}"
SMOKE_PROJECT_KEY="${SMOKE_PROJECT_KEY:-}"
SMOKE_AGENT_NAME="${SMOKE_AGENT_NAME:-}"

curl_args=(-fsS)
if [[ -n "$AUTH_HEADER" ]]; then
  curl_args+=(-H "Authorization: Bearer ${AUTH_HEADER}")
fi

echo "==> liveness"
ready=0
for _ in $(seq 1 30); do
  if curl "${curl_args[@]}" "${SERVICE_URL}/health/liveness" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done

if [[ "$ready" != "1" ]]; then
  echo "service did not become healthy within 30s" >&2
  exit 1
fi

echo "==> health_check tool"
health_payload='{"jsonrpc":"2.0","id":"smoke-health","method":"tools/call","params":{"name":"health_check","arguments":{}}}'
health_response=$(curl "${curl_args[@]}" -H "Content-Type: application/json" -d "$health_payload" "${SERVICE_URL}${MCP_PATH}")
python3 - "$health_response" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
if payload.get("error"):
    raise SystemExit(f"health_check returned error: {payload['error']}")
PY

echo "==> projects resource"
projects_payload='{"jsonrpc":"2.0","id":"smoke-projects","method":"resources/read","params":{"uri":"resource://projects"}}'
projects_response=$(curl "${curl_args[@]}" -H "Content-Type: application/json" -d "$projects_payload" "${SERVICE_URL}${MCP_PATH}")
python3 - "$projects_response" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
if payload.get("error"):
    raise SystemExit(f"projects resource returned error: {payload['error']}")
result = payload.get("result") or {}
contents = result.get("contents") or []
if not contents:
    raise SystemExit("projects resource returned no contents")
PY

if [[ -n "$SMOKE_PROJECT_KEY" && -n "$SMOKE_AGENT_NAME" ]]; then
  echo "==> fetch_inbox smoke for ${SMOKE_AGENT_NAME} @ ${SMOKE_PROJECT_KEY}"
  inbox_payload=$(python3 - "$SMOKE_PROJECT_KEY" "$SMOKE_AGENT_NAME" <<'PY'
import json
import sys

project_key, agent_name = sys.argv[1], sys.argv[2]
payload = {
    "jsonrpc": "2.0",
    "id": "smoke-inbox",
    "method": "tools/call",
    "params": {
        "name": "fetch_inbox",
        "arguments": {
            "project_key": project_key,
            "agent_name": agent_name,
            "limit": 1,
        },
    },
}
print(json.dumps(payload))
PY
)
  inbox_response=$(curl "${curl_args[@]}" -H "Content-Type: application/json" -d "$inbox_payload" "${SERVICE_URL}${MCP_PATH}")
  python3 - "$inbox_response" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
if payload.get("error"):
    raise SystemExit(f"fetch_inbox returned error: {payload['error']}")
PY
else
  echo "==> fetch_inbox smoke skipped (set SMOKE_PROJECT_KEY and SMOKE_AGENT_NAME to enable)"
fi

echo "==> smoke checks passed"
