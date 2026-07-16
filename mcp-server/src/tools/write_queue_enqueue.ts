import { z } from "zod";
import type { ToolDef } from "../types.js";

export const tool: ToolDef = {
  name: "write_queue_enqueue",
  description:
    "Persist a downstream write request before attempting it. Idempotent by idempotency_key, " +
    "so process restarts and retries do not create duplicate downstream writes. Default retry " +
    "policy is 3 retries with 1m/5m/15m backoff.",
  schema: {
    idempotency_key: z.string().min(1),
    payload: z.record(z.unknown()).describe("Downstream write request as JSON"),
    queue_name: z.string().optional().describe("Logical queue, default 'default'"),
    available_at: z.string().datetime().optional().describe("ISO timestamp when the item becomes leaseable"),
    max_retries: z.number().int().min(0).max(10).optional().describe("Default 3"),
  },
};
