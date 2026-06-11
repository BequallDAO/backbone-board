# bequall-backbone

Coordination substrate for Bequall's agent operation. Replaces Slack-as-database with a
Postgres ledger: tasks with atomic claims, an append-only event log, human decision queues
with SLA escalation, data requests, cron heartbeats, and workflows/programs as data.
Spec: `Backbone-PRD-Bequall-v2` (PRD v2, June 10, 2026).

## Live infrastructure

- **Supabase project**: `bequall-backbone` (`nkpmzpttlajqjykzhmoc`, us-east-1, BequallDAO org).
  Separate from both REDA projects — Backbone is a substrate, not REDA.
- **API URL**: `https://nkpmzpttlajqjykzhmoc.supabase.co`
- **Edge function**: `notifier` (Slack one-liners; self-authenticated via bearer from `app_config`)
- **pg_cron**: `backbone-sla-check` every 15 min (decision SLA escalation + lease expiry)
- **Migrations**: `supabase/migrations/` 0001–0005, applied via Supabase MCP

## Layout

```
supabase/migrations/   numbered SQL — schema, seed, tool functions, notifier/SLA wiring
supabase/functions/    notifier edge function (Deno)
mcp-server/            TypeScript MCP server (stdio), one file per tool in src/tools/
mcp-server/test/       harness.ts (PRD §8 spec tests, two simulated agents), e2e-phase1.ts
.keys/                 agent keys + notifier bearer (chmod 600, gitignored, NEVER commit)
skills/                dao-task + backbone skill rewrites (Phase 3/5)
```

## How auth works

Each agent has a random 64-hex key. Only the sha256 hash is stored (`agent_keys`). The MCP
server (or any client) calls PostgREST RPCs with the anon key + passes `p_agent_key`; every
SQL function authenticates via `_auth_agent()`. Tables are RLS-locked with zero policies —
the security-definer functions in migration 0003 are the only write path, so the Exit Gate,
atomic claims, and event emission cannot be bypassed.

**Adding an agent (no code change):**
```bash
KEY=$(openssl rand -hex 32)
HASH=$(printf %s "$KEY" | shasum -a 256 | cut -d' ' -f1)
# insert into agents + agent_keys (via Supabase MCP or SQL editor):
#   insert into agents (id, human_owner, capabilities) values ('scott-cowork','scott','{docx,proposal}');
#   insert into agent_keys (key_hash, agent_id, label) values ('<HASH>','scott-cowork','issued YYYY-MM-DD');
# hand KEY to the agent's machine as BACKBONE_AGENT_KEY
```

## Installing the MCP server on an agent machine

```bash
cd mcp-server && npm install && npm run build
claude mcp add backbone --scope user \
  --env BACKBONE_URL="https://nkpmzpttlajqjykzhmoc.supabase.co" \
  --env BACKBONE_ANON_KEY="<anon key>" \
  --env BACKBONE_AGENT_KEY="<this agent's key>" \
  -- node <repo>/mcp-server/dist/index.js
```

Fallback if a runtime can't mount MCP (e.g. DAO's Mac Studio): call PostgREST directly —
`POST {BACKBONE_URL}/rest/v1/rpc/<tool_name>` with headers `apikey: <anon>`,
`Authorization: Bearer <anon>` and JSON body `{"p_agent_key": "...", ...}`. Same functions,
same semantics; the MCP server is a thin shim.

## Tools (20)

`register_agent, board_query, task_create, task_get, task_claim, task_release,
task_transition, task_complete, task_supersede, decision_open, decision_resolve,
request_open, request_fulfill, cron_register, cron_heartbeat, pulse_query, event_append,
workflow_define, program_create, program_query`

Key semantics:
- **task_claim** is an atomic single-UPDATE claim with a lease (default 4h). Losers get the
  owner + lease expiry and an instruction not to build. Expired leases auto-release.
- **task_complete** enforces the Exit Gate in SQL: local paths rejected; `drive` tasks need a
  docs/drive.google.com URL; `thread` needs inline content; `workspace` needs a relative path.
  Deliverable row + state change + event commit atomically.
- **task_supersede** is the only way to re-spec work: releases the prior claimant, notifies
  them, chains old → new. Never dispatch a parallel copy.
- **decision_open/resolve** is the blocked-on-human queue; pg_cron escalates SLA breaches.
- **board_query** replaces a channel sweep; **pulse_query** replaces forensic digest assembly.
- **workflow_define + program_create** add domain runtimes with zero schema changes
  (the fourth-program test, PRD §4).

## Board (the human UI)

**URL: https://buildwithbequall.github.io/backbone-board/** — three views per PRD §6:
`#decisions` (phone-first queue, one-tap resolve), `#board` (tasks by state, unclaimed
queue, cron health, programs), `#task/<id>` (timeline, deliverables, claim history),
plus `#pulse` (today's events + shipped deliverables).

Architecture: static shell on GitHub Pages (`BuildWithBequall/backbone-board`, zero
secrets; canonical source `board/index.html`) + the `board` edge function as a
CORS-enabled data API. *.supabase.co refuses to serve HTML (anti-phishing), which is
why the shell lives on Pages; the function's GET redirects there.

Auth: per-human access tokens in `app_config` (`board_token_jack`, `board_token_scott`;
plaintext copies in `.keys/board-token-*.txt`). First visit: open
`.../backbone-board/?token=<token>` once — it's stored in localStorage and stripped
from the URL. The only mutation the board can make is `decision_resolve`, recorded
with the human's name; reads go through the `board` service agent. Add a human:
insert `board_token_<name>` into `app_config`. Revoke: delete the row.

## Notifier + degraded mode

`events` insert → trigger `_notify_event()` (pg_net) → `notifier` edge function → Slack
one-liner in `#dao-to-cowork` / `#cowork-to-dao` / approver DM. Config in `app_config`
(`notifier_url`, `notifier_bearer`, optional `board_url`); Slack token in function secret
`SLACK_BOT_TOKEN`. If any link is missing the ledger keeps working silently — Slack carries
pointers, never truth. If Supabase is unreachable, agents fall back to the legacy Slack
protocol; backfill replays into the ledger on `external_id` idempotency.

## Tests

```bash
cd mcp-server && source ../.keys/test.env
npm test                      # PRD §8 spec harness (13 tests, two agents, live ledger)
npx tsx test/e2e-phase1.ts    # end-to-end dispatch → claim → complete + Slack notify
```

Harness rows are tagged (`test-` external ids, `TEST` specs); sweep with:
`delete from ... where deliverable_spec like 'TEST%' / external_id like 'test-%' / id like 'test-%'`.
Events are append-only and stay.

## Phase status (PRD §7)

- **Phase 1 — done 2026-06-10.** Migrations, MCP server, Exit Gate in SQL, notifier, keys
  for dao/cowork/claude-code, harness green (13/13), real task end-to-end with Slack proof.
- **Phase 2 — partial.** decisions + data_requests + SLA escalation live; remaining: board
  web app (Lovable or Next.js) and DAO integration on the Mac Studio.
- **Phases 3–6** — shadow mode, cutover, capability routing/plugin packaging, program layer
  compilers + governors. Workflows/programs/tools already exist for Phase 6 groundwork.
