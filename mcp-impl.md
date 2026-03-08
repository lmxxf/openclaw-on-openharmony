# MCP Client 技术实现文档

## 1. 概述

MCP（Model Context Protocol）是一种让大语言模型调用外部工具的标准协议。OHClaw 实现了标准 MCP Client（Streamable HTTP Transport），可连接任意 MCP Server，动态获取工具列表，与本地工具合并后一起传给 DeepSeek Function Calling。

## 2. 架构

```
OHClaw (MCP Client)                     远程 MCP Server（高德、天气等）
    |                                     |
    |  1. POST /mcp  initialize          |
    | ----------------------------------> |  JSON-RPC 2.0 握手
    |  <200 OK + protocolVersion>          |
    |                                     |
    |  2. POST /mcp  tools/list          |
    | ----------------------------------> |  获取工具列表
    |  <返回 tools[]>                      |
    |                                     |
    |  ---- 用户发消息 ----                |
    |                                     |
    |  3. DeepSeek 返回 tool_call         |
    |  4. POST /mcp  tools/call          |
    | ----------------------------------> |  执行远程工具
    |  <返回结果>                           |
    |                                     |
    |  5. 结果喂回 DeepSeek               |
```

本地工具（文件/记忆/网页/任务）和远程工具共存。DeepSeek 返回 tool_call 时，AgentCore 先检查是否本地工具，不是则路由到对应的远程 MCP Server。

## 3. 工具路由

AgentCore 维护两套工具表：

| 来源 | 注册方式 | 执行方式 |
|------|----------|----------|
| 本地工具（file_read, memory_write 等） | ToolRegistry.registerTool() | ToolRegistry.executeTool() |
| 远程工具（maps_weather, maps_geo 等） | MCP Server tools/list 动态获取 | McpClient.callTool() HTTP 转发 |

两套工具在 `runAgent()` 中合并为一个 `allTools` 数组传给 DeepSeek：

```
const localTools = this.toolRegistry.getToolDefinitions()
const remoteTools = this.mcpClient.getAllRemoteToolsAsOpenAi()
const allTools = [...localTools, ...remoteTools]
```

DeepSeek 返回 tool_call 时的路由逻辑：

```
isLocalTool(name)?
  → yes: toolRegistry.executeTool()      // 本地执行
  → no:  remoteToolRouteMap.has(name)?
    → yes: mcpClient.callTool()          // 远程执行
    → no:  返回 "unknown tool" 错误
```

## 4. MCP 握手流程

标准 MCP Streamable HTTP 三步握手：

1. **initialize**：发送 `protocolVersion` + `clientInfo`，接收 server capabilities，提取 `Mcp-Session-Id`
2. **notifications/initialized**：通知 server 握手完成（无状态 server 忽略此步）
3. **tools/list**：获取所有可用工具的名称、描述、参数 Schema

Session 失效时自动重连：`callTool()` 失败后会重新执行 `initServer()` 再重试一次。

## 5. 配置

在 Settings 页面配置 MCP Server：

- **Server Name**：显示名称（仅用于日志）
- **Server URL**：MCP Server 的 Streamable HTTP 端点

或者通过 ConfigService 的默认值预置（当前默认高德地图）。

不配置 MCP Server 时，行为与之前完全一致（只有本地工具）。

## 6. 高德地图 MCP Server

高德官方提供 MCP Server，免费使用，需到 [lbs.amap.com](https://lbs.amap.com) 注册获取 API Key。

**端点**：`https://mcp.amap.com/mcp?key=你的高德Key`

**提供 15 个工具**：

| 工具名 | 功能 |
|--------|------|
| `maps_weather` | 查询天气 |
| `maps_geo` | 地址转经纬度 |
| `maps_regeocode` | 经纬度转地址 |
| `maps_ip_location` | IP 定位 |
| `maps_text_search` | 关键词搜索 POI |
| `maps_around_search` | 周边搜索 POI |
| `maps_search_detail` | POI 详情查询 |
| `maps_direction_driving` | 驾车路径规划 |
| `maps_direction_walking` | 步行路径规划 |
| `maps_direction_bicycling` | 骑行路径规划 |
| `maps_direction_transit_integrated` | 公交路径规划 |
| `maps_distance` | 距离测量 |

注意：高德 MCP Server 是**无状态模式**——不返回 `Mcp-Session-Id`，我们的 McpClient 兼容此模式。

## 7. MCP vs 普通 API

**API**：程序员写代码告诉程序"调这个接口"——你是大脑，代码是手。

**MCP**：把工具说明书给 LLM，LLM 自己决定调不调、调哪个、传什么参数——LLM 是大脑，你只提供手。

MCP 不是一种新的通信协议，它是一个**"给 AI 装工具箱"的标准格式**。底下走的还是 HTTP，只是请求里多了个 `tools` 字段描述工具，响应里多了个 `tool_calls` 字段返回 LLM 的调用决策。

## 8. 关键代码路径

**McpClient** — `services/McpClient.ets`

```
McpClient.initAll(configs)
  → initServer(config)                    // 对每个 MCP Server
    → POST /mcp  initialize              // JSON-RPC 握手
    → POST /mcp  notifications/initialized
    → POST /mcp  tools/list              // 获取工具列表
  → getAllRemoteToolsAsOpenAi()           // 转换为 DeepSeek tools 格式
  → buildToolRouteMap()                   // toolName → serverIndex 映射

McpClient.callTool(serverIndex, toolName, argsJson)
  → POST /mcp  tools/call               // 执行远程工具
  → 解析 result.content[].text          // 提取文本结果
```

**AgentCore** — `services/AgentCore.ets`

```
runAgent()
  → buildSystemPrompt(userMessage)        // RAG 增强
  → allTools = localTools + remoteTools   // 合并工具列表
  → ReAct loop:
    → sendMessage(apiMessages, allTools)
    → [DeepSeek 返回 tool_calls]
    → isLocalTool(name)?
      → yes: toolRegistry.executeTool()
      → no:  mcpClient.callTool()
    → 结果喂回 DeepSeek 继续循环
```

## 9. 对比

| | 本地工具 | 远程 MCP Server |
|---|---|---|
| 工具定义 | 代码里 registerTool() | MCP Server 通过 tools/list 动态暴露 |
| 加工具 | 改代码 + 重新编译 | 在 Settings 加一个 server URL |
| 执行方式 | 直接调 OH 系统 API | HTTP POST tools/call 到远程 |
| 生态 | 自己写 | 复用社区/厂商已有的 MCP Server |
| 离线可用 | 是 | 否（需要网络） |
