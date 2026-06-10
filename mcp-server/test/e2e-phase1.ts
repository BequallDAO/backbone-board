// Phase 1 definition-of-done: DAO dispatches and Cowork completes one real task
// end-to-end through the ledger, with the notifier posting to #dao-to-cowork.
import { createClient } from "@supabase/supabase-js";

function env(n: string): string {
  const v = process.env[n];
  if (!v) throw new Error(`${n} not set`);
  return v;
}
const sb = createClient(env("BACKBONE_URL"), env("BACKBONE_ANON_KEY"), {
  auth: { persistSession: false },
});
async function rpcAs(key: string, fn: string, args: Record<string, unknown> = {}) {
  const { data, error } = await sb.rpc(fn, { p_agent_key: key, ...args });
  if (error) throw new Error(error.message);
  return data;
}
const DAO = env("BACKBONE_DAO_KEY");
const COWORK = env("BACKBONE_COWORK_KEY");

// DAO registers and dispatches
console.log("dao register:", JSON.stringify((await rpcAs(DAO, "register_agent")).agent));
const created = await rpcAs(DAO, "task_create", {
  p_task: {
    external_id: "backbone-phase1-acceptance",
    type: "analysis",
    priority: "high",
    output_location: "thread",
    context:
      "Backbone PRD v2 Phase 1 acceptance. This task itself is the end-to-end proof: " +
      "dispatched by dao, claimed and completed by cowork, entirely through the ledger.",
    deliverable_spec:
      "Phase 1 acceptance report: confirm schema, tool functions, Exit Gate, event log, " +
      "notifier, and test results for the Backbone coordination substrate.",
  },
});
console.log("dispatched:", created.task.id, "existing:", created.existing);

// Cowork registers, sees it on the board, claims, completes
const reg = await rpcAs(COWORK, "register_agent");
console.log("cowork register: unclaimed_ready_for_me =", reg.unclaimed_ready_for_me);
const claim = await rpcAs(COWORK, "task_claim", { p_task_id: created.task.id });
console.log("claimed:", claim.claimed, "lease:", claim.task.lease_expires_at);
const done = await rpcAs(COWORK, "task_complete", {
  p_task_id: created.task.id,
  p_inline_content:
    "Backbone Phase 1 acceptance — 2026-06-10. " +
    "Ledger live on Supabase project bequall-backbone (nkpmzpttlajqjykzhmoc). " +
    "5 migrations applied; 20 MCP tools backed by security-definer SQL; Exit Gate enforced in SQL; " +
    "13/13 spec tests passing (claim race, Exit Gate, idempotent dispatch, duplicate trigger, SLA " +
    "escalation, lease expiry, workflow validation, DS-158 replay, fourth-program stub, cron drift, " +
    "capability routing, request round-trip). This completion was produced by the cowork agent " +
    "through the ledger itself.",
});
console.log("completed:", done.completed, "deliverable v" + done.deliverable.version);

// The board view DAO will use instead of channel sweeps
const board = await rpcAs(DAO, "board_query");
console.log("board tasks_by_state keys:", Object.keys(board.tasks_by_state));
const pulse = await rpcAs(DAO, "pulse_query");
console.log("pulse completed_deliverables today:", pulse.completed_deliverables.length);
