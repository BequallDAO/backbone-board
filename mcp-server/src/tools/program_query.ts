import { z } from "zod";
import type { ToolDef } from "../types.js";

export const tool: ToolDef = {
  name: "program_query",
  description:
    "Full program state in one call: the program row + config, its tasks grouped by state " +
    "(chain heads only), open decisions blocking its tasks, and the last 50 events.",
  schema: {
    program_id: z.string().uuid(),
  },
};
