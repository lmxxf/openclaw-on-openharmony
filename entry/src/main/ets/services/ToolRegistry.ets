// Tool registration and dispatch
import { ToolDefinition, ToolFunction, ToolResult } from '../models/Types'
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
    const fn: ToolFunction = {
      name,
      description,
      parameters
    }
    const def: ToolDefinition = {
      type: 'function',
      function: fn
    }
    const registered: RegisteredTool = {
      definition: def,
      executor
    }
    this.tools.set(name, registered)
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
      const errResult: ToolResult = {
        toolCallId,
        content: `Error: unknown tool "${name}"`,
        isError: true
      }
      return errResult
    }

    try {
      const input = JSON.parse(inputJson) as Record<string, Object>
      Logger.info(`Executing tool: ${name}`)
      const resultStr = await tool.executor(input)
      const okResult: ToolResult = {
        toolCallId,
        content: resultStr,
        isError: false
      }
      return okResult
    } catch (e) {
      const errorMsg = (e as Error).message || String(e)
      Logger.error(`Tool ${name} failed: ${errorMsg}`)
      const failResult: ToolResult = {
        toolCallId,
        content: `Error: ${errorMsg}`,
        isError: true
      }
      return failResult
    }
  }
}
