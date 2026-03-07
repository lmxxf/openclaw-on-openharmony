// AgentCore - The ReAct loop
// Replaces NanoClaw's container-runner + agent-runner
// Direct HTTP API calls to DeepSeek with tool_use support
import { Logger } from '../utils/Logger'
import { generateId } from '../utils/TextFormatter'
import { ApiClient } from './ApiClient'
import { ToolRegistry } from './ToolRegistry'
import { dbService } from './DatabaseService'
import { configService } from './ConfigService'
import { registerFileTools, initFileTools } from '../tools/FileTools'
import { registerMemoryTools, initMemoryTools } from '../tools/MemoryTools'
import { registerWebTools } from '../tools/WebTools'
import { registerTaskTools, setTaskChatId } from '../tools/TaskTools'
import {
  AgentEvent,
  AgentTextEvent,
  AgentToolUseEvent,
  AgentErrorEvent,
  AgentDoneEvent,
  ApiConfig,
  ApiMessage,
  ChatMessage,
  ToolCallRecord
} from '../models/Types'

const MAX_ITERATIONS = 15
const CONTEXT_WINDOW = 50 // max messages to send as context

const SYSTEM_PROMPT = `You are a helpful AI assistant running on an OpenHarmony device.
You have access to tools for file operations, web access, memory management, and task scheduling.

Key capabilities:
- Read and write files in the app sandbox
- Search the web and fetch web pages
- Save and retrieve persistent memory notes (markdown files that survive across conversations)
- Schedule recurring or one-time tasks

Memory guidelines:
- At the start of a conversation, use memory_list and memory_read to recall previous notes.
- When the user shares preferences, important facts, or says "remember this", use memory_write to save it.
- Keep memory notes organized: one topic per file, update existing files rather than creating duplicates.

When using tools, think step by step about what you need to do.
Always respond in the language the user uses.
Be concise and helpful.`

export class AgentCore {
  private apiClient: ApiClient | null = null
  private toolRegistry: ToolRegistry = new ToolRegistry()
  private initialized: boolean = false

  async init(filesDir: string): Promise<void> {
    if (this.initialized) return

    // Initialize tool dependencies
    initFileTools(filesDir)
    initMemoryTools(filesDir)

    // Register all tools
    registerFileTools(this.toolRegistry)
    registerMemoryTools(this.toolRegistry)
    registerWebTools(this.toolRegistry)
    registerTaskTools(this.toolRegistry)

    this.initialized = true
    Logger.info('AgentCore initialized')
  }

  private async ensureApiClient(): Promise<ApiClient> {
    const apiKey = await configService.getApiKey()
    if (!apiKey) {
      throw new Error('API key not configured. Go to Settings to set it up.')
    }

    const config: ApiConfig = {
      apiKey,
      baseUrl: await configService.getBaseUrl(),
      model: await configService.getModel(),
      maxTokens: await configService.getMaxTokens(),
      temperature: await configService.getTemperature()
    }

    if (this.apiClient) {
      this.apiClient.updateConfig(config)
    } else {
      this.apiClient = new ApiClient(config)
    }

    return this.apiClient
  }

  async runAgent(
    userMessage: string,
    chatId: string,
    onEvent: (event: AgentEvent) => void
  ): Promise<void> {
    try {
      const client = await this.ensureApiClient()
      setTaskChatId(chatId)

      // Ensure chat exists
      await dbService.ensureChat(chatId, 'Chat')

      // Store user message
      const userMsg: ChatMessage = {
        id: generateId(),
        chatId,
        sender: 'user',
        senderName: 'User',
        content: userMessage,
        timestamp: new Date().toISOString(),
        isFromMe: true
      }
      await dbService.storeMessage(userMsg)

      // Load conversation history
      const history = await dbService.getMessages(chatId, CONTEXT_WINDOW)

      // Build API messages
      const sysMsg: ApiMessage = { role: 'system', content: SYSTEM_PROMPT }
      const apiMessages: ApiMessage[] = [sysMsg]

      // Add history (convert to API format)
      for (const msg of history) {
        if (msg.isFromMe) {
          const uMsg: ApiMessage = { role: 'user', content: msg.content }
          apiMessages.push(uMsg)
        } else {
          const aMsg: ApiMessage = { role: 'assistant', content: msg.content }
          apiMessages.push(aMsg)
        }
      }

      // ReAct loop
      const tools = this.toolRegistry.getToolDefinitions()
      let iterations = 0
      const allToolRecords: ToolCallRecord[] = []

      while (iterations < MAX_ITERATIONS) {
        iterations++
        Logger.info(`ReAct iteration ${iterations}/${MAX_ITERATIONS}`)

        const response = await client.sendMessage(apiMessages, tools)
        const choice = response.choices[0]
        const assistantMessage = choice.message

        Logger.info(`finish_reason: ${choice.finishReason}, tokens: ${response.usage.totalTokens}`)

        // Check if model wants to call tools
        if (choice.finishReason === 'tool_calls' && assistantMessage.toolCalls) {
          // Append assistant message with tool calls to history
          const assistApiMsg: ApiMessage = {
            role: 'assistant',
            content: assistantMessage.content,
            toolCalls: assistantMessage.toolCalls
          }
          apiMessages.push(assistApiMsg)

          // Execute each tool call
          for (const toolCall of assistantMessage.toolCalls) {
            Logger.info(`Tool call: ${toolCall.function.name}`)

            const result = await this.toolRegistry.executeTool(
              toolCall.function.name,
              toolCall.function.arguments,
              toolCall.id
            )

            // Report tool use to UI
            const toolEvent: AgentToolUseEvent = {
              type: 'tool_use',
              name: toolCall.function.name,
              input: toolCall.function.arguments,
              result: result.content,
              isError: result.isError
            }
            onEvent(toolEvent)

            // Record for storage
            const record: ToolCallRecord = {
              name: toolCall.function.name,
              input: toolCall.function.arguments,
              result: result.content,
              isError: result.isError
            }
            allToolRecords.push(record)

            // Append tool result to history
            const toolMsg: ApiMessage = {
              role: 'tool',
              content: result.content,
              toolCallId: toolCall.id
            }
            apiMessages.push(toolMsg)
          }

          // Continue the loop - model will see tool results
          continue
        }

        // Model is done (stop or end_turn)
        const textContent = assistantMessage.content || ''

        if (textContent) {
          const textEvent: AgentTextEvent = { type: 'text', content: textContent }
          onEvent(textEvent)
        }

        // Store assistant response
        const assistantMsg: ChatMessage = {
          id: generateId(),
          chatId,
          sender: 'assistant',
          senderName: 'Assistant',
          content: textContent,
          timestamp: new Date().toISOString(),
          isFromMe: false,
          toolCalls: allToolRecords.length > 0 ? allToolRecords : undefined
        }
        await dbService.storeMessage(assistantMsg)

        const doneEvent: AgentDoneEvent = { type: 'done' }
        onEvent(doneEvent)
        return
      }

      // Hit max iterations
      const maxIterMsg = `[Reached maximum ${MAX_ITERATIONS} tool call iterations]`
      const maxEvent: AgentTextEvent = { type: 'text', content: maxIterMsg }
      onEvent(maxEvent)

      const overflowMsg: ChatMessage = {
        id: generateId(),
        chatId,
        sender: 'assistant',
        senderName: 'Assistant',
        content: maxIterMsg,
        timestamp: new Date().toISOString(),
        isFromMe: false,
        toolCalls: allToolRecords.length > 0 ? allToolRecords : undefined
      }
      await dbService.storeMessage(overflowMsg)

      const doneEvent2: AgentDoneEvent = { type: 'done' }
      onEvent(doneEvent2)

    } catch (e) {
      const errorMsg = (e as Error).message || String(e)
      Logger.error(`Agent error: ${errorMsg}`)
      const errEvent: AgentErrorEvent = { type: 'error', error: errorMsg }
      onEvent(errEvent)
    }
  }
}

// Singleton
export const agentCore = new AgentCore()
