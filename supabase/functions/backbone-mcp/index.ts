// Backbone hosted MCP proxy.
// Public TLS is provided by Supabase Edge Functions. This proxy is the security
// boundary for Notion Custom Agents: bearer auth, per-token rate limits, request
// size limits, explicit tool allowlist, audit events, and an ingest route with
// signature + replay checks for the later webhook fallback.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

type JsonRpcRequest = {
  jsonrpc?: string;
  id?: string | number | null;
  method?: string;
  params?: Record<string, unknown>;
};

type TokenEntry = {
  agent: string;
  agent_key: string;
  token?: string;
  token_sha256?: string;
  revoked?: boolean;
  expires_at?: string;
  rate_limit_per_minute?: number;
};

type Caller = {
  agent: string;
  agentKey: string;
  tokenHash: string;
  rateLimitPerMinute: number;
};

const VERSION = "0.1.0-bld601";
const MAX_BYTES = Number(Deno.env.get("BACKBONE_MCP_MAX_BYTES") ?? 65_536);
const DEFAULT_RATE_LIMIT = Number(Deno.env.get("BACKBONE_MCP_RATE_PER_MINUTE") ?? 60);
const REPLAY_WINDOW_SECONDS = Number(Deno.env.get("BACKBONE_INGEST_REPLAY_WINDOW_SECONDS") ?? 300);

const svc = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);
const api = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_ANON_KEY")!,
);

let confCache: { at: number; conf: Record<string, string> } | null = null;

const TOOL_DEFS = [
  {
    name: "board_query",
    description:
      "Canonical Backbone read: tasks grouped by state, unclaimed queue, Jack decisions, open requests, cron health, and active programs.",
    inputSchema: { type: "object", additionalProperties: false, properties: {} },
  },
  {
    name: "pulse_query",
    description: "Read Backbone events and completed deliverables for a date range.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {
        from: { type: "string", description: "ISO timestamp, default start of today" },
        to: { type: "string", description: "ISO timestamp, default now" },
      },
    },
  },
  {
    name: "task_create",
    description: "Originate machine-side work into the Backbone ledger. Idempotent on external_id.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["deliverable_spec", "type"],
      properties: {
        deliverable_spec: { type: "string" },
        type: {
          type: "string",
          enum: ["document", "email", "analysis", "research", "sequence", "proposal", "other"],
        },
        priority: { type: "string", enum: ["urgent", "high", "medium", "low"] },
        external_id: { type: "string" },
        program_id: { type: "string" },
        workflow_id: { type: "string" },
        workflow_version: { type: "integer" },
        deadline: { type: "string" },
        context: { type: "string" },
        data_intel: { type: "string" },
        wiki_page: { type: "string" },
        reference_docs: { type: "array", items: { type: "string" } },
        output_location: { type: "string", enum: ["drive", "workspace", "thread"] },
        drive_folder: { type: "string" },
        skill_route: { type: "string" },
        voice_rules: { type: "string" },
        required_capabilities: { type: "array", items: { type: "string" } },
      },
    },
  },
  {
    name: "request_open",
    description: "Open an agent-to-agent data request, usually to DAO.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["type", "request"],
      properties: {
        type: { type: "string" },
        request: { type: "string" },
        context: { type: "string" },
        fulfiller: { type: "string" },
        requires_approval: { type: "boolean" },
      },
    },
  },
  {
    name: "decision_open",
    description: "Open a human decision queue item and optionally block a task.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["question", "approver"],
      properties: {
        question: { type: "string" },
        approver: { type: "string" },
        options: {
          type: "array",
          items: {
            type: "object",
            additionalProperties: false,
            required: ["label"],
            properties: {
              label: { type: "string" },
              description: { type: "string" },
            },
          },
        },
        default_action: { type: "string" },
        blocking_task_id: { type: "string" },
        artifact_url: { type: "string" },
        sla_hours: { type: "integer" },
      },
    },
  },
  {
    name: "event_append",
    description: "Append a custom idempotent Backbone event.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["verb", "object_type", "object_id"],
      properties: {
        verb: { type: "string" },
        object_type: { type: "string" },
        object_id: { type: "string" },
        payload: { type: "object" },
        significance: { type: "string", enum: ["major", "standard", "routine"] },
        idempotency_key: { type: "string" },
      },
    },
  },
] as const;

const ALLOWED_TOOLS = new Set(TOOL_DEFS.map((tool) => tool.name));

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);
  const path = normalizePath(url.pathname);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });

  if (path === "/healthz") {
    return json({
      ok: true,
      service: "backbone-mcp",
      version: VERSION,
      allowed_tools: [...ALLOWED_TOOLS],
      configured_tokens: (await tokenRegistry()).length,
      timestamp: new Date().toISOString(),
    });
  }

  if (path === "/handoff-ingest") {
    return handoffIngest(req);
  }

  if (path !== "/" && path !== "/mcp") {
    return json({ error: "not found" }, 404);
  }

  if (req.method === "GET") {
    return json({
      service: "backbone-mcp",
      transport: "streamable-http",
      endpoint: "/mcp",
      health: "/healthz",
      version: VERSION,
    });
  }

  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const sized = await readSizedBody(req);
  if (!sized.ok) return json({ error: sized.error }, sized.status);

  const caller = await authenticate(req);
  if (!caller.ok) return json({ error: caller.error }, caller.status);

  const limited = await takeRateLimit(caller.caller);
  if (!limited.ok) return json({ error: "rate limited" }, 429);

  let payload: unknown;
  try {
    payload = JSON.parse(sized.body);
  } catch {
    return json({ error: "bad json" }, 400);
  }

  const session = req.headers.get("mcp-session-id") ?? crypto.randomUUID();
  const requests = Array.isArray(payload) ? payload : [payload];
  const responses = [];
  for (const item of requests) {
    const result = await handleJsonRpc(item as JsonRpcRequest, caller.caller, session);
    if (result !== null) responses.push(result);
  }

  if (responses.length === 0) return new Response(null, { status: 202, headers: CORS });
  return json(Array.isArray(payload) ? responses : responses[0], 200, { "Mcp-Session-Id": session });
});

async function handleJsonRpc(req: JsonRpcRequest, caller: Caller, session: string): Promise<unknown | null> {
  const id = req.id ?? null;
  const method = String(req.method ?? "");

  try {
    switch (method) {
      case "initialize":
        await audit(caller, "initialize", "ok", { session });
        return rpcResult(id, {
          protocolVersion: "2025-03-26",
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: "backbone", version: VERSION },
        });
      case "notifications/initialized":
        await audit(caller, method, "ok", { session });
        return null;
      case "ping":
        await audit(caller, method, "ok", { session });
        return rpcResult(id, {});
      case "tools/list":
        await audit(caller, method, "ok", { session, tool_count: TOOL_DEFS.length });
        return rpcResult(id, { tools: TOOL_DEFS });
      case "tools/call": {
        const name = String(req.params?.name ?? "");
        const args = (req.params?.arguments ?? {}) as Record<string, unknown>;
        if (!ALLOWED_TOOLS.has(name)) {
          await audit(caller, name, "denied", { session, reason: "tool_not_allowed" });
          return rpcResult(id, {
            content: [{ type: "text", text: `Backbone policy error: tool ${name} is not exposed.` }],
            isError: true,
          });
        }
        const started = Date.now();
        const data = await callBackboneTool(caller, name, args);
        await audit(caller, name, "ok", { session, latency_ms: Date.now() - started });
        return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] });
      }
      default:
        await audit(caller, method || "unknown", "denied", { session, reason: "unknown_method" });
        return rpcError(id, -32601, "method not found");
    }
  } catch (e) {
    await audit(caller, method || "unknown", "error", { session, error: (e as Error).message });
    return rpcResult(id, {
      content: [{ type: "text", text: `Backbone: ${(e as Error).message}` }],
      isError: true,
    });
  }
}

async function callBackboneTool(caller: Caller, name: string, args: Record<string, unknown>) {
  if (name === "task_create") {
    return rpc("task_create", { p_agent_key: caller.agentKey, p_task: scrubUndefined(args) });
  }
  return rpc(name, { p_agent_key: caller.agentKey, ...prefixArgs(args) });
}

async function handoffIngest(req: Request): Promise<Response> {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  const sized = await readSizedBody(req);
  if (!sized.ok) return json({ error: sized.error }, sized.status);

  const caller = await authenticate(req);
  if (!caller.ok) return json({ error: caller.error }, caller.status);

  const secret = Deno.env.get("BACKBONE_INGEST_SECRET");
  if (!secret) return json({ error: "handoff ingest secret not configured" }, 503);

  const timestamp = req.headers.get("x-backbone-timestamp") ?? "";
  const signature = req.headers.get("x-backbone-signature") ?? "";
  if (!timestamp || !signature) return json({ error: "missing replay headers" }, 401);

  let payload: Record<string, unknown>;
  try {
    payload = JSON.parse(sized.body);
  } catch {
    return json({ error: "bad json" }, 400);
  }
  const idempotencyKey =
    req.headers.get("x-backbone-idempotency-key") ??
    String(payload.page_id ?? payload.handoff_page_id ?? "");
  if (!idempotencyKey) return json({ error: "missing handoff page id" }, 401);

  const age = Math.abs(Date.now() / 1000 - Number(timestamp));
  if (!Number.isFinite(age) || age > REPLAY_WINDOW_SECONDS) return json({ error: "stale timestamp" }, 401);

  const expected = await hmacSha256Hex(secret, `${timestamp}.${sized.body}`);
  if (!constantTimeEqual(signature.replace(/^sha256=/, ""), expected)) return json({ error: "bad signature" }, 401);

  const event = await rpc("event_append", {
    p_agent_key: caller.caller.agentKey,
    p_verb: "handoff.ingest.received",
    p_object_type: "handoff",
    p_object_id: String(payload.page_id ?? idempotencyKey),
    p_payload: payload,
    p_significance: "standard",
    p_idempotency_key: `handoff-ingest:${idempotencyKey}`,
  });

  return json({ accepted: true, replay_protected: true, event });
}

async function authenticate(req: Request): Promise<
  | { ok: true; caller: Caller }
  | { ok: false; status: number; error: string }
> {
  const bearer = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!bearer) return { ok: false, status: 401, error: "missing bearer token" };

  const incomingHash = await sha256Hex(bearer);
  const now = Date.now();
  for (const entry of await tokenRegistry()) {
    const tokenHash = entry.token_sha256 ?? (entry.token ? await sha256Hex(entry.token) : "");
    if (!tokenHash || tokenHash !== incomingHash) continue;
    if (entry.revoked) return { ok: false, status: 401, error: "token revoked" };
    if (entry.expires_at && Date.parse(entry.expires_at) <= now) {
      return { ok: false, status: 401, error: "token expired" };
    }
    return {
      ok: true,
      caller: {
        agent: entry.agent,
        agentKey: entry.agent_key,
        tokenHash,
        rateLimitPerMinute: entry.rate_limit_per_minute ?? DEFAULT_RATE_LIMIT,
      },
    };
  }
  return { ok: false, status: 401, error: "invalid bearer token" };
}

async function tokenRegistry(): Promise<TokenEntry[]> {
  const fromEnv = Deno.env.get("BACKBONE_MCP_TOKENS");
  if (fromEnv) return JSON.parse(fromEnv) as TokenEntry[];

  const conf = await config();
  return Object.entries(conf)
    .filter(([key]) => key.startsWith("mcp_proxy_token_"))
    .map(([, value]) => JSON.parse(value) as TokenEntry);
}

async function config(): Promise<Record<string, string>> {
  if (confCache && Date.now() - confCache.at < 60_000) return confCache.conf;
  const { data, error } = await svc.from("app_config").select("key,value");
  if (error) throw new Error(error.message);
  const conf = Object.fromEntries((data ?? []).map((row) => [row.key, row.value]));
  confCache = { at: Date.now(), conf };
  return conf;
}

async function rpc(fn: string, args: Record<string, unknown>) {
  const { data, error } = await api.rpc(fn, scrubUndefined(args));
  if (error) throw new Error(error.message);
  return data;
}

async function audit(caller: Caller, tool: string, result: string, payload: Record<string, unknown>) {
  try {
    await rpc("event_append", {
      p_agent_key: caller.agentKey,
      p_verb: "mcp_proxy.call",
      p_object_type: "mcp_proxy",
      p_object_id: tool,
      p_payload: { agent: caller.agent, tool, result, ...payload },
      p_significance: result === "ok" ? "routine" : "standard",
      p_idempotency_key: `mcp-proxy:${crypto.randomUUID()}`,
    });
  } catch {
    // Audit failure must not turn a successful read into a client-visible outage.
  }
}

function prefixArgs(args: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(args)) {
    if (value !== undefined) out[`p_${key}`] = value;
  }
  return out;
}

function scrubUndefined(args: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(args)) {
    if (value !== undefined) out[key] = value;
  }
  return out;
}

async function readSizedBody(req: Request): Promise<
  | { ok: true; body: string }
  | { ok: false; status: number; error: string }
> {
  const header = Number(req.headers.get("content-length") ?? 0);
  if (header > MAX_BYTES) return { ok: false, status: 413, error: "request too large" };
  const body = await req.text();
  if (new TextEncoder().encode(body).byteLength > MAX_BYTES) {
    return { ok: false, status: 413, error: "request too large" };
  }
  return { ok: true, body };
}

async function takeRateLimit(caller: Caller): Promise<{ ok: boolean }> {
  const capacity = Math.max(1, caller.rateLimitPerMinute);
  const { data, error } = await api.rpc("mcp_proxy_rate_limit_acquire", {
    p_agent_key: caller.agentKey,
    p_bucket_key: `mcp:${caller.tokenHash}`,
    p_capacity: capacity,
    p_refill_per_second: capacity / 60,
    p_request_count: 1,
  });
  if (error) throw new Error(error.message);
  return { ok: data?.granted === true };
}

function rpcResult(id: string | number | null, result: unknown) {
  return { jsonrpc: "2.0", id, result };
}

function rpcError(id: string | number | null, code: number, message: string) {
  return { jsonrpc: "2.0", id, error: { code, message } };
}

async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return hex(digest);
}

async function hmacSha256Hex(secret: string, payload: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return hex(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(payload)));
}

function hex(buffer: ArrayBuffer): string {
  return [...new Uint8Array(buffer)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function json(value: unknown, status = 200, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { ...CORS, "Content-Type": "application/json", ...extraHeaders },
  });
}

const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "content-type, authorization, mcp-session-id, x-backbone-signature, x-backbone-timestamp, x-backbone-idempotency-key",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

function normalizePath(pathname: string): string {
  const functionPath = "/backbone-mcp";
  if (pathname === functionPath || pathname === functionPath + "/") return "/";
  if (pathname.startsWith(functionPath + "/")) return pathname.slice(functionPath.length);
  const prefix = "/functions/v1/backbone-mcp";
  if (pathname === prefix) return "/";
  if (pathname === prefix + "/") return "/";
  if (pathname.startsWith(prefix + "/")) return pathname.slice(prefix.length);
  return pathname;
}
