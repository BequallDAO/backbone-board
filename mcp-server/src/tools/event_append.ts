import { z } from "zod";
import type { ToolDef } from "../types.js";

export const tool: ToolDef = {
  name: "event_append",
  description:
    "Append a custom event to the ledger (for program triggers and anything the typed tools " +
    "don't cover). Idempotent on idempotency_key: a duplicate key returns the original event " +
    "id with duplicate=true and fires nothing twice. The events log is append-only.",
  schema: {
    verb: z.string().describe("e.g. 'trigger.payment_received'"),
    object_type: z.string(),
    object_id: z.string(),
    payload: z.record(z.unknown()).optional(),
    significance: z.enum(["major", "standard", "routine"]).optional(),
    idempotency_key: z.string().optional().describe("source+event-id for inbound triggers"),
  },
};
