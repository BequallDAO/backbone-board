import { z } from "zod";
import type { ToolDef } from "../types.js";

export const tool: ToolDef = {
  name: "task_claim",
  description:
    "Atomically claim a task before building it. Exactly one agent can hold a task at a time " +
    "(this is what prevents duplicate builds). If someone else holds it, you get their id and " +
    "lease expiry — do not build; coordinate with the owner. Re-claiming a task you hold renews " +
    "the lease. Claims expire after ttl_minutes (default 240).",
  schema: {
    task_id: z.string().uuid(),
    ttl_minutes: z.number().int().positive().optional().describe("Lease length, default 240"),
  },
};
