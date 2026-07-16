import { z } from "zod";
import type { ToolDef } from "../types.js";

export const tool: ToolDef = {
  name: "workspace_rate_limit_status",
  description:
    "Inspect the workspace token-bucket limiter, including SLOs, available headroom, reserve, " +
    "and per-integration pacing state displayed on the Backbone ops panel.",
  schema: {
    workspace_key: z.string().optional().describe("Default 'notion-workspace'"),
    integration_key: z.string().optional().describe("Optional integration filter"),
  },
};
