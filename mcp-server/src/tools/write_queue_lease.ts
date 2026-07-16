import { z } from "zod";
import type { ToolDef } from "../types.js";

export const tool: ToolDef = {
  name: "write_queue_lease",
  description:
    "Atomically lease the next ready queued write. Expired leases are returned to the queue first, " +
    "which lets a new process recover unacked writes after a forced restart.",
  schema: {
    queue_name: z.string().optional().describe("Logical queue, default 'default'"),
    lease_seconds: z.number().int().min(0).optional().describe("Default 300"),
  },
};
