import { z } from "zod";
import type { ToolDef } from "../types.js";

export const tool: ToolDef = {
  name: "request_fulfill",
  description:
    "Fulfill (or decline) an open data request with a structured payload. The requester is " +
    "notified. Fulfilling an already-closed request is a safe no-op with a notice.",
  schema: {
    request_id: z.string().uuid(),
    payload: z.record(z.unknown()).optional().describe("The answer, as JSON"),
    status: z.enum(["fulfilled", "declined"]).optional().describe("Default: fulfilled"),
  },
};
