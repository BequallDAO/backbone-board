import { z } from "zod";
import type { ToolDef } from "../types.js";

export const tool: ToolDef = {
  name: "decision_resolve",
  description:
    "Resolve an open decision (relaying a human's answer, or acting as the approver's agent). " +
    "Unblocks the linked task automatically. Resolving an already-resolved or superseded " +
    "decision is a safe no-op with a notice, never an error. Pass resolved_by with the human's " +
    "name when relaying their answer.",
  schema: {
    decision_id: z.string().uuid(),
    resolution: z.string().describe("The answer / chosen option"),
    resolved_by: z.string().optional().describe("Human who actually decided (e.g. 'jack')"),
  },
};
