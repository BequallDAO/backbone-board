import { z } from "zod";
import type { ToolDef } from "../types.js";

export const tool: ToolDef = {
  name: "task_release",
  description:
    "Release a task you claimed without completing it (you hit a blocker or are handing it off). " +
    "Returns it to the ready pool. If you are blocked on a human, open a decision instead " +
    "(decision_open); if you are blocked on data, open a request (request_open).",
  schema: {
    task_id: z.string().uuid(),
  },
};
