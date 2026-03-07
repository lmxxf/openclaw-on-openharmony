// Data interfaces for NanoClaw on OpenHarmony
// Ported from NanoClaw types.ts + DeepSeek API types

// --- Chat & Messages ---

export interface ChatMessage {
  id: string
  chatId: string
  sender: string
  senderName: string
  content: string
  timestamp: string
  isFromMe: boolean
  toolCalls?: ToolCallRecord[]
}

export interface ChatConversation {
  id: string
  name: string
  lastMessageTime: string
  lastMessagePreview: string
}

// --- Agent Tool Use ---

export interface ToolDefinition {
  type: 'function'
  function: ToolFunction
}

export interface ToolFunction {
  name: string
  description: string
  parameters: Record<string, Object>
}

export interface ToolCall {
  id: string
  type: 'function'
  function: ToolCallFunction
}

export interface ToolCallFunction {
  name: string
  arguments: string // JSON string
}

export interface ToolResult {
  toolCallId: string
  content: string
  isError: boolean
}

export interface ToolCallRecord {
  name: string
  input: string
  result: string
  isError: boolean
}

// --- DeepSeek API (OpenAI-compatible) ---

export interface ApiConfig {
  apiKey: string
  baseUrl: string
  model: string
  maxTokens: number
  temperature: number
}

export interface ApiMessage {
  role: 'system' | 'user' | 'assistant' | 'tool'
  content?: string | null
  toolCalls?: ToolCall[]
  toolCallId?: string
}

export interface ApiResponse {
  id: string
  choices: ApiChoice[]
  usage: ApiUsage
}

export interface ApiChoice {
  index: number
  message: ApiMessage
  finishReason: string
}

export interface ApiUsage {
  promptTokens: number
  completionTokens: number
  totalTokens: number
}

// --- Scheduled Tasks ---

export interface ScheduledTask {
  id: string
  chatId: string
  prompt: string
  scheduleType: 'cron' | 'interval' | 'once'
  scheduleValue: string
  nextRun: string | null
  lastRun: string | null
  lastResult: string | null
  status: 'active' | 'paused' | 'completed'
  createdAt: string
}

export interface TaskRunLog {
  taskId: string
  runAt: string
  durationMs: number
  status: 'success' | 'error'
  result: string | null
  error: string | null
}

// --- Agent Events (for UI streaming) ---

export interface AgentTextEvent {
  type: 'text'
  content: string
}

export interface AgentToolUseEvent {
  type: 'tool_use'
  name: string
  input: string
  result: string
  isError: boolean
}

export interface AgentErrorEvent {
  type: 'error'
  error: string
}

export interface AgentDoneEvent {
  type: 'done'
}

export type AgentEvent = AgentTextEvent | AgentToolUseEvent | AgentErrorEvent | AgentDoneEvent
