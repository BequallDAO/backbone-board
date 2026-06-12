// Backbone board — the human surface (PRD §6). One edge function, three views:
//   #decisions  phone-first decision queue, one-tap resolve (THE Jack/Scott surface)
//   #board      tasks by state (chain heads), unclaimed queue, cron health, programs
//   #task/<id>  full event timeline, deliverables, claim history
// Auth: per-human access tokens in app_config (board_token_<human>). The page is a
// static shell; all data flows through POST with the token. Mutations are limited to
// decision_resolve, recorded with the human's name.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const svc = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);
const api = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_ANON_KEY")!,
);

// app_config changes rarely; cache it in the warm instance to avoid one DB
// round-trip per request (token revocation takes effect within a minute).
let confCache: { at: number; conf: Record<string, string> } | null = null;
async function config(): Promise<Record<string, string>> {
  if (confCache && Date.now() - confCache.at < 60_000) return confCache.conf;
  const { data } = await svc.from("app_config").select("key,value");
  const conf = Object.fromEntries((data ?? []).map((r) => [r.key, r.value]));
  confCache = { at: Date.now(), conf };
  return conf;
}

async function rpc(fn: string, args: Record<string, unknown>) {
  const { data, error } = await api.rpc(fn, args);
  if (error) throw new Error(error.message);
  return data;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS });
  }
  if (req.method === "GET") {
    // *.supabase.co refuses to serve HTML (anti-phishing); the shell lives on Pages.
    return new Response(null, {
      status: 302,
      headers: { ...CORS, Location: "https://buildwithbequall.github.io/backbone-board/" },
    });
  }
  if (req.method !== "POST") return new Response("method not allowed", { status: 405, headers: CORS });

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad request" }, 400);
  }

  const conf = await config();
  const token = String(body.token ?? "");
  const human = Object.entries(conf).find(
    ([k, v]) => k.startsWith("board_token_") && v === token && token.length >= 16,
  )?.[0]?.slice("board_token_".length);
  if (!human) return json({ error: "invalid token" }, 401);

  const key = conf.board_agent_key;
  if (!key) return json({ error: "board_agent_key not configured" }, 500);

  try {
    switch (body.action) {
      case "board": {
        const board = await rpc("board_query", { p_agent_key: key });
        return json({ viewer: human, board });
      }
      case "task": {
        const task = await rpc("task_get", { p_agent_key: key, p_task_id: body.task_id });
        return json({ viewer: human, ...task });
      }
      case "pulse": {
        const args: Record<string, unknown> = { p_agent_key: key };
        if (body.from) args.p_from = body.from;
        if (body.to) args.p_to = body.to;
        return json({ viewer: human, pulse: await rpc("pulse_query", args) });
      }
      case "resolve": {
        const result = await rpc("decision_resolve", {
          p_agent_key: key,
          p_decision_id: body.decision_id,
          p_resolution: body.resolution,
          p_resolved_by: human,
        });
        return json({ viewer: human, result });
      }
      default:
        return json({ error: "unknown action" }, 400);
    }
  } catch (e) {
    return json({ error: (e as Error).message }, 422);
  }
});

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

function json(o: unknown, status = 200): Response {
  return new Response(JSON.stringify(o), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

