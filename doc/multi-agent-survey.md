# 多智能体系统 + 大模型：技术现状与可落地方向调研

> 调研日期：2026-03-10
>
> 调研范围：公开资料，不涉及任何保密内容

---

## 一、什么是多智能体系统

### 一句话版本

多个 AI Agent 各自有角色、有工具、有记忆，按照一定规则协作完成一个任务。

### 和单 Agent 的区别

**单 Agent** 就是一个人干所有事。你给它一个任务，它自己拆分、自己查资料、自己写代码、自己检查。能力上限取决于这一个模型有多强。

**多 Agent** 是一个团队分工。比如你要写一份作战方案：

- Agent A（情报分析员）：负责收集和分析情报，输出态势评估
- Agent B（作战参谋）：根据态势评估，制定 2-3 套作战方案
- Agent C（后勤参谋）：评估每套方案的物资、运输、时间可行性
- Agent D（指挥官）：综合所有输入，做最终决策

每个 Agent 只关注自己的职责，各自调用自己的工具（数据库、地图、计算器等），最后的输出质量通常优于让一个 Agent 从头到尾全干。

### 为什么不直接用一个更强的模型？

实际工程中，单 Agent 面临几个问题：
1. **上下文窗口有限**：一个复杂任务的所有信息塞进一个对话里，模型容易"忘"前面的内容
2. **角色混乱**：让一个模型同时扮演分析员和决策者，它经常分不清自己在干什么
3. **工具调用冲突**：不同阶段需要不同工具，单 Agent 容易在工具选择上出错
4. **调试困难**：出了问题不知道是哪个环节错了

多 Agent 的代价是：Agent 之间的通信有开销，协调逻辑需要额外编写，整体延迟更高。不是所有场景都适合用多 Agent。

---

## 二、主流框架对比

### 概览表

| 框架 | 出品方 | 设计思路 | 适合场景 | 上手难度 | 国产模型支持 | GitHub Stars |
|------|--------|---------|---------|---------|------------|-------------|
| CrewAI | CrewAI Inc | 角色 + 任务 + 团队 | 快速原型、角色协作 | 低 | 支持（OpenAI 兼容接口） | 27k+ |
| AutoGen / AG2 | 微软 → 社区分叉 | 对话式多 Agent | 人在回路、研究探索 | 中 | 支持 | 40k+ |
| LangGraph | LangChain 团队 | 有向图状态机 | 精确工作流控制、生产部署 | 高 | 支持 | 10k+ |
| MetaGPT | 学术团队 (DeepWisdom) | 软件公司 SOP 模拟 | 代码/文档生成 | 中 | 支持 | 46k+ |

### 逐个说明

#### 1. CrewAI — 最容易上手的多 Agent 框架

**核心思路**：定义角色（Agent）、任务（Task）、团队（Crew），框架自动编排执行顺序。

**适合场景**：快速搭建原型、角色分工明确的协作任务。

**局限**：复杂工作流控制能力弱，据多个团队反馈，使用 6-12 个月后可能遇到设计上的限制。

**代码示意**：

```python
from crewai import Agent, Task, Crew

# 定义角色
analyst = Agent(
    role="情报分析员",
    goal="分析当前态势并输出评估报告",
    backstory="你是一名经验丰富的情报分析员",
    llm="deepseek/deepseek-chat"  # 直接用 DeepSeek
)

planner = Agent(
    role="作战参谋",
    goal="根据态势评估制定作战方案",
    backstory="你是一名作战参谋",
    llm="deepseek/deepseek-chat"
)

# 定义任务
analysis_task = Task(
    description="分析以下情报数据，输出态势评估：{intel_data}",
    agent=analyst
)

planning_task = Task(
    description="根据态势评估，制定 2 套作战方案",
    agent=planner,
    context=[analysis_task]  # 依赖上一个任务的输出
)

# 组建团队并执行
crew = Crew(agents=[analyst, planner], tasks=[analysis_task, planning_task])
result = crew.kickoff(inputs={"intel_data": "..."})
```

#### 2. AutoGen / AG2 — 对话驱动的多 Agent

**背景**：AutoGen 最早由微软研究院开发。2024 年底，核心作者离开微软，将项目分叉为社区驱动的 AG2。微软则将 AutoGen 整合进了新的 Microsoft Agent Framework（目前公开预览阶段）。

**核心思路**：Agent 之间通过"对话"交互，支持人类随时插入对话（Human-in-the-loop）。

**适合场景**：需要人工审核的复杂推理任务、学术研究。

**局限**：目前不太适合生产环境部署，缺乏内置的可观测性工具。

**代码示意**：

```python
from autogen import AssistantAgent, UserProxyAgent

# 创建 AI 助手
assistant = AssistantAgent(
    name="作战参谋",
    llm_config={"model": "deepseek-chat", "api_key": "..."}
)

# 创建人类代理（可以自动回复，也可以等待人工输入）
commander = UserProxyAgent(
    name="指挥官",
    human_input_mode="TERMINATE"  # 任务完成时终止
)

# 发起对话
commander.initiate_chat(
    assistant,
    message="根据以下态势，制定作战方案：..."
)
```

#### 3. LangGraph — 精确控制的有向图

**核心思路**：把工作流定义为一个有向图（DAG），节点是 Agent 或函数，边定义数据流向。支持条件分支、并行执行、持久化状态。

**适合场景**：需要精确控制执行流程的生产级应用。Klarna 用它处理 8500 万用户的客服，响应时间缩短 80%。

**局限**：学习曲线陡峭，需要理解图论和状态机的概念。

**代码示意**：

```python
from langgraph.graph import StateGraph, END

# 定义状态
class WarState(TypedDict):
    intel: str
    assessment: str
    plan: str

# 定义节点函数
def analyze_intel(state):
    # 调用 LLM 分析情报
    assessment = llm.invoke(f"分析情报: {state['intel']}")
    return {"assessment": assessment}

def make_plan(state):
    plan = llm.invoke(f"根据评估制定方案: {state['assessment']}")
    return {"plan": plan}

def need_revision(state):
    # 条件判断：方案是否需要修改
    return "revise" if "风险过高" in state["plan"] else "approve"

# 构建图
graph = StateGraph(WarState)
graph.add_node("分析", analyze_intel)
graph.add_node("制定方案", make_plan)
graph.add_edge("分析", "制定方案")
graph.add_conditional_edges("制定方案", need_revision, {
    "revise": "分析",   # 打回重新分析
    "approve": END      # 通过
})

app = graph.compile()
result = app.invoke({"intel": "..."})
```

#### 4. MetaGPT — 模拟软件公司

**核心思路**：定义一个"AI 软件公司"，包含产品经理、架构师、工程师、QA 等角色，按照标准软件开发 SOP 协作。

**适合场景**：代码生成、文档生成、需求分析。在代码生成基准测试上 Pass@1 达到 85.9%。

**局限**：场景相对固定（软件开发），迁移到其他领域需要较多改造。

**代码示意**：

```python
from metagpt.roles import ProductManager, Architect, Engineer
from metagpt.team import Team

# 组建团队
team = Team()
team.hire([
    ProductManager(),
    Architect(),
    Engineer()
])

# 一句话需求，自动走完整个软件开发流程
team.run_project("开发一个库存管理系统，支持需求预测和自动补货建议")
# 输出：需求文档 → 系统设计 → API 定义 → 代码 → 测试
```

### 选型建议

- **想快速出 Demo**：选 CrewAI，半天就能跑起来
- **需要人工介入审核**：选 AutoGen/AG2
- **要上生产、需要精确控制**：选 LangGraph
- **专门做代码/文档生成**：选 MetaGPT

---

## 三、可落地的应用方向

按 Demo 实现难度从低到高排序。

### 1. 协同指挥决策辅助（最容易做 Demo）

**做什么**：多个参谋角色 Agent 协作完成一个决策流程——情报分析 → 方案制定 → 后勤评估 → 指挥官决策。

**为什么容易**：不需要对接真实数据源，用模拟数据即可演示效果。角色分工和 CrewAI 的设计思路天然契合。

**技术栈**：Python + CrewAI + DeepSeek API

**预计开发周期**：3-5 天（含调试 prompt）

**预期效果**：输入一段情报文本，输出结构化的态势评估 + 多套作战方案 + 可行性分析 + 最终建议。

### 2. 后勤保障优化

**做什么**：
- 需求预测 Agent：根据历史数据预测物资消耗
- 库存管理 Agent：监控当前库存状态
- 采购建议 Agent：生成补货计划

**技术栈**：CrewAI + DeepSeek API + 简单的 Excel/CSV 数据

**预计开发周期**：1-2 周

**注意**：LLM 做数值计算不可靠，涉及精确计算的部分需要用传统算法（作为 Agent 的工具调用），LLM 负责理解需求和生成报告。

### 3. 多源情报融合

**做什么**：
- 多个数据源（结构化数据库 + 非结构化文本 + 地理信息）
- 不同 Agent 负责不同数据源的分析
- 融合 Agent 汇总各方分析，输出综合态势报告

**技术栈**：LangGraph（需要精确控制数据流）+ DeepSeek API + RAG（检索增强生成）

**预计开发周期**：2-3 周

**难点**：数据源接入、信息冲突时的融合策略、输出格式标准化。

### 4. 战略推演仿真

**做什么**：基于 WarAgent（宾夕法尼亚大学开源）改造，多个"国家/势力" Agent 进行多轮博弈推演。

**参考项目**：[WarAgent](https://github.com/agiresearch/WarAgent)（Apache 2.0 协议）
- 已实现一战、二战、中国战国时期的历史推演
- 每个国家 Agent 有独立的决策逻辑和秘书 Agent 进行方案评估
- 支持 GPT-4 和 Claude 作为底层模型

**技术栈**：WarAgent 代码 + 替换底层模型为 DeepSeek

**预计开发周期**：2-4 周（主要时间在改造和调试 prompt）

### 5. 鸿蒙分布式多智能体（差异化方向）

**做什么**：每台鸿蒙设备运行一个 Agent（本地小模型），设备间通过鸿蒙分布式能力协同。

**已有技术基础**：
- **OHClaw**：我们已经实现的鸿蒙 AI Agent 应用，具备 MCP 协议支持、RAG 检索增强、Skill 加载等能力
- **llama.cpp**：已适配 OpenHarmony，可以在鸿蒙设备上运行 Qwen 1.5B/7B 等小模型

**设想场景**：
- 手持设备 Agent：负责前方情报采集和初步分析
- 车载设备 Agent：负责区域态势汇总
- 指挥所设备 Agent：负责全局决策
- 设备间通过鸿蒙分布式软总线通信

**预计开发周期**：4-8 周

**差异化价值**：目前公开资料中没有看到在鸿蒙/OpenHarmony 上做分布式多智能体的方案。这个方向结合了国产操作系统 + 国产大模型 + 端侧部署 + 多智能体协同，具备明确的技术独特性。

---

## 四、技术实现要点

### 模型选择

| 模型 | 部署方式 | 适用场景 | 参考价格 |
|------|---------|---------|---------|
| DeepSeek V3.2 | 云端 API | 快速原型、网络可用场景 | $0.28/百万 token（约 2 元人民币） |
| Qwen 1.5B | 本地部署 | 端侧设备、离线场景 | 免费，需要算力 |
| Qwen 7B | 本地部署 | 服务器端、离线场景 | 免费，需要 GPU（16GB 显存） |

DeepSeek API 目前是性价比最高的选择：新注册账号赠送 500 万 token，足够开发和测试阶段使用。

### 框架部署

所有框架都是 Python 生态，安装方式统一：

```bash
pip install crewai        # CrewAI
pip install autogen-agentchat  # AutoGen
pip install langgraph     # LangGraph
pip install metagpt       # MetaGPT
```

不需要特殊硬件（使用云端 API 的情况下），普通开发机即可。

### 关键限制——必须在汇报中说清楚

1. **推理延迟**：每次 Agent 调用 LLM 需要 1-3 秒（云端 API），多个 Agent 串行交互延迟会累加。不适合毫秒级实时决策场景。

2. **模型幻觉**：Agent 可能输出看起来合理但不符合事实的内容。所有 Agent 的输出都需要人工审核，不能直接作为决策依据。

3. **上下文长度**：多 Agent 对话轮次多，token 消耗大。一次完整的多 Agent 协作可能消耗数万 token。

4. **多 Agent 不等于更聪明**：Agent 数量多了协调成本也高，Agent 之间可能产生信息丢失或理解偏差。通常 3-5 个 Agent 的效果优于 10 个以上。

5. **确定性问题**：相同输入不一定得到相同输出。需要通过 prompt 工程和输出格式约束来提高一致性。

---

## 五、国内外现状

### 国际

| 项目/机构 | 说明 |
|-----------|------|
| CJADC2（美军） | 联合全域指挥控制，2024 年底发布初始版本软件，目标是用 AI 连接各军种传感器和决策系统 |
| DARPA Mosaic Warfare | "马赛克战"概念，用分布式自主单元 + AI 编排替代集中式指挥 |
| Scale AI Defense Llama | 基于 Meta Llama 3 微调的军事专用模型，部署在美国政府受控环境中 |
| Thunderforge（Scale AI + 美国防部） | 2025 年 3 月签约，用 AI 规划舰船、飞机等资产调动 |

### 国内

| 公司/产品 | 说明 |
|-----------|------|
| 渊亭科技 CMAS | 多智能体协同决策平台，已在 2025 年北京军博会展示，入选信通院 AI Agent 产业图谱 |
| 华如科技 XSimVerse | 军事大模型 + 仿真平台，已接入 DeepSeek，推出军事智能一体机（便携版/专业版/算力中心版） |

### 开源项目

| 项目 | 说明 |
|------|------|
| WarAgent | 宾夕法尼亚大学，Apache 2.0 协议，LLM 驱动的战争推演仿真 |
| CrewAI / LangGraph / AG2 | 通用多 Agent 框架，均可用于军事场景改造 |

**现状判断**：国内军工领域已经有产品在展会上展示，说明技术路线基本成立。但实战部署案例不公开，无法评估实际效果。从公开信息看，目前仍处于"能做 Demo、能上展会，但离实战部署有距离"的阶段。

---

## 六、建议

### 第一步：做出第一个 Demo（1 周内）

- **方向**：协同指挥决策辅助
- **技术栈**：CrewAI + DeepSeek API + Python
- **目标**：输入情报文本，输出结构化的决策建议
- **成本**：几乎为零（DeepSeek API 注册送 token）

### 第二步：建立技术积累（1-2 个月）

- 尝试 LangGraph 实现更复杂的工作流
- 接入真实数据源（数据库、文档）
- 探索本地模型部署（Qwen 7B + llama.cpp）

### 第三步：差异化方向（2-3 个月）

- 基于 OHClaw 在鸿蒙平台上实现分布式多智能体
- 这是目前公开资料中没有看到的方向，值得投入

### 要避免的事

- 不要一上来就搞大架构，先用最简单的框架跑通
- 不要期望 LLM 替代人做决策，它是辅助工具
- 不要忽略模型幻觉问题，Demo 阶段就要加入人工审核环节

---

## 附录

### 框架 GitHub 链接

- CrewAI：https://github.com/crewAIInc/crewAI
- AutoGen / AG2：https://github.com/ag2ai/ag2
- Microsoft Agent Framework：https://github.com/microsoft/autogen
- LangGraph：https://github.com/langchain-ai/langgraph
- MetaGPT：https://github.com/FoundationAgents/MetaGPT

### 关键论文

- MetaGPT: Meta Programming for A Multi-Agent Collaborative Framework (ICLR 2024)：https://arxiv.org/abs/2308.00352
- War and Peace (WarAgent): LLM-based Multi-Agent Simulation of World Wars：https://arxiv.org/abs/2311.17227
- LLM-based Multi-Agents Survey (IJCAI 2024)：https://github.com/taichengguo/LLM_MultiAgents_Survey_Papers

### 开源项目

- WarAgent（战争推演）：https://github.com/agiresearch/WarAgent

### 国内竞品

- 渊亭科技：https://www.utenet.com
- 华如科技：https://www.intesim.com.cn

### API 服务

- DeepSeek API：https://platform.deepseek.com
- DeepSeek 定价：https://api-docs.deepseek.com/quick_start/pricing
