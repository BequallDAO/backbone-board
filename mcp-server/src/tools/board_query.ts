import type { ToolDef } from "../types.js";

export const tool: ToolDef = {
  name: "board_query",
  description:
    "The canonical read — one call replaces a 30-message channel sweep. Returns tasks grouped " +
    "by state (supersession-chain heads only), the unclaimed queue, open decisions per approver " +
    "with age and SLA countdown, open data requests, cron health (expected vs observed), and " +
    "active programs. Also reclaims expired leases. Call this BEFORE creating or claiming work.",
  schema: {},
};
