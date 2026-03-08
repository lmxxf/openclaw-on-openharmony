# 端侧 RAG 技术实现文档

## 1. 概述

RAG（Retrieval-Augmented Generation，检索增强生成）是一种让大语言模型基于外部知识库回答问题的技术。OHClaw 实现了轻量级端侧 RAG：知识库以文本文件形式随 HAP 包打包分发，应用启动时加载并切片，用户提问时通过向量检索（或关键词匹配降级）相关片段注入 system prompt，再由云端 DeepSeek 模型基于检索上下文生成回答。

## 2. 架构

```
首次启动流程：
知识文件 (rawfile/knowledge/*.txt)
        |  加载切片
        v
14 个 chunk --> 分 3 批调用 SiliconFlow BGE-M3 API
        |  每个 chunk 得到 1024 维 float 向量
        v
存入 SQLite (vector_rag.db, BLOB 格式, 每条 4096 字节)
        |
        v
标记 chunk_count=14 --> 下次启动检测一致则跳过

用户提问流程：
用户输入 "怎么连蓝牙"
        |
        v
调用 SiliconFlow API 算 query embedding (1024 维)
        |
        v
从 SQLite 读取全部 14 条 chunk embedding
        |
        v
逐条算余弦相似度 --> 排序取 Top-3
        |
        v
注入 system prompt --> 发送 DeepSeek API
```

## 3. 知识库结构

| 文件 | 说明 |
|------|------|
| `kb_index.json` | 文档元数据索引，定义每个文档的 id、文件路径、标题、关键词列表 |
| `device_manual.txt` | 设备使用手册（蓝牙/亮度/WiFi/时间/系统信息等操作指南）|
| `oh6_features.txt` | OpenHarmony 6.0 特性说明（ArkTS/Stage 模型/分布式/安全/AI 子系统）|
| `settings_faq.txt` | 设置应用常见问题 Q&A（13 个问答对）|

**扩展方式**：新增知识 = 添加一个 `.txt` 文件到 `rawfile/knowledge/` 目录 + 在 `kb_index.json` 中注册文档元数据。无需修改任何代码。向量索引会在下次启动时自动重建（检测到 chunk_count 变化）。

## 4. Embedding 模型

**DeepSeek 没有 Embedding API**（官方只提供 chat 和 reasoner），所以 embedding 用 SiliconFlow 托管的开源模型。

| 配置项 | 值 | 说明 |
|--------|------|------|
| 提供商 | [SiliconFlow](https://siliconflow.cn) | 国内平台，免费开源模型不收费 |
| 模型 | `BAAI/bge-m3` | 北京智源研究院的开源 embedding 模型 |
| 向量维度 | 1024 | 每段文本输出 1024 个 float 值 |
| 最大 Token | 8192 | 支持长文本 |
| 语言 | 中英文 + 100 多种语言 | 多语言场景友好 |
| 价格 | **免费** | 属于 SiliconFlow 免费开源模型系列 |

**API 格式**（OpenAI 兼容）：

```
POST https://api.siliconflow.cn/v1/embeddings
Authorization: Bearer {api_key}
Content-Type: application/json

请求体：
{
  "model": "BAAI/bge-m3",
  "input": ["文本1", "文本2", "文本3"],
  "encoding_format": "float"
}

响应体：
{
  "data": [
    { "embedding": [0.023, -0.011, ...], "index": 0 },
    { "embedding": [-0.005, 0.032, ...], "index": 1 }
  ],
  "model": "BAAI/bge-m3"
}
```

支持批量输入，建索引时每批 5 个 chunk，14 个 chunk 分 3 批完成。

## 5. 向量存储（SQLite）

使用 OpenHarmony 的 `@ohos.data.relationalStore`（SQLite），独立数据库 `vector_rag.db`。

**表 `kb_vector_chunks`**：

| 列 | 类型 | 说明 |
|---|---|---|
| id | INTEGER PRIMARY KEY AUTOINCREMENT | 行 ID |
| doc_id | TEXT | 文档来源（如 "device_manual"） |
| chunk_index | INTEGER | 切片序号 |
| chunk_text | TEXT | 切片原文 |
| embedding | BLOB | 1024 个 float32，共 4096 字节 |

**表 `kb_meta`**：

| 列 | 类型 | 说明 |
|---|---|---|
| key | TEXT PRIMARY KEY | 键名 |
| value | TEXT | 值 |

`kb_meta` 存储 `chunk_count`（已建索引的切片数）。启动时检查：如果数据库中的 chunk_count 与当前知识库切片数一致，跳过 embedding 计算直接进入就绪状态。

**向量序列化**：

```
写入：number[1024] → Float32Array(1024) → .buffer → Uint8Array → BLOB（4096 字节）
读取：BLOB → Uint8Array → Float32Array → number[1024]
```

## 6. 余弦相似度

手写实现，纯 ArkTS，无需外部库：

```
cosineSimilarity(a, b) = dot(a, b) / (|a| × |b|)

其中：
  dot(a, b) = Σ a[i] × b[i]
  |a| = sqrt(Σ a[i]²)
  |b| = sqrt(Σ b[i]²)
```

1024 维向量计算一次约 3000 次浮点乘法 + 1 次 sqrt，14 个 chunk 全表扫描在毫秒级完成。

## 7. Prompt 注入策略

```
You are a helpful AI assistant...（基础 prompt）

Relevant knowledge base context:
---
[检索到的切片1]
---
[检索到的切片2]
---
[检索到的切片3]
---
Use the above context to help answer the user's question if relevant.
```

检索结果为空时只发基础 prompt，不注入无关内容。

## 8. 降级策略

向量检索是主路径，关键词匹配是后备，自动切换，用户无感知：

| 场景 | 行为 | 用户体验 |
|------|------|----------|
| SiliconFlow API Key 未配置 | 不建索引，直接降级 | 关键词匹配 |
| 建索引时网络请求失败 | 标记 fallback | 关键词匹配 |
| 还在建索引时用户提问 | 检测到未就绪 | 关键词匹配 |
| 向量检索 query embedding 失败 | 该次降级 | 关键词匹配 |
| 向量检索正常但结果为空 | 退回关键词兜底 | 关键词匹配 |
| 向量检索正常 | 返回 Top-3 | 语义匹配，准确率更高 |

关键词匹配算法：文档级关键词（`kb_index.json` 预定义）+ 查询词在切片文本中的命中次数，按总分排序取 Top-3。

## 9. 启动时序

```
AgentCore.init(filesDir, context)
  → initMcpAndRag()                        // 异步，不阻塞 UI
    → initRag()
      → loadKnowledgeBase()                // 从 rawfile 加载切片
      → vectorRagService.init(context, config)  // 建表
      → vectorRagService.buildIndex(chunks)      // 异步建索引
        → 检查 kb_meta.chunk_count == 14?
          → 一致：跳过，毫秒级进入 ready
          → 不一致：分 3 批调 SiliconFlow API，~1-2 秒完成
```

首次启动约 1-2 秒建索引（3 次网络请求）。后续启动检测 chunk_count 一致则跳过，即时就绪。

## 10. 关键词 RAG vs 向量 RAG 对比

| 维度 | 关键词 RAG（后备） | 向量 RAG（主路径） |
|------|-------------------|-------------------|
| 检索方式 | 关键词 + 查询词匹配 | 余弦相似度 |
| 语义理解 | 弱（纯字符串匹配） | 强（同义词/近义词/语义相似都能匹配） |
| 需要网络 | 否 | 是（调 SiliconFlow API 算 embedding） |
| 需要数据库 | 否（纯内存） | 是（SQLite 存向量） |
| 首次启动开销 | 无 | ~1-2 秒建索引 |
| 查询开销 | 纯 CPU，微秒级 | 1 次 API 调用 + CPU，~150ms |
| 离线可用 | 是 | 否（降级到关键词） |

两套方案并存互补：在线时用向量检索获得更好的语义匹配效果，离线或 API 不可用时自动降级到关键词匹配保证可用性。

## 11. 关键代码路径

**VectorRagService** — `services/VectorRagService.ets`

```
VectorRagService.init(context, config)
  → relationalStore.getRdbStore()           // 创建 vector_rag.db
  → executeSql(CREATE_CHUNKS_SQL)           // 建 kb_vector_chunks 表
  → executeSql(CREATE_META_SQL)             // 建 kb_meta 表

VectorRagService.buildIndex(chunks)
  → getMetaValue('chunk_count')             // 检查是否需要重建
  → callEmbeddingApi(texts[])               // 分批调 SiliconFlow
  → floatArrayToBlob() → store.insert()    // BLOB 存入 SQLite
  → setMetaValue('chunk_count', '14')       // 标记完成

VectorRagService.retrieveByVector(query, topK)
  → callEmbeddingApi([query])               // query embedding
  → store.query() → blobToFloatArray()     // 读取所有 chunk 向量
  → cosineSimilarity()                      // 逐条计算
  → sort + slice(0, topK)                   // 排序取 Top-K
```

**AgentCore** — `services/AgentCore.ets`

```
buildSystemPrompt(userMessage)
  → vectorRagService.isReady()?
    → yes: retrieveByVector(userMessage, 3)  // 向量检索
    → no:  keywordRetrieve(userMessage, 3)   // 关键词降级
  → 拼接到 system prompt
```
