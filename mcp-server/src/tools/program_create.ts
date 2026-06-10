import { z } from "zod";
import type { ToolDef } from "../types.js";

export const tool: ToolDef = {
  name: "program_create",
  description:
    "Create a program — one running loop (an engagement, a deal, a campaign) that tasks hang " +
    "off. Domain policy (WIP limits, cadence, gates) goes in config as data; governor workers " +
    "read it. Backbone itself never hardcodes domain policy.",
  schema: {
    type: z.string().describe("engagement | ai-deal | modular-deal | campaign | ..."),
    name: z.string().describe("e.g. 'ReNu Housing — Bynum Place'"),
    workflow_id: z.string(),
    workflow_version: z.number().int().positive().optional().describe("Default: latest"),
    config: z.record(z.unknown()).optional().describe("WIP limits, cadence, gates — read by governors"),
    source_ref: z.string().optional().describe("Drive URL of the compiled source of truth"),
    owner_human: z.string().describe("'jack', 'scott', 'kevin'"),
  },
  map: (input) => ({ p_program: input }),
};
