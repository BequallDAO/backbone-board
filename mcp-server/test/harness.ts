// Backbone test harness — simulates two agents (dao, cowork) hitting the live
// ledger. Implements the spec tests from PRD §8 that are runnable in Phase 1-2.
//
// Env: BACKBONE_URL, BACKBONE_ANON_KEY, BACKBONE_DAO_KEY, BACKBONE_COWORK_KEY
// Run:  npm test   (from mcp-server/, after sourcing ../.keys/test.env)
//
// All rows it creates carry a 'test-' external_id / 'test-' workflow ids /
// 'TEST —' program names so they can be swept after a run.
import { createClient } from "@supabase/supabase-js";

function env(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`${name} not set — source .keys/test.env first`);
  return v;
}

const sb = createClient(env("BACKBONE_URL"), env("BACKBONE_ANON_KEY"), {
  auth: { persistSession: false },
});
const DAO = env("BACKBONE_DAO_KEY");
const COWORK = env("BACKBONE_COWORK_KEY");
const RUN = Date.now().toString(36);

async function rpcAs(key: string | null, fn: string, args: Record<string, unknown> = {}) {
  const params = key ? { p_agent_key: key, ...args } : args;
  const { data, error } = await sb.rpc(fn, params);
  if (error) throw new Error(error.message);
  return data;
}

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(`assertion failed: ${msg}`);
}

async function expectError(p: Promise<unknown>, match: string) {
  try {
    await p;
  } catch (e) {
    const m = (e as Error).message;
    assert(m.includes(match), `expected error containing "${match}", got: ${m}`);
    return m;
  }
  throw new Error(`expected an error containing "${match}", but the call succeeded`);
}

const results: { name: string; pass: boolean; detail?: string }[] = [];
async function test(name: string, fn: () => Promise<void>) {
  try {
    await fn();
    results.push({ name, pass: true });
    console.log(`PASS  ${name}`);
  } catch (e) {
    results.push({ name, pass: false, detail: (e as Error).message });
    console.log(`FAIL  ${name}\n      ${(e as Error).message}`);
  }
}

function mkTask(over: Record<string, unknown> = {}) {
  return {
    type: "analysis",
    deliverable_spec: `TEST harness task (run ${RUN})`,
    output_location: "thread",
    priority: "low",
    ...over,
  };
}

const DRIVE_URL = "https://docs.google.com/document/d/test-harness-doc/edit";

// ---------------------------------------------------------------------------

await test("1. claim race — exactly one of two simultaneous claims wins", async () => {
  const t = await rpcAs(DAO, "task_create", { p_task: mkTask({ external_id: `test-race-${RUN}` }) });
  const id = t.task.id;
  const [a, b] = await Promise.all([
    rpcAs(DAO, "task_claim", { p_task_id: id }),
    rpcAs(COWORK, "task_claim", { p_task_id: id }),
  ]);
  const winners = [a, b].filter((r) => r.claimed === true);
  const losers = [a, b].filter((r) => r.claimed !== true);
  assert(winners.length === 1, `expected exactly 1 winner, got ${winners.length}`);
  assert(losers.length === 1, "expected exactly 1 loser");
  assert(losers[0].owner, "loser response must name the owner");
  assert(losers[0].lease_expires_at, "loser response must include lease expiry");
  assert(String(losers[0].message).includes("Do not build"), "loser must be told not to build");
});

await test("2. Exit Gate — local path rejected with corrective message, Drive URL passes", async () => {
  const t = await rpcAs(DAO, "task_create", {
    p_task: mkTask({ external_id: `test-gate-${RUN}`, output_location: "drive", type: "document" }),
  });
  const id = t.task.id;
  const claim = await rpcAs(COWORK, "task_claim", { p_task_id: id });
  assert(claim.claimed === true, "cowork must be able to claim");
  await expectError(
    rpcAs(COWORK, "task_complete", { p_task_id: id, p_drive_url: "/sessions/abc/deliverable.docx" }),
    "Local paths are invisible to DAO and Jack",
  );
  await expectError(
    rpcAs(COWORK, "task_complete", { p_task_id: id, p_drive_url: "https://example.com/file.docx" }),
    "Cowork-Shared drive",
  );
  const done = await rpcAs(COWORK, "task_complete", { p_task_id: id, p_drive_url: DRIVE_URL });
  assert(done.completed === true, "completion with Drive URL must succeed");
  const full = await rpcAs(DAO, "task_get", { p_task_id: id });
  assert(full.deliverables.length === 1, "deliverable row must exist");
  assert(
    full.timeline.some((e: { verb: string }) => e.verb === "task.completed"),
    "task.completed event must exist",
  );
});

await test("3. idempotent dispatch — same external_id twice yields one row", async () => {
  const ext = `test-idem-${RUN}`;
  const first = await rpcAs(DAO, "task_create", { p_task: mkTask({ external_id: ext }) });
  const second = await rpcAs(DAO, "task_create", { p_task: mkTask({ external_id: ext }) });
  assert(first.existing === false, "first call creates");
  assert(second.existing === true, "second call returns existing");
  assert(first.task.id === second.task.id, "both calls must return the same task id");
});

await test("4. duplicate trigger — same idempotency_key yields one event", async () => {
  const key = `test-trigger-${RUN}`;
  const a = await rpcAs(DAO, "event_append", {
    p_verb: "trigger.test", p_object_type: "test", p_object_id: RUN, p_idempotency_key: key,
  });
  const b = await rpcAs(DAO, "event_append", {
    p_verb: "trigger.test", p_object_type: "test", p_object_id: RUN, p_idempotency_key: key,
  });
  assert(a.duplicate === false, "first append is not a duplicate");
  assert(b.duplicate === true, "second append is flagged duplicate");
  assert(a.event_id === b.event_id, "both return the same event id");
});

await test("5. SLA — breach escalates; double-resolve is a no-op with notice", async () => {
  const t = await rpcAs(DAO, "task_create", { p_task: mkTask({ external_id: `test-sla-${RUN}` }) });
  const d = await rpcAs(DAO, "decision_open", {
    p_question: `TEST ${RUN}: approve the harness artifact?`,
    p_approver: "jack", p_blocking_task_id: t.task.id, p_sla_hours: 0,
  });
  const blocked = await rpcAs(DAO, "task_get", { p_task_id: t.task.id });
  assert(blocked.task.state === "blocked", "blocking task must move to blocked");
  await rpcAs(null, "sla_check");
  const board = await rpcAs(DAO, "board_query");
  const mine = (board.decisions_by_approver.jack ?? []).find(
    (x: { id: string }) => x.id === d.decision_id,
  );
  assert(mine, "decision must appear in jack's queue");
  assert(mine.escalated === true, "decision past SLA must be escalated");
  const r1 = await rpcAs(DAO, "decision_resolve", {
    p_decision_id: d.decision_id, p_resolution: "approved", p_resolved_by: "jack",
  });
  assert(r1.resolved === true, "first resolve succeeds");
  const after = await rpcAs(DAO, "task_get", { p_task_id: t.task.id });
  assert(after.task.state === "ready", "blocked task must unblock to ready");
  const r2 = await rpcAs(DAO, "decision_resolve", {
    p_decision_id: d.decision_id, p_resolution: "approved again",
  });
  assert(r2.resolved === false && String(r2.notice).includes("already resolved"),
    "second resolve must be a no-op with notice");
});

await test("5b. resolve after supersession — no-op-with-notice on the unblock", async () => {
  const t = await rpcAs(DAO, "task_create", { p_task: mkTask({ external_id: `test-sup-res-${RUN}` }) });
  const d = await rpcAs(DAO, "decision_open", {
    p_question: `TEST ${RUN}: decision whose task gets superseded`,
    p_approver: "jack", p_blocking_task_id: t.task.id,
  });
  await rpcAs(DAO, "task_supersede", { p_old_task_id: t.task.id });
  const r = await rpcAs(DAO, "decision_resolve", {
    p_decision_id: d.decision_id, p_resolution: "moot",
  });
  assert(r.resolved === true && String(r.notice ?? "").includes("superseded"),
    "resolution lands with a superseded notice, never an error");
});

await test("6. lease expiry — task returns to ready and emits the event", async () => {
  const t = await rpcAs(DAO, "task_create", { p_task: mkTask({ external_id: `test-lease-${RUN}` }) });
  const id = t.task.id;
  const c = await rpcAs(COWORK, "task_claim", { p_task_id: id, p_ttl_minutes: 0 });
  assert(c.claimed === true, "claim with 0-minute TTL succeeds");
  await new Promise((r) => setTimeout(r, 1100));
  await rpcAs(DAO, "board_query"); // board_query sweeps expired leases
  const after = await rpcAs(DAO, "task_get", { p_task_id: id });
  assert(after.task.claimed_by === null, "expired lease must be cleared");
  assert(after.task.state === "ready", "task must be back in ready");
  assert(
    after.timeline.some((e: { verb: string }) => e.verb === "task.lease_expired"),
    "task.lease_expired event must exist",
  );
  const re = await rpcAs(DAO, "task_claim", { p_task_id: id });
  assert(re.claimed === true, "task must be claimable again after expiry");
});

await test("7. workflow validation — illegal transition lists legal next states", async () => {
  await rpcAs(DAO, "workflow_define", {
    p_id: `test-ai-sales-${RUN}`,
    p_states: ["discovery", "demo", "proposal", "closed"],
    p_transitions: { discovery: ["demo"], demo: ["proposal"], proposal: ["closed"], closed: [] },
  });
  await rpcAs(DAO, "workflow_define", {
    p_id: `test-engagement-${RUN}`,
    p_states: ["compiled", "released", "in_review", "approved", "done"],
    p_transitions: { compiled: ["released"], released: ["in_review"], in_review: ["approved"], approved: ["done"], done: [] },
  });
  const t = await rpcAs(DAO, "task_create", {
    p_task: mkTask({ external_id: `test-wf-${RUN}`, workflow_id: `test-ai-sales-${RUN}` }),
  });
  assert(t.task.state === "discovery", "initial state is the workflow's first state");
  const msg = await expectError(
    rpcAs(DAO, "task_transition", { p_task_id: t.task.id, p_to_state: "proposal" }),
    "Legal next states",
  );
  assert(msg!.includes("demo"), "error must list the legal next state");
  const ok = await rpcAs(DAO, "task_transition", { p_task_id: t.task.id, p_to_state: "demo" });
  assert(ok.state === "demo", "legal transition succeeds");
  // engagement workflow validated independently
  const e = await rpcAs(DAO, "task_create", {
    p_task: mkTask({ external_id: `test-wf-eng-${RUN}`, workflow_id: `test-engagement-${RUN}` }),
  });
  await expectError(
    rpcAs(DAO, "task_transition", { p_task_id: e.task.id, p_to_state: "approved" }),
    "Legal next states",
  );
});

await test("10. DS-158 replay — supersession + claims, one build, one rejection, no HOLD", async () => {
  // Two dispatches of the same deliverable: the second arrives as a supersession.
  const t1 = await rpcAs(DAO, "task_create", {
    p_task: mkTask({
      external_id: `test-ds158-${RUN}`, type: "document", output_location: "drive",
      deliverable_spec: `TEST DS-158 one-pager v1 (run ${RUN})`,
    }),
  });
  const c1 = await rpcAs(COWORK, "task_claim", { p_task_id: t1.task.id });
  assert(c1.claimed === true, "cowork claims v1");
  const sup = await rpcAs(DAO, "task_supersede", {
    p_old_task_id: t1.task.id,
    p_overrides: { deliverable_spec: `TEST DS-158 one-pager v2 — corrected scope (run ${RUN})` },
  });
  assert(sup.prior_claimant === "cowork", "supersession must report the released claimant");
  const old = await rpcAs(DAO, "task_get", { p_task_id: t1.task.id });
  assert(old.task.claimed_by === null, "old claim must be released");
  assert(old.task.superseded_by === sup.new_task_id, "old task must point at its replacement");
  const oldClaim = await rpcAs(COWORK, "task_claim", { p_task_id: t1.task.id });
  assert(oldClaim.claimed === false && oldClaim.reason === "superseded",
    "old task must refuse claims and point to the replacement");
  const c2 = await rpcAs(COWORK, "task_claim", { p_task_id: sup.new_task_id });
  assert(c2.claimed === true, "cowork claims the replacement — one claim");
  const rejected = await rpcAs(DAO, "task_claim", { p_task_id: sup.new_task_id });
  assert(rejected.claimed === false && rejected.owner === "cowork",
    "second claim is rejected naming the owner — one rejection, never a HOLD");
  const done = await rpcAs(COWORK, "task_complete", { p_task_id: sup.new_task_id, p_drive_url: DRIVE_URL });
  assert(done.completed === true, "one build ships");
  const head = await rpcAs(DAO, "task_get", { p_task_id: sup.new_task_id });
  assert(head.deliverables.length === 1, "exactly one deliverable on the chain head");
});

await test("11. fourth-program stub — campaign program with own workflow, zero schema changes", async () => {
  const wf = await rpcAs(DAO, "workflow_define", {
    p_id: `test-campaign-wf-${RUN}`,
    p_states: ["queued", "drafted", "brand_review", "scheduled", "published"],
    p_transitions: {
      queued: ["drafted"], drafted: ["brand_review"], brand_review: ["scheduled", "drafted"],
      scheduled: ["published"], published: [],
    },
  });
  const prog = await rpcAs(DAO, "program_create", {
    p_program: {
      type: "campaign", name: `TEST — Q3 brand campaign (run ${RUN})`,
      workflow_id: `test-campaign-wf-${RUN}`, owner_human: "jack",
      config: { calendar_batching: "weekly", brand_review_gate: true, wip_limit: 5 },
    },
  });
  const t = await rpcAs(DAO, "task_create", {
    p_task: mkTask({
      external_id: `test-campaign-task-${RUN}`,
      workflow_id: `test-campaign-wf-${RUN}`, program_id: prog.program_id,
    }),
  });
  assert(t.task.state === "queued", "campaign task starts in the campaign workflow");
  const q = await rpcAs(DAO, "program_query", { p_program_id: prog.program_id });
  assert(q.program.config.brand_review_gate === true, "governor config readable as data");
  assert(q.tasks_by_state.queued.length === 1, "program_query groups its tasks");
  void wf;
});

await test("9 (partial). cron drift — silent cron flagged, heartbeat clears it, unknown id instructs", async () => {
  const cronId = `test-drift-${RUN}`;
  await rpcAs(COWORK, "cron_register", {
    p_cron_id: cronId, p_schedule: "0 */4 * * *", p_expected_interval_minutes: 240,
  });
  const board = await rpcAs(DAO, "board_query");
  const drift = board.cron_health.find((c: { id: string }) => c.id === cronId);
  assert(drift, "registered cron must appear in health strip");
  assert(["never_ran", "late"].includes(drift.health), "silent cron must be flagged");
  await rpcAs(COWORK, "cron_heartbeat", { p_cron_id: cronId, p_note: `harness run ${RUN}` });
  const board2 = await rpcAs(DAO, "board_query");
  const drift2 = board2.cron_health.find((c: { id: string }) => c.id === cronId);
  assert(drift2.health === "ok", "heartbeat must clear the flag");
  await expectError(
    rpcAs(COWORK, "cron_heartbeat", { p_cron_id: `test-ghost-${RUN}` }),
    "cron_register",
  );
});

await test("extra. capability suggestions — gaps advise but do not block claims", async () => {
  const t = await rpcAs(DAO, "task_create", {
    p_task: mkTask({ external_id: `test-cap-${RUN}`, required_capabilities: ["docx"] }),
  });
  const ok = await rpcAs(DAO, "task_claim", { p_task_id: t.task.id }); // dao lacks docx
  assert(ok.claimed === true, "capability suggestions must not block an otherwise valid claim");
  assert(ok.advisory.capability_gaps.includes("docx"), "claim response must surface missing suggestions");
  assert(String(ok.advisory.message).includes("not claim requirements"),
    "advisory message must explain that gaps are not authorization gates");
  await rpcAs(DAO, "task_release", { p_task_id: t.task.id });
});

await test("extra. requests — open/fulfill round-trip with no human gate", async () => {
  const r = await rpcAs(COWORK, "request_open", {
    p_type: "data_query", p_request: `TEST ${RUN}: ICP score for Bridge Housing`,
    p_fulfiller: "dao",
  });
  const f = await rpcAs(DAO, "request_fulfill", {
    p_request_id: r.request_id, p_payload: { icp_score: 8.2 },
  });
  assert(f.fulfilled === true && f.requester === "cowork", "fulfillment closes the loop");
  const again = await rpcAs(DAO, "request_fulfill", { p_request_id: r.request_id });
  assert(again.fulfilled === false, "double-fulfill is a no-op with notice");
});

// ---------------------------------------------------------------------------
const failed = results.filter((r) => !r.pass);
console.log(`\n${results.length - failed.length}/${results.length} passed`);
if (failed.length) process.exit(1);
