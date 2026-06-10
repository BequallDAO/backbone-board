import { z } from "zod";
import type { ToolDef } from "../types.js";

export const tool: ToolDef = {
  name: "decision_open",
  description:
    "Put a question in a human's decision queue (replaces waiting on Slack reactions). If " +
    "blocking_task_id is set, that task moves to 'blocked' and auto-unblocks when the decision " +
    "is resolved. Attach artifact_url to make it a review-queue item. SLA default 24h; breaches " +
    "escalate automatically. Client-facing sends ALWAYS require a decision first — no exceptions.",
  schema: {
    question: z.string().describe("The decision, in one sentence"),
    approver: z.string().describe("Human who decides: 'jack', 'scott', 'kevin'"),
    options: z
      .array(z.object({ label: z.string(), description: z.string().optional() }))
      .optional(),
    default_action: z.string().optional().describe("What happens if nobody decides"),
    blocking_task_id: z.string().uuid().optional(),
    artifact_url: z.string().optional().describe("Drive URL of the artifact under review"),
    sla_hours: z.number().int().positive().optional().describe("Default 24"),
  },
};
