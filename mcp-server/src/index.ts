#!/usr/bin/env node
// Backbone MCP server (stdio). One process per agent: identity comes from
// BACKBONE_AGENT_KEY in the environment; all semantics live in the database.
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { rpc, pArgs } from "./db.js";
import type { ToolDef } from "./types.js";

import { tool as registerAgent } from "./tools/register_agent.js";
import { tool as workflowDefine } from "./tools/workflow_define.js";
import { tool as programCreate } from "./tools/program_create.js";
import { tool as programQuery } from "./tools/program_query.js";
import { tool as taskCreate } from "./tools/task_create.js";
import { tool as taskGet } from "./tools/task_get.js";
import { tool as taskClaim } from "./tools/task_claim.js";
import { tool as taskRelease } from "./tools/task_release.js";
import { tool as taskTransition } from "./tools/task_transition.js";
import { tool as taskComplete } from "./tools/task_complete.js";
import { tool as taskSupersede } from "./tools/task_supersede.js";
import { tool as decisionOpen } from "./tools/decision_open.js";
import { tool as decisionResolve } from "./tools/decision_resolve.js";
import { tool as requestOpen } from "./tools/request_open.js";
import { tool as requestFulfill } from "./tools/request_fulfill.js";
import { tool as cronRegister } from "./tools/cron_register.js";
import { tool as cronHeartbeat } from "./tools/cron_heartbeat.js";
import { tool as boardQuery } from "./tools/board_query.js";
import { tool as pulseQuery } from "./tools/pulse_query.js";
import { tool as eventAppend } from "./tools/event_append.js";
import { tool as writeQueueEnqueue } from "./tools/write_queue_enqueue.js";
import { tool as writeQueueLease } from "./tools/write_queue_lease.js";
import { tool as writeQueueAck } from "./tools/write_queue_ack.js";
import { tool as writeQueueRetry } from "./tools/write_queue_retry.js";
import { tool as writeQueueStatus } from "./tools/write_queue_status.js";
import { tool as workspaceRateLimitAcquire } from "./tools/workspace_rate_limit_acquire.js";
import { tool as workspaceRateLimitStatus } from "./tools/workspace_rate_limit_status.js";

const tools: ToolDef[] = [
  registerAgent,
  boardQuery,
  taskCreate,
  taskGet,
  taskClaim,
  taskRelease,
  taskTransition,
  taskComplete,
  taskSupersede,
  decisionOpen,
  decisionResolve,
  requestOpen,
  requestFulfill,
  cronRegister,
  cronHeartbeat,
  pulseQuery,
  eventAppend,
  writeQueueEnqueue,
  writeQueueLease,
  writeQueueAck,
  writeQueueRetry,
  writeQueueStatus,
  workspaceRateLimitAcquire,
  workspaceRateLimitStatus,
  workflowDefine,
  programCreate,
  programQuery,
];

const server = new McpServer({ name: "backbone", version: "0.1.0" });

for (const def of tools) {
  server.registerTool(
    def.name,
    { description: def.description, inputSchema: def.schema },
    async (input: Record<string, unknown>) => {
      try {
        const args = def.map ? def.map(input) : pArgs(input);
        const data = await rpc(def.rpcName ?? def.name, args);
        return { content: [{ type: "text" as const, text: JSON.stringify(data, null, 2) }] };
      } catch (e) {
        return {
          isError: true,
          content: [{ type: "text" as const, text: `Backbone: ${(e as Error).message}` }],
        };
      }
    },
  );
}

const transport = new StdioServerTransport();
await server.connect(transport);
console.error("backbone-mcp ready");
