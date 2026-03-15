# mcp_agent_mail — Deployment Note

**Service type:** HTTP API (not an MCP server — legacy naming)

## Runtime Target

| Field | Value |
|-------|-------|
| Live deploy path | `/home/ubuntu/mcp_agent_mail_port/` |
| Live branch | `port/upstream-20260309` |
| Restart authority | `sudo systemctl restart mcp-agent-mail` |
| Systemd service | `mcp-agent-mail.service` |
| Port | 8765 (localhost only) |
| Health | `GET /health/liveness`, `GET /health/readiness` |

## What is NOT the runtime target

| Path | Branch | Status |
|------|--------|--------|
| `/home/ubuntu/mcp_agent_mail/` (VPS) | `main` | Worktree, behind, NOT live |
| `/Users/amarpatel/GitHub/mcp_agent_mail/` (mac-mini) | `main` | Source repo, NOT deployed |
| `/home/ubuntu/mcp_agent_mail_upstream_base/` (VPS) | `verify/upstream-base-20260309` | Reference worktree, NOT live |

## Rule

All implementation and verification for the live HTTP API must target
`port/upstream-20260309` at `/home/ubuntu/mcp_agent_mail_port/` unless
a separate convergence brief changes this.

## History

- 2026-03-15: B-006 was code-verified on main but not deployed. Topology correction applied fixes directly to port branch (commit 25b3553).
