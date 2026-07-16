import { z } from "zod";
import type { ToolDef } from "../types.js";

export const tool: ToolDef = {
  name: "workspace_rate_limit_acquire",
  description:
    "Reserve workspace write budget before a downstream writer runs. Returns a serialized " +
    "retry_after response instead of throwing when the token bucket is over budget.",
  schema: {
    workspace_key: z.string().optional().describe("Default 'notion-workspace'"),
    integration_key: z.string().optional().describe("Default 'default'"),
    request_count: z.number().int().min(1).max(10000).optional().describe("Default 1"),
    now: z.string().datetime().optional().describe("Optional ISO timestamp for deterministic tests"),
  },
};
