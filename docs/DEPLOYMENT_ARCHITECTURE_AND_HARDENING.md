# MCP Agent Mail Deployment Architecture And Hardening

## Current deployment model

The current production shape is a single-host Linux deployment managed by `systemd`.

- The service is supervised by `mcp-agent-mail.service`.
- Code runs from a checked-out repo/worktree on disk.
- Runtime configuration is injected via an environment file.
- Persistent state is stored in a SQLite database on the same host.
- Most clients reach the service over local loopback HTTP, often from other local automations or interactive agent sessions.

This is a reasonable architecture for the current system because it is simple, cheap to operate, and compatible with the broader single-host agent tooling already in place.

## Why hardening was necessary

The recent upgrade exposed the main operational weakness in the prior setup: the service could come up healthy while pointed at the wrong database.

The underlying cause was not application logic. It was runtime contract ambiguity:

- the process `WorkingDirectory` changed
- the default SQLite URL was relative
- the service still passed health checks
- path-based `project_key` lookups then failed because the service had silently created a fresh empty database in the new directory

That class of incident is exactly why this hardening work matters. The server can be logically correct and still be operationally unsafe if runtime inputs are implicit.

## Hardened architecture

The hardened model keeps the current infra, but makes the runtime contract explicit and verifiable.

### Canonical runtime inputs

- One service unit controls the process lifecycle.
- One env file is the canonical runtime config surface.
- The env file path is made explicit to the app with `MCP_AGENT_MAIL_ENV_FILE`.
- Persistent paths, especially `DATABASE_URL`, are absolute.
- `WorkingDirectory` is no longer allowed to choose the database implicitly.

### Deterministic service start

The service unit now represents an explicit contract:

- env file must exist
- app directory must exist
- interpreter must exist
- database path must be valid before startup

This improves failure mode quality. A bad deploy should fail early and loudly, not start “successfully” against the wrong state.

### Deploy and rollback workflow

The deploy path is intentionally conservative.

- back up the unit
- validate env/app/db inputs
- restart the service
- run smoke checks
- restore the prior unit automatically if smoke checks fail

This is better than ad hoc operator commands because it standardizes recovery and removes hidden assumptions from maintenance windows.

### Smoke verification

Liveness alone is not enough.

The smoke check verifies:

- HTTP liveness
- a real MCP `health_check` tool call
- visibility into the live project set via `resource://projects`
- optional `fetch_inbox` against a known project/agent

This directly addresses the original failure mode. A service pointed at an empty or incorrect database will not pass the full smoke check.

## Why this is better upstream

If this project is used by other Linux operators, the hardened model is a better reference deployment than “copy files somewhere and run it.”

Upstream benefits:

- It gives operators a clear single-host deployment story.
- It treats runtime path safety as a first-class concern.
- It reduces support churn around “service is up but state is wrong.”
- It matches the repo’s existing `deploy/systemd` direction rather than leaving deployment tribal.
- It creates a cleaner basis for future release automation.

In other words, this is not just a local convenience. It is a better operational baseline for the project.

## Why this is better downstream in this infra

This VPS already has surrounding automation that depends on the mail server indirectly.

Downstream consumers include:

- devops timers and local automation loops
- interactive Claude/Codex sessions using the HTTP surface
- path-based project identities keyed to absolute repo paths
- thread-claim and coordination semantics layered on top of the storage and HTTP runtime

The hardened deployment improves all of these because it lowers the chance of “healthy but wrong” state.

That matters more than cosmetic deploy cleanliness. A wrong DB target breaks path-based project identity, agent lookup, inbox reads, and thread visibility all at once.

## Relationship to the rest of the infra

This hardening deliberately preserves the existing connections instead of forcing an infra migration.

- `systemd` remains the process supervisor.
- SQLite remains the source of truth.
- Existing timer jobs and local clients continue to talk to the same service endpoint.
- Path-based `project_key` behavior stays intact.
- The VLAN-style thread-claim layer remains supported and documented.

The only thing that changes is how explicit and testable the runtime contract is.

That is the right tradeoff for the current environment: safer operations without re-architecting the platform.

## Pros

- Lower risk of silently selecting the wrong database
- Faster diagnosis during incidents
- Clearer release provenance from logs
- Safer repeatable deploys
- Easier handoff to future operators and coding agents
- Better alignment between repo deployment assets and real production behavior

## Cons and tradeoffs

- More operational ceremony than “edit unit and restart”
- More explicit config to keep in sync
- Conservative scripts still assume a single-host deployment model
- SQLite remains a single-node durability and concurrency boundary
- The repo still supports more deployment shapes than the local VPS actually uses

These are acceptable tradeoffs for the current phase because the goal is reliability, not architectural novelty.

## Why not do a more aggressive architecture change now

A more aggressive design could include:

- release directories with a stable `current` symlink
- containers
- an external Postgres deployment
- service discovery / multi-host orchestration
- richer observability infrastructure

Those approaches can be valid, but they solve a different problem set.

Right now they would increase migration risk without materially improving the immediate operational failure modes that actually appeared. The recent incident was caused by path ambiguity, not by limits of `systemd` or single-host deployment.

## Identity, thread claims, and the rest of the product behavior

This hardening is not a substitute for product-layer coordination semantics.

- identity/session continuity helps agents maintain continuity across sessions and worktrees
- thread claims help agents coordinate exclusive ownership over conversational work

Both matter in this deployment. The hardened runtime makes those features safer by ensuring the process is attached to the intended state, but it does not replace them.

## Recommended future evolution

If the service later becomes more central or more heavily loaded, the next meaningful improvements would be:

1. stable release directories plus `current` symlink
2. stronger release metadata and metrics
3. a tested migration path off SQLite if concurrency or durability needs outgrow it

Those are future platform choices. The current hardening work is the correct intermediate step because it makes today’s architecture reliable without forcing tomorrow’s architecture prematurely.
