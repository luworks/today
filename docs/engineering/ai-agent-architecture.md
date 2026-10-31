# Today AI：Agent 架构（定稿 v3）

日期 2026-10-31 · 状态：**设计定稿，尚未实现** · 取代 `docs/engineering/ai-architecture.md` 描述的"规则路由 + 多个零散 prompt"架构（那份文档保留为现状审计，迁移完成后删除）。

本文按四步写：§1 先给新框架（v1），§2 和竞品对比，§3 根据对比做优化（v2），§4 给最终版本（v3）以及为什么选它。

资料：OpenAI Responses / Decisions / function calling 官方文档，Apple WWDC26 session，各竞品帮助中心，加上本仓库的现状审计、`docs/qa/decisions-api-spike-20261031.md`、`docs/apple-intelligence.md`、`docs/research/ai-native-vision.md`。标 **[二手]** 的来自媒体或厂商营销，标 **[未核实]** 的还没有用一次真实请求验证过。

模型说明：云端模型是我们自己 Worker 后面的 `gpt-6-luna`（OpenAI Responses API）。所有模型调用都经过一个 `ModelClient` 协议。v1 只有一个实现 `HostedLunaClient`；以后要加本地模型（例如 Llama 或 Apple Foundation Models），就是再写一个实现，不改上层。

---

## 0. 结论（先看这个）

1. **一个 agent，一套带类型的工具，写入规则由代码决定，再加一条纯确定性的快车道。** 删掉现在约 6 个互相重叠的路由器和 5 个各自为政的 prompt。
2. **agent 循环跑在手机上，Worker 只是一个"带锁的转发器"。** 工具读写的是手机本地的 Apple 日历、提醒事项和闹钟，数据不需要上传到我们的服务器。模型每次请求只能看到这一轮需要的东西。
3. **模型永远不直接写。** 写类工具只会生成一张"提议卡"（`Proposal`），由 `ActionPolicy`（代码）决定这张卡是直接执行、显示预览，还是要用户确认后果。产品原则 1–6 写在 `ActionPolicy` 里，模型绕不过去。
4. **快车道只用规则，不联网也能用。** 只有 `CaptureParser` 百分之百确定、而且是"清楚的一次性提醒"时，才直接建，给 Undo。其余全部交给 agent。Decisions API 只是一个**可选**的额外检查：要在盲测集上证明零误判，才能启用。
5. **我们比竞品强的地方要保住：精确的 Undo 收据和 Activity 账本。** 调研中没有任何竞品公开写明"每一次 AI 改动都能精确撤销"。
6. 需要你定的有三件事（§4.7）。最急的是预算：$0.50 的总上限已经用了 $0.31，第一轮评测就会撞线。建议提到 **$5**。

---

## 1. 新框架 v1

### 1.1 一句话和一张图

用户说一句话 → 能确定就走快车道，不能确定就交给 agent → agent 一边查一边想，最后给出提议卡 → 代码决定每张卡怎么处理 → 用户点了才写，写了就能 Undo。

```
 输入：Ask 输入框 / 语音 / 长按条目问 AI（AskSubject） / Reminder·Event·Alarm 快捷键
   │
   ├─①快车道 FastLane（纯规则，本地，<100 ms，离线可用）
   │    CaptureParser 完全确定 + 是清楚的一次性提醒 ──→ ActionPolicy.direct → 直接建 + Undo 收据
   │
   └─②Agent（AgentRunner，跑在手机上）
        │  请求 = [固定前缀：系统提示 + 工具 + skills]（可缓存） + [本轮上下文] + [历史 items]
        ▼
      ModelClient ──HTTPS/SSE──▶ Worker（鉴权、限额、固定模型、固定工具清单）──▶ OpenAI Responses
        ▲                                                             │
        │       function_call（可能多个，读类并行）                    │
        └── ToolRegistry 在手机上执行 ◀───────────────────────────────┘
              读工具 → 直接返回数据
              写工具 → 生成 Proposal（不写），返回 "proposal p1 已展示，等待用户"
        │
        ▼  模型最后给一段简短回复（纯文本）
   ③ActionPolicy：给每个 Proposal 定级 → 卡片 UI（Add/Apply、Undo、Open）
   ④PlannerActions / EventKit / AlarmKit / Ledger（现有代码，不重写）
```

### 1.2 组件

| 组件 | 做什么 | 新写还是复用 |
|---|---|---|
| `FastLane` | 判断"规则是否百分百确定"，确定就构造 Proposal。逻辑来自现有 `OneOffReminderRequest` 和 `CaptureParser` | 复用并收拢 |
| `AgentRunner` | 循环：发请求 → 收流 → 执行工具 → 回填结果 → 直到模型给出最终回复，或到达步数/时间上限。纯 Swift，没有 UI | 新写，约 300–500 行 |
| `ModelClient`（协议） | `func respond(_ req: AgentRequest) -> AsyncThrowingStream<AgentEvent>`。v1 的实现是 `HostedLunaClient`；测试用 `ScriptedModelClient`（回放录好的响应） | 新写，替换 `HostedGPT.generate` |
| Worker `/v1/agent` | 鉴权、按"轮次"计额度、强制步数上限、固定模型和工具清单、SSE 透传、`store:false` | 改写 `backend/luna/worker.mjs` |
| `ToolRegistry` | 每个工具一份：JSON schema、风险元数据、Swift 执行函数。App 内 agent 和 Siri App Intents **共用同一套** | 新写外壳，内部调用现有 `PlannerActions` 等 |
| `ActionPolicy` | 输入 Proposal 和动态事实（有没有参会人、是不是重复事件、是谁发起的），输出 `direct / preview / confirmConsequence / refuse`。原则 1–6 写成代码 | 新写，纯逻辑，单元测试 |
| Skills | 每类事情一小段说明（提醒、事件、闹钟、修改、整理逾期、日程问答），Markdown 文件，带版本号，打包进 App | 新写，替代 `AskQuickKind.skill` 和散落在各处的 prompt |
| 卡片 UI | `CaptureStack` / `ChangeCard` / Tidy 卡，加上 `CardStatus` 和 `StoredCard` | 复用 |
| 写入和撤销 | `PlannerActions`、`TaskActions`、`ListActions`、`Ledger`、`CaptureUndo` | 复用 |

### 1.3 工具清单（v1 共 11 个，彼此不重叠）

读类工具全部自动执行。写类工具全部只生成 Proposal。

| 工具 | 类型 | 参数（strict schema） | 内部调用 |
|---|---|---|---|
| `get_agenda` | 读 | `start`, `end`（ISO 日期）, `kinds[]` | `CalendarEntries.make` |
| `find_items` | 读 | `query`, `kinds[]`, `range?`, `include_done` | SwiftData fetch + EventKit；返回短 id |
| `get_item` | 读 | `id` | 详情：时间、重复、参会人数、所在列表 |
| `free_time` | 读 | `day`, `min_minutes` | `DaySchedule.freeGaps` |
| `list_lists` | 读 | — | `OneList` |
| `resolve_when` | 读 | `text`（如 "下周五下午3点"） | `CaptureParser`：**日期由代码算，不由模型算** |
| `propose_create` | 写→提议 | `items[]`：`kind`, `title`, `when_text`, `list?`, `repeat?`, `ring?` | 内部用 `resolve_when` 解析时间；解析不了就返回错误，让模型追问 |
| `propose_edit` | 写→提议 | `id`, `changes{title?, when_text?, list?, repeat?, done?}` | `AttachedReminderActions` / `setDue` / `moveEvent` 的预览 |
| `propose_delete` | 写→提议 | `id`, `scope`（这一次/整个系列） | `EntryDeletion` 预览 |
| `revise_proposal` | 写→提议 | `proposal_id`, `changes` | 改还没决定的卡（"其实是4点"） |
| `propose_tidy` | 写→提议 | `ids[]?` | `OverdueTidy.suggest` |

不提供的工具：发消息、邀请别人、改设置、删除列表、批量删除，以及任何联网工具（web search、MCP）。这些以后要加，必须单独评审。

### 1.4 一轮对话怎么走（例："把明天下午的牙医改到4点，顺便提醒我买牛奶"）

1. 快车道：一句话里有两件事，规则判定为"不确定"，交给 agent。
2. 第 1 步：模型并行调用 `find_items("牙医", range=明天)` 和 `resolve_when("4点")`。
3. 第 2 步：找到唯一的 `t17`，模型调用 `propose_edit(t17, when_text="明天16:00")` 和 `propose_create([{reminder, "买牛奶"}])`。
4. `ActionPolicy`：改期定为 preview；买牛奶没有时间，也定为 preview（agent 发起的创建不走 direct）。
5. 模型回复："改好了两张卡，点 Apply 就生效。" 用户点 Apply，写入，Ledger 记录，可以 Undo。

### 1.5 上下文和状态

- **固定前缀**（每个请求都一样，命中缓存）：系统提示、11 个工具的 schema、所有 skills。总共约 5–7K token。缓存价格 $0.01/M，几乎不花钱。
- **本轮上下文**（放在最后）：当前时间、时区、语言，当前所在的 tab 和日期，附着的条目（`AskSubject`），以及选中的快捷键 skill 名。**数据不预先塞进去**，模型需要什么就用工具查什么。
- **历史**：每一步返回的 `output` items（包括加密的 reasoning item 和 `phase`）原样存在本机 `ChatThread`，下一轮原样回放。OpenAI 端 `store:false`，不使用 `previous_response_id` 或 Conversations API（这两者都要求 OpenAI 存数据，Conversations 也不支持零数据保留）。
- SwiftData：`ChatThread` 新增一个**可选**字段 `agentItems: Data?`。这是增量迁移，老数据照常可读，做法和当年保留 `plannedStart`、`Habit` 一样。

---

## 2. 和竞品对比

| | 循环结构 | 动作怎么定义 | 什么时候要确认 | 撤销 / 记录 | 数据在哪 |
|---|---|---|---|---|---|
| **Apple Siri（iOS 27）** | 系统统一调度，App 只负责执行 | App Intents + 官方 app schemas（如 `.calendar.event`） | 按 schema 元数据加动态状态计算；私有条目可以直接做，**共享条目（有参会人）要确认** | 没看到 Undo 的说明 | 端侧 8K / PCC 32K。"Siri 底层用 Gemini" 是 **[二手]**；提醒事项的 schema **[未核实]** |
| **Google Gemini** | 云端 agent | 内部工具、MCP | 发送、删除、购买要确认；**批量处理 Tasks 时不确认** | 确认通知里有 Undo 链接；已经发给参会人的邮件撤不回 | 全在云端 |
| **Microsoft Copilot（Outlook）** | 规则驱动的 agent | 没有公开 | "长期规则"只确认一次，之后自动执行 | Activity history 带理由，**没有 Undo** | 云端，App 关着也会执行 |
| **ChatGPT** | Agent / Work | Apps SDK 工具带 `readOnlyHint` / `destructiveHint` | 带 `destructiveHint` 的要批准；但这只影响界面提示，**服务端必须自己再校验** | 没找到 | 云端 + 记忆 + Pulse 夜间批处理 |
| **Claude 应用** | 单 agent + 连接器 | MCP | 每个工具可以设"总是允许 / 需要批准 / 禁止" | 没找到 | 云端 |
| **Notion Agent** | 单 agent；自定义 agent 可以定时跑 | 没有公开 | 三档：总是问 / 让 agent 自审（默认） / 全部跳过 | 让 agent 自己撤，或者用页面历史 | 云端，权限等同用户本人 |
| **Todoist Ramble** | 只有工具、没有文字输出的模型（Gemini Live 音频） | add/edit/delete task | 先全部进预览，用户说"就这些"再一起提交；可以口头改（"其实我是说……"） | 没找到 | 必须联网；项目和标签全量塞进 prompt |
| **Motion / Reclaim** | 自动排程 | Reclaim 提供 MCP **[厂商]** | Motion 自动重排（**用户抱怨最多**）；Reclaim 说先放进预览沙箱 **[厂商]** | 没找到 | 云端 |
| **Today v1** | 单 agent，循环在手机上，加规则快车道 | 11 个 strict schema 工具，和 Siri 共用 | 由代码定级：只有快车道的一次性提醒直接做，其余预览；有参会人或整个系列的要确认后果 | **每次改动都有精确的 Undo 收据和 Ledger** | 数据留在本机；每次只发这一轮相关的部分；OpenAI `store:false` |

**我们领先的地方：** 精确 Undo 收据、Ledger 账本、数据留在本机、"会议不会被偷偷挪"。

**我们缺的（v1 还没做）：**
1. Apple 的风险**由元数据加动态事实计算**，v1 的 `ActionPolicy` 还是手写的分支。
2. Todoist 的**批量预览加口头修改**，v1 有 `revise_proposal`，但没有"整批一起确认"。
3. Apple 专门警告过**prompt injection**：别人发来的日历邀请标题里可能藏着指令，v1 没有处理。
4. Copilot 的**每条动作都带理由**，v1 的 Proposal 没有 `why`。
5. Gemini / Siri 的**系统入口**：v1 的 Siri 还走老的 intent 规则。
6. 延迟：v1 没写具体手段和目标。

---

## 3. 优化（v2）：从对比里学到的

| # | 优化 | 学自 | 改了什么 |
|---|---|---|---|
| O1 | **工具自带风险元数据，确认级别由代码计算** | Apple schema 加 entity ownership；ChatGPT `destructiveHint` | 每个工具声明 `effect: read / create / modify / delete`、`reversible`、`audience`（`self / others`）。`ActionPolicy.tier = f(元数据, 动态事实)`，动态事实包括参会人数、是否重复、发起来源（快车道 / agent / Siri）、条目是否刚被改过 |
| O2 | **整批预览，可以口头改** | Todoist Ramble | 同一条消息产生的多张卡显示为一组，带"全部添加"按钮；用户追问"其实是4点"时，agent 用 `revise_proposal` 改原卡，不新增卡 |
| O3 | **别人的数据一律当作不可信** | Apple WWDC26 安全 session（"lethal trifecta"） | 工具返回结果时，把别人写的标题和备注包在 `<untrusted>` 里；**任何写类 Proposal 都必须能追溯到用户自己打的字**，不能由数据内容触发；快车道只看用户原话 |
| O4 | **每张卡带一句理由** | Copilot activity history | Proposal 增加 `why` 字段（≤80 字，由模型写），卡片上显示，并写进 Ledger |
| O5 | **Siri 和 App 内 agent 共用 ToolRegistry** | Apple app schemas | App Intents 直接调 ToolRegistry 和 ActionPolicy（Siri 本身就是 agent）；iOS 27 上采用官方 calendar schema，有参会人的事件用 `OwnershipProvidingEntity` 标为 shared |
| O6 | **延迟手段写成规定** | OpenAI 延迟指南 | 流式输出；固定前缀让缓存命中；先输出一句话（`phase: commentary`）再深入；读类工具并行；effort 先用 `low`，由评测决定要不要升到 `medium`；可选 `service_tier: fast`（2 倍价格，要测才知道值不值） |
| O7 | **评测在本地做** | OpenAI 托管的 Evals 平台今天（10/31）变只读，11/30 关闭 | 两套：①`ScriptedModelClient` 回放录好的响应，作为单元测试进 CI，确定性、免费；②真实评测脚本经 Worker 跑开发集和**盲测集**，指标见 §4.3 |
| O8 | **"少一跳"的小快照** | Todoist 把项目列表塞进 prompt | **不做全量塞入。** 只有问日程类问题时，第一步由代码顺手附上今天的精简日程（≤20 条），省掉一次 `get_agenda` 往返。是否值得做由评测决定 |
| O9 | **不做"长期规则 / 自动执行"** | Copilot、Motion 的反面教训 | v3 明确不做。以后要做，按 `ai-native-vision.md` §3.8 的自主权阶梯另行评审 |

---

## 4. 最终版本 v3

v3 = v1 加上 O1–O7，O8 待评测决定，O9 明确不做。下面是落地需要的全部规定。

### 4.1 最终结构

```
FastLane（规则，本地）──┐
                        ├─▶ Proposal[] ─▶ ActionPolicy（元数据 + 动态事实）─▶ 卡片组 ─▶ 用户 ─▶ PlannerActions + Ledger + Undo
AgentRunner ──ModelClient──Worker──Luna   │
  └─ ToolRegistry（11 个工具，Siri 共用）─┘
```

**为什么 Proposal 是唯一出口：** 不管来源是快车道、agent 还是 Siri，写操作都先变成一个带类型的 `Proposal`，再由同一个 `ActionPolicy` 定级、同一套卡片显示、同一个 `Ledger` 记录。这样原则 1 只需要在一个地方保证。

### 4.2 关键规则

- `ActionPolicy.direct` 只有一种情况：**来源是快车道，而且是清楚的一次性提醒**（现行例外，范围不变）。agent 和 Siri 产生的一律至少 preview（Siri 的确认由系统界面完成）。
- 有参会人、整个系列、删除事件：定级为 `confirmConsequence`，卡片写明"会通知 N 人 / 影响整个系列"。
- 原则 2–6 是硬约束：事件不能被模型自发挪动；提醒只有 `due`；停闹钟 ≠ 完成；笔记不会自动变成任务；逾期不会被悄悄挪走。这些都写成 `ActionPolicy` 的单元测试。
- 单轮上限：**最多 6 步、30 秒**。超出就停下，把已有的 Proposal 和"没做完"告诉用户。
- 失败：网络、额度或超时出问题时，显示"AI 暂时不可用"，并保留用户的草稿；快车道照常可用。不会悄悄回退到另一个模型。

### 4.3 目标（评测的及格线）

| 指标 | 目标 |
|---|---|
| 快车道本地耗时 | < 100 ms |
| agent 到第一张卡 | p50 ≤ 3 s，p90 ≤ 6 s |
| 每轮步数 | p90 ≤ 4 |
| 每轮成本 | ≤ $0.002（固定前缀命中缓存时） |
| 盲测集上的不安全写入 | **0**（没点就写了、写错了对象、挪了不该挪的事件） |
| 盲测集上的任务完成率 | ≥ 90%，并且要高于现架构在同一套题上的成绩 |

成本估算：每轮约 3 步。每步缓存前缀约 6K token（$0.01/M），新输入约 2K token（$0.10/M），输出加 reasoning 约 800 token（$0.50/M），合计每轮约 $0.002。按每人每天 40 轮算，约 $0.08/人/天。

### 4.4 Worker 合同（`/v1/agent`）

| 项目 | 现在（`/v1/responses`） | v3 |
|---|---|---|
| 输入 | 只接受字符串 `input` 和 `instructions` | items 数组（message、`function_call`、`function_call_output`、reasoning） |
| 工具 | 禁止 | **服务端白名单**，按 `tools_version` 选择；客户端不能自带工具 |
| 输出格式 | 必须是 strict JSON | 最终回复是纯文本；Proposal 只能从工具调用里来 |
| 体积上限 | 24 KB | 约 256 KB（历史要每步重发） |
| 上游超时 | 20 s | 每步 30 s，整轮 30 s 由客户端控制 |
| 流式 | 不支持 | SSE 透传 |
| 额度 | 每次调用算一次：6/分钟、40/天 | **按轮算**：每轮最多 6 步；40 轮/天；Worker 自己数步数（OpenAI 的 `max_tool_calls` 不管自定义函数） |
| 模型 / effort / store | 固定 | 固定（`gpt-6-luna`、`low` 起步、`store:false`） |

### 4.5 迁移步骤（每步一个 PR，就绪就合并）

| 阶段 | 内容 | 删除什么 |
|---|---|---|
| **P0** | Worker `/v1/agent` 加测试；用一次真实请求验证 §4.8 的未知项 | — |
| **P1** | 把写入逻辑从界面里抽出来，做成 `ToolRegistry` 和 `ActionPolicy`，**行为不变**。重点是 `AskView.swift` 里的 `AskNativeActions.applyChange` 和 `applyTidy`（约 2232–2470 行），以及 `apply` 里系统事件改期的编排 | — |
| **P2** | `AgentRunner`、`ModelClient`、`HostedLunaClient`、`ScriptedModelClient`、skills 文件；放在开关 `today.ai.agent` 后面（默认关） | — |
| **P3** | 评测：开发集加**新写的盲测集**，新旧架构跑同一套题，量 §4.3 的指标。可选：在同一套题上测 Decisions 作为快车道的额外检查 | — |
| **P4** | 默认打开 agent，删除旧管线 | `ChatRouting`、`Dialogue`（**保留** `CaptureConversation.parse`，Siri 在用）、`Understanding`、`AICapture`、`ChatResponse`、`Editing`、`AskSuggestionRanker`、`SentenceRoute` 等路由规则、`EditingLogic` 的判断部分（**保留** `newStart`）、`AskView` 里的路由部分（目标是从 2492 行降到 1000 行以下）、约 20 个测试文件（约 230 个测试）、`ios/Eval/Understanding`、旧的 AI 文档 |
| **P5** | Siri 接入 ToolRegistry；iOS 27 采用 app schemas | `IntentLogic` 中和 ToolRegistry 重复的部分 |

**一定保留：** `CaptureParser`（日期由代码算）、`IntentLogic` 和 `EditingLogic.newStart`（Siri 在用）、`PlannerActions` / `Ledger` / Undo、卡片 UI、`OverdueTidy.suggest`、`ListGuess`。

### 4.6 为什么选这个，而不选别的

| 备选方案 | 为什么不选 |
|---|---|
| 保留现状，继续加规则和 prompt | 这就是今天的问题：6 个路由器互相打架、`AskView` 2500 行、5 个 prompt 超时各不相同，越改越乱 |
| 多 agent（总管 + 专家） | 我们的任务很窄，单 agent 加 11 个不重叠的工具就够用。多 agent 的 token 消耗约 15 倍，延迟也更高（Anthropic、OpenAI 的指南都建议先把单 agent 用到极限） |
| agent 循环放在服务器上 | 工具要读写手机里的日历和提醒，放在服务器上就得把用户数据上传，违背"数据留在本机" |
| 端侧 Foundation Models 当 agent | 上下文只有 4–8K；我们实测它在时间计算上只对了 26%，也不会追问。只留一个 `ModelClient` 的空位，等它变强 |
| Decisions API 做总路由 | 它只能做选择题，填不了标题和时间，还多一跳；在 27 句的开发集上，"信息够不够"那道题确定度 0.98 时还会答错。只保留为可选的额外检查 |
| OpenAI Agents SDK | 没有 Swift 版本；用它就得把循环放到服务器上（同上） |
| `previous_response_id` / Conversations API | 要求 OpenAI 存数据，Conversations 也不支持零数据保留；我们自己在本机回放历史 |

**一句话：** 这是满足"数据留在本机、写入由代码决定、离线也能用、成本可控"这四个条件的最简单结构，而且大部分零件（写入、Undo、卡片、日期解析）已经是现成的。

### 4.7 需要你定

1. **预算上限**：建议从 $0.50 提到 **$5**。按每轮 $0.002 算，大约能跑 2,500 轮，足够 P3 的几轮评测加上自己日常用。
2. **effort**：建议**先用 `low`**。P3 评测时也跑一遍 `medium`，如果完成率高出 5 个百分点以上，再升级。
3. **离线**：建议**只保留快车道，另外显示"AI 离线"**，不再维护第二套引擎。

### 4.8 P0 要用一次真实请求验证的未知项（都不作为设计前提）

- 同一个请求里同时传 `tools` 和 `text.format` 是否可行。v3 不依赖它：最终回复就是纯文本。
- `gpt-6-luna` 的 `reasoning.context` 默认值；加密 reasoning 在 `store:false` 下回放是否正常。
- `async: true` 工具的实际表现。v3 不依赖它。
- 缓存 TTL 是 30 分钟还是 12 小时。按 30 分钟设计。
- `service_tier: fast` 在 Luna 上实际能快多少。

## 来源

- OpenAI：[Function calling](https://developers.openai.com/api/docs/guides/function-calling) · [Conversation state](https://developers.openai.com/api/docs/guides/conversation-state) · [Reasoning](https://developers.openai.com/api/docs/guides/reasoning) · [Prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching) · [Latency](https://developers.openai.com/api/docs/guides/latency-optimization) · [Decisions](https://developers.openai.com/api/docs/guides/decisions) · [gpt-6-luna](https://developers.openai.com/api/docs/models/gpt-6-luna) · [Your data](https://developers.openai.com/api/docs/guides/your-data) · [Evals 下线通知](https://developers.openai.com/api/docs/guides/evaluation-getting-started) · [A practical guide to building agents](https://cdn.openai.com/business-guides-and-resources/a-practical-guide-to-building-agents.pdf) · [Agents SDK HITL](https://openai.github.io/openai-agents-js/guides/human-in-the-loop/) · [Apps SDK reference](https://developers.openai.com/apps-sdk/reference)
- Apple：[WWDC26 240](https://developer.apple.com/videos/play/wwdc2026/240) · [343](https://developer.apple.com/videos/play/wwdc2026/343) · [347（安全）](https://developer.apple.com/videos/play/wwdc2026/347/) · [241（Foundation Models）](https://developer.apple.com/videos/play/wwdc2026/241)
- Anthropic：[Building effective agents](https://www.anthropic.com/engineering/building-effective-agents) · [Context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) · [Multi-agent research system](https://www.anthropic.com/engineering/multi-agent-research-system)
- 竞品：[Gemini 帮助](https://support.google.com/gemini/answer/17094507) · [Copilot 日历指令](https://support.microsoft.com/outlook/calendar-instructions-in-outlook-and-copilot) · [Office365 IT Pros 评测](https://office365itpros.com/2026/07/07/calendar-agent-disappoints/amp/)（二手） · [Claude 工具权限](https://support.claude.com/en/articles/11176164) · [Notion 审批模式](https://www.notion.com/help/choose-how-notion-agent-asks-for-your-approval) · [Todoist Ramble](https://www.todoist.com/help/articles/dictate-to-add-tasks-with-ramble-P1Raq7vVF) · [Building Ramble](https://www.producttalk.org/building-todoist-ramble-how-doist-turned-voice-braindumps-into-real-time-task-capture/)（二手） · [Motion](https://www.usemotion.com/ai-employees)（厂商） · [Motion 评测](https://www.usecarly.com/blog/motion-ai-review/)（二手） · [Reclaim](https://reclaim.ai/blog/slack-mcp-server)（厂商）
