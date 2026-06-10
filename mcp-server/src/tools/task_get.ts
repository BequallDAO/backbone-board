import { z } from "zod";
import type { ToolDef } from "../types.js";

export const tool: ToolDef = {
  name: "task_get",
  description:
    "Fetch one task in full: every field, its deliverables, linked decisions, and the " +
    "complete event timeline (claims, transitions, supersessions, completion).",
  schema: {
    task_id: z.string().uuid(),
  },
};
