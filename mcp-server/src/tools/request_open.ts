import { z } from "zod";
import type { ToolDef } from "../types.js";

export const tool: ToolDef = {
  name: "request_open",
  description:
    "Open a data request to another agent (replaces the Slack wait-protocol). Agent-to-agent " +
    "requests flow with no human gate unless requires_approval is true. Types: data_query, " +
    "signal_scan, city_lookup, write_back, wiki_path — or any string for new kinds.",
  schema: {
    type: z.string().describe("data_query | signal_scan | city_lookup | write_back | wiki_path | ..."),
    request: z.string().describe("What you need, specifically"),
    context: z.string().optional().describe("Why you need it / which task it unblocks"),
    fulfiller: z.string().optional().describe("Agent id to route to (usually 'dao'); omit for anyone"),
    requires_approval: z.boolean().optional().describe("Only for flagged-sensitive types"),
  },
};
