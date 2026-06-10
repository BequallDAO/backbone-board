# skills/

Phase 3/5 deliverables land here:

- `dao-task/` — rewrite of the dao-task skill: dispatch via `task_create` (ledger-first),
  Slack message becomes the notification, not the record.
- `pulse/` — pulse skill rewritten on `pulse_query` (no channel reconstruction).
- `backbone/` — the skill packaged with the backbone plugin for teammate agents
  (claim-before-build, Exit Gate rules, decision/request protocol).

Not yet written: the legacy skills keep running until the Phase 3 shadow week starts,
per the PRD adoption plan (a half-adopted ledger is worse than none).
