# Today：AI-native 愿景、持续规划与个人 agent 控制平面

调研日期 2026-10-17。本文只做调研和设计，没有改 App 代码（`ios/`、`src/` 未动）。配套原型在 `docs/research/prototypes/`。

**资料说明：**
- 各 App 的事实来自网页调研（官方页面、App Store、TechCrunch / MacRumors / 9to5Mac / MacStories、帮助中心、评测博客）。
- 写本文时，我抽查了 23 个链接的可达性：21 个返回 HTTP 200，另外 2 个返回 404，已换成可达的地址。正文内容由调研子任务阅读，我没有逐条复读原文。
- 标 **未核实** 的是二手或互相矛盾的说法。评测里有不少出自竞品（Morgen、Saner、Carly、Ellie、ClickUp 等），已经注明。
- Reddit 原帖被搜索工具屏蔽，用户抱怨大多是转引。
- Overlap（以及 Bonobo 的 Timepage / Flow）由另一份调研负责，这里不重复。

---

## 0. 结论（先看这个）

1. **最值得做的是“账本”，不是更聪明的模型。** 把 Today 做成个人 agent 的控制平面，核心是一本只追加的账本，每条记录写清：谁（你 / Today AI / 哪个 agent），经由什么通道，在什么时候，对哪个提醒、事件或闹钟，做了什么，改前和改后，是否批准，能否撤销。T3 Code、Conductor、Claude Code 桌面版、GitHub Agent HQ 这些编码 agent 面板，本质上都是同一个结构：任务列表 → 状态 → 日志 → diff → 批准或合并。Today 把 diff 换成“改前 → 改后”，把 merge 换成 Apply 就行。
2. **持续规划 = 确定性的排程器 + 端侧模型写理由 + 用户逐条批准。** 时间由 `DayPlanner`（代码）算，模型只决定“排哪些”和“为什么”。每次规划都是一张 diff 卡，逐行勾选，每行标明写到哪里。这条路线和现在的 agent 架构（`docs/engineering/ai-agent-architecture.md`）一致，也是对 Motion 式“AI 偷偷挪东西”的反面回应。研究里抱怨最多的正是这一点。
3. **“agent 自己行动”和原则 1 的冲突，用四级自主权来解。**

   | 级别 | 内容 | 是否需要询问 |
   |---|---|---|
   | 0 观察 | 只读、只记录 | 不问 |
   | 1 本地 | 只改 Today 自己的副本：计划时间、链接、账本备注 | 用户点过一次“允许这个 agent 做这类事 30 天”之后才能自动做 |
   | 2 Apple App | 写 Apple 日历、提醒事项、闹钟 | 默认要问，可限时放行 |
   | 3 他人 / 不可逆 | 通知别人、删除、发送、花钱 | 永远要问 |

   原则 2–6（会议不动、计划 ≠ 截止、停闹钟 ≠ 完成、想法不变任务、过期不偷偷挪）是代码层面的硬约束，任何授权都绕不过。
4. **iOS 的限制决定了“持续”的真实含义。** iPhone 上没有常驻后台。实际的重新规划时机是：打开 App、日历变更通知、系统安排的后台刷新、快捷指令自动化触发 App Intent、小组件刷新。MCP 服务器只能跑在 Mac 上；iPhone 上的入口只有 App Intents / 快捷指令 / URL scheme。
   - WeatherKit 需要付费开发者账号（官方页面写明按 Developer Program 会员计费额度）。
   - 账本跨设备同步（CloudKit / iCloud Drive）同样需要付费账号（据 Apple 能力表，未在本项目验证）。
   - 现在用的是免费 Apple ID 签名，所以天气和跨设备同步都要往后放。
5. **先做什么：** `LedgerEntry` 模型 + 侧边栏里的 Activity（只读时间线）+ 把 `PlanCard` 改成逐行 diff 卡。
   - 这是控制平面的最小内核。路线图上已有的“tidy overdue 预览”和“App Intents / Siri”都要用到它，不是另起炉灶。
   - 工作量约 S+M，见 §6。

---

## 1. 十个最好的点子（排序）

| # | 点子 | 学自 | 为什么适合 Today | 工作量 |
|---|---|---|---|---|
| 1 | **一本账本 + Activity 视图**：每个动作都记录 actor、通道、时间、改前/改后、批准状态、撤销 | T3 Code / Claude Code 桌面版 / Agent HQ 的会话列表 + 日志；W3C Activity Streams 的 actor-verb-object | 回答“谁在什么时候做了什么”，是控制平面的地基；撤销、评测、信任都建在它上面 | S–M |
| 2 | **计划更新 = diff 卡，逐行勾选，标明写到哪里** | Morgen：批准之前不同步到日历；Craft：先提议再改的编辑模式；编码 agent 的 diff 审阅 | 直接升级现有 `PlanCard`；用户能拿走一部分，不用全盘接受 | S |
| 3 | **四级自主权 + 按 agent × 改动类型的限时授权** | Claude Code 权限模式（default / acceptEdits / plan…）；T3 Code 每个 thread 单独设权限；Apple `requestConfirmation` | 让 agent 能自己做低风险的事，又不违反“用户决定”；授权本身是一次用户点击 | M |
| 4 | **晚间复盘：计划 vs 实际 + 三个决定** | Sunsama 收工流程；Akiflow 每日 / 每周仪式 | “实际发生了什么”是持续规划的燃料；没做完的由用户决定去处（原则 6） | M |
| 5 | **手动动过就锁定；排不下的进“问题箱”，不悄悄消失** | Motion：手动移动的任务被锁定，Resolve Issues 箱 | 直接针对“AI 动了我的东西”的焦虑；和原则 6 一致 | S |
| 6 | **工作量预测：“预计几点收工 vs 想几点收工”** | Sunsama 的规划引导 | 一行字就能说明今天是否过载，比 AI 自动删任务更可信 | S |
| 7 | **时长校准：计划 45 分钟、实际 70 分钟 → 下次建议 60** | Structured / Tiimo 的 AI 估时；OmniFocus “Help Me Estimate” 插件；Motion 的反面教训 | 让规划随用户的真实节奏变准；只改本地参数（第 1 级） | M |
| 8 | **“该出发了”：路程时间 → 出发提醒（可响铃）** | Structured 用户在 App Store 评论里要求读通勤时间；Apple 日历的出发时间 | 把 AlarmKit 和日历连起来，只有 Today 能做；事件本身不动 | M |
| 9 | **软占位 → 越接近截止越“硬”** | Reclaim 的闲→忙渐进锁定、时长区间、P1–P4 | 计划时间先只存在 Today 本地；接近截止时才提议写进 Apple 日历（第 2 级） | M |
| 10 | **边说边出卡片、可以口头改** | Todoist Ramble；TickTick 语音模式；Fantastical 粘贴整段文字解析 | 现有 `CaptureStack` + 听写的自然下一步；受端侧 4096 token 限制，要分段 | M–L |

另外值得记下的小点子：
- **Things 的 Magic Plus**：把 + 拖到列表某个位置就在那里插入。
- **Fantastical 的“AI 正在工作”彩虹光晕**：一个状态信号，让人知道 AI 在动。
- **Tiimo 的倒计时进度环 + 灵动岛**。
- **Agenda 的 Ask Agenda**：端侧问答，明确不上云。
- **Due 的 12 个快捷时间键**：Today 的 Quick add 已经借鉴了。

---

## 2. 各 App 调研

### 2.1 用户已安装的

#### Structured（日程时间线）
- **巧妙设计：**
  - 一天就是一条竖向时间线，块的高度等于时长，直接拖动改时间。Apple 日历和提醒事项的条目直接插进来。
  - Inbox 先收，有空再拖进时间线；Replan 一键把没做完的挪走。
  - AI（Pro）：说一句话或打一段字，就拆成多个任务、估时长、排进空档。2026 年加入 Siri AI 创建和修改任务、颜色预测、子任务建议。
  - Pomodoro / Intervals 计时，Live Activities。
- **用户评价：**
  - 夸：4.8 分、约 16.8 万条评分、Editors' Choice；ADHD 用户说它缓解“时间盲”；打勾的反馈很爽。
  - 骂：iCloud 同步不稳（后来自建 Structured Cloud）；免费版缺很多功能；试用只有 3 天。
  - 有用户希望读取通勤时间，并且“固定课程不动，只顺延后面的任务”。这正是 Today 的原则 2。
- **对 Today：** 时间线 + 灵活任务拖动，Today 已有；值得借鉴“出发时间”和“重排只动灵活项”。
- 来源：[App Store](https://apps.apple.com/app/structured-daily-planner/id1499198946) · [Structured 5 博客](https://structured.app/blog/structuredfive) · [Saner 评测（竞品）](https://blog.saner.ai/structured-review/)

#### OmniFocus 4
- **巧妙设计：**
  - Perspectives：把项目、标签、日期组合成保存好的过滤视图。
  - Forecast：日历、到期、旗标合在一个列表。
  - **Planned 日期和 Due 日期分开**，与 Today 原则 3 完全一致。
  - 4.8（2025-09）让 Omni Automation 插件调用 Apple 端侧 Foundation Models，附带 “Help Me Plan / Help Me Estimate” 等示例。官方承认模型能力有限。
  - 4.9 加入 Siri AI。
- **用户评价：**
  - 夸：灵活、跨设备、端到端加密同步。
  - 骂：App Store 4.0 分；iPhone 上项目一多就卡；层级深，把任务挪到某天要点很多下；价格高。
- **对 Today：** “用户可写的自动化脚本调用端侧模型”是一个有意思的方向，但对 Today 来说太重。可借鉴的是 Planned / Due 分离的心智模型，Today 已经有了。
- 来源：[Omni 博客](https://www.omnigroup.com/blog/ready-for-os-26) · [9to5Mac](https://9to5mac.com/2025/09/15/omnifocus-4-8-apple-intelligence-support/) · [App Store](https://apps.apple.com/us/app/omnifocus-4/id1542143627)

#### Calendars（Readdle）
- **巧妙设计：**
  - 任务和事件在同一视图，任务可以拖进日历变成时间块。
  - 自然语言输入能识别时间、地点、联系人。
  - AI 早期体验：Magic Input 从截图、照片、文件里抽事件；Ask AI 回顾一周并批量挪动。
  - 2.0 版深度集成 Google Tasks。
- **用户评价：**
  - 夸：4.7 分、约 12.2 万条评分。
  - 骂：改成订阅后，原本免费的功能收费；iOS 更新后重开慢。
- **对 Today：** “截图 → 事件”是值得做的捕获入口。iOS 27 的端侧模型支持图片 prompt（仅 iOS 27）。
- 来源：[官网](https://readdle.com/calendars) · [App Store](https://apps.apple.com/us/app/calendars-planner-reminders/id608834326) · [新闻稿](https://readdle.com/press/release/2803)

#### Fantastical
- **巧妙设计：**
  - 招牌的自然语言解析，能懂“每月第三个周四”这类说法；以 “remind me to” 开头就建成任务。
  - 4.1（2025-09）的 Apple Intelligence 解析器：粘贴一大段啰嗦文字，抽出多个事件和任务；AI 工作时输入框有彩虹光晕。
  - Openings / Proposals 预约；Calendar Sets 按地点自动切换。
- **用户评价：**
  - 夸：输入自然，多账户稳定。
  - 骂：订阅贵，个人用户被迫为协作功能付费。
- 2026 年 3 月 Product Hunt 上出现 “Fantastical MCP for Mac”，是否官方出品 **未核实**。
- **对 Today：** 多条目抽取 Today 已有（`CaptureStack`）；“AI 正在工作”的视觉信号值得借鉴。
- 来源：[Flexibits 博客](https://flexibits.com/blog/2025/09/apple-os-26-updates-starring-fantastical-4-1-and-cardhop-2-4/) · [TidBITS](https://tidbits.com/watchlist/fantastical-4-1-cardhop-2-4/) · [App Store](https://apps.apple.com/us/app/fantastical-calendar/id975937182?mt=12)

#### TickTick
- **巧妙设计：**
  - 智能日期解析，识别出的时间文字可以从标题里隐藏。
  - 列表、日历、四象限、专注计时都在一个 App 里，专注数据可写入 HealthKit。
  - 很重的 Live Activities 和小组件。
  - 2026 年加入 AI 语音模式（一段话拆成多个任务）和 AI Assistant。
- **用户评价：**
  - 夸：4.9 分、约 4.6 万条评分；便宜，功能全。
  - 骂：功能太多，学习成本高；部分功能付费；同步 Google 日历不稳。
  - 第三方普遍认为它的 AI 弱于 Todoist。
- **对 Today：** “专注计时写入 Health”说明计时器可以成为“实际发生了什么”的信号源（Today 已有 `TimerCard`）。
- 来源：[App Store](https://apps.apple.com/app/ticktick-todo-task-list/id626144601) · [2sync 对比](https://2sync.com/blog/ticktick-vs-todoist) · [Morgen 对比（竞品）](https://www.morgen.so/blog-posts/ticktick-vs-todoist)

#### Notion Calendar（原 Cron）
- **巧妙设计：**
  - Notion 数据库条目和会议放在同一个面上。
  - 选好时段就生成预约链接。
  - 多时区并排，Cmd+K 命令菜单，键盘优先。
  - AI 会议纪要（2025-05）能自动挂到对应会议上。
- **用户评价：**
  - 夸：免费、快、好看。
  - 骂：长期不支持 Outlook；重复事件编辑弱；任务和时间块同步有延迟。
- **对 Today：** “会议旁边放着它的准备材料”是一个意图（intention）和事件之间的连接，对应账本里的 `intent`。
- 来源：[官网](https://www.notion.com/product/calendar) · [AlternativeTo 新闻](https://alternativeto.net/news/2026/7/notion-calendar-integrates-ai-meeting-notes-with-outlook/)

#### Due
- **巧妙设计：**
  - Auto Snooze：没处理的提醒按设定间隔一直重复，直到标记完成。
  - 12 个可自定义的快捷时间键，和键盘同屏。
  - 自然语言解析结果先出现在一条临时确认栏里，用户确认才生效。
  - 精确到秒的倒计时，配 Live Activities、Prominent Alerts。
- **用户评价：**
  - 夸：4.7 分；Auto Snooze 无可替代，对 ADHD 友好。
  - 骂：UI 显旧；关闭编辑器时会留下空任务。
- **对 Today：** 快捷时间键 Today 已经借鉴（`QuickReminderSheet`）。“一直响到完成”与 Today 的原则 4 和已删除的 nag 方向冲突，只能作为单条可选项。
- 来源：[App Store](https://apps.apple.com/us/app/due-reminders-countdown-timers/id390017969) · [MacStories Due 2 评测（2014，设计理念参考）](https://macstories.net/?p=37702)

#### Overlap
由另一份调研（Bonobo 的 Timepage / Flow / Overlap）负责，本文不重复。

### 2.2 其他领先 App

#### Things 3
- **巧妙设计：**
  - Magic Plus：把 + 拖到哪里，就在哪里插入。
  - Today 分区：顶部放当天日历事件，下面是 This Evening。
  - 开始日期和截止日期分开。
  - 3.23（2026-08）重做重复任务；3.24（2026-09）接入 iOS 27 Siri AI 多轮对话，整库进 Spotlight。
  - App 内没有 AI。
- **用户评价：**
  - 夸：两次 Apple Design Award，界面几乎不过时。
  - 骂：更新慢；没有协作；重复任务长期被吐槽。
- 来源：[功能页](https://culturedcode.com/things/features/) · [MacRumors 3.24](https://www.macrumors.com/2026/09/14/things-3-updated-for-ios-27/) · [MacRumors 3.23](https://macrumors.com/2026/08/19/things-3-23-brings-long-requested-overhaul-of-repeating-to-dos)

#### Todoist（Assist / Ramble）
- **巧妙设计：**
  - Ramble：边说边实时生成任务卡，可以口头改（“改成周四”）。底层是 Gemini Flash Live 边说边调用工具。2026-01 正式上线，支持 38 种语言；官方说音频不存储。
  - Todoist Assist：邮件转任务、用自然语言写筛选、把任务拆步骤。
- **用户评价：**
  - 夸：自然语言是业界标杆。
  - 骂：提醒要付费；日历同步不稳；Assist 对重度用户太基础。
  - 公司自报 Ramble 的任务创建成功率从约 40% 提到约 62%。
- **对 Today：** 一句话里修正前文，Today 的 `Dialogue` 已经支持（“make it 4pm”）。Ramble 的实时性要靠流式输出，端侧要验证延迟。
- 来源：[TechCrunch](https://techcrunch.com/2026/01/21/todoists-app-now-lets-you-add-tasks-to-your-to-do-list-by-speaking-to-its-ai/) · [Product Talk 幕后](https://www.producttalk.org/building-todoist-ramble-how-doist-turned-voice-braindumps-into-real-time-task-capture/) · [Todoist Assist 帮助](https://www.todoist.com/help/articles/introduction-to-todoist-assist-KgPP22q5O)

#### Any.do
- **巧妙设计：**
  - 每天一次的“Plan your day”引导，逐条决定今天做不做。
  - WhatsApp 里建任务、收提醒；转发邮件就建任务。
  - 家庭共享清单。
- **用户评价：**
  - 夸：简单，引导好。
  - 骂：付费墙多；会擅自把文字识别成日期。
  - AI 功能多来自第三方描述，**未核实**。
- 来源：[App Store](https://apps.apple.com/us/app/any-do-to-do-list-planner/id497328576) · [Zapier](https://zapier.com/blog/anydo-features/)

#### Agenda
- **巧妙设计：**
  - 笔记挂在时间线上，可以绑定日历事件。
  - “On the Agenda” 标记当前重点。
  - Related Notes 自动推荐相关笔记。
  - Ask Agenda（2025-09）用端侧 Apple Intelligence 回答关于笔记的问题，明确不上云；2026 年支持 Siri 创建和移动笔记。
- **用户评价：**
  - 夸：笔记和日程的关系清楚，可以买断。
  - 骂：协作弱，缺模板。
- **对 Today：** 对应原则 5（想法 ≠ 义务）。笔记可以挂在事件上，但不自动变成任务。
- 来源：[App Store](https://apps.apple.com/app/id1370289240) · [MacStories 评测](https://www.macstories.net/reviews/agenda-for-ios-review/) · [手册](https://agenda.com/manual/en/)

#### Craft
- **巧妙设计：**
  - 文档里写的任务自动汇进统一 Inbox。
  - AI 有两种模式：直接改，或**先提议、用户确认**；还有后台模式。
  - 3.5 起支持免费的端侧 Apple 模型，也可以用自己的 OpenAI / Anthropic key。
  - 提供 API 和 MCP，让 ChatGPT / Claude 读写 Craft 内容。
- **对 Today：** “先提议”模式和 MCP 接入，正是 Today 控制平面要做的两件事。Craft 证明一个消费级 App 可以同时做好这两点。
- 来源：[App Store](https://apps.apple.com/us/app/craft-docs-notes-tasks-ai/id1487937127) · [TechRepublic 评测](https://www.techrepublic.com/de/article/craft-review/)

#### Amie
- **巧妙设计：**
  - 左栏待办拖进日历就变成时间块。
  - 自然语言建待办。
  - AI 把未排的待办填进空档（确认流程 **未核实**）。
  - 动效和细节做得好。
- **用户评价：**
  - 夸：设计精致。
  - 骂：有 bug；集成少；任务管理浅。
- 来源：[TechCrunch](https://techcrunch.com/2024/01/24/amie-brings-your-email-inbox-to-its-calendar-app) · [文档](https://amie.so/documentation/getting-started/quick-start)

#### Sunsama
- **巧妙设计：**
  - 早上的规划引导分五步：回顾昨天 → 拉入今天的任务 → **工作量预测**（计划时长之和对比阈值，显示“预计几点收工 vs 想几点收工”，一键推到别天）→ 定稿 → 分享。
  - 收工三步：回顾 → 反思 → 收尾。
  - 建议新手每天只计划约 5.5 小时。
- **用户评价：**
  - 夸：适合“AI 全自动反而更焦虑”的人。
  - 骂：贵；全靠手动；早上的流程偏重。
- **对 Today：** 工作量预测（点子 #6）和收工（点子 #4）都是低成本、高信任的做法。
- 来源：[收工帮助](https://help.sunsama.com/docs/daily-shutdown) · [Changelog](https://roadmap.sunsama.com/changelog/daily-shutdown) · [Asian Efficiency 评测](https://www.asianefficiency.com/schedule-management/sunsama-review/)

#### Motion
- **巧妙设计：**
  - 排程信号写得很清楚：时长、开始日、截止、优先级、工作时间、已有日程；截止近、优先级高的先排。
  - 日历事件永远压过任务。
  - 硬截止 / 软截止。
  - **排不下的进 Resolve Issues 箱**，不悄悄消失。
  - **手动移动过的任务被锁定**，算法之后不再动。
- **用户评价：**
  - 夸：减少“决定什么时候做”的负担。
  - 骂：官方帮助自己承认任务会被“挪好几次”；全天忙碌事件会把任务整天挤走；贵；移动端弱。
  - “日历被排满、看着焦虑”在多个评测中出现，原帖 **未核实**。
- **对 Today：** 学它的锁定和问题箱，不学它的全自动。
- 来源：[排程原理](https://www.usemotion.com/help/time-management/auto-scheduling/reference-auto-scheduling/how-auto-scheduling-works-behind-the-scenes) · [Resolve Issues](https://help.usemotion.com/product-and-feature-guides/calendar/tasks/understanding-the-resolve-issues-box) · [ClickUp 评测（竞品）](https://clickup.com/blog/motion-review/)

#### Reclaim.ai
- **巧妙设计：**
  - Habit 先以“闲”占位，日历快满时才翻成“忙”；任务越接近截止越被保护。
  - 时长是一个区间（最短到最长）。
  - P1–P4 四级优先级，时间不够时明确牺牲低优先级。
  - 三档“防守强度”。
- **用户评价：**
  - 夸：自动化省心。
  - 骂：有时排得太满、看着有压力；希望能暂停某段时间的自动排程；调参靠试错；停用后日历里残留块；没有原生移动 App。
- 来源：[Habits vs Tasks](https://reclaim.ai/blog/habits-vs-tasks) · [时间块](https://reclaim.ai/blog/block-time-automatically-habits-routines) · [Capterra](https://www.capterra.com.au/software/1058797/reclaim)

#### Akiflow
- **巧妙设计：**
  - 统一收件箱（30 多个集成）。
  - 每日 / 每周的规划和收工仪式。
  - Schedule Optimizer 只在你改动之后才顺延后续任务，不会悄悄重排（据评测转述，**未核实**原文）。
- **用户评价：**
  - 夸：手动时间块做得干净。
  - 骂：没有免费版；移动端不稳；部分集成只能单向同步。
- 来源：[Morgen 评测（竞品）](https://www.morgen.so/blog-posts/akiflow-review) · [Dhruvir Zala 评测](https://dhruvirzala.com/akiflow-review/)

#### Morgen（AI Planner）
- **巧妙设计：**
  - AI 起草当日计划，可以全部接受、改单个块或拒绝；**批准之前不同步到任何日历**。
  - Frames：先划好“什么时间做哪类事”，AI 只在框内建议。
  - 冲突时把取舍摆给用户选，不自动重洗。
- **用户评价：**
  - 夸：控制感强。
  - 骂：设置繁琐；AI Planner 像 beta；手机端要先在桌面设置好。
- **对 Today：** 这是和 Today 原则最接近的产品，也说明“先提议、后写入”在市场上成立。
- 来源：[官网](https://www.morgen.so/ai-personal-assistant) · [thesweetbits 评测](https://thesweetbits.com/tools/morgen-review/)

#### Tiimo（2025 年 iPhone 年度 App）
- **巧妙设计：**
  - 当天是一条彩色积木式时间线，和职能治疗师一起设计。
  - AI co-planner 把一堆事拆小、估时长，排成“一天装得下”的计划。
  - 倒计时进度环 + 灵动岛。
- **用户评价：**
  - 夸：降低焦虑。
  - 骂：计时时屏幕会变暗；日历同步范围说法矛盾（**未核实**）；订阅贵。
- 来源：[Widgets & Live Activities](https://www.tiimoapp.com/product/widgets-live-activities) · [JustUseApp 评论汇总](https://justuseapp.com/en/app/1480220328/tiimo-visual-daily-planner/reviews)

#### Routine
- **巧妙设计：**
  - Console 随时呼出、快速捕捉。
  - 任务和日程在同一界面。
  - Pages 放笔记。
  - 刻意极简。
- **用户评价：**
  - 夸：好看，拖拽顺滑。
  - 骂：只集成 Google 日历；没有 AI 排程；上手要摸索。
- 来源：[The Business Dive](https://thebusinessdive.com/routine-review) · [G2](https://www.g2.com/products/routine)

### 2.3 横向结论

| 维度 | 市场现状 | Today 的位置 |
|---|---|---|
| AI 写入方式 | Motion / Reclaim 自动写；Morgen / Craft / Fantastical / OmniFocus 先提议后写 | 先提议后写，并且逐行、标明写到哪里 |
| 端侧模型 | OmniFocus、Agenda、Craft、Fantastical 都接了 Apple Foundation Models | Today 已接入（`Understanding.swift`）；差异化要靠“规划 + 账本”，不是单纯的解析 |
| Siri / App Intents | iOS 27 上 Things、Structured、OmniFocus、Agenda 都接了 Siri AI | Today 已有 4 个 intent，下一步加“提议类” intent |
| MCP | Craft 有；Fantastical MCP **未核实** | Mac 端本地 MCP 是 Today 成为控制平面的关键 |
| 复盘 | Sunsama、Akiflow 有仪式；其他大多没有 | 晚间复盘 + 账本 = 持续规划的反馈回路 |

---

## 3. AI-native 概念：持续规划

### 3.1 一句话

**Today 一直在后台“想”今天该怎么过，但从不自己动手。** 每当有新信号（会议拖堂、牙医取消、没睡好、事情做完了），它就准备一张新的 diff 卡。用户逐条勾选，Apply 才写回 Apple 的 App。所有过程记进账本。

### 3.2 闭环

```
 信号 ──▶ 理解 ──▶ 规划 ──▶ 提议 ──▶ 批准 ──▶ 写回 ──▶ 观察 ──▶ 学习
 (EventKit,  (端侧模型:   (DayPlanner:  (diff 卡,   (用户点,    (EventKit /  (实际完成时间、 (时长校准、
  计时器,     排哪些、     确定性排程,   逐行勾选,   或第 1 级   AlarmKit /   事件结束、     缓冲、
  路程,       为什么)      校验原则)     标明去处)   限时授权)   本地副本)    账本)          eval 用例)
  睡眠…)                                                                                   │
   ▲                                                                                       │
   └───────────────────────────────────────────────────────────────────────────────────────┘
```

### 3.3 信号

| 信号 | 来源 / API | 用来做什么 | 权限 / 限制 |
|---|---|---|---|
| 日程 | EventKit（`CalendarSync`） | 固定障碍、空档 | 已有 |
| 提醒、截止 | EventKit（`RemindersSync`） | 要排的东西 | 已有；计划时间只存本地 |
| **实际发生了什么** | 完成时间戳（`OneTask.doneAt`）、事件结束、`TimerCard` 计时、账本 | 重新规划、复盘、时长校准 | 无需新权限，最有价值 |
| 路程时间 | MapKit ETA，基于事件地点 | “该出发了”提醒，可以用 AlarmKit 响铃 | 事件要有地点；定位授权 |
| 天气 | WeatherKit | 跑腿类任务排在下雨前；只提示，不挪事件 | **需要付费 Developer Program**（[官方](https://developer.apple.com/weatherkit/)）。免费 Apple ID 下先不做 |
| 睡眠 | HealthKit 睡眠分析 | 建议提早 Wind down，或下午排轻一点 | 单独授权弹窗；免费账号是否可用 HealthKit **未核实** |
| 专注模式 | Focus Filter（`SetFocusFilterIntent`） | 专注时只显示相关列表，agent 审批延后 | App 不能直接读取当前专注模式，只能通过 filter 接收 |
| 位置 / 到达离开 | 快捷指令自动化 → App Intent `ReportSignal` | “离家了”“到公司了” | 由用户自己配置自动化，权限最清楚 |
| 外部 agent | MCP / App Intent / 共享账本 | 邮件、行程、代码等外部世界的信号 | 见 §4 |

### 3.4 “持续”在 iOS 上的真实含义

iPhone 不允许 App 常驻后台，所以“持续规划”实际是在下面这些时刻重新计算：
1. **打开 App / 回到前台**：最常见，也最便宜。
2. **日历库变更通知**（`EKEventStoreChanged`）：只在 App 运行时收到。
3. **`BGAppRefreshTask`**：由系统决定什么时候跑，几十秒预算（[BGTaskScheduler](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler)）。可以算好一张提议，再发一条本地通知“有新的计划建议”。
4. **快捷指令自动化 → App Intent**：例如离家、到公司、闹钟停止后。这是唯一由事件准时触发的途径。
5. **小组件时间线刷新**（`WidgetFeed`）：只读，可以显示“有 1 个计划更新”。
6. **通知操作**：Done / Snooze 本身就是“实际发生了什么”。

**不要承诺**“它会在你开会时自动帮你重排”。正确的说法是：“下一次你看手机，计划已经更新好了，等你点头”。

### 3.5 分工：模型、代码、用户

| 谁 | 做什么 | 不做什么 |
|---|---|---|
| 端侧模型（约 3B，4096 token） | 选“排哪些”（例如“只排工作的”），写理由，理解“把 demo 挪到午饭前” | 不算时间，不输出绝对日期，不直接写库 |
| `DayPlanner`（代码） | 把任务放进空档；事件是固定障碍；输出每行的改前 / 改后 | 不挪事件，不改 due，不碰过期项（除非用户勾选） |
| 校验（代码） | 强制原则 2–6；给每行标出级别和写入目标 | — |
| 用户 | 勾选、Apply、Undo；在复盘里决定没做完的去处 | — |

`docs/engineering/ai-agent-architecture.md` 已经定下“模型只提议、不执行”，本方案沿用。新增的是 **diff 卡的数据结构**：

```swift
struct PlanChange {            // one row on the card
    let ref: ItemRef           // reminder / event / alarm id
    let field: Field           // plannedStart, ringsAsAlarm, …  (never `due`)
    let before: String, after: String
    let writes: Destination    // .todayOnly / .appleReminders / .appleCalendar / .alarm
    let tier: Int              // 0…3, computed by code, not by the model
    let why: String            // written by the model, shown under the row
    var included: Bool         // the checkbox
}
```

### 3.6 “自己保留一份”和“写回 Apple”

- **Apple 日历 / 提醒事项**是条目的真相来源（已有：Apple 在冲突时胜出）。
- **Today 本地存的是 Apple 没有的东西：**
  - 计划时间（已经是本地的）
  - 账本
  - 信号摘要
  - 学到的参数（每类任务的真实时长、约会后的缓冲）
  - 待批的提议
  - 意图（intention）
- 写回只发生在 Apply 时：
  - 第 2 级走 `CalendarSync` / `RemindersSync` / `Ringer`，第 1 级只改本地。
  - 写回失败（列表不存在、日历只读）要记成账本里的 `failed`，不能静默。
- 外部 agent 绕过 Today 直接改了 Apple 日历（比如 Mac 上的脚本），Today 下次同步时记一条“在 Today 之外被修改（来源未知）”。这样账本仍然完整。

### 3.7 端侧模型 + prompt 迭代 + 评测

1. **Prompt 版本化。** prompt 放进带版本号的文件（例如 `Prompts/plan.v3.txt`）。每条账本记录带上 `model`（系统模型版本）和 `prompt` 版本号。Apple 升级系统会换模型，必须能按版本回看。
2. **两套评测（都放进 `ios/Eval`）：**
   - **NL 捕获**：已有，train / test 分开，保持 ratchet。
   - **规划评测**（新）：
     - 以 `tests/fixtures/today-dataset.json` 为底，派生 6–10 个场景：会议拖堂、取消、过期堆积、满日程、跨午夜、中文标题。
     - **不变量（程序判）：** 事件不动；`due` 不变；过期项没勾选就不动；没有重叠；不超出工作时间；每行都有级别和写入目标。不变量 100% 通过才算及格。
     - **软指标：** 和“用户最后实际接受的计划”的差距；被取消勾选的行占比（越低越好）。
3. **用户纠正就是数据，但留在本机：**
   - Apply 前改掉的行、Decline 掉的提议、复盘里“Today 学到了什么”的选择，都可以（用户勾选后）变成**本机私有的评测用例**。
   - 下一版 prompt 先在本机评测集上跑，不能更差才启用。
   - 导出给开发者是单独的明确操作，默认关闭。
4. **分级使用模型：**
   - 端侧模型做日常小决定。
   - 要长上下文的（周计划、整理 50 条过期项），先用代码切块，或者以后再考虑 PCC（需要申请 entitlement）。
   - 外部 agent 自带模型，通过 §4 接入。

### 3.8 什么能自己做、什么要批准（自主权阶梯）

| 级别 | 例子 | 默认 | 能否预先授权 |
|---|---|---|---|
| **0 观察** | 读日历、发现某项过期、Shortcuts 报告“离家了”、Coding agent 报告“PR 已开” | 自动，只记录 | — |
| **1 本地** | 改计划时间（本地）、把邮件链接到提醒、生成晨报、调整时长参数 | 要问 | 可以：按 agent × 动作类型，限时（默认 30 天），设置里随时撤销 |
| **2 Apple App** | 新建提醒、在提醒里加备注、新建自己的事件、设置响铃 | 要问 | 可以，但范围更窄：按 agent × 动作 × 列表或日历，限时 |
| **3 他人 / 不可逆** | 挪有参会人的会议、删除、发消息、付款 | 要问 | **不能**。每次都要问，卡片写明“会通知 N 人” |

**和原则 1 的关系：** 原则 1 的精神是“用户决定”。第 1、2 级的授权本身是一次明确的用户点击，有范围、有期限，所有自动行为都记在 Activity 里，并且可以一键撤销。所以它仍然是“用户决定”，只是决定一次、管一段时间。

是否改写 CLAUDE.md 的原则 1 措辞，**需要 Yuan 决定**（§8）。

**硬约束（任何授权都不能绕过）：**
- 原则 2：会议不动。
- 原则 3：截止时间不跟着计划时间动。
- 原则 4：停闹钟 ≠ 完成任务。
- 原则 5：想法不自动变成任务。
- 原则 6：过期的不偷偷挪。
- 新增：同一项 24 小时内被 AI 挪过一次后，再挪必须问（学 Motion 的教训）。
- 新增：用户手动拖过的项被锁定（学 Motion）。

---

## 4. 个人 agent 控制平面

### 4.1 定位

Agent 会替人做越来越多的事：订票、回邮件、写代码、买东西。人需要一个地方看三件事：
- **该做什么**：意图
- **谁做了什么、什么时候**：动作
- **结果怎样**：写到了哪里、成功还是失败、能不能撤

Today 天然适合当这个地方，因为“时间”是所有 agent 动作的公共轴，Today 又已经握着日历、提醒和闹钟。

### 4.2 和编码 agent 面板对照

| 编码 agent 面板 | 它们的做法 | Today 的对应 |
|---|---|---|
| T3 Code（[GitHub](https://github.com/pingdotgg/t3code)） | 一个任务一个 thread，三栏：列表 / 对话 / 实时 diff；每个 thread 单独设权限（Supervised → Full access）；外部 agent 可通过 MCP 只读 thread | 意图 ↔ thread；改前 → 改后 ↔ diff；四级自主权 ↔ 权限档 |
| Conductor（[官网](https://conductor.build/)） | 一个 workspace 一个 worktree；在内置 diff 里审阅，把评论回传给 agent | 卡片上的 Edit = “改了再批” |
| Claude Code 桌面版（[介绍](https://claude.com/resources/articles/claude-code-desktop-redesign)） | 侧栏放多个并行 session，diff 统计（+12 −1），PR 监控 | 侧栏 Activity；徽标显示待批数 |
| OpenAI Codex | 入口是任务列表，完成后在 diff 里审阅，再迭代或开 PR | 审批收件箱 |
| GitHub Agent HQ（[报道](https://visualstudiomagazine.com/articles/2025/10/28/github-introduces-agent-hq-to-orchestrate-any-agent-any-way-you-work.aspx)） | 一个界面给多家 agent 派任务，统一日志，多端同一视图 | “任何 agent 都能接进来”，Today 是统一视图 |
| Cursor 云端 agent | 关掉电脑也在跑，从 Slack / Linear 发起 | Mac 上的 agent 夜里跑，早上 Today 里出现提议 |

**共同模式：** 一个任务一个沙盒 → 列表里有状态 → 可展开的日志 → diff 是审阅单位 → 权限分档 → 最终落地一定由人点一下 → 多端可看。

**Today 的不同之处：**
1. 改动作用在**个人数据和其他人**身上（会议有参会人），所以第 3 级是硬门槛。
2. **时间**是一等公民，提议会过期（9:41 提的“10:00 做 demo”到 11 点就没意义了），提议要带有效期。
3. 手机优先，审批要能在锁屏通知和小组件上完成。

### 4.3 账本格式（建议）

只追加。撤销是一条新记录，不是删除旧记录。字段借鉴 W3C [Activity Streams 2.0](https://www.w3.org/TR/activitystreams-core/) 的 actor-verb-object。调试级的追踪另用 [OpenTelemetry GenAI 约定](https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-agent-spans/)（不给用户看）。原型里点任意一行可以看到类似的 JSON（原型版没有 `expires` / `model` / `prompt` 字段）：

```jsonc
{
  "id": "L12",
  "at": "2026-10-15T08:31",
  "actor": "trip",                       // you | today | <agent id>
  "via": "MCP",                          // Today app | Ask AI | App Intent | MCP | URL | Ledger file
  "intent": "tokyo",                     // optional link to an intention
  "verb": "proposed",                    // proposed | applied | created | moved | completed | linked | noticed | failed | undone …
  "object": { "type": "event", "title": "Leave for airport", "ref": "ek:…" },
  "before": "—",
  "after": "New event Tue 06:15–06:55",
  "tier": 2,
  "approval": { "state": "pending", "by": null, "grant": null },
  "effects": { "writes": ["Apple Calendar"], "notifies": 0, "undo": "one tap" },
  "why": "Flight 08:15; 40 min to the airport at that hour.",
  "expires": "2026-10-20T06:00",         // proposals go stale
  "model": "afm-27.0", "prompt": "plan.v3" // only for Today AI records
}
```

**存储：**
- SwiftData 新模型 `LedgerEntry`，按 `day` 和 `state` 建索引，按天分页。
- 超过 90 天的压缩成每日摘要。账本会一直增长，要按“大数据量”设计。
- 导出为 JSONL，放在 App Group（与 `WidgetFeed` 同一个容器）。跨设备同步用 CloudKit 或 iCloud Drive，需要付费账号。

**意图（Intention）：** 一个轻量对象，包含 title、可选截止、关联的提醒和事件、来源（用户说的 / agent 提的）。它不是新的任务系统，只是把相关动作串起来的线，对应原型里的 Board 泳道和 Graph 中心节点。

### 4.4 权限与审批

- **授权单位：** agent × 动作类型 × 范围（某个列表或日历）× 期限。例如：“Trip agent 可以在 Travel 列表新建提醒，至 11 月 14 日”。
- **授权从哪里来：** 只能在审批卡上勾选“Always allow…”，或者在设置里手动加。agent 不能自己申请到授权。
- **专注模式感知：** 专注时第 1、2 级的提议攒着不打扰，第 3 级按通知设置走。
- **总开关：** 设置里“暂停所有 agent”，一键把所有授权降回“要问”。
- **提示注入：** agent 的提议是**数据**。卡片上要显示来源（例如“来自 Priya 的邮件”），第 3 级永远要问。邮件里写“请帮我把会议挪到明天”只能变成一张卡，不能变成一个动作。
- **iOS 侧：** App Intent 里写操作用 `requestConfirmation`。论坛反馈从小组件、Live Activity、Siri 调用时确认框行为不一致，需要真机测试（**未核实**）。

### 4.5 agent 怎么接进来

| 通道 | 跑在哪 | 能做什么 | 审批路径 | 工作量 |
|---|---|---|---|---|
| **App Intents / 快捷指令 / Siri** | iPhone | 已有 4 个（AddReminder、StartTimer、WhatsNext、OpenToday）。新增：`ReadAgenda`（只读）、`ProposeChange`（只建待批提议）、`ReportSignal`（第 0 级）、`ApproveProposal`（带 `requestConfirmation`） | 提议进收件箱；交互式运行时可以当场确认 | M |
| **URL scheme / Universal Link** | iPhone | `today://propose?...` 打开一张预填的预览卡，**永远不直接写** | 用户在卡上点 Add | S |
| **本地 MCP 服务器（stdio）** | Mac 伴侣 App 或 macOS 版 Today | 工具：`get_agenda`、`list_reminders`、`propose_change`、`get_proposal_status`、`log_activity`。不提供直接写入的工具 | 提议通过账本同步到 iPhone → 通知 → 收件箱 | L |
| **共享账本文件（JSONL）** | iCloud Drive `Today/inbox/` | 不会 MCP 的脚本或 agent 往里追加提议 | Today 读入后按提议处理 | M（要 iCloud） |
| 远程 MCP（OAuth 2.1） | 服务器 | 任何云端 agent | 同上 | L，而且违背“数据留在本地”，暂不做 |
| A2A | 服务器 | agent 之间互相委托 | — | 不做 |

**关键点：** Apple 日历和提醒事项通过 iCloud 本来就是一条“共享总线”。Mac 上的 agent 直接写 EventKit，iPhone 上马上能看到，但 Today 不知道是谁写的。所以：
1. 鼓励 agent 走 MCP 或账本文件，这样有署名、能审批。
2. Today 对“外部写入”做差异检测，并记成 `observed`。

**一条完整的流程（原型里的 Trip agent）：**
1. Mac 上的 Trip agent 调 `propose_change`（新事件 “Leave for airport”，周二 06:15）。
2. 账本记一条 `pending`，经 iCloud 同步到 iPhone，本地通知提示“Trip agent 有 2 个提议”。
3. 用户在收件箱点 Approve（可以顺手勾“30 天内允许它往日历加事件”）。
4. Today 通过 `CalendarSync` 写入，账本记 `approved` 和写入目标。
5. agent 调 `get_proposal_status` 得知已落地。
6. 如果写入失败（例如列表 Travel 不存在），账本记 `failed`，Board 上显示“下一步：你选一个列表”。

---

## 5. 原型

全部在 `docs/research/prototypes/`，单文件 HTML，无外部依赖、无网络请求，双击就能打开。
- 界面文字用英文，与 App 一致；每页右侧（手机上是下方）有中文设计说明。
- 数据来自 `tests/fixtures/today-dataset.json`，第 0 天固定为 2026-10-15 周四 9:41。
- agent、天气、路程、睡眠都是虚构的。源文件在 `prototypes/src/`，改完运行 `python3 docs/research/prototypes/src/build.py docs/research/prototypes` 重新生成。

| 文件 | 内容 |
|---|---|
| `index.html` | 目录 |
| `today-planned.html` | **AI 规划的 Today**：顶部是实时信号胶囊（点开看来源和权限）；计划更新卡逐行勾选，每行标“Today only / Writes: Alarm”；时间线上虚线是建议的新位置；Apply / Undo。可以模拟“Standup 拖堂”“牙医取消”“只睡了 5 小时”，计划会跟着变 |
| `approval-inbox.html` | **审批收件箱**：所有 agent 的提议按级别排序；每张卡写明谁、改前 / 改后、为什么、写到哪里、是否通知别人、能否撤销；第 1–2 级可以勾“Always allow… 30 天”；第 3 级上锁；右上角的盾牌打开 agent × 动作的权限表和现有授权（可撤销） |
| `agent-board.html` | **Agent 活动板**：已连接的 agent 一排（可以过滤）；Timeline / Board / Graph 三种视图；点任意记录看账本 JSON，并可以 Undo |
| `evening-review.html` | **晚间复盘**：计划 vs 实际的条形对比；没做完的三项给建议但不预选；“Today 学到了什么”（时长校准、约会缓冲）并可以加入本机评测集；明天预览 |

---

## 6. 路线图（本 repo）

工作量：S ≈ 1–2 天，M ≈ 3–5 天，L ≈ 1–2 周以上。顺序按依赖排列。

### 阶段 A：内核（现在做，接在“Optimize”已有计划后面）

| # | 内容 | 涉及文件 | 量 |
|---|---|---|---|
| A1 | `LedgerEntry` SwiftData 模型（字段见 §4.3）。在现有写入点记账：Add / Apply / Undo / 完成 / 删除 / 同步发现的外部改动 | `Models.swift`（或新 `Ledger.swift`）、`OneApp.swift` schema、`TaskActions.swift`、`AskView.swift`、`RemindersSync.swift`、`CalendarSync.swift` | M |
| A2 | 侧边栏 **Activity**：只读时间线，按天分页，点开看改前 / 改后，可 Undo | `Sidebar.swift`、新 `ActivityView.swift` | S |
| A3 | `PlanCard` 升级为逐行 diff 卡（勾选、写入目标、级别、理由） | `AskView.swift`、`Logic.swift`（`DayPlanner` 输出 `PlanChange`） | S–M |
| A4 | **Tidy overdue** 预览（路线图已有），基于 A3：过期项默认不勾选 | 同上 | M |
| A5 | **规划评测**：在 fixture 场景上跑不变量（事件不动、due 不变、无重叠…） | `ios/Eval/`、`tests/fixtures/` 新场景 | S–M |

### 阶段 B：持续规划

| # | 内容 | 量 |
|---|---|---|
| B1 | 重新规划的触发点：前台、`EKEventStoreChanged`、`BGAppRefreshTask` + 本地通知“有计划建议”、App Intent `Replan` | M |
| B2 | “实际发生了什么”信号：完成时间、事件实际结束、计时器；手动拖过即锁定；24 小时内只自动提议挪一次 | M |
| B3 | 路程时间 → “该出发了”（MapKit，事件有地点时），可选响铃（AlarmKit） | M |
| B4 | 工作量预测一行字（预计收工 vs 设定收工） | S |
| B5 | 晚间复盘页 + 时长 / 缓冲校准（本地参数）+ 本机评测用例 | M |
| B6 | 睡眠（HealthKit，可选）；天气推迟到有付费账号 | M / 推迟 |

### 阶段 C：控制平面

| # | 内容 | 量 |
|---|---|---|
| C1 | App Intents：`ReadAgenda`、`ProposeChange`、`ReportSignal`、`ApproveProposal` | M |
| C2 | 审批收件箱 + 四级自主权 + 限时授权 + 总开关 | M |
| C3 | URL scheme `today://propose` | S |
| C4 | 账本跨设备同步（CloudKit 私有库）或 iCloud Drive JSONL。**需要付费开发者账号** | L |
| C5 | Mac 伴侣 + 本地 MCP 服务器（只读 + 提议） | L |
| C6 | 意图对象 + Board / Graph 视图 | M |

### 阶段 D：放手（在 A–C 被验证之后）

| # | 内容 | 量 |
|---|---|---|
| D1 | 第 1 级授权真正自动执行，加每日摘要“Today 替你做了 3 件事” | M |
| D2 | 更强的模型（PCC 或外部 agent 自带的），只用于长上下文规划；端侧仍然做日常 | L |

**先做 A1 + A2 + A3。** 它们不需要新权限、不需要付费账号、不改产品原则，做完以后每个后续功能（tidy overdue、Siri 提议、外部 agent）都有地方记账和审批。

---

## 7. 风险

| 类别 | 风险 | 对策 |
|---|---|---|
| 隐私 | 账本会记下很多个人信息（邮件主题、地点、睡眠） | 只存本机；外部 agent 默认只能看到自己写的记录和 `ReadAgenda` 的摘要；睡眠等健康数据永远不给 agent；导出和评测上传都是显式操作 |
| 隐私 | 不能把个人数据放进 URL | URL scheme 只带 id 或很短的标题，详细内容走 App Group / 账本 |
| iOS 限制 | 没有常驻后台，`BGAppRefreshTask` 不准时 | 按 §3.4 的触发点设计，文案说“下次打开时已更新” |
| iOS 限制 | App 读不到当前专注模式 | 用 Focus Filter |
| iOS 限制 | AlarmKit 读不到“时钟”里的闹钟 | 已知（README 写明），不承诺 |
| iOS 限制 | 被邀请人修改会议的行为没有验证 | `docs/engineering/ai-agent-architecture.md` §6.1 已记，第 3 级卡片写明 |
| 账号 | WeatherKit、CloudKit / iCloud 需要付费 Developer Program；HealthKit 在免费账号下是否可用 **未核实** | 天气和跨设备账本列为“需付费账号”；先做单机 |
| 端侧模型 | 4096 token、约 3B、随系统换版本、中文质量未知 | 模型只选和写理由；prompt 版本化；规划评测守不变量；每个 iOS beta 跑一次 |
| 信任 | 像 Motion 那样挪太多次、排太满 | 锁定手动项；每项 24 小时只自动提议挪一次；工作量预测；问题箱；默认不勾选可选项 |
| 安全 | 提示注入（邮件里藏指令） | 提议是数据；显示来源；第 3 级永远问；agent 不能给自己授权 |
| 打扰 | 提议太多，变成另一个收件箱 | 按意图合并；过期自动作废；专注时攒着；“全部批准第 1–2 级”按钮；每日摘要 |
| 规模 | 账本无限增长 | 按天索引和分页；90 天后压缩成每日摘要；Graph 只画一个意图 |
| 范围 | 控制平面做大了，偏离“先把 Today 做好” | A 阶段只做账本 + Activity + diff 卡，都服务于现有功能；Mac / MCP 放到 C |

---

## 8. 需要 Yuan 决定

1. **原则 1 的措辞**：是否允许“用户点过一次、有期限的授权”让 agent 自动做第 1 级（以及窄范围的第 2 级）改动？我建议允许，并写进 CLAUDE.md。
2. **付费开发者账号**：天气、跨设备账本（CloudKit / iCloud Drive）、Mac 伴侣分发都需要。
3. **Mac 端形态**：是单独的伴侣 App（只跑 MCP + 同步），还是 Today 的 macOS 版？
4. **晚间复盘放在哪里**：在 Today 页 21:00 之后出现，还是一个通知入口？

---

## 来源汇总

App 部分的来源见 §2 各节。平台与协议：
- Apple：[WeatherKit](https://developer.apple.com/weatherkit/) · [BGTaskScheduler](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler) · [IntentDonationManager](https://developer.apple.com/documentation/appintents/intentdonationmanager)
- MCP：[Authorization 规范](https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization)
- 账本格式：[Activity Streams 2.0](https://www.w3.org/TR/activitystreams-core/) · [OpenTelemetry GenAI agent spans](https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-agent-spans/)
- 编码 agent 面板：
  - [T3 Code（GitHub）](https://github.com/pingdotgg/t3code) · [T3 Code 笔记](https://notes.nicolasdeville.com/ai/t3-code/)
  - [Conductor](https://conductor.build/)
  - [Claude Code 权限模式](https://code.claude.com/docs/en/permission-modes) · [Claude Code 桌面版](https://claude.com/resources/articles/claude-code-desktop-redesign)
  - [GitHub Agent HQ](https://visualstudiomagazine.com/articles/2025/10/28/github-introduces-agent-hq-to-orchestrate-any-agent-any-way-you-work.aspx)
  - [Cursor 云端 agent](https://cursor.com/help/ai-features/background-agents)
- iOS 27 / WWDC 2026 里 App Intents 成为 Siri 进入第三方 App 的唯一通道：多家二手来源一致，我没读到 Apple 原文，**未核实**（[Bitrise](https://bitrise.io/blog/post/wwdc26-under-the-radar)）。“iOS 系统级支持 MCP”的说法 **未核实**。
