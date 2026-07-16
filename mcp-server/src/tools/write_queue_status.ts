import { z } from "zod";
import type { ToolDef } from "../types.js";

export const tool: ToolDef = {
  name: "write_queue_status",
  description:
    "Inspect queued write state by item id, idempotency key, or queue summary. Includes exception " +
    "queue rows when inspecting a single item.",
  schema: {
    item_id: z.string().uuid().optional(),
    idempotency_key: z.string().optional(),
    queue_name: z.string().optional(),
  },
};
