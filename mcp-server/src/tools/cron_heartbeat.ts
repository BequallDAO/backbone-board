import { z } from "zod";
import type { ToolDef } from "../types.js";

export const tool: ToolDef = {
  name: "cron_heartbeat",
  description:
    "Record that a scheduled job ran (status ok or failed). Call at the end of every cron " +
    "execution — board_query's cron health compares heartbeats against expected intervals, " +
    "which is what makes the registry truth instead of documentation.",
  schema: {
    cron_id: z.string(),
    status: z.enum(["ok", "failed"]).optional().describe("Default: ok"),
    note: z.string().optional(),
  },
};
