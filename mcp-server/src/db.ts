// Single source of database access. Every tool call goes through rpc(), which
// injects this agent's key; all semantics live in the security-definer SQL
// functions (supabase/migrations/0003_functions.sql).
import { createClient, type SupabaseClient } from "@supabase/supabase-js";

function env(name: string): string {
  const v = process.env[name];
  if (!v) {
    throw new Error(
      `${name} is not set. The backbone MCP server needs BACKBONE_URL, BACKBONE_ANON_KEY, ` +
        `and BACKBONE_AGENT_KEY in its environment — see bequall-backbone/README.md.`,
    );
  }
  return v;
}

let client: SupabaseClient | null = null;

function getClient(): SupabaseClient {
  if (!client) {
    client = createClient(env("BACKBONE_URL"), env("BACKBONE_ANON_KEY"), {
      auth: { persistSession: false },
    });
  }
  return client;
}

export async function rpc(
  fn: string,
  args: Record<string, unknown> = {},
  withKey = true,
): Promise<unknown> {
  const params: Record<string, unknown> = withKey
    ? { p_agent_key: env("BACKBONE_AGENT_KEY"), ...args }
    : { ...args };
  for (const k of Object.keys(params)) {
    if (params[k] === undefined) delete params[k];
  }
  const { data, error } = await getClient().rpc(fn, params);
  if (error) {
    const hint = error.hint ? `\nHint: ${error.hint}` : "";
    const details = error.details ? `\nDetails: ${error.details}` : "";
    throw new Error(`${error.message}${hint}${details}`);
  }
  return data;
}

/** Prefix every input key with p_ to match the SQL function signatures. */
export function pArgs(input: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(input)) {
    if (v !== undefined) out[`p_${k}`] = v;
  }
  return out;
}
