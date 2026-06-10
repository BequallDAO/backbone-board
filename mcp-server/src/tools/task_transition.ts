import { z } from "zod";
import type { ToolDef } from "../types.js";

export const tool: ToolDef = {
  name: "task_transition",
  description:
    "Move a task to another state in its workflow. Transitions are validated against the " +
    "task's pinned workflow version; an illegal move returns the legal next states. " +
    "Use task_complete (not this) to finish a task — completion enforces the Exit Gate.",
  schema: {
    task_id: z.string().uuid(),
    to_state: z.string(),
    note: z.string().optional(),
  },
};
