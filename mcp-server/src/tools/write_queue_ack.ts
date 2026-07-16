import { z } from "zod";
import type { ToolDef } from "../types.js";

export const tool: ToolDef = {
  name: "write_queue_ack",
  description:
    "Acknowledge a queued write leased by this agent after the downstream write has completed. " +
    "Only the current lease holder can ack.",
  schema: {
    item_id: z.string().uuid(),
    result: z.record(z.unknown()).optional().describe("Downstream write result/proof"),
  },
};
