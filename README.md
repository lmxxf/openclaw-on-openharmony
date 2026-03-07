# NanoClaw on OpenHarmony

基于 [NanoClaw](https://github.com/qwibitai/nanoclaw)（[OpenClaw](https://github.com/openclaw/openclaw) 极简替代方案）的 OpenHarmony/HarmonyOS NEXT 移植版。

在鸿蒙设备上运行完整的 AI Agent，支持 ReAct 推理循环、工具调用、持久化记忆和定时任务。

## 背景

OpenClaw 是 2026 年增长最快的开源 AI Agent 框架（GitHub 163K stars），但其 40 万行 Node.js 代码库和 Docker 容器依赖使其无法直接运行在 OpenHarmony 上。NanoClaw 是 OpenClaw 的极简重写版（~3500 行 TypeScript，5 个文件，一个进程），但仍依赖 Docker 容器运行 Claude Agent SDK。

本项目采用 **方案 A**：保留 NanoClaw 的调度/数据层架构，砍掉 Docker 依赖，用 DeepSeek API + 自写 ReAct 循环替代 Claude Agent SDK，实现完全本地化的鸿蒙 AI Agent 应用。

### 移植策略

| NanoClaw 模块 | 行数 | 处理方式 | 本项目对应 |
|:---|:---|:---|:---|
| `db.ts` (SQLite) | 697 | 移植，API 替换 | `DatabaseService.ets` |
| `types.ts` | 107 | 移植，精简 | `Types.ets` |
| `router.ts` | 52 | 移植 | `TextFormatter.ets` |
| `task-scheduler.ts` | 281 | 简化移植 | `TaskScheduler.ets` |
| `container-runner.ts` | 702 | **完全重写** | `AgentCore.ets` + `ApiClient.ets` |
| `agent-runner/index.ts` | 588 | **完全重写** | `AgentCore.ets` |
| `ipc-mcp-stdio.ts` | 339 | 重写为直接调用 | `tools/*.ets` |
| `group-queue.ts` | 365 | 简化（单进程） | 内嵌于 `AgentCore` |
| `index.ts` (主循环) | 588 | 重写为 UI 驱动 | `Index.ets` |
| `channels/` | ~200 | 不需要 | — |
| `container-runtime.ts` | 87 | 不需要 | — |
| `mount-security.ts` | 419 | 不需要 | — |

**总计：18 个文件，2427 行 ArkTS 代码。**

## 架构

```
┌─────────────────────────────────────────────────────┐
│                    ArkUI 前端                        │
│  ┌──────────┐  ┌──────────────┐                     │
│  │ Index.ets│  │SettingsPage  │                     │
│  │ 聊天界面  │  │ .ets         │                     │
│  │          │  │ API配置      │                     │
│  └────┬─────┘  └──────────────┘                     │
│       │                                              │
│  ─────┼──────────── 服务层 ──────────────────────    │
│       │                                              │
│  ┌────▼─────────────────────────────────────────┐   │
│  │              AgentCore.ets                    │   │
│  │              ReAct 循环                       │   │
│  │                                               │   │
│  │  用户输入                                     │   │
│  │    ↓                                          │   │
│  │  ApiClient.ets ──→ DeepSeek API               │   │
│  │    ↓                                          │   │
│  │  finish_reason == "tool_calls"?               │   │
│  │  ├─ Yes → ToolRegistry → 执行工具 → 回 API    │   │
│  │  └─ No  → 返回文本 → 显示在 UI               │   │
│  └──────────────────────────────────────────────┘   │
│       │               │              │               │
│  ┌────▼────┐   ┌──────▼─────┐  ┌────▼──────┐       │
│  │Database │   │ToolRegistry│  │TaskSched-  │       │
│  │Service  │   │  + Tools   │  │uler       │       │
│  │ SQLite  │   │            │  │ Cron/定时  │       │
│  └─────────┘   └──────┬─────┘  └───────────┘       │
│                       │                              │
│          ┌────────────┼────────────┐                 │
│          │            │            │                 │
│     ┌────▼───┐  ┌─────▼────┐ ┌────▼───┐            │
│     │FileTools│  │WebTools  │ │Memory  │            │
│     │文件读写 │  │搜索/抓取 │ │Tools   │            │
│     └────────┘  └──────────┘ └────────┘            │
└─────────────────────────────────────────────────────┘
```

## 模块详解

### 1. 数据模型 — `models/Types.ets` (144行)

所有数据接口的集中定义，分为四个区域：

- **Chat & Messages**：`ChatMessage`（消息体，含发送者、时间戳、工具调用记录）、`ChatConversation`（会话摘要）
- **Agent Tool Use**：`ToolDefinition`（工具的 JSON Schema 定义，符合 OpenAI function calling 格式）、`ToolCall`（LLM 返回的工具调用指令）、`ToolResult`（工具执行结果）、`ToolCallRecord`（用于 UI 展示和持久化的工具调用记录）
- **DeepSeek API**：`ApiConfig`（API 密钥、Base URL、模型名、温度等）、`ApiMessage`（符合 OpenAI chat completion 格式的消息）、`ApiResponse`/`ApiChoice`/`ApiUsage`（响应结构）
- **Scheduled Tasks**：`ScheduledTask`（定时任务，支持 cron/interval/once 三种调度模式）、`TaskRunLog`（任务执行日志）
- **Agent Events**：`AgentTextEvent`/`AgentToolUseEvent`/`AgentErrorEvent`/`AgentDoneEvent`（Agent 执行过程中的事件流，用于 UI 实时更新）

设计原则：所有 API 交互使用 camelCase（ArkTS 惯例），与 DeepSeek API 的 snake_case 之间的转换在 `ApiClient` 中完成。

### 2. 核心服务

#### 2.1 AgentCore — `services/AgentCore.ets` (239行)

**系统的大脑。** 替代了 NanoClaw 中 `container-runner.ts`（容器管理）+ `agent-runner/index.ts`（Claude Agent SDK 调用）共计 ~1300 行代码。

核心算法 — ReAct 循环：

```
runAgent(userMessage, chatId, onEvent):
  1. 从 DB 加载最近 50 条对话历史
  2. 构造 system prompt + 对话历史 → API messages 数组
  3. LOOP (最多 15 次迭代):
     a. 调用 ApiClient.sendMessage(messages, tools)
     b. 检查 finish_reason:
        - "tool_calls": 逐个执行工具 → 把结果追加到 messages → continue
        - "stop": 提取文本 → 存入 DB → 返回
  4. 超过 15 次迭代则强制停止（防止无限循环）
```

关键设计决策：
- **回调模式而非 AsyncGenerator**：ArkTS 对 generator 支持有限，改用 `onEvent` 回调函数，UI 通过回调实时更新
- **对话窗口限制**：只发送最近 50 条消息作为上下文，防止 token 爆炸
- **错误透传**：工具执行失败不中断循环，而是把错误信息作为 tool_result 返回给 LLM，让 LLM 自己决定如何处理（这是 NanoClaw 原版的设计哲学）
- **单例模式**：全局一个 `agentCore` 实例，工具注册在 `init()` 时一次完成

#### 2.2 ApiClient — `services/ApiClient.ets` (236行)

DeepSeek API 的 HTTP 客户端，使用 `@ohos.net.http`。

特性：
- **OpenAI 兼容格式**：请求体完全符合 OpenAI Chat Completion API 规范（DeepSeek API 兼容该格式）
- **camelCase ↔ snake_case 自动转换**：内部全用 camelCase，发请求时转 snake_case，收响应时转回来
- **指数退避重试**：429（限流）和网络错误自动重试 3 次，退避间隔 2s → 4s → 8s
- **工具调用支持**：请求中包含 `tools` 数组（JSON Schema 格式），响应中解析 `tool_calls`
- **非流式**：PoC 阶段使用 `stream: false`，整体响应一次返回。后续可改为 SSE 流式解析

请求格式：
```json
POST https://api.deepseek.com/v1/chat/completions
{
  "model": "deepseek-chat",
  "messages": [
    {"role": "system", "content": "..."},
    {"role": "user", "content": "帮我创建一个文件"},
    {"role": "assistant", "content": null, "tool_calls": [...]},
    {"role": "tool", "tool_call_id": "call_xxx", "content": "文件已创建"}
  ],
  "tools": [{"type": "function", "function": {"name": "file_write", ...}}],
  "max_tokens": 8192,
  "temperature": 0.7,
  "stream": false
}
```

#### 2.3 ToolRegistry — `services/ToolRegistry.ets` (73行)

工具的注册中心和分发器。

- `registerTool(name, description, schema, executor)`：注册一个工具，包括 JSON Schema 参数定义和执行函数
- `getToolDefinitions()`：生成符合 OpenAI function calling 格式的工具定义数组，传给 API 请求
- `executeTool(name, inputJson, toolCallId)`：接收 LLM 返回的 tool_use 指令，解析 JSON 参数，分发到对应执行器，捕获异常返回错误信息

设计原则：工具注册与工具实现解耦。ToolRegistry 不知道具体工具做什么，只负责路由和错误处理。

#### 2.4 DatabaseService — `services/DatabaseService.ets` (275行)

从 NanoClaw `db.ts` (697行) 移植，使用 `@ohos.data.relationalStore` 替代 `better-sqlite3`。

数据表结构（与 NanoClaw 保持一致）：

| 表名 | 用途 | 主要字段 |
|:---|:---|:---|
| `chats` | 会话列表 | id, name, last_message_time, last_message_preview |
| `messages` | 消息历史 | id, chat_id, sender, content, timestamp, is_from_me, tool_calls (JSON) |
| `scheduled_tasks` | 定时任务 | id, chat_id, prompt, schedule_type, schedule_value, next_run, status |
| `task_run_logs` | 任务执行日志 | task_id, run_at, duration_ms, status, result, error |
| `kv_store` | 键值存储 | key, value（替代 NanoClaw 的 router_state 表）|

主要 API 变化：
- NanoClaw 的 `db.prepare(sql).run(args)` → `rdbStore.executeSql(sql, args)`
- NanoClaw 的 `db.prepare(sql).all(args) as T[]` → `rdbStore.querySql(sql, args)` + `ResultSet` 逐行遍历
- 所有操作从同步变为 `async`

砍掉的部分：JSON 文件迁移逻辑（NanoClaw 从旧版 JSON 文件迁移到 SQLite 的代码）、`registered_groups` 表（PoC 只有单会话）。

#### 2.5 TaskScheduler — `services/TaskScheduler.ets` (96行)

从 NanoClaw `task-scheduler.ts` (281行) 简化移植。

工作流程：
1. 应用启动时 `taskScheduler.start()`
2. 每 60 秒轮询 DB 查找到期任务（`scheduled_tasks.next_run <= NOW`）
3. 对每个到期任务，调用 `agentCore.runAgent(task.prompt, task.chatId, ...)`
4. 执行完毕后记录日志（`task_run_logs`），计算下次运行时间

支持三种调度模式：
- **cron**：标准 5 段 cron 表达式（如 `0 9 * * *` = 每天早上 9 点）
- **interval**：固定间隔毫秒数（如 `3600000` = 每小时）
- **once**：一次性任务，执行后状态变为 `completed`

限制：PoC 阶段只在 App 前台运行时轮询。后续可接入 `@ohos.WorkSchedulerExtensionAbility` 实现后台调度。

#### 2.6 ConfigService — `services/ConfigService.ets` (81行)

使用 `@ohos.data.preferences` 存储应用配置。

存储项：
- `api_key`：DeepSeek API 密钥
- `base_url`：API 地址（默认 `https://api.deepseek.com/v1`）
- `model`：模型名（默认 `deepseek-chat`）
- `max_tokens`：最大生成 token 数（默认 8192）
- `temperature`：采样温度（默认 0.7）
- `assistant_name`：助手名称（默认 `Andy`）

### 3. 工具集

Agent 可调用的工具，通过 ToolRegistry 注册，LLM 通过 function calling 协议触发。

#### 3.1 FileTools — `tools/FileTools.ets` (137行)

文件系统操作，限制在 App 沙箱 (`context.filesDir`) 内。

| 工具 | 功能 | 安全措施 |
|:---|:---|:---|
| `file_read` | 读取文件内容 | 路径遍历过滤（`../` 剥离） |
| `file_write` | 写入文件（自动创建父目录） | 限制在 filesDir 内 |
| `file_list` | 列出目录内容（带文件大小和类型标注） | 同上 |

使用 `@kit.CoreFileKit` 的 `fileIo` 模块。所有路径在使用前经过 `resolvePath()` 规范化，防止路径遍历攻击。

#### 3.2 MemoryTools — `tools/MemoryTools.ets` (115行)

持久化记忆系统 —— Agent 的"长期记忆"。

文件存储在 `filesDir/memory/{name}.md`，跨对话持久化。

| 工具 | 功能 |
|:---|:---|
| `memory_read` | 读取指定名称的记忆文件 |
| `memory_write` | 写入/更新记忆文件 |
| `memory_list` | 列出所有记忆文件及大小 |

文件名安全处理：只允许字母、数字、下划线、连字符，其他字符替换为下划线。

设计来源：NanoClaw 原版的 Memory 系统也是 Markdown 文件（`SOUL.md`, `USER.md`, `MEMORY.md` 等），本工具保持了相同的理念。

#### 3.3 WebTools — `tools/WebTools.ets` (128行)

网络访问工具。

| 工具 | 功能 | 实现方式 |
|:---|:---|:---|
| `web_fetch` | 抓取网页内容 | `@ohos.net.http` GET 请求 → 去 HTML 标签 → 截断到 50K 字符 |
| `web_search` | 搜索引擎查询 | DuckDuckGo HTML 搜索（无需 API Key）→ 解析结果提取标题/URL/摘要 |

`web_search` 的实现使用了 DuckDuckGo 的 HTML 端点 (`html.duckduckgo.com`)，不需要额外的 API Key，返回前 8 条搜索结果。

#### 3.4 TaskTools — `tools/TaskTools.ets` (182行)

从 NanoClaw `ipc-mcp-stdio.ts` 移植。NanoClaw 中这些工具通过文件系统 IPC 与宿主进程通信；本项目中直接调用 `DatabaseService`。

| 工具 | 功能 |
|:---|:---|
| `schedule_task` | 创建定时任务（验证 cron 表达式/interval 值） |
| `list_tasks` | 列出所有任务及状态 |
| `pause_task` | 暂停任务 |
| `resume_task` | 恢复任务 |
| `cancel_task` | 删除任务 |

### 4. 工具函数

#### 4.1 CronParser — `utils/CronParser.ets` (103行)

轻量级 cron 表达式解析器（NanoClaw 使用的 `cron-parser` NPM 包在鸿蒙上不可用）。

支持标准 5 段 cron 格式：分 时 日 月 周

特性支持：
- 通配符 `*`
- 范围 `1-5`
- 步进 `*/5`、`1-30/2`
- 列表 `1,3,5`

`computeNextRun()` 函数处理三种调度类型（cron/interval/once）的下次运行时间计算，移植自 NanoClaw `task-scheduler.ts` 的同名函数。

#### 4.2 TextFormatter — `utils/TextFormatter.ets` (34行)

文本处理工具集：
- `escapeXml()`：移植自 NanoClaw `router.ts`
- `stripInternalTags()`：移植自 NanoClaw，剥离 `<internal>` 标签
- `stripHtmlTags()`：用于 `web_fetch` 工具的 HTML 清洗
- `truncateText()`：长文本截断
- `generateId()`：生成时间戳+随机数的唯一 ID

#### 4.3 Logger — `utils/Logger.ets` (23行)

`hilog` 的薄封装，统一日志 TAG 为 `OHClaw`。

### 5. UI 页面

#### 5.1 Index（聊天页）— `pages/Index.ets` (284行)

单页聊天界面，核心交互页面。

状态管理：
```
@State messages: DisplayMessage[]    // 消息列表
@State inputText: string             // 输入框内容
@State isRunning: boolean            // Agent 是否运行中
@State hasApiKey: boolean            // 是否已配置 API Key
@State currentToolInfo: string       // 当前工具调用提示
```

UI 结构：
- **标题栏**：应用名 + Settings 按钮
- **未配置态**：欢迎页面 + "Go to Settings" 按钮
- **消息列表**：`List` 组件，消息气泡（用户蓝色/右对齐，Agent 灰色/左对齐）
- **工具调用展示**：消息上方显示 🔧 图标和工具名
- **思考指示器**：Agent 运行时显示 "Thinking..." 或 "Using tool: xxx..."
- **输入栏**：`TextInput` + 圆形发送按钮

交互流程：
1. 用户输入 → `sendMessage()`
2. 立即显示用户消息 + "Thinking..." 占位
3. `agentCore.runAgent()` 通过回调更新：
   - `tool_use` → 更新思考提示为 "Using tool: xxx..."
   - `text` → 替换占位为实际回复
   - `error` → 显示错误信息
   - `done` → 解锁输入框

#### 5.2 SettingsPage — `pages/SettingsPage.ets` (199行)

配置页面，表单式布局：
- API Key 输入（密码模式）
- API Base URL 输入（默认 DeepSeek）
- 模型名称输入
- "Test Connection" 按钮（发送一条测试消息验证 API 可用性）
- "Save" 按钮
- 状态提示（成功/失败信息）

### 6. 应用入口

#### EntryAbility — `entryability/EntryAbility.ets` (63行)

应用生命周期管理。在 `onWindowStageCreate()` 中按顺序初始化：

1. `dbService.init(context)` — 创建/打开 SQLite 数据库
2. `configService.init(context)` — 加载 Preferences
3. `agentCore.init(context.filesDir)` — 初始化文件工具和注册所有工具
4. `taskScheduler.start()` — 启动定时任务轮询

在 `onDestroy()` 中停止 TaskScheduler。

## 配置改动

### module.json5

新增网络权限：
```json
"requestPermissions": [
  { "name": "ohos.permission.INTERNET" }
]
```

### main_pages.json

注册新页面：
```json
{
  "src": ["pages/Index", "pages/SettingsPage"]
}
```

## 与 NanoClaw 原版的核心差异

| 维度 | NanoClaw | 本项目 |
|:---|:---|:---|
| 运行时 | Node.js 20+ | ArkTS (ArkCompiler) |
| Agent 执行 | Docker 容器 + Claude Agent SDK | 进程内 ReAct 循环 + DeepSeek HTTP API |
| LLM 后端 | Claude (Anthropic) | DeepSeek（OpenAI 兼容格式） |
| IPC 方式 | 文件系统 IPC（宿主 ↔ 容器） | 直接函数调用（同进程） |
| 消息通道 | WhatsApp/Telegram/Discord/Slack | 本地 UI |
| 数据库 | better-sqlite3（同步） | @ohos.data.relationalStore（异步） |
| 安全模型 | 容器隔离 + 文件系统挂载白名单 | App 沙箱隔离 |
| 部署方式 | 服务器/PC 上的常驻进程 | 手机上的 App |

## 技术栈

- **平台**：OpenHarmony / HarmonyOS NEXT 6.0.1 (API 21)
- **语言**：ArkTS（TypeScript 超集）
- **UI 框架**：ArkUI 声明式
- **数据库**：`@ohos.data.relationalStore` (SQLite)
- **配置**：`@ohos.data.preferences`
- **网络**：`@ohos.net.http`
- **文件**：`@kit.CoreFileKit` (`fileIo`)
- **日志**：`@kit.PerformanceAnalysisKit` (`hilog`)
- **LLM API**：DeepSeek Chat API（OpenAI 兼容格式）

## 使用方法

1. 用 DevEco Studio 打开项目
2. 连接鸿蒙设备或启动模拟器
3. Build & Run
4. 首次启动进入 Settings，输入 DeepSeek API Key
5. 返回聊天页，开始对话

验证 ReAct 循环：
```
你：帮我创建一个 todo.md 文件，写上今天要做的三件事
Agent：[调用 file_write] → 文件已创建
Agent：我已经创建了 todo.md 文件，内容如下...

你：读一下刚才创建的文件
Agent：[调用 file_read] → 返回文件内容

你：记住我喜欢用中文回复
Agent：[调用 memory_write] → 已保存到记忆

你：每天早上 9 点提醒我喝水
Agent：[调用 schedule_task] → 任务已创建 (cron: 0 9 * * *)
```

## 已知限制

- **非流式响应**：当前使用 `stream: false`，Agent 回复会在完全生成后一次性显示
- **仅前台调度**：定时任务只在 App 前台时轮询，后台不运行
- **单会话**：PoC 只有一个默认对话，未实现多会话管理
- **无浏览器自动化**：NanoClaw 原版支持 Chrome CDP 控制，鸿蒙上不可用

## License

MIT
