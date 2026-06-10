import { z } from "zod";
import type { ToolDef } from "../types.js";

export const tool: ToolDef = {
  name: "register_agent",
  description:
    "Register or heartbeat this agent with Backbone. Returns your identity, capabilities, " +
    "tasks you currently hold, and counts of unclaimed work matching your capabilities. " +
    "Call once at session start.",
  schema: {
    capabilities: z
      .array(z.string())
      .optional()
      .describe("Replace this agent's capability list (omit to keep current)"),
  },
};
