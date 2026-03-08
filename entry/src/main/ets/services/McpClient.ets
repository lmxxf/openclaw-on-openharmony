// MCP Client — Streamable HTTP Transport
// Standard MCP client for connecting to external MCP Servers
// Protocol: https://modelcontextprotocol.io/specification/2025-03-26/basic/transports

import { http } from '@kit.NetworkKit'
import { Logger } from '../utils/Logger'
import { ToolDefinition } from '../models/Types'

// ============================================================
// Types
// ============================================================

export interface McpServerConfig {
  name: string
  url: string
}

interface McpRemoteTool {
  name: string
  description: string
  inputSchema: Record<string, Object>
}

interface McpJsonRpcResponse {
  jsonrpc: string
  id?: number
  result?: Record<string, Object>
  error?: McpJsonRpcError
}

interface McpJsonRpcError {
  code: number
  message: string
}

interface McpContentItem {
  type: string
  text: string
}

interface McpServerState {
  config: McpServerConfig
  sessionId: string
  tools: McpRemoteTool[]
  ready: boolean
  error: string
}

interface PostResult {
  body: string
  sessionId: string
}

// JSON-RPC request body types (for ArkTS typed object literals)
interface JsonRpcToolCallParams {
  name: string
  arguments: Record<string, Object>
}

interface JsonRpcToolCallRequest {
  jsonrpc: string
  id: number
  method: string
  params: JsonRpcToolCallParams
}

interface McpClientInfo {
  name: string
  version: string
}

interface McpInitializeParams {
  protocolVersion: string
  capabilities: Record<string, Object>
  clientInfo: McpClientInfo
}

interface JsonRpcInitRequest {
  jsonrpc: string
  id: number
  method: string
  params: McpInitializeParams
}

interface JsonRpcNotification {
  jsonrpc: string
  method: string
}

interface JsonRpcSimpleRequest {
  jsonrpc: string
  id: number
  method: string
}

// ============================================================
// McpClient
// ============================================================

export class McpClient {
  private servers: McpServerState[] = []
  private requestId: number = 0

  private nextId(): number {
    this.requestId++
    return this.requestId
  }

  // --------------------------------------------------------
  // Public API
  // --------------------------------------------------------

  async initAll(configs: McpServerConfig[]): Promise<void> {
    this.servers = []
    const promises: Promise<void>[] = []
    for (const cfg of configs) {
      promises.push(this.initServer(cfg))
    }
    await Promise.all(promises)
    const readyCount = this.servers.filter(s => s.ready).length
    Logger.info(`[McpClient] initAll done: ${readyCount}/${this.servers.length} servers ready`)
  }

  getAllRemoteToolsAsOpenAi(): ToolDefinition[] {
    const result: ToolDefinition[] = []
    for (const server of this.servers) {
      if (!server.ready) {
        continue
      }
      for (const tool of server.tools) {
        const def: ToolDefinition = {
          type: 'function',
          function: {
            name: tool.name,
            description: tool.description + ' [via ' + server.config.name + ']',
            parameters: tool.inputSchema
          }
        }
        result.push(def)
      }
    }
    return result
  }

  buildToolRouteMap(): Map<string, number> {
    const map = new Map<string, number>()
    for (let i = 0; i < this.servers.length; i++) {
      const server = this.servers[i]
      if (!server.ready) {
        continue
      }
      for (const tool of server.tools) {
        if (!map.has(tool.name)) {
          map.set(tool.name, i)
        }
      }
    }
    return map
  }

  async callTool(serverIndex: number, toolName: string, argsJson: string): Promise<string> {
    if (serverIndex < 0 || serverIndex >= this.servers.length) {
      return 'Invalid server index: ' + serverIndex
    }
    const server = this.servers[serverIndex]
    if (!server.ready) {
      return 'MCP Server unavailable: ' + server.config.name
    }

    let args: Record<string, Object> = {}
    try {
      args = JSON.parse(argsJson) as Record<string, Object>
    } catch (e) {
      return 'Args parse failed: ' + argsJson
    }

    try {
      const result = await this.callToolInner(server, toolName, args)
      return result
    } catch (e) {
      // Session may have expired, retry after re-init
      Logger.info('[McpClient] callTool failed, retrying after re-init: ' + server.config.name)
      try {
        await this.initServer(server.config)
        const newServer = this.servers[this.servers.length - 1]
        if (newServer && newServer.ready) {
          this.servers[serverIndex] = newServer
          this.servers.pop()
          return await this.callToolInner(this.servers[serverIndex], toolName, args)
        }
      } catch (e2) {
        // retry also failed
      }
      return 'Remote tool call failed: ' + JSON.stringify(e)
    }
  }

  getReadyServerCount(): number {
    return this.servers.filter(s => s.ready).length
  }

  // --------------------------------------------------------
  // Internal
  // --------------------------------------------------------

  private async callToolInner(server: McpServerState, toolName: string, args: Record<string, Object>): Promise<string> {
    const params: JsonRpcToolCallParams = {
      name: toolName,
      arguments: args
    }
    const request: JsonRpcToolCallRequest = {
      jsonrpc: '2.0',
      id: this.nextId(),
      method: 'tools/call',
      params: params
    }
    const body = JSON.stringify(request)

    const responseStr = await this.postJsonRpc(server.config.url, server.sessionId, body)
    const response = this.parseJsonRpcResponse(responseStr)

    if (response.error) {
      return 'Tool error: ' + response.error.message
    }

    if (response.result) {
      const callResult = response.result as Record<string, Object>
      const content = callResult['content'] as McpContentItem[]
      if (content && content.length > 0) {
        const texts: string[] = []
        for (const item of content) {
          if (item.text) {
            texts.push(item.text)
          }
        }
        return texts.join('\n')
      }
      return JSON.stringify(response.result)
    }

    return 'No result returned'
  }

  private async initServer(config: McpServerConfig): Promise<void> {
    const state: McpServerState = {
      config: config,
      sessionId: '',
      tools: [],
      ready: false,
      error: ''
    }

    try {
      Logger.info('[McpClient] Initializing server: ' + config.name + ' at ' + config.url)

      // Step 1: initialize
      const clientInfo: McpClientInfo = { name: 'OHClaw', version: '1.0.0' }
      const initParams: McpInitializeParams = {
        protocolVersion: '2025-03-26',
        capabilities: {},
        clientInfo: clientInfo
      }
      const initRequest: JsonRpcInitRequest = {
        jsonrpc: '2.0',
        id: this.nextId(),
        method: 'initialize',
        params: initParams
      }
      const initBody = JSON.stringify(initRequest)

      const initResult = await this.postJsonRpcWithHeaders(config.url, '', initBody)
      state.sessionId = initResult.sessionId

      const initResponse = this.parseJsonRpcResponse(initResult.body)
      if (initResponse.error) {
        throw new Error('initialize failed: ' + initResponse.error.message)
      }

      Logger.info('[McpClient] Server initialized: ' + config.name + ', sessionId: ' + state.sessionId)

      // Step 2: notifications/initialized
      const notification: JsonRpcNotification = {
        jsonrpc: '2.0',
        method: 'notifications/initialized'
      }
      const notifyBody = JSON.stringify(notification)
      await this.postJsonRpc(config.url, state.sessionId, notifyBody)

      // Step 3: tools/list
      const toolsRequest: JsonRpcSimpleRequest = {
        jsonrpc: '2.0',
        id: this.nextId(),
        method: 'tools/list'
      }
      const toolsBody = JSON.stringify(toolsRequest)

      const toolsResponseStr = await this.postJsonRpc(config.url, state.sessionId, toolsBody)
      const toolsResponse = this.parseJsonRpcResponse(toolsResponseStr)

      if (toolsResponse.error) {
        throw new Error('tools/list failed: ' + toolsResponse.error.message)
      }

      if (toolsResponse.result) {
        const toolsResult = toolsResponse.result as Record<string, Object>
        const tools = toolsResult['tools'] as McpRemoteTool[]
        if (tools) {
          state.tools = tools
        }
      }

      state.ready = true
      Logger.info('[McpClient] Server ready: ' + config.name + ', tools: ' + state.tools.length)

      for (const tool of state.tools) {
        Logger.info('[McpClient]   - ' + tool.name + ': ' + tool.description)
      }

    } catch (e) {
      state.error = JSON.stringify(e)
      state.ready = false
      Logger.error('[McpClient] Failed to init server ' + config.name + ': ' + state.error)
    }

    this.servers.push(state)
  }

  // --------------------------------------------------------
  // HTTP layer
  // --------------------------------------------------------

  private async postJsonRpc(url: string, sessionId: string, bodyStr: string): Promise<string> {
    const result = await this.postJsonRpcWithHeaders(url, sessionId, bodyStr)
    return result.body
  }

  private async postJsonRpcWithHeaders(url: string, sessionId: string, bodyStr: string): Promise<PostResult> {
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/event-stream'
    }
    if (sessionId.length > 0) {
      headers['Mcp-Session-Id'] = sessionId
    }

    Logger.info('[McpClient] POST ' + url + ' body: ' + bodyStr.substring(0, 150))

    const httpRequest = http.createHttp()
    try {
      const response = await httpRequest.request(url, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: bodyStr,
        readTimeout: 15000,
        connectTimeout: 10000,
        expectDataType: http.HttpDataType.STRING
      })

      const responseBody = (response.result || '') as string
      const responseHeaders = response.header as Record<string, string>

      let extractedSessionId = ''
      if (responseHeaders) {
        for (const key of Object.keys(responseHeaders)) {
          if (key.toLowerCase() === 'mcp-session-id') {
            extractedSessionId = responseHeaders[key]
            break
          }
        }
      }

      Logger.info('[McpClient] Response (' + response.responseCode + '): ' + responseBody.substring(0, 200))

      httpRequest.destroy()
      const postResult: PostResult = { body: responseBody, sessionId: extractedSessionId }
      return postResult
    } catch (e) {
      httpRequest.destroy()
      throw e as Error
    }
  }

  private parseJsonRpcResponse(responseStr: string): McpJsonRpcResponse {
    let jsonStr = responseStr.trim()

    // SSE compatibility: extract data: line
    if (jsonStr.startsWith('data:') || jsonStr.startsWith('event:') || jsonStr.startsWith('id:')) {
      const lines = jsonStr.split('\n')
      for (const line of lines) {
        if (line.startsWith('data:')) {
          const dataContent = line.slice(5).trim()
          if (dataContent.length > 0 && dataContent !== '[DONE]') {
            jsonStr = dataContent
            break
          }
        }
      }
    }

    if (jsonStr.length === 0) {
      const empty: McpJsonRpcResponse = { jsonrpc: '2.0' }
      return empty
    }

    try {
      return JSON.parse(jsonStr) as McpJsonRpcResponse
    } catch (e) {
      Logger.error('[McpClient] Failed to parse response: ' + jsonStr.substring(0, 200))
      const errResp: McpJsonRpcResponse = {
        jsonrpc: '2.0',
        error: { code: -1, message: 'JSON parse error' }
      }
      return errResp
    }
  }
}
