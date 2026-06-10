import { z } from "zod";
import type { ToolDef } from "../types.js";

export const tool: ToolDef = {
  name: "cron_register",
  description:
    "Register (or update) a scheduled job in the cron registry. You become its owner. " +
    "Heartbeats against unregistered crons are rejected, so register before the first run.",
  schema: {
    cron_id: z.string().describe("Stable id, e.g. 'cowork-pulse'"),
    schedule: z.string().describe("Cron expression (documentation only; heartbeats are truth)"),
    expected_interval_minutes: z.number().int().positive(),
  },
};
