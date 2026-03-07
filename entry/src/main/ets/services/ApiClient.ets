// DeepSeek API client (OpenAI-compatible format)
// Uses @ohos.net.http for HTTP requests
import { http } from '@kit.NetworkKit'
import { Logger } from '../utils/Logger'
import { ApiConfig, ApiMessage, ApiResponse, ApiChoice, ApiUsage, ToolDefinition, ToolCall, ToolCallFunction } from '../models/Types'

interface ApiRequestBody {
  model: string
  messages: ApiRequestMessage[]
  tools?: ApiRequestTool[]
  max_tokens: number
  temperature: number
  stream: boolean
}

interface ApiRequestMessage {
  role: string
  content?: string | null
  tool_calls?: ApiRequestToolCall[]
  tool_call_id?: string
}

interface ApiRequestToolCall {
  id: string
  type: string
  function: ApiRequestFunction
}

interface ApiRequestFunction {
  name: string
  arguments: string
}

interface ApiRequestTool {
  type: string
  function: ApiRequestToolFunction
}

interface ApiRequestToolFunction {
  name: string
  description: string
  parameters: Record<string, Object>
}

interface ApiResponseBody {
  id: string
  choices: ApiResponseChoice[]
  usage: ApiResponseUsage
  error?: ApiResponseError
}

interface ApiResponseChoice {
  index: number
  message: ApiResponseMessage
  finish_reason: string
}

interface ApiResponseMessage {
  role: string
  content: string | null
  tool_calls?: ApiResponseToolCall[]
}

interface ApiResponseToolCall {
  id: string
  type: string
  function: ApiResponseFunction
}

interface ApiResponseFunction {
  name: string
  arguments: string
}

interface ApiResponseUsage {
  prompt_tokens: number
  completion_tokens: number
  total_tokens: number
}

interface ApiResponseError {
  message: string
  type: string
}

export class ApiClient {
  private config: ApiConfig

  constructor(config: ApiConfig) {
    this.config = config
  }

  updateConfig(config: ApiConfig): void {
    this.config = config
  }

  async sendMessage(
    messages: ApiMessage[],
    tools?: ToolDefinition[]
  ): Promise<ApiResponse> {
    const url = `${this.config.baseUrl}/chat/completions`

    // Convert messages to API format (snake_case)
    const apiMessages: ApiRequestMessage[] = []
    for (const m of messages) {
      const msg: ApiRequestMessage = { role: m.role }
      if (m.content !== undefined) msg.content = m.content
      if (m.toolCalls && m.toolCalls.length > 0) {
        const tcList: ApiRequestToolCall[] = []
        for (const tc of m.toolCalls) {
          const fn: ApiRequestFunction = {
            name: tc.function.name,
            arguments: tc.function.arguments
          }
          const reqTc: ApiRequestToolCall = {
            id: tc.id,
            type: tc.type,
            function: fn
          }
          tcList.push(reqTc)
        }
        msg.tool_calls = tcList
      }
      if (m.toolCallId) msg.tool_call_id = m.toolCallId
      apiMessages.push(msg)
    }

    const body: ApiRequestBody = {
      model: this.config.model,
      messages: apiMessages,
      max_tokens: this.config.maxTokens,
      temperature: this.config.temperature,
      stream: false
    }

    if (tools && tools.length > 0) {
      const toolList: ApiRequestTool[] = []
      for (const t of tools) {
        const fn: ApiRequestToolFunction = {
          name: t.function.name,
          description: t.function.description,
          parameters: t.function.parameters
        }
        const reqTool: ApiRequestTool = {
          type: t.type,
          function: fn
        }
        toolList.push(reqTool)
      }
      body.tools = toolList
    }

    const httpRequest = http.createHttp()
    let retries = 0
    const maxRetries = 3

    while (retries <= maxRetries) {
      try {
        Logger.info(`API request: model=${this.config.model}, messages=${messages.length}, tools=${tools?.length ?? 0}`)

        const response = await httpRequest.request(url, {
          method: http.RequestMethod.POST,
          header: {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${this.config.apiKey}`
          },
          extraData: JSON.stringify(body),
          connectTimeout: 30000,
          readTimeout: 120000
        })

        const responseCode = response.responseCode

        if (responseCode === 429) {
          retries++
          if (retries > maxRetries) {
            throw new Error('Rate limited: too many requests')
          }
          const waitMs = Math.pow(2, retries) * 1000
          Logger.warn(`Rate limited, retrying in ${waitMs}ms (attempt ${retries}/${maxRetries})`)
          await new Promise<void>(resolve => setTimeout(resolve, waitMs))
          continue
        }

        if (responseCode !== 200) {
          const errorBody = response.result as string
          throw new Error(`API error ${responseCode}: ${errorBody}`)
        }

        const result = JSON.parse(response.result as string) as ApiResponseBody

        if (result.error) {
          throw new Error(`API error: ${result.error.message}`)
        }

        httpRequest.destroy()

        return this.parseResponse(result)
      } catch (e) {
        if (retries >= maxRetries) {
          httpRequest.destroy()
          throw e as Error
        }
        retries++
        Logger.warn(`API request failed, retrying (attempt ${retries}/${maxRetries}): ${(e as Error).message}`)
        const waitMs = Math.pow(2, retries) * 1000
        await new Promise<void>(resolve => setTimeout(resolve, waitMs))
      }
    }

    httpRequest.destroy()
    throw new Error('API request failed after max retries')
  }

  private parseResponse(body: ApiResponseBody): ApiResponse {
    const choice = body.choices[0]
    const message = choice.message

    let toolCalls: ToolCall[] | undefined
    if (message.tool_calls && message.tool_calls.length > 0) {
      toolCalls = []
      for (const tc of message.tool_calls) {
        const fn: ToolCallFunction = {
          name: tc.function.name,
          arguments: tc.function.arguments
        }
        const toolCall: ToolCall = {
          id: tc.id,
          type: 'function',
          function: fn
        }
        toolCalls.push(toolCall)
      }
    }

    const apiMessage: ApiMessage = {
      role: message.role as ('system' | 'user' | 'assistant' | 'tool'),
      content: message.content,
      toolCalls: toolCalls
    }

    const apiChoice: ApiChoice = {
      index: choice.index,
      message: apiMessage,
      finishReason: choice.finish_reason
    }

    const apiUsage: ApiUsage = {
      promptTokens: body.usage.prompt_tokens,
      completionTokens: body.usage.completion_tokens,
      totalTokens: body.usage.total_tokens
    }

    const apiResponse: ApiResponse = {
      id: body.id,
      choices: [apiChoice],
      usage: apiUsage
    }

    return apiResponse
  }
}
