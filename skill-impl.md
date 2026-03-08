# Skill 斜杠命令技术实现文档

## 1. 概述

Skill 是 OHClaw 的斜杠命令扩展机制。每个 Skill 是一个 JSON 文件，定义了命令名、描述和 prompt 模板。用户输入 `/translate 你好` 时，App 匹配命令、展开模板、发给 LLM。扩展方式纯数据驱动——往 `rawfile/skills/` 丢 JSON 文件并在索引中注册即可，不改代码。

## 2. 架构

```
rawfile/skills/
├── skills_index.json     索引文件：列出所有 skill
├── translate.json        /translate → 翻译成英文
└── explain.json          /explain → 逐步解释代码

启动流程：
AgentCore.init()
  → loadSkills()
    → 读 skills_index.json
    → 逐个读取 skill JSON 文件
    → 存入 this.skills: SkillDefinition[]

用户输入流程：
"/translate 你好"
  → runAgent(userMessage)
    → /help? → 直接返回帮助文本，不走 LLM
    → matchSkill(userMessage)
      → 拆分: command="/translate", input="你好"
      → 遍历 skills 匹配 command
      → 命中 → 替换 {{input}} → 返回展开后的 prompt
    → effectiveMessage = 展开后的 prompt
    → 存 DB: 原始输入 "/translate 你好"
    → 发 LLM: 展开后的 prompt
    → ReAct 循环正常执行
```

## 3. Skill JSON 格式

每个 Skill 一个 JSON 文件，四个字段：

| 字段 | 类型 | 说明 |
|------|------|------|
| name | string | Skill 标识名（内部使用） |
| command | string | 斜杠命令，如 `/translate` |
| description | string | 描述，/help 时展示 |
| prompt | string | Prompt 模板，`{{input}}` 是占位符 |

**示例：translate.json**

```json
{
  "name": "translate",
  "command": "/translate",
  "description": "翻译文本到英文",
  "prompt": "Translate the following text to English. Output only the translation, nothing else.\n\n{{input}}"
}
```

**示例：explain.json**

```json
{
  "name": "explain",
  "command": "/explain",
  "description": "逐步解释代码逻辑",
  "prompt": "Explain the following code step by step in the user's language. Be clear and concise.\n\n```\n{{input}}\n```"
}
```

## 4. 索引文件

`skills_index.json` 列出所有 Skill 文件路径：

```json
{
  "skills": [
    { "file": "skills/translate.json" },
    { "file": "skills/explain.json" }
  ]
}
```

路径相对于 `rawfile/` 目录。

## 5. 类型定义

在 `AgentCore.ets` 内部定义（非独立文件）：

```
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
```

## 6. 加载流程

`loadSkills()` 在 `initMcpAndRag()` 中最后执行（MCP → RAG → Skill），异步非阻塞。

```
loadSkills()
  → resourceManager.getRawFileContent('skills/skills_index.json')
  → JSON.parse → SkillIndex
  → for each entry:
    → resourceManager.getRawFileContent(entry.file)
    → JSON.parse → SkillDefinition
    → push to this.skills[]
  → Logger: "Loaded 2 skills"
```

使用 `uint8ArrayToString()`（`util.TextDecoder`）将 rawfile 的 `Uint8Array` 转 UTF-8 字符串，与知识库加载共用同一方法。

加载失败不影响 Agent 正常运行——`this.skills` 为空数组，所有 `/command` 不匹配，消息原样发给 LLM。

## 7. 匹配逻辑

```
matchSkill(userMessage: string): string | null
  → 不以 '/' 开头 → return null
  → 找第一个空格，拆分为 command + input
  → 无空格时 input 为空字符串
  → command === '/help' → return null（/help 单独处理）
  → 遍历 this.skills：
    → skill.command === command → skill.prompt.replace('{{input}}', input)
  → 无匹配 → return null（消息原样发 LLM）
```

**注意**：未匹配的斜杠命令（如 `/unknown xxx`）不报错，直接当普通消息发给 LLM。LLM 可能会理解用户意图并做出合理回应。

## 8. runAgent 中的拦截

Skill 拦截发生在 `runAgent()` 入口处，ReAct 循环之前：

| 输入 | 处理 | 存 DB | 发 LLM |
|------|------|-------|--------|
| `/help` | 直接返回帮助文本 | 不存 | 不调 |
| `/translate 你好` | 展开 prompt 模板 | `/translate 你好` | `Translate the following text to English...你好` |
| `/unknown xxx` | matchSkill 返回 null | `/unknown xxx` | `/unknown xxx` |
| `普通消息` | 不拦截 | `普通消息` | `普通消息` |

**关键设计**：存 DB 用原始输入，发 LLM 用展开后的 prompt。用户回看聊天记录看到自己打的命令，不是一段提示词。

History 替换逻辑：加载对话历史后，如果 skill 匹配成功，把最后一条用户消息的 content 替换为 effectiveMessage：

```
for (let i = 0; i < history.length; i++) {
    const isLast = i === history.length - 1
    const content = (isLast && skillPrompt !== null) ? effectiveMessage : msg.content
    apiMessages.push({ role: 'user', content: content })
}
```

## 9. /help 实现

```
getHelpText(): string
  → skills 为空 → "No skills available."
  → 遍历 skills，拼接:
    "Available commands:\n"
    "  /translate — 翻译文本到英文\n"
    "  /explain — 逐步解释代码逻辑\n"
    "  /help — Show this help"
```

`/help` 不存 DB、不调 LLM，直接返回文本后触发 `done` 事件。

## 10. 扩展方式

添加新 Skill 三步：

1. 在 `rawfile/skills/` 创建 JSON 文件（如 `summarize.json`）：
   ```json
   {
     "name": "summarize",
     "command": "/summarize",
     "description": "总结文本要点",
     "prompt": "Summarize the following text into 3-5 bullet points in the user's language.\n\n{{input}}"
   }
   ```

2. 在 `skills_index.json` 注册：
   ```json
   {
     "skills": [
       { "file": "skills/translate.json" },
       { "file": "skills/explain.json" },
       { "file": "skills/summarize.json" }
     ]
   }
   ```

3. 重新编译安装。无需修改任何代码。

## 11. 关键代码路径

**AgentCore** — `services/AgentCore.ets`

```
类型定义：SkillDefinition, SkillIndexEntry, SkillIndex     （行 71-84）
loadSkills()                                               （行 241-268）
matchSkill(userMessage)                                    （行 271-304）
getHelpText()                                              （行 306-316）
runAgent() 中的拦截逻辑                                     （行 430-442）
runAgent() 中的 history 替换                                （行 468-480）
```

**Skill 文件**

```
rawfile/skills/skills_index.json       索引
rawfile/skills/translate.json          /translate 命令
rawfile/skills/explain.json            /explain 命令
```

## 12. Skill vs MCP vs RAG 对比

| 维度 | Skill | MCP | RAG |
|------|-------|-----|-----|
| 扩展什么 | 用户输入 | 工具列表 | 系统上下文 |
| 作用点 | ReAct 循环之前 | ReAct 循环之中 | system prompt |
| 配置方式 | rawfile JSON 文件 | Settings 页面输入 URL | rawfile 文本文件 |
| 需要网络 | 否 | 是 | 是（向量模式）/ 否（关键词模式） |
| 改代码 | 不用 | 不用 | 不用 |
| 复杂度 | 低（字符串替换） | 中（JSON-RPC 协议） | 高（embedding + 向量存储 + 相似度计算） |
