// Backbone notifier — turns ledger events into one-line Slack notifications with
// deep links. Slack carries pointers, never state. If SLACK_BOT_TOKEN is not
// configured, the function no-ops (the ledger never depends on Slack).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const DAO_TO_COWORK = "C0AMBL0FPFV"; // dispatches + completions
const COWORK_TO_DAO = "C0AMBL6HW3V"; // data requests
const APPROVER_CHANNELS: Record<string, string> = {
  jack: "D0AG14232FR", // Jack DM
};

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

interface BackboneEvent {
  id: number;
  actor: string;
  verb: string;
  object_type: string;
  object_id: string;
  payload: Record<string, unknown>;
  significance: string;
  ts: string;
}

function short(id: string): string {
  return id.length > 8 ? id.slice(0, 8) : id;
}

function trunc(s: unknown, n = 120): string {
  const t = String(s ?? "");
  return t.length > n ? t.slice(0, n - 1) + "…" : t;
}

function format(e: BackboneEvent, boardUrl: string): { channel: string; text: string } | null {
  const p = e.payload ?? {};
  const link = boardUrl ? ` — ${boardUrl}/task/${e.object_id}` : "";
  const decisionLink = boardUrl ? ` — ${boardUrl}/decisions` : "";
  switch (e.verb) {
    case "task.created":
      return {
        channel: DAO_TO_COWORK,
        text: `📋 New ${p.priority ?? "medium"} ${p.type ?? "task"} [${short(e.object_id)}]: ${trunc(p.deliverable_spec)}${p.deadline ? ` (due ${p.deadline})` : ""} — claim via backbone task_claim${link}`,
      };
    case "task.completed":
      return {
        channel: DAO_TO_COWORK,
        text: `✅ ${e.actor} completed [${short(e.object_id)}] v${p.version ?? 1}: ${trunc(p.deliverable_spec, 90)}${p.drive_url ? ` — ${p.drive_url}` : ""}`,
      };
    case "task.superseded":
      return {
        channel: DAO_TO_COWORK,
        text: `🔁 Task [${short(e.object_id)}] superseded by [${short(String(p.superseded_by ?? ""))}]${p.prior_claimant ? ` — ${p.prior_claimant}: stop work on the old task and re-claim the new one` : ""}${link}`,
      };
    case "decision.opened": {
      const channel = APPROVER_CHANNELS[String(p.approver)] ?? DAO_TO_COWORK;
      return {
        channel,
        text: `🟡 Decision needed (${p.sla_hours ?? 24}h SLA) from ${p.approver}: ${trunc(p.question)}${p.artifact_url ? ` — artifact: ${p.artifact_url}` : ""}${decisionLink}`,
      };
    }
    case "decision.escalated": {
      const channel = APPROVER_CHANNELS[String(p.approver)] ?? DAO_TO_COWORK;
      return {
        channel,
        text: `🔴 SLA breach (${p.age_hours}h old, SLA ${p.sla_hours}h) — ${p.approver}, this decision is blocking work: ${trunc(p.question)}${decisionLink}`,
      };
    }
    case "decision.resolved":
      return {
        channel: DAO_TO_COWORK,
        text: `🟢 Decision [${short(e.object_id)}] resolved by ${p.resolved_by ?? e.actor}: ${trunc(p.resolution)}${p.unblocked_task_id ? ` — task ${short(String(p.unblocked_task_id))} unblocked` : ""}`,
      };
    case "request.opened":
      return {
        channel: COWORK_TO_DAO,
        text: `📨 ${e.actor} requests ${p.type}${p.fulfiller ? ` from ${p.fulfiller}` : ""}: ${trunc(p.request)} — fulfill via backbone request_fulfill ${short(e.object_id)}`,
      };
    case "request.fulfilled":
      return {
        channel: COWORK_TO_DAO,
        text: `📬 Request [${short(e.object_id)}] ${p.status} by ${e.actor} (requester: ${p.requester})`,
      };
    default:
      return null;
  }
}

Deno.serve(async (req: Request) => {
  // Authenticate the caller: the DB trigger sends Bearer <notifier_bearer from app_config>.
  const auth = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: cfg } = await supabase.from("app_config").select("key,value")
    .in("key", ["notifier_bearer", "slack_bot_token", "board_url"]);
  const conf = Object.fromEntries((cfg ?? []).map((r) => [r.key, r.value]));
  if (!conf.notifier_bearer || auth !== conf.notifier_bearer) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401 });
  }

  const token = Deno.env.get("SLACK_BOT_TOKEN") ?? conf.slack_bot_token;
  const event = (await req.json()) as BackboneEvent;
  const msg = format(event, conf.board_url ?? "");
  if (!msg) return new Response(JSON.stringify({ skipped: "verb not notified" }), { status: 200 });
  if (!token) return new Response(JSON.stringify({ skipped: "no slack token configured" }), { status: 200 });

  const res = await fetch("https://slack.com/api/chat.postMessage", {
    method: "POST",
    headers: { "Content-Type": "application/json; charset=utf-8", Authorization: `Bearer ${token}` },
    body: JSON.stringify({ channel: msg.channel, text: msg.text, unfurl_links: false }),
  });
  const body = await res.json();
  return new Response(JSON.stringify({ ok: body.ok, error: body.error ?? null }), { status: 200 });
});
