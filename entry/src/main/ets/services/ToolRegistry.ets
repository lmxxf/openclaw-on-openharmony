// Tool registration and dispatch
import { ToolDefinition, ToolResult } from '../models/Types'
import { Logger } from '../utils/Logger'

export type ToolExecutor = (input: Record<string, Object>) => Promise<string>

interface RegisteredTool {
  definition: ToolDefinition
  executor: ToolExecutor
}

export class ToolRegistry {
  private tools: Map<string, RegisteredTool> = new Map()

  registerTool(
    name: string,
    description: string,
    parameters: Record<string, Object>,
    executor: ToolExecutor
  ): void {
    this.tools.set(name, {
      definition: {
        type: 'function',
        function: {
          name,
          description,
          parameters
        }
      },
      executor
    })
    Logger.info(`Tool registered: ${name}`)
  }

  getToolDefinitions(): ToolDefinition[] {
    const defs: ToolDefinition[] = []
    this.tools.forEach((tool) => {
      defs.push(tool.definition)
    })
    return defs
  }

  async executeTool(name: string, inputJson: string, toolCallId: string): Promise<ToolResult> {
    const tool = this.tools.get(name)
    if (!tool) {
      Logger.warn(`Unknown tool: ${name}`)
      return {
        toolCallId,
        content: `Error: unknown tool "${name}"`,
        isError: true
      }
    }

    try {
      const input = JSON.parse(inputJson) as Record<string, Object>
      Logger.info(`Executing tool: ${name}`)
      const result = await tool.executor(input)
      return {
        toolCallId,
        content: result,
        isError: false
      }
    } catch (e) {
      const errorMsg = (e as Error).message || String(e)
      Logger.error(`Tool ${name} failed: ${errorMsg}`)
      return {
        toolCallId,
        content: `Error: ${errorMsg}`,
        isError: true
      }
    }
  }
}
