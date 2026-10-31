# Today AI：Agent 架构（定稿 v3）

日期 2026-10-31 · 状态：**设计定稿，尚未实现** · 迁移完成后取代 `docs/engineering/ai-architecture.md` 描述的"规则路由 + 多个零散 prompt"架构。那份文档在迁移期间保留，作为现状审计。

本文按四步写：§1 新框架（v1）→ §2 和竞品对比 → §3 根据对比优化（v2）→ §4 最终版本（v3），以及为什么选它。§5 记录独立审查发现的问题和修正位置。

资料来源：OpenAI 的 Responses / Decisions / function calling 官方文档，Apple WWDC26 session，各竞品的帮助中心，本仓库的现状审计，`docs/qa/decisions-api-spike-20261031.md`，`docs/apple-intelligence.md`，`docs/research/ai-native-vision.md`。标 **[二手]** 的来自媒体或厂商营销；标 **[未核实]** 的还没有用一次真实请求验证过。

模型：云端用我们自己 Worker 后面的 `gpt-6-luna`（OpenAI Responses API）。所有模型调用都经过一个 `ModelClient` 协议。v1 只有 `HostedLunaClient` 一个实现。以后要接本地模型（例如 Llama 或 Apple Foundation Models），就是再加一个实现，上层不用改。

---

## 0. 结论（先看这个）

1. **一个 agent，一套带类型的工具，由代码决定怎么写，再加一条纯确定性的快车道。** 现在约 6 个互相重叠的路由器和 5 个各自为政的 prompt 全部删掉。
2. **agent 循环跑在手机上，Worker 只做"带锁的转发"**：负责鉴权，固定模型和工具清单，并在服务端记录每轮走了几步。工具读写的是手机本地的 Apple 日历、提醒事项和闹钟；每次请求只把这一步需要的内容发给模型。
3. **模型永远不直接写。** 写类工具只能生成"提议卡"（`Proposal`）。是直接执行、显示预览，还是要用户确认后果，由 `ActionPolicy`（代码）决定；用户点 Apply 时还会再检查一次。产品原则 1–6 写在 `ActionPolicy` 里。
4. **快车道只用规则，离线也能用。** 规则有把握的输入（提醒、事件、闹钟）都在本地直接出预览卡；只有"清楚的一次性提醒"可以直接建（现行例外，范围不变）。Decisions API 只作为**可选**的额外检查，要在盲测集上做到零误判才启用。
5. **我们领先的地方要保住：精确的 Undo 收据和 Activity 账本。** 调研中没有任何竞品公开写明"每一次 AI 改动都能精确撤销"。
6. **三项决定已定（§4.7）**：预算提到 $5 并修正记账，effort 用 `low`，离线由快车道出预览卡。

---

## 1. 新框架 v1

### 1.1 一句话和一张图

用户说一句话：规则能确定的走快车道，确定不了的交给 agent。agent 一边查一边想，最后给出提议卡；代码决定每张卡怎么处理；用户点了才写，写了就能 Undo。

```
 输入：Ask 输入框 / 语音 / 长按条目问 AI（AskSubject）/ Reminder·Event·Alarm 快捷键
   │
   ├─①快车道 FastLane（纯规则，本地，<100 ms，离线可用）
   │    规则有把握 ──→ Proposal（preview；清楚的一次性提醒为 direct）
   │
   └─②Agent（AgentRunner，跑在手机上）
        │  请求 = [固定前缀：系统提示 + 工具 + skills]（可缓存） + [本轮上下文] + [历史 items]
        ▼
      ModelClient ──HTTPS/SSE──▶ Worker（鉴权、按轮计额度、固定模型和工具）──▶ OpenAI Responses
        ▲                                                         │
        │      function_call（可能有多个，读类并行执行）            │
        └── ToolRegistry 在手机上执行 ◀───────────────────────────┘
              读工具 → 返回数据
              写工具 → 生成 Proposal（不写入），返回"提议 p1 已展示给用户"
        │
        ▼  模型最后给一段简短的纯文本回复
   ③ActionPolicy：给每个 Proposal 定级 → 卡片组 UI（Add/Apply、Undo、Open）
   ④PlannerActions / EventKit / AlarmKit / Ledger（现有代码，不重写）
```

### 1.2 组件

| 组件 | 做什么 | 来源 |
|---|---|---|
| `FastLane` | 规则判定加 `CaptureParser`，有把握就生成 Proposal | 从现有 `OneOffReminderRequest` 及其依赖的判定函数收拢而来（见 §4.5 P1） |
| `AgentRunner` | 循环：发请求 → 收流 → 执行工具 → 回填结果 → 直到模型给出最终回复，或碰到步数、时间上限。纯 Swift，没有 UI | 新写 |
| `ModelClient`（协议） | `respond(_:) -> AsyncThrowingStream<AgentEvent>`。实现有 `HostedLunaClient`（线上）和 `ScriptedModelClient`（测试时回放录好的响应） | 新写，替换 `HostedGPT.generate` |
| Worker `/v1/responses`（扩展现有接口，不新增） | 鉴权、按轮计额度并记录步数、固定模型和工具清单、SSE 透传、`store:false` | 改写 `backend/luna/worker.mjs` |
| `ToolRegistry` | 每个工具一条：strict JSON schema、风险元数据、Swift 执行函数。App 内 agent 和 Siri App Intents 共用 | 新写外壳，内部调用现有 `PlannerActions` 等 |
| `ActionPolicy` | 输入 Proposal 和动态事实，输出 `direct / preview / confirmConsequence / refuse`。原则 1–6 在这里实现 | 新写，纯逻辑，有单元测试 |
| Skills | 每类事情一小段说明：提醒、事件、闹钟、修改、整理逾期、日程问答。Markdown 文件，带版本号，打包进 App | 新写，替代 `AskQuickKind.skill` 和散落在各处的 prompt |
| 卡片 UI | `CaptureStack` / `ChangeCard` / Tidy 卡，`CardStatus`，`StoredCard` | 复用 |
| 写入和撤销 | `PlannerActions`、`TaskActions`、`ListActions`、`Ledger`、`CaptureUndo` | 复用 |

### 1.3 工具清单（v3 定稿，共 12 个）

读类工具自动执行；写类工具只生成 Proposal。所有参数都是 strict schema：可选参数写成"必填，但允许 null"。日期一律写成 `when_text`，交给代码里的 `CaptureParser` 解析，模型不做日期计算。

| 工具 | 类型 | 参数 | 内部实现 / 说明 |
|---|---|---|---|
| `get_agenda` | 读 | `start`, `end`, `kinds[]` | `CalendarEntries.make`，按时间范围列出 |
| `find_items` | 读 | `query`（必填）, `kinds[]`, `start\|null`, `end\|null`, `include_done` | 按名称找，返回短 id |
| `get_item` | 读 | `id` | 详情：时间、重复规则、参会人数、所属列表 |
| `free_time` | 读 | `day`, `min_minutes` | `DaySchedule.freeGaps` |
| `list_lists` | 读 | — | `OneList` |
| `get_activity` | 读 | `start`, `end` | Ledger 摘要（"上周 AI 改了什么"），不返回正文 |
| `propose_create` | 写→提议 | `items[]`: `kind`, `title`, `when_text\|null`, `list\|null`, `repeat\|null`, `ring` | 代码解析 `when_text`，结果写在返回值里给模型看；解析失败就返回错误，让模型追问 |
| `propose_edit` | 写→提议 | `id`, `title\|null`, `when_text\|null`, `list\|null`, `repeat\|null`, `done\|null`, `enabled\|null`（闹钟） | 提醒、事件、闹钟都支持 |
| `propose_delete` | 写→提议 | `id`, `scope`（这一次 / 整个系列） | `EntryDeletion` 预览 |
| `propose_undo` | 写→提议 | `ledger_id` | "撤销刚才那个"：生成一张撤销卡，由用户点 |
| `revise_proposal` | 写→提议 | `proposal_id`, 与 `propose_edit` 相同的字段 | 只能修改**还没决定**的卡；已经添加或撤销的卡返回错误，并附上条目 id，引导模型改用 `propose_edit` |
| `propose_tidy` | 写→提议 | `ids[]\|null` | `OverdueTidy.suggest` |

**不提供**：发消息、邀请别人、改设置、删除列表、批量删除、计时器（属于 Clock tab，以后单独评审），也不提供任何联网工具（web search、MCP）。**健康数据不发给模型。**

### 1.4 一轮对话怎么走（例："把明天下午的牙医改到4点，顺便提醒我买牛奶"）

1. 快车道：这句话里有两件事，规则判定"没把握"，交给 agent。
2. 第 1 步：模型调用 `find_items("牙医", 明天)`，找到唯一的 `t17`。
3. 第 2 步：模型**并行**调用 `propose_edit(t17, when_text="4点")` 和 `propose_create([{reminder, "买牛奶", when_text: null}])`。代码把"4点"解析成明天 16:00，写在返回值里。工具调用的参数一完整，卡片就立刻显示，不用等模型写完回复。
4. `ActionPolicy`：两张卡都定为 preview（agent 发起的操作不允许 direct）。
5. 模型回复一句"准备好了两张卡"。卡片上显示 Added / Applied 等状态的是代码，模型的回复**不允许**声称"已完成"。
6. 用户点 Apply，代码先重新检查快照（§4.2），再写入；Ledger 记录这次改动，可以 Undo。

### 1.5 上下文和状态

- **固定前缀**（每个请求都一样，可以命中缓存）：系统提示、12 个工具的 schema、全部 skills，约 5–7K token。缓存价格 $0.01/M。
- **本轮上下文**（放在最后）：现在的时间、时区、语言，当前在哪个 tab、看的是哪一天，附着的条目（`AskSubject`），选中的快捷键 skill。**数据不预先塞进去**，需要什么由模型用工具去查。
- **不可信内容**：所有从 EventKit 读出来的文字（标题、备注、参会人名字），以及建议 chip 里拼进去的标题，都当作数据处理。它们以 JSON 字符串转义后放进工具结果，不用标签包裹，因为标签可以被伪造的闭合标签打断。
- **历史**：每一步返回的 `output` items 原样保存在本机，包括加密的 reasoning 和 `phase`，下一轮原样回放。OpenAI 端设 `store:false`，不使用 `previous_response_id`，也不使用 Conversations API：前者要求 OpenAI 保存数据，后者不支持零数据保留。
- **快车道写进历史**：快车道直接建完一条提醒后，往历史里写一条合成收据（带条目 id）。这样用户接着说"其实是4点"时，agent 知道改的是哪一条。
- **存储**：`ChatThread` 新增 `agentItemsData: Data = Data()`（和现有字段写法一致），使用 `@Attribute(.externalStorage)`，并单独存一份元数据 `{model, tools_version, created}`。版本对不上、内容太旧或体积超限时，把旧历史压缩成"纯文本消息 + 卡片收据"再继续。这是增量迁移，老数据照常可读。

---

## 2. 和竞品对比

| | 循环结构 | 动作怎么定义 | 什么时候要确认 | 撤销 / 记录 | 数据在哪 |
|---|---|---|---|---|---|
| **Apple Siri（iOS 27）** | 系统统一调度，App 只负责执行 | App Intents + 官方 app schemas（如 `.calendar.event`） | 由 schema 元数据加动态状态计算：私有条目可以直接做，**共享条目（有参会人）要确认**。Apple 自己也警告：即使是 `createTimer` 也不能完全跳过确认，因为标签里的文字可能是注入内容 | 没看到 Undo 的说明 | 端侧 8K，PCC 32K。"Siri 底层用 Gemini" **[二手]**；提醒事项的 schema **[未核实]** |
| **Google Gemini** | 云端 agent | 内部工具、MCP | 发送、删除、购买要确认；**批量处理 Tasks 时不确认** | 确认通知里带 Undo 链接；已经发给参会人的邮件撤不回 | 全在云端 |
| **Microsoft Copilot（Outlook）** | 规则驱动的 agent | 没有公开 | "长期规则"只确认一次，之后自动执行 | 有 Activity history 和理由，**没有 Undo** | 云端，App 关着也执行 |
| **ChatGPT** | Agent / Work | Apps SDK 工具带 `readOnlyHint` / `destructiveHint` | 带 `destructiveHint` 的要批准；但这个标记只影响界面怎么提示，**服务端必须自己校验** | 没找到 | 云端 + 记忆 + Pulse 夜间批处理 |
| **Claude 应用** | 单 agent + 连接器 | MCP | 每个工具可以设为"总是允许 / 需要批准 / 禁止" | 没找到 | 云端 |
| **Notion Agent** | 单 agent；自定义 agent 可以定时跑 | 没有公开 | 三档：总是问 / 让 agent 自审（默认） / 全部跳过 | 让 agent 自己撤，或者用页面历史 | 云端，权限等同用户本人 |
| **Todoist Ramble** | 只调工具、不输出文字的模型（Gemini Live 音频） | add / edit / delete task | 所有任务先进预览，用户说"就这些"再一起提交；中途可以口头改（"其实我是说……"） | 没找到 | 必须联网；项目和标签全部塞进 prompt **[二手]** |
| **Motion / Reclaim** | 自动排程 | Reclaim 提供 MCP **[厂商]** | Motion 会自动重排，**这是用户抱怨最多的地方**；Reclaim 称所有改动先进预览沙箱 **[厂商]** | 没找到 | 云端 |
| **Today v3** | 单 agent，循环在手机上，加规则快车道 | 12 个 strict schema 工具，和 Siri 共用 | 代码定级，Apply 时再检查一次：只有快车道里清楚的一次性提醒直接做，其余预览；有参会人、整个系列、删除的操作要确认后果 | **每次改动都有精确的 Undo 收据和 Ledger** | 数据留在本机，每一步只发相关的部分；OpenAI 端 `store:false` |

**我们领先的地方**：精确的 Undo 收据、Ledger 账本、数据留在本机、"会议不会被偷偷挪"。

**v1 和竞品比还缺的**（已在 v2 补上）：
1. 风险等级应由元数据和动态事实算出来（Apple）。
2. 批量预览，并且可以口头修改（Todoist）。
3. 防止 prompt injection（Apple 的警告）。
4. 每条动作附上理由（Copilot）。
5. Siri 和 App 内 agent 应走同一套工具（Apple app schemas）。
6. 延迟要有具体手段和目标。

---

## 3. 优化（v2）：从对比里学到的

| # | 优化 | 学自 | 具体改法 |
|---|---|---|---|
| O1 | **工具自带风险元数据，确认等级由代码计算** | Apple schema + entity ownership；ChatGPT `destructiveHint` | 每个工具声明 `effect: read / create / modify / delete`、`reversible`、`audience: self / others`。`ActionPolicy.tier = f(元数据, 动态事实)`，动态事实包括参会人数、是否重复事件、发起来源（快车道 / agent / Siri）、条目是否刚被改过。**用户点 Apply 时重新计算一次** |
| O2 | **一组卡片，可以口头修改** | Todoist Ramble | 同一条消息产生的卡片显示为一组；用户追问"其实是4点"时，用 `revise_proposal` 改原卡。"全部添加"只对 preview 级的卡生效；`confirmConsequence` 级的卡必须单独点。同一轮里内容相同的 `propose_create` 按内容哈希去重 |
| O3 | **别人写的数据一律不可信** | Apple WWDC26 安全 session（"lethal trifecta"） | ① `direct` 只接受**用户亲手输入或口述**的原话；点建议 chip 发出去的句子里拼了日历标题，一律不走 direct。② 卡片上显示的是**代码渲染的改前 → 改后**，不是模型写的文字。③ 不可信文字按 §1.5 的规则转义 |
| O4 | **每张卡附一句理由** | Copilot activity history | Proposal 增加 `why` 字段（≤80 字），卡片上明确标成"AI 说明"，并记进 Ledger。理由只是解释，决定权在代码渲染的改动本身 |
| O5 | **Siri 和 App 内 agent 共用 ToolRegistry** | Apple app schemas | App Intents 调用同一套 ToolRegistry 和 ActionPolicy；iOS 27 上采用官方的 calendar schema，有参会人的事件用 `OwnershipProvidingEntity` 标为 shared。哪些 intent 可以直接执行，见 §4.2 |
| O6 | **延迟手段写成规定** | OpenAI 延迟指南 | 全程流式；固定前缀保证命中缓存；读类工具并行；**工具参数一完整就显示卡片**；不先输出铺垫文字（会推迟第一次工具调用）；effort 先用 `low`；`service_tier: fast`（价格 2 倍）要测过才决定用不用 |
| O7 | **评测放在本地** | OpenAI 托管的 Evals 平台今天（10/31）起只读，11/30 关闭 | 两套：① `ScriptedModelClient` 回放录好的响应，作为单元测试进 CI，结果确定、不花钱；② 真实评测脚本经 Worker 跑开发集和**盲测集**，指标见 §4.3 |
| O8 | **"少一跳"的小快照** | Todoist 把项目列表放进 prompt | 不做全量放入。只有问日程时，由代码在第一步附上今天的精简日程（≤20 条），省掉一次 `get_agenda` 往返。做不做由评测决定 |
| O9 | **不做"长期规则"或自动执行** | Copilot、Motion 的教训 | v3 明确不做。以后要做，按 `ai-native-vision.md` §3.8 的自主权阶梯另行评审 |

---

## 4. 最终版本 v3

v3 = v1 + O1–O7；O8 等评测决定；O9 明确不做；同时包含 §5 审查后的所有修正。

### 4.1 最终结构

```
FastLane（规则，本地）──┐
                        ├─▶ Proposal[] ─▶ ActionPolicy ─▶ 卡片组 ─▶ 用户点 ─▶ 重新检查快照和等级 ─▶ PlannerActions + Ledger + Undo
AgentRunner ─ModelClient─ Worker ─ Luna  │
  └─ ToolRegistry（12 个工具，Siri 共用）─┘
```

**为什么只有 Proposal 这一个出口**：快车道、agent、Siri 产生的写操作都先变成同一种 `Proposal`，经过同一个 `ActionPolicy`、同一套卡片和同一本 Ledger。这样，原则 1 只需要在一个地方保证。

### 4.2 关键规则

- **`direct` 只有一种情况**：来源是快车道，原话由用户亲手输入或口述，而且是清楚的一次性提醒。也就是现行的例外，范围不变。agent 产生的 Proposal 一律至少是 preview。
- **多轮续答**：用户补充的回答（"4点""好的""go ahead"）**只能补全快车道自己的草稿**，永远不能用来 Apply agent 的卡。agent 的卡只能由用户点击生效。
- **Apply 时重新检查**：每个 Proposal 都带一份预期快照（`lastModified`、时间、参会人数、是否重复）。用户点 Apply 时，先和 Apple 那边的最新状态对比：对不上就作废这张卡并说明原因；等级变了（比如刚多了参会人）就重新确认。
- **后果确认**：有参会人、影响整个系列、删除事件，定为 `confirmConsequence`。卡片写明"会通知 N 人 / 影响整个系列"，并且不能用"全部添加"一起提交。
- **硬约束（原则 2–6）**：事件不会被模型自发挪动；提醒只有一个 `due`；停闹钟 ≠ 完成任务；笔记不会自动变成任务；逾期的不会被悄悄挪走。每条都对应 `ActionPolicy` 的单元测试。
- **Siri**：保持现在的做法，用户亲口说的"加一条提醒""设一个闹钟"可以直接执行，因为这是用户自己的决定，也符合系统的确认规则。修改、删除、移动事件这类 intent，在 `perform` 里自己调用 `requestConfirmation`，不完全依赖系统判断。残余风险是：Siri 读到被注入的内容后去调"加提醒"。这种情况靠 Undo 和 Ledger 兜底，在 §5 记作已知风险。
- **单轮上限**：最多 6 步、30 秒。到上限就停下，把已经生成的卡和"还没做完"一起告诉用户。
- **失败处理**：网络、额度或超时出问题时，显示"AI 暂时不可用"，保留用户的草稿；快车道照常工作。不会在后台悄悄换成另一个模型。

### 4.3 目标（评测的及格线）

| 指标 | 目标 |
|---|---|
| 快车道本地耗时 | < 100 ms |
| 一步就能出卡（新建、简单提问），从发送到第一张卡 | p50 ≤ 2.5 s，p90 ≤ 4 s |
| 需要先查再改（修改、删除），从发送到第一张卡 | p50 ≤ 4.5 s，p90 ≤ 7 s |
| 每轮步数 | p90 ≤ 4 |
| 每轮成本（修正记账后，固定前缀命中缓存） | ≤ $0.002 |
| 盲测集上的不安全写入 | **0**（没点就写了、写错对象、挪了不该挪的事件、卡片过期后仍然写入） |
| 盲测集上的任务完成率 | ≥ 90%，并且高于现架构在同一套题上的成绩 |

成本估算：每轮约 3 步。每步固定前缀约 6K token，命中缓存按 $0.01/M；新输入约 2K token，按 $0.10/M；输出加推理约 800 token，按 $0.50/M。合计每轮约 $0.002。如果不修记账（缓存 token 按 $0.10/M 记），账面上约 $0.0036 一轮。

### 4.4 Worker 合同（扩展现有的 `/v1/responses`，不新增接口）

整个 agent 都建在 **OpenAI Responses API**（`POST https://api.openai.com/v1/responses`）上。手机只和我们自己 Worker 上的 `/v1/responses` 通信，由 Worker 补上固定的模型、系统提示和工具清单，再转发给 OpenAI。迁移期间，这个接口同时支持两种请求：旧管线的"strict JSON、不带工具"和新 agent 的"items 加工具"。到 P4 删掉旧管线时，旧模式也一起删掉。

用到的 Responses 功能：

| 功能 | 用法 |
|---|---|
| function calling（`tools`，`strict: true`） | 12 个工具，schema 由服务端按 `tools_version` 注入 |
| `function_call` / `function_call_output` items | 手机执行工具，把结果回填 |
| `parallel_tool_calls: true` | 读类工具并行执行 |
| `stream: true`（SSE） | 文字逐字显示；`function_call_arguments.done` 一到就显示卡片 |
| `store: false` + 加密 reasoning items | 不在 OpenAI 端存数据；历史由手机回放 |
| prompt caching（固定前缀） | 系统提示、工具、skills 放在最前面，保持不变 |
| `reasoning.effort: low` | 已定（§4.7） |

新旧对比：

| 项目 | 现在（`/v1/responses`） | v3 |
|---|---|---|
| 输入 | 只接受字符串 `input` 和 `instructions` | items 数组（message、`function_call`、`function_call_output`、reasoning）；**拒绝客户端传来的 system / developer 角色**，系统提示由服务端按版本注入 |
| 工具 | 禁止 | **服务端白名单**，按 `tools_version` 选择；客户端不能自带工具 |
| 输出格式 | 必须是 strict JSON | 最终回复是纯文本；Proposal 只能来自工具调用 |
| 体积上限 | 24 KB | 约 256 KB，客户端负责压缩历史（§1.5） |
| 上游超时 | 20 s | 每步 30 s |
| 流式 | 不支持 | SSE 透传。客户端中途断开时，用 `ctx.waitUntil` 把上游读完再结账，避免预留的额度一直挂着 |
| 额度 | 每次调用算一次，6 次/分钟、40 次/天 | **按轮计**：D1 新增 `runs` 表（`run_id, user, steps, started`），由服务端计数，每轮最多 6 步；每人每天 40 轮；每分钟的调用限额保留，作为兜底 |
| 记账 | `input*0.1 + output*0.5`，缓存 token 按全价算 | 用 `input_tokens_details.cached_tokens` 分档计价 |
| 模型 / effort / store | 固定 | 固定：`gpt-6-luna`，effort 从 `low` 起，`store:false` |

### 4.5 迁移步骤（每步一个 PR，就绪就合并）

| 阶段 | 内容 | 删除什么 |
|---|---|---|
| **P0** | 扩展 Worker `/v1/responses` 支持 agent 模式：runs 表、缓存计价、SSE、白名单，加测试；用一次真实请求验证 §4.8 的未知项 | — |
| **P1** | 抽出 `ToolRegistry`、`ActionPolicy`、`FastLane`，**行为不变**。① 先用内存 `ModelContainer` 加假的 `CalendarService`，给 `AskNativeActions.applyChange` 和 `applyTidy`（`AskView.swift` 约 2232–2470 行）以及系统事件改期的编排写**行为快照测试**，然后再抽取。② 把快车道要用的判定函数收进 `FastLane`：`ChatRouting.intent / requestsEvent / hasMultipleActions / hasMaterialCorrection`、`CaptureConversation.parse / referencesReminder / resolve / isOneOffAnswer`、`Editing.looksLikeEdit` | — |
| **P2** | `AgentRunner`、`ModelClient`、`HostedLunaClient`、`ScriptedModelClient`、skills 文件，放在开关 `today.ai.agent` 后面（默认关） | — |
| **P3** | 评测：开发集加**新写的盲测集**，新旧两套架构跑同一套题，量 §4.3 的全部指标。可选：在同一套题上测 Decisions 能否作为快车道的额外检查 | — |
| **P4** | 默认打开 agent，删除旧管线 | `ChatRouting` 和 `Dialogue` 里没被收进 `FastLane` 的部分、`Understanding`、`AICapture`、`ChatResponse`、`Editing`（`looksLikeEdit` 已移走）、`AskSuggestionRanker`、`SentenceRoute` 等路由规则、`EditingLogic` 的判断部分、`AskView` 的路由部分（目标是从 2492 行降到 1000 行以下）、约 20 个只测旧路由的测试文件、`ios/Eval/Understanding`、旧的 AI 文档 |
| **P5** | Siri 接入 ToolRegistry，iOS 27 采用 app schemas；修改类 intent 加 `requestConfirmation` | `IntentLogic` 里和 ToolRegistry 重复的部分 |

**一定保留**：`CaptureParser`（日期由代码算）、`FastLane` 的判定函数、`IntentLogic` 和 `EditingLogic.newStart`（Siri 在用）、`PlannerActions` / `Ledger` / Undo、卡片 UI、`OverdueTidy.suggest`、`TidySheet`、`ListGuess`。

**测试要移植、不能删**：`OneOffReminderTests`、`SubmittedCaptureBoundaryTests`、`ExplicitPlannerRequestSafetyTests`、`AttachedItemEditingTests`、`EditRoutingTests`，以及 `DialogueTests` 里的续答用例。它们改为测 `FastLane` 和 `ActionPolicy`。

### 4.6 为什么选这个，而不是别的

| 备选方案 | 为什么不选 |
|---|---|
| 保留现状，继续加规则和 prompt | 这就是今天的问题：6 个路由器互相打架，`AskView` 有 2500 行，5 个 prompt 的超时各不相同，越改越乱 |
| 多 agent（一个总管 + 几个专家） | 我们的任务面很窄，单 agent 加 12 个不重叠的工具就够了。多 agent 的 token 用量约是普通聊天的 15 倍，延迟也更高。Anthropic 和 OpenAI 的指南都建议先把单 agent 用到极限 |
| agent 循环放在服务器上 | 不管循环放哪，工具结果都要经过 Worker 发给 OpenAI，所以真正的差别是**服务器要不要保存对话**。工具必须在手机上执行，放到服务器上也省不掉往返，反而要在服务器上长期保存用户的对话。我们只在服务器上放最少的状态（`runs` 计数，§4.4），对话留在手机上 |
| 端侧 Foundation Models 当 agent | 上下文只有 4–8K，装不下我们约 6K 的固定前缀和历史；实测它在编辑请求里从来不会追问（15 次里 0 次）。只留一个 `ModelClient` 空位，等它变强再接 |
| 用 Decisions API 做总路由 | 它只能做选择题，填不了标题和时间，还多一次往返；在 27 句的开发集上，"信息够不够"这道题在置信度 0.98 时还会答错。只保留为可选的额外检查 |
| OpenAI Agents SDK | 没有 Swift 版本，用它就得把循环放到服务器上（同上） |
| `previous_response_id` / Conversations API | 都要求 OpenAI 保存数据，Conversations 还不支持零数据保留；我们在手机上自己回放历史 |

**一句话**：这是同时满足"数据留在本机、写入由代码决定、离线能用、成本可控"这四个条件的最简单结构。大部分零件（写入、Undo、卡片、日期解析、快车道的规则）都已经有了，新写的只有 `AgentRunner`、`ToolRegistry` 外壳、`ActionPolicy` 和 Worker 的一个新接口。

### 4.7 已定（2026-10-31，按推荐执行）

1. **预算上限**：已定。从 $0.50 提到 **$5**，同时修正记账。修正后大约能跑 2,500 轮，不修正约 1,400 轮，足够 P3 跑几轮评测，再加上日常自用。
2. **effort**：已定。先用 **`low`**。P3 评测时同时跑一遍 `medium`；如果完成率高出 5 个百分点以上，再升级。
3. **离线和没开云端的用户**：已定。**由快车道在本地出预览卡**（规则有把握的提醒、事件、闹钟都能出），整理逾期继续用 `TidySheet`，其他功能提示"AI 离线"。不再维护第二套引擎。这比现在少一些离线能力：离线时不能再按名字匹配改期，也不能做日程问答，不过 Today tab 本身就能看到日程。

### 4.8 P0 要用一次真实请求验证的未知项（这些都不作为设计前提）

- 同一个请求能否同时带 `tools` 和 `text.format`。v3 不依赖这一点，最终回复本来就是纯文本。
- `gpt-6-luna` 的 `reasoning.context` 默认值；在 `store:false` 下回放加密 reasoning 是否正常；模型别名更新以后，旧的加密 reasoning 还能不能回放。回放不了就按 §1.5 压缩。
- `async: true` 工具的实际行为。v3 不依赖它。
- 缓存的 TTL 是 30 分钟还是 12 小时。按 30 分钟设计。
- `service_tier: fast` 在 Luna 上实际能快多少。

---

## 5. 独立审查记录（Claude Opus，2026-10-31）

审查要求是找具体的失败场景，而不是给出同意或反对。下表是全部发现和修正位置。

| 编号 | 发现 | 修正位置 |
|---|---|---|
| H1 | P4 原计划会删掉快车道依赖的判定函数（`OneOffReminderRequest` 依赖 `ChatRouting`、`CaptureConversation`、`Editing.looksLikeEdit`）。删掉后，"把牙医提醒改到4点"这类句子可能被当成新提醒直接建出来 | §4.5 P1 先收进 `FastLane`；"一定保留"和"测试要移植"两个清单 |
| H2 | Siri 的规则前后矛盾；被注入的内容可能经 Siri 调用创建类 intent | §4.2 Siri 条目；残余风险见下 |
| H3 | Worker 记账没有扣缓存 token；流式中途断开会让预留额度一直挂着 | §4.4 记账、SSE；§4.3、§4.7 的成本已重算 |
| H4 | "每轮最多 6 步"原设计没有服务端状态，客户端可以无限续步，还能自带 system 消息 | §4.4 `runs` 表，并拒绝 system / developer 角色 |
| M1 | 卡片生成之后，Apple 那边的条目可能变了（比如多了参会人） | §4.2 Apply 时重新检查快照和等级 |
| M2 | 多轮续答没有写清；快车道建的提醒不在 agent 的历史里 | §4.2 续答规则；§1.5 合成收据 |
| M3 | "所有写入都能追溯到用户原话"实际执行不了：标签包裹可以被打破，`why` 可能被注入内容利用 | §1.5 转义规则；§3 O3、O4 重写 |
| M4 | "全部添加"可能把需要确认后果的卡一起提交 | §3 O2 |
| M5 | 离线用户和没开云端的用户能力明显变少 | §4.7 第 3 条：快车道出预览卡 |
| M6 | 原来的延迟目标做不到（修改需要两次串行调用） | §4.3 按类别定目标；§3 O6 |
| M7 | 历史回放可能失败：体积一直增长、模型别名更新、工具版本变化 | §1.5 元数据 + 压缩；§4.8 |
| M8 | 否决"服务器跑循环"的理由写错了 | §4.6 已改写 |
| 低 | `revise_proposal` 用在已决定的卡上会怎样没有定义；缺闹钟编辑、"撤销刚才那个"、Activity 问答；`resolve_when` 重复；strict schema 的可选参数写法；回复里谎称"已完成"；P1 缺行为测试 | §1.3、§1.4、§4.5 P1 |

**已知残余风险**：
- Siri 读到被注入的内容后，可能去调"加一条提醒"。这种写入能完全撤销，并且会记进 Ledger。
- 共享的 Apple 提醒列表没有逐条记录作者，代码无法区分"别人写的"和"自己写的"，所以一律按不可信处理。

## 来源

- OpenAI：[Function calling](https://developers.openai.com/api/docs/guides/function-calling) · [Conversation state](https://developers.openai.com/api/docs/guides/conversation-state) · [Reasoning](https://developers.openai.com/api/docs/guides/reasoning) · [Prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching) · [Latency](https://developers.openai.com/api/docs/guides/latency-optimization) · [Decisions](https://developers.openai.com/api/docs/guides/decisions) · [gpt-6-luna](https://developers.openai.com/api/docs/models/gpt-6-luna) · [Your data](https://developers.openai.com/api/docs/guides/your-data) · [Evals 下线通知](https://developers.openai.com/api/docs/guides/evaluation-getting-started) · [A practical guide to building agents](https://cdn.openai.com/business-guides-and-resources/a-practical-guide-to-building-agents.pdf) · [Agents SDK HITL](https://openai.github.io/openai-agents-js/guides/human-in-the-loop/) · [Apps SDK reference](https://developers.openai.com/apps-sdk/reference)
- Apple：[WWDC26 240](https://developer.apple.com/videos/play/wwdc2026/240) · [343](https://developer.apple.com/videos/play/wwdc2026/343) · [347（安全）](https://developer.apple.com/videos/play/wwdc2026/347/) · [241（Foundation Models）](https://developer.apple.com/videos/play/wwdc2026/241)
- Anthropic：[Building effective agents](https://www.anthropic.com/engineering/building-effective-agents) · [Context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) · [Multi-agent research system](https://www.anthropic.com/engineering/multi-agent-research-system)
- 竞品：[Gemini 帮助](https://support.google.com/gemini/answer/17094507) · [Copilot 日历指令](https://support.microsoft.com/outlook/calendar-instructions-in-outlook-and-copilot) · [Office365 IT Pros 评测](https://office365itpros.com/2026/07/07/calendar-agent-disappoints/amp/)（二手） · [Claude 工具权限](https://support.claude.com/en/articles/11176164) · [Notion 审批模式](https://www.notion.com/help/choose-how-notion-agent-asks-for-your-approval) · [Todoist Ramble](https://www.todoist.com/help/articles/dictate-to-add-tasks-with-ramble-P1Raq7vVF) · [Building Ramble](https://www.producttalk.org/building-todoist-ramble-how-doist-turned-voice-braindumps-into-real-time-task-capture/)（二手） · [Motion](https://www.usemotion.com/ai-employees)（厂商） · [Motion 评测](https://www.usecarly.com/blog/motion-ai-review/)（二手） · [Reclaim](https://reclaim.ai/blog/slack-mcp-server)（厂商）
