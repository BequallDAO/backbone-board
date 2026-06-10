import { z } from "zod";
import type { ToolDef } from "../types.js";

export const tool: ToolDef = {
  name: "workflow_define",
  description:
    "Define a workflow state machine as data (no schema change, no code change). The first " +
    "state in states is the initial state for new tasks. Versions are immutable: redefining an " +
    "id creates the next version; in-flight tasks finish on the version they started with.",
  schema: {
    id: z.string().describe("e.g. 'engagement-runtime', 'ai-sales'"),
    states: z.array(z.string()).min(1),
    transitions: z
      .record(z.array(z.string()))
      .describe('{"ready": ["in_production"], "in_production": ["blocked", "done"], ...}'),
    version: z.number().int().positive().optional().describe("Default: next version for this id"),
  },
};
