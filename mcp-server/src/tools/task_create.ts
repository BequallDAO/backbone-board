import { z } from "zod";
import type { ToolDef } from "../types.js";

export const tool: ToolDef = {
  name: "task_create",
  description:
    "Dispatch a task into the Backbone ledger (replaces DAO-TASK Slack messages). " +
    "Idempotent on external_id: re-sending the same external_id returns the existing task " +
    "instead of creating a duplicate. Notifies the channels automatically.",
  schema: {
    deliverable_spec: z.string().describe("Exactly what the finished deliverable must contain"),
    type: z
      .enum(["document", "email", "analysis", "research", "sequence", "proposal", "other"])
      .describe("Task type"),
    priority: z.enum(["urgent", "high", "medium", "low"]).optional(),
    external_id: z.string().optional().describe("Idempotency key for dispatch retries"),
    program_id: z.string().uuid().optional().describe("Program this task belongs to (omit for ad-hoc)"),
    workflow_id: z.string().optional().describe("Workflow state machine (default: 'default')"),
    workflow_version: z.number().int().optional(),
    deadline: z.string().optional().describe("ISO timestamp"),
    context: z.string().optional().describe("Why this task exists, background the builder needs"),
    data_intel: z.string().optional(),
    wiki_page: z.string().optional().describe("Wiki page path for the relevant account/project"),
    reference_docs: z.array(z.string()).optional(),
    output_location: z.enum(["drive", "workspace", "thread"]).optional(),
    drive_folder: z.string().optional(),
    skill_route: z.string().optional(),
    voice_rules: z.string().optional(),
    required_capabilities: z
      .array(z.string())
      .optional()
      .describe("Capabilities the claiming agent must have"),
  },
  map: (input) => ({ p_task: input }),
};
