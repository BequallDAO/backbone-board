import { z } from "zod";
import type { ToolDef } from "../types.js";

export const tool: ToolDef = {
  name: "write_queue_retry",
  description:
    "Return a leased queued write to the queue with the next backoff, or dead-letter it to the " +
    "exception queue once its retry budget is exhausted.",
  schema: {
    item_id: z.string().uuid(),
    error: z.string().min(1),
  },
};
