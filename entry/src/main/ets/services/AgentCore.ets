// AgentCore - The ReAct loop with MCP + RAG
// Replaces NanoClaw's container-runner + agent-runner
// Direct HTTP API calls to DeepSeek with tool_use support
import { Logger } from '../utils/Logger'
import { generateId } from '../utils/TextFormatter'
import { ApiClient } from './ApiClient'
import { ToolRegistry } from './ToolRegistry'
import { dbService } from './DatabaseService'
import { configService } from './ConfigService'
import { McpClient, McpServerConfig } from './McpClient'
import { VectorRagService, VectorRagConfig, KbChunkInput } from './VectorRagService'
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
  ToolCallRecord,
  ToolDefinition,
  ToolResult
} from '../models/Types'
import { common } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'

const MAX_ITERATIONS = 15
const CONTEXT_WINDOW = 50

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

interface ScoredText {
  text: string
  score: number
}

// Knowledge base chunk (loaded from rawfile)
interface KbDoc {
  id: string
  file: string
  title: string
  keywords: string[]
}

interface KbIndex {
  documents: KbDoc[]
}

// Skill (slash command) types
interface SkillDefinition {
  name: string
  command: string
  description: string
  prompt: string
}

interface SkillIndexEntry {
  file: string
}

interface SkillIndex {
  skills: SkillIndexEntry[]
}

export class AgentCore {
  private apiClient: ApiClient | null = null
  private toolRegistry: ToolRegistry = new ToolRegistry()
  private initialized: boolean = false

  // MCP
  private mcpClient: McpClient = new McpClient()
  private remoteToolRouteMap: Map<string, number> = new Map()

  // RAG
  private vectorRagService: VectorRagService = new VectorRagService()
  private knowledgeChunks: KbChunkInput[] = []

  // Skills
  private skills: SkillDefinition[] = []

  // Context for RAG init
  private appContext: common.UIAbilityContext | null = null

  async init(filesDir: string, context?: common.UIAbilityContext): Promise<void> {
    if (this.initialized) return

    if (context) {
      this.appContext = context
    }

    // Initialize tool dependencies
    initFileTools(filesDir)
    initMemoryTools(filesDir)

    // Register all local tools
    registerFileTools(this.toolRegistry)
    registerMemoryTools(this.toolRegistry)
    registerWebTools(this.toolRegistry)
    registerTaskTools(this.toolRegistry)

    this.initialized = true
    Logger.info('AgentCore initialized')

    // Async init MCP + RAG (non-blocking)
    this.initMcpAndRag()
  }

  private async initMcpAndRag(): Promise<void> {
    try {
      await this.initMcp()
    } catch (e) {
      Logger.error('MCP init failed: ' + JSON.stringify(e))
    }
    try {
      await this.initRag()
    } catch (e) {
      Logger.error('RAG init failed: ' + JSON.stringify(e))
    }
    try {
      await this.loadSkills()
    } catch (e) {
      Logger.error('Skills load failed: ' + JSON.stringify(e))
    }
  }

  private async initMcp(): Promise<void> {
    const mcpJson = await configService.getMcpServers()
    let configs: McpServerConfig[] = []
    try {
      configs = JSON.parse(mcpJson) as McpServerConfig[]
    } catch (e) {
      return
    }
    if (configs.length === 0) {
      Logger.info('No MCP servers configured')
      return
    }

    Logger.info(`Initializing ${configs.length} MCP server(s)...`)
    await this.mcpClient.initAll(configs)
    this.remoteToolRouteMap = this.mcpClient.buildToolRouteMap()
    Logger.info(`MCP ready: ${this.mcpClient.getReadyServerCount()} server(s), ${this.remoteToolRouteMap.size} remote tool(s)`)
  }

  private async initRag(): Promise<void> {
    if (!this.appContext) {
      Logger.info('No app context, skip RAG init')
      return
    }

    // Load knowledge base from rawfile
    await this.loadKnowledgeBase()

    if (this.knowledgeChunks.length === 0) {
      Logger.info('No knowledge chunks, skip RAG init')
      return
    }

    const sfApiKey = await configService.getSiliconFlowApiKey()
    const sfApiUrl = await configService.getSiliconFlowApiUrl()
    const embModel = await configService.getEmbeddingModel()

    const ragConfig: VectorRagConfig = {
      apiKey: sfApiKey,
      apiUrl: sfApiUrl,
      model: embModel
    }

    await this.vectorRagService.init(this.appContext, ragConfig)

    // Build index async
    if (this.vectorRagService.getStatus() !== 'fallback') {
      this.vectorRagService.buildIndex(this.knowledgeChunks)
        .then((ok) => {
          Logger.info('RAG index build result: ' + ok)
        })
        .catch((e: Error) => {
          Logger.error('RAG index build error: ' + e.message)
        })
    }
  }

  private async loadKnowledgeBase(): Promise<void> {
    if (!this.appContext) return

    try {
      const resourceManager = this.appContext.resourceManager
      const indexBytes = await resourceManager.getRawFileContent('knowledge/kb_index.json')
      const indexStr = this.uint8ArrayToString(indexBytes)
      const kbIndex = JSON.parse(indexStr) as KbIndex

      const chunks: KbChunkInput[] = []
      for (const doc of kbIndex.documents) {
        try {
          const fileBytes = await resourceManager.getRawFileContent(doc.file)
          const text = this.uint8ArrayToString(fileBytes)

          // Split into paragraphs as chunks
          const paragraphs = text.split('\n\n').filter(p => p.trim().length > 0)
          for (const para of paragraphs) {
            const chunk: KbChunkInput = {
              docId: doc.id,
              text: para.trim(),
              keywords: doc.keywords
            }
            chunks.push(chunk)
          }
        } catch (e) {
          Logger.error('Failed to load knowledge file: ' + doc.file)
        }
      }

      this.knowledgeChunks = chunks
      Logger.info('Loaded ' + chunks.length + ' knowledge chunks from ' + kbIndex.documents.length + ' documents')
    } catch (e) {
      Logger.error('Failed to load knowledge base index: ' + JSON.stringify(e))
    }
  }

  private async loadSkills(): Promise<void> {
    if (!this.appContext) return

    try {
      const resourceManager = this.appContext.resourceManager
      const indexBytes = await resourceManager.getRawFileContent('skills/skills_index.json')
      const indexStr = this.uint8ArrayToString(indexBytes)
      const skillIndex = JSON.parse(indexStr) as SkillIndex

      const loaded: SkillDefinition[] = []
      for (const entry of skillIndex.skills) {
        try {
          const fileBytes = await resourceManager.getRawFileContent(entry.file)
          const fileStr = this.uint8ArrayToString(fileBytes)
          const skill = JSON.parse(fileStr) as SkillDefinition
          loaded.push(skill)
          Logger.info('Loaded skill: ' + skill.command + ' — ' + skill.description)
        } catch (e) {
          Logger.error('Failed to load skill file: ' + entry.file)
        }
      }

      this.skills = loaded
      Logger.info('Loaded ' + loaded.length + ' skills')
    } catch (e) {
      Logger.error('Failed to load skills index: ' + JSON.stringify(e))
    }
  }

  // Try to match a slash command, returns the expanded prompt or null
  private matchSkill(userMessage: string): string | null {
    const trimmed = userMessage.trim()
    if (!trimmed.startsWith('/')) {
      return null
    }

    // Parse: /command rest of input
    const spaceIdx = trimmed.indexOf(' ')
    let command: string
    let input: string
    if (spaceIdx === -1) {
      command = trimmed
      input = ''
    } else {
      command = trimmed.substring(0, spaceIdx)
      input = trimmed.substring(spaceIdx + 1).trim()
    }

    // Special: /help
    if (command === '/help') {
      return null // handled separately in runAgent
    }

    // Match skill
    for (const skill of this.skills) {
      if (skill.command === command) {
        // Replace {{input}} in prompt template
        const expanded = skill.prompt.replace('{{input}}', input)
        return expanded
      }
    }

    return null // no match
  }

  private getHelpText(): string {
    if (this.skills.length === 0) {
      return 'No skills available.'
    }
    let help = 'Available commands:\n'
    for (const skill of this.skills) {
      help += `  ${skill.command} — ${skill.description}\n`
    }
    help += '  /help — Show this help'
    return help
  }

  private uint8ArrayToString(arr: Uint8Array): string {
    const textDecoder = new util.TextDecoder('utf-8')
    return textDecoder.decodeWithStream(arr)
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

  // Build system prompt with RAG context
  private async buildSystemPrompt(userMessage: string): Promise<string> {
    let prompt = SYSTEM_PROMPT

    // Try vector RAG retrieval
    if (this.vectorRagService.isReady()) {
      try {
        const ragResults = await this.vectorRagService.retrieveByVector(userMessage, 3)
        if (ragResults.length > 0) {
          prompt += '\n\nRelevant knowledge base context:\n'
          for (const chunk of ragResults) {
            prompt += '---\n' + chunk + '\n'
          }
          prompt += '---\nUse the above context to help answer the user\'s question if relevant.'
          return prompt
        }
      } catch (e) {
        Logger.error('Vector RAG retrieval failed: ' + JSON.stringify(e))
      }
    }

    // Fallback: keyword matching
    if (this.knowledgeChunks.length > 0) {
      const relevant = this.keywordRetrieve(userMessage, 3)
      if (relevant.length > 0) {
        prompt += '\n\nRelevant knowledge base context:\n'
        for (const chunk of relevant) {
          prompt += '---\n' + chunk + '\n'
        }
        prompt += '---\nUse the above context to help answer the user\'s question if relevant.'
      }
    }

    return prompt
  }

  private keywordRetrieve(query: string, topK: number): string[] {
    const queryLower = query.toLowerCase()
    const scored: ScoredText[] = []

    for (const chunk of this.knowledgeChunks) {
      let score = 0
      for (const kw of chunk.keywords) {
        if (queryLower.includes(kw.toLowerCase())) {
          score += 1
        }
      }
      // Also check if query words appear in chunk text
      const words = queryLower.split(/\s+/)
      for (const word of words) {
        if (word.length >= 2 && chunk.text.toLowerCase().includes(word)) {
          score += 0.5
        }
      }
      if (score > 0) {
        const item: ScoredText = { text: chunk.text, score: score }
        scored.push(item)
      }
    }

    scored.sort((a, b) => b.score - a.score)
    return scored.slice(0, topK).map(s => s.text)
  }

  // Check if a tool name is local (registered in ToolRegistry)
  private isLocalTool(name: string): boolean {
    const localTools = this.toolRegistry.getToolDefinitions()
    for (const t of localTools) {
      if (t.function.name === name) {
        return true
      }
    }
    return false
  }

  async runAgent(
    userMessage: string,
    chatId: string,
    onEvent: (event: AgentEvent) => void
  ): Promise<void> {
    try {
      const client = await this.ensureApiClient()
      setTaskChatId(chatId)

      // Skill interception: /help returns help text directly
      if (userMessage.trim() === '/help') {
        const helpText = this.getHelpText()
        const textEvent: AgentTextEvent = { type: 'text', content: helpText }
        onEvent(textEvent)
        const doneEvent: AgentDoneEvent = { type: 'done' }
        onEvent(doneEvent)
        return
      }

      // Skill interception: /command → expand prompt template
      const skillPrompt = this.matchSkill(userMessage)
      const effectiveMessage = skillPrompt !== null ? skillPrompt : userMessage

      // Ensure chat exists
      await dbService.ensureChat(chatId, 'Chat')

      // Store user message (original, not expanded)
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

      // Build system prompt with RAG (use effective message for RAG retrieval)
      const systemPrompt = await this.buildSystemPrompt(effectiveMessage)
      const sysMsg: ApiMessage = { role: 'system', content: systemPrompt }
      const apiMessages: ApiMessage[] = [sysMsg]

      // Add history (replace last user message with effectiveMessage if skill was matched)
      for (let i = 0; i < history.length; i++) {
        const msg = history[i]
        if (msg.isFromMe) {
          // If this is the last message and a skill was matched, use expanded prompt
          const isLast = i === history.length - 1
          const content = (isLast && skillPrompt !== null) ? effectiveMessage : msg.content
          const uMsg: ApiMessage = { role: 'user', content: content }
          apiMessages.push(uMsg)
        } else {
          const aMsg: ApiMessage = { role: 'assistant', content: msg.content }
          apiMessages.push(aMsg)
        }
      }

      // Merge local + remote tools
      const localTools = this.toolRegistry.getToolDefinitions()
      const remoteTools = this.mcpClient.getAllRemoteToolsAsOpenAi()
      const allTools: ToolDefinition[] = [...localTools, ...remoteTools]

      // ReAct loop
      let iterations = 0
      const allToolRecords: ToolCallRecord[] = []

      while (iterations < MAX_ITERATIONS) {
        iterations++
        Logger.info(`ReAct iteration ${iterations}/${MAX_ITERATIONS}`)

        const response = await client.sendMessage(apiMessages, allTools)
        const choice = response.choices[0]
        const assistantMessage = choice.message

        Logger.info(`finish_reason: ${choice.finishReason}, tokens: ${response.usage.totalTokens}`)

        // Check if model wants to call tools
        if (choice.finishReason === 'tool_calls' && assistantMessage.toolCalls) {
          const assistApiMsg: ApiMessage = {
            role: 'assistant',
            content: assistantMessage.content,
            toolCalls: assistantMessage.toolCalls
          }
          apiMessages.push(assistApiMsg)

          // Execute each tool call
          for (const toolCall of assistantMessage.toolCalls) {
            const toolName = toolCall.function.name
            Logger.info(`Tool call: ${toolName}`)

            let result: ToolResult

            if (this.isLocalTool(toolName)) {
              // Local tool
              result = await this.toolRegistry.executeTool(
                toolName,
                toolCall.function.arguments,
                toolCall.id
              )
            } else if (this.remoteToolRouteMap.has(toolName)) {
              // Remote MCP tool
              const serverIdx = this.remoteToolRouteMap.get(toolName)!
              const mcpResult = await this.mcpClient.callTool(serverIdx, toolName, toolCall.function.arguments)
              result = {
                toolCallId: toolCall.id,
                content: mcpResult,
                isError: false
              }
            } else {
              result = {
                toolCallId: toolCall.id,
                content: `Error: unknown tool "${toolName}"`,
                isError: true
              }
            }

            // Report tool use to UI
            const toolEvent: AgentToolUseEvent = {
              type: 'tool_use',
              name: toolName,
              input: toolCall.function.arguments,
              result: result.content,
              isError: result.isError
            }
            onEvent(toolEvent)

            // Record for storage
            const record: ToolCallRecord = {
              name: toolName,
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

          continue
        }

        // Model is done
        const textContent = assistantMessage.content || ''

        if (textContent) {
          const textEvent: AgentTextEvent = { type: 'text', content: textContent }
          onEvent(textEvent)
        }

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
