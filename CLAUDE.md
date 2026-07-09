# CLAUDE.md — Backbone Repo
# Agent: claude-code | Owner: jack
# Read this at session start. It governs how you operate in the Bequall agent network.

## What this repo is

Backbone is the coordination substrate for Bequall's agent operation. It is a Postgres
ledger (Supabase) that replaces Slack-as-database for task dispatch, claims, decisions,
data requests, and cron heartbeats. You (claude-code) are one of three registered agents.

Registered agents: dao · cowork · claude-code
Chain of command: Jack (CEO) → DAO (COO) → agents. DAO dispatches. You execute.

---

## Session start — always do this first

If using the CLI wrapper, set your agent key before calling `backbone.sh`:

```bash
export BACKBONE_AGENT_KEY=$(cat /Users/dao/bequall-backbone/.keys/claude-code.key)
```

Call backbone.board_query() via the backbone MCP tool.

It returns:
- unclaimed_queue: tasks you can claim right now
- tasks_by_state: full in-flight picture
- decisions_by_approver: human decisions pending (check sla_remaining_hours)
- open_requests: data requests from other agents you can fulfill
- cron_health: scheduled job health

Do NOT read #dao-to-cowork or #cowork-to-dao Slack history to reconstruct state.
The board is state. Slack is notification-only.

---

## Standard workflow

1. board_query — orient
2. task_claim(task_id) — atomic claim before any work. If refused: do not build.
3. Execute deliverable_spec exactly
4. task_complete(task_id, ...) — correct field for output_location

### task_complete field rules

output_location: "workspace"
  Write to /Users/dao/.openclaw/workspace/<relative-path>
  Pass the relative path in inline_content (e.g., "deliverables/proposals/foo.txt")
  DAO reads from this path. It must exist.

output_location: "drive"
  Upload to Google Drive. Get the URL. Pass in drive_url.
  Standard folder: 1oC9T-mavIw0z5amkDMWiHlvxsux_6hzf (Cowork-Shared)
  Share: `gog drive share <id> --email jack@bequall.com --role writer -y`
         `gog drive share <id> --email dao@bequall.com --role writer -y`

output_location: "thread"
  Pass full deliverable text in inline_content. Not a summary — the whole thing.

### EXIT GATE (enforced in SQL — cannot be bypassed)
These paths are REJECTED:
  /Users/dao/Documents/Claude/...  (your local session — invisible to DAO)
  /sessions/...
  /tmp/...
  Any path not under /Users/dao/.openclaw/workspace/ for workspace tasks

If the Exit Gate rejects your completion: you delivered to the wrong location.
Move the file to the correct path and call task_complete again.

---

## Blocked on a human

backbone.decision_open(
  question = "one sentence — what Jack needs to decide",
  approver = "jack",  // or "scott", "kevin"
  blocking_task_id = "<your task uuid>",
  options = [{label, description}, ...],
  sla_hours = 24  // default
)

The task blocks automatically. Backbone escalates to Jack's DM if no response within SLA.
Do NOT wait for a Slack reaction. Do NOT guess. Open a decision row.

---

## Blocked on DAO (need data, HubSpot records, memory, Grain data)

backbone.request_open(
  type = "data_query",
  request = "<specific ask — what exactly you need>",
  context = "<which task this unblocks>",
  fulfiller = "dao"
)

DAO sees it on their board_query under open_requests and fulfills with request_fulfill.
You see the response when you next call board_query or task_get.

---

## Cron runs

End every scheduled run: backbone.cron_heartbeat(cron_id="<id>", status="ok" or "failed")
New scheduled job: backbone.cron_register first.

---

## File paths — what DAO can read

DAO can read:
  /Users/dao/.openclaw/workspace/  — full workspace
  /Users/dao/bequall-backbone/     — this repo

DAO cannot read:
  /Users/dao/Documents/Claude/     — your local Claude project storage
  Anything in Cowork's filesystem  — Cowork and DAO are on different machines

For workspace deliverables: write to /Users/dao/.openclaw/workspace/deliverables/ and
complete with the workspace-relative path.

---

## Supabase project

Project: bequall-backbone (nkpmzpttlajqjykzhmoc, us-east-1)
Separate from REDA projects. Backbone is coordination substrate, not REDA.
Migrations: supabase/migrations/ (0001–0005 applied)
Edge function: notifier (Deno, posts Slack one-liners on task events)

---

## Adding an agent (for reference)

See README.md. No code changes required. Insert into agents + agent_keys tables,
hand the key to the new agent, have them call register_agent.

---

## What you are graded on (live test period)

1. Claim speed — how quickly after task creation do you claim?
2. Execution accuracy — does your output match deliverable_spec exactly?
3. Completion discipline — do you call task_complete with the right field, no local paths?
4. Decision hygiene — do you use decision_open for blockers, or do you guess/stall?
