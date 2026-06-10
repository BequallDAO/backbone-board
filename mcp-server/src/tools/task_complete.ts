import { z } from "zod";
import type { ToolDef } from "../types.js";

export const tool: ToolDef = {
  name: "task_complete",
  description:
    "Complete a task you hold. Enforces the Exit Gate: local paths (/sessions/, /tmp/, /Users/...) " +
    "are rejected — they are invisible to DAO and Jack. Tasks with output_location 'drive' need a " +
    "docs.google.com / drive.google.com URL in drive_url; 'thread' needs the full deliverable text " +
    "in inline_content; 'workspace' needs a workspace-relative path in inline_content. Records the " +
    "deliverable, marks the task done, and notifies — all atomically.",
  schema: {
    task_id: z.string().uuid(),
    drive_url: z.string().optional().describe("Google Drive/Docs URL of the shipped deliverable"),
    inline_content: z
      .string()
      .optional()
      .describe("Deliverable text (thread tasks) or workspace-relative path (workspace tasks)"),
  },
};
