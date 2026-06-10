import { z } from "zod";
import type { ToolDef } from "../types.js";

export const tool: ToolDef = {
  name: "pulse_query",
  description:
    "Events for a day or range, grouped major/standard/routine, plus completed deliverables in " +
    "the window and everything currently blocked with age. This is the source for pulses and " +
    "digests — no more forensic reconstruction from Slack history.",
  schema: {
    from: z.string().optional().describe("ISO timestamp, default start of today"),
    to: z.string().optional().describe("ISO timestamp, default now"),
  },
};
