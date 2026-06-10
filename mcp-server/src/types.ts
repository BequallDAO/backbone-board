import type { ZodRawShape } from "zod";

export interface ToolDef {
  /** MCP tool name (also the SQL function name unless rpcName overrides). */
  name: string;
  description: string;
  schema: ZodRawShape;
  rpcName?: string;
  /** Map validated input to SQL named args. Default: prefix each key with p_. */
  map?: (input: Record<string, unknown>) => Record<string, unknown>;
}
