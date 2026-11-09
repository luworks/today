# Health 模块（原型）

> Current implementation: [global dashboard order](dashboard-redesign.md) and [public read coverage](public-read-coverage.md). The grouped ordering and ten-metric scope below are historical design notes, superseded by the user-approved October 19 dashboard redesign. Read-only, on-device processing and no medical advice remain constraints.

**现状：不做第 5 个 tab。** Today tab 顶部（只在今天）一行安静的摘要「6,240 steps · slept 7 hr 12 min」（默认步数 + 睡眠；任一被隐藏时用显示列表里的前两项），点开是 Health sheet：一个**紧凑的分组列表**（Activity / Sleep & Recovery / Body），每行 = 指标名 + 最新值（大号数字、小号单位）+ 很淡的日期标签（Today / Yesterday / 日期）+ 右侧 7 天迷你图（累计型柱状，读数型点线）。点一行进详情（7 / 30 / 90 天、一张图、平均 / 最低 / 最高 / 与上一段的变化，不生成文字总结）。用户可以「Add Metric」（静息心率、活动能量、锻炼分钟、步行+跑步距离、体脂、正念分钟、日照时间），右滑「Hide」（只隐藏，不删 Apple Health 数据），长按菜单 Hide / Move Up / Move Down，按住拖动在分组内排序；选择和顺序存在 UserDefaults（`today.health.metrics`，JSON id 列表），健康数值不落盘。Settings → Today → "Health summary" 开关（默认开）、"Health metrics" 打开同一个 sheet；第一次要显示这行时才请求 HealthKit 授权（只请求这一行用到的类型），Add Metric 时只请求新增类型。设计说明：`metrics-and-density.md`。代码：`ios/One/TodayHealthLine.swift`、`HealthView.swift`、`HealthMetricDetail.swift`、`HealthMetricPicker.swift`、`HealthSparkline.swift`、`HealthModel.swift`、`HealthSource.swift` / `HealthKitSource.swift`、`HealthMetrics.swift`（目录、选择、格式化、迷你图和区间统计，`swift test` 覆盖）、`HealthSampleSeries.swift`（样例数据）。截图（样例数据，模拟器 Today-Health2，亮/暗）：`docs/health/list-*.png`（列表）、`detail-*.png`（详情）、`add-metric-*.png`、`today-line-*.png`。下面是原型（tab 版）时的调研与说明，其中「放什么、不放什么」已被 `metrics-and-density.md` 取代。

## 超时规则（Add Metric 卡死修复）

任何 Health 调用（授权请求、每个指标的查询、单位）都不会无限等：`HealthTimeout.race` 给每个调用 8 秒，超时就放弃（HealthKit 的挂起调用取消不掉，所以放在独立任务里，不占住调用方）。每个指标单独查询、单独超时，一个卡住不影响其他行；列表永远在屏幕上，只有「新行自己」显示小转圈，不再有整页转圈。卡住的行：有旧数据就保留旧数据；没有就显示「—」加一行「Can't read this yet. Check Health access.」和 Allow / Try Again。授权请求由 `HealthAccessGate` 统一发（每批新类型只请求一次，串行，超时后忘掉以便重试，晚到的回答会触发刷新）；Add Metric 先关掉选择器、等它完全消失后再请求授权并加行。被拒绝时 Health 不会说，空数据就显示「No data」并在页脚用一句话说明。日志：`os.Logger`，subsystem `com.luworks.today`，category `health`。测试：`swift test --filter HealthLoadingTests`；模拟器验证用启动参数 `-uiTestingHealthStall <ids>`、`-uiTestingHealthAuthStall <ids>`；真机路径可在模拟器用 `-realHealth -seedHealth steps,sleep,weight`（仅 Debug，写入样例数据）。

## Apple 健康 App 是怎么做的（调研摘要）

- **摘要（Summary）**：顶部"已固定"的指标卡，每张卡 = 类别色小标题 + 今天的大数字 + 一个迷你图（步数是柱状、体重是折线/点）；下面是"亮点（Highlights）"——自动生成的一句话对比（"本周平均步数比上周多"）和一张图。
- **趋势（Trends）**：比较过去 4 周 vs 过去 52 周的平均值，只有数据足够时才出现。
- **浏览（Browse）**：按类别（活动、身体测量、睡眠、心脏……）列出所有数据类型，点进去是 日/周/月/6个月/年 的详细图表。
- **步数**：今天的累计数 + 每小时/每天柱状图，Health 本身没有"步数目标"（目标在健身 App 的圆环里）。
- **体重**：最近一次的值和时间 + 折线，范围可切换。kg/lb 跟随地区。
- **睡眠**：昨晚"睡眠时间"（不含清醒）+ 阶段图（清醒 / 快速眼动 REM / 核心 Core / 深度 Deep，需 Apple Watch），周视图是每晚的柱子。
- **活动圆环**（Move/Exercise/Stand）属于健身 App，依赖 Apple Watch；没有手表的用户只有 iPhone 估算的活动能量。

## HealthKit 能拿到什么

| 数据 | 类型 | 说明 |
|---|---|---|
| 步数 | `HKQuantityType(.stepCount)` | 用 `HKStatisticsCollectionQuery` 按天求和，系统会对 iPhone + Watch 去重；直接加样本会重复计数 |
| 活动能量 | `.activeEnergyBurned` | iPhone 估算，Watch 更准 |
| 锻炼分钟 | `.appleExerciseTime` | 基本只有 Watch 才有 |
| 体重 | `.bodyMass` | 用户手动记录或智能秤写入 |
| 睡眠 | `HKCategoryType(.sleepAnalysis)` | 值为 inBed / awake / asleepCore / asleepDeep / asleepREM / asleepUnspecified |
| 静息心率 | `.restingHeartRate` | 只有 Watch |
| 活动圆环 | `HKActivitySummaryQuery` | 只有 Watch |

隐私要点：HealthKit **不会告诉 App 读取权限被拒绝**，被拒的类型只是返回空。所以"无数据"和"未授权"在 UI 上只能一并提示。

## 放什么、不放什么（保持克制）

**放**：步数（今天大数字 + 目标环 + 7 天柱状）、体重（最新值 + 30/90 天折线 + 变化量）、睡眠（昨晚时长 + 阶段条 + 7 晚柱状）。这三项 iPhone 单机就有数据（睡眠需要手表或第三方 App 写入），也是最常被看的。

**不放**：活动圆环、锻炼分钟、静息心率（依赖 Watch，而且健身 App 已经做得很好）；趋势/亮点/浏览（Health 本身就是看完整历史的地方，页底一个 "Open Health" 链接过去）；任何写入（不记录体重、不改数据）；任何 AI 健康建议。

## 数据来源规则

- `-uiTesting` 和模拟器：样例数据（`HealthSample`，固定种子，每次一样），页面顶部明确写 "Sample data"。
- 真机：永远读 Apple Health。没数据就显示空状态，不会用假数据冒充。
- 首次打开 tab 时弹 Apple 的授权页（只读：步数、体重、睡眠）。数据只放在页面内存里，不进 SwiftData、不进 widget 快照。

## + 按钮

Health tab 上 + 仍然是"新提醒"（和 Today/Reminders 一样）。Health 是只读的，记体重会多一个写入权限和一张表单，不值得；隐藏 + 又会让底栏在不同 tab 间跳动。

## 截图

（tab 版的截图已随 tab 一起删掉，现行截图见上面。）

## 已知问题（tab 版，已撤掉）

- 第 5 个 tab 让顶部 pill 栏放不下了：Pro Max 上 Health pill 右侧就被截断（栏变成可横滑），小屏 iPhone 更明显。要留这个 tab，得把 pill 收窄或改成别的入口。
