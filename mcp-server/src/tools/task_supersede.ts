import { z } from "zod";
import type { ToolDef } from "../types.js";

export const tool: ToolDef = {
  name: "task_supersede",
  description:
    "Replace a task with a corrected version (new spec, deadline, or context). The old task is " +
    "closed to claims, any active claim is released, the prior claimant is notified, and a new " +
    "head task is created carrying the old fields merged with your overrides. This is how scope " +
    "changes happen without duplicate builds — never dispatch a parallel copy.",
  schema: {
    old_task_id: z.string().uuid(),
    overrides: z
      .record(z.unknown())
      .optional()
      .describe(
        "Fields to change on the replacement (same field names as task_create, e.g. " +
          '{"deliverable_spec": "...", "deadline": "..."})',
      ),
  },
};
