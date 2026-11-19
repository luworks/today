# Today 交互、动效与触感规范

本文记录首次源码基线、共用交互规则及迁移计划。基线日期为 2026-11-19，审阅版本为 `a9208a9f11a2d47d172e901f5abdb0f76a34d46d`，与审阅时的远端主分支一致。下文评分与盘点保留为改动前的基线。

**当前设计成熟度 6.0 / 10。** Today 已经有可靠的时间粒度、原生控件、拖动预览和撤销基础。主要差距在于手指和内容偶尔脱节，以及同一结果在不同页面用不同的力度、时点和动画表达。**手一动就有回应，跨过有意义的格子才有刻度，确实完成的操作才有确认。**

## 当前基线与评分

以 [47 个注册场景][scenes]、[现有页面覆盖清单][coverage]和原生源码为索引，盘点四个主 Tab、侧栏、Ask、Search、Activity、Health、Settings，以及分享扩展和桌面／锁屏组件的交互边界。扫描 SwiftUI、UIKit 手势、分页、动画与触感调用，并追读日期提交、撤销及相关测试。显式触感搜索检出 **15 个 Swift 文件中的 18 处匹配**，包括仅在 Debug 可进入的 Alarm Wheel Lab 的两处。原生控件自带的反馈不在静态计数内。

输入证据包括 Yuan 对周条的真机使用反馈及截图。源码可解释周条的手势接管路径。装机 SHA、其他页面的实际触感、真机性能与完整无障碍表现仍为 **UNKNOWN**。已有性能记录也明确指出部分模拟器试验没有返回 hitch 数据。以下是基于证据的设计审阅分，权重为本提案设定。 [现有性能证据][performance]

| 维度 | 得分 / 满分 | 当前依据 | 满分表现 |
| --- | ---: | --- | --- |
| 跟手、反向与连续性 | 1.3 / 2.5 | Calendar 用原生 ScrollView，时钟有可接管滑动。Today 周条有 36 pt 接管和动画锁，Tab 快划到松手才生效。 | 主要手势有即时且连续的视觉响应，停、反向和再次触碰都能接管，明确保留系统导航及滚动。 |
| 时间粒度与落点 | 1.5 / 2.0 | 日／月相邻分页、周条同星期、闹钟 5／1 分钟、世界时钟慢拨 1 分钟均有明确定义。日、周、月的提交时点和快速反向体验尚未统一验证。 | 操作的下一落点可预测，跨天、周、月、年份及夏令时后也容易辨认。 |
| 触感的含义、一致性与节制 | 1.1 / 2.0 | 已有轻点、选择、成功和静音的例子。通用按压、Pill 选择、抽屉和拖放各自触发，缺少统一的归属与去重。 | 用户能分清选择一格、落位、写入成功和出错。被取消、重复或系统已经反馈的动作遵循明确规则。 |
| 状态可信、位置稳定与可撤销 | 1.5 / 2.0 | Today 有预览、同日拖移、撤销和视口保护，Ask 有状态回执。触感仍有从视图状态推断结果的路径，密集时间线的连续操作需要实机验证。 | 预览、正在提交、成功、失败和撤销各有清楚的状态。滚动位置和任务身份在操作后有连续性。 |
| 无障碍与可验证性 | 0.6 / 1.5 | 周条有 VoiceOver 周切换，部分控件支持 Reduce Motion 和可调操作。缺少跨模块证据和按设备的真实触感／卡顿基线。 | 常用任务在关闭触感、减少动态效果、VoiceOver 与大字体下同样成立，有可复现的实机与回归记录。 |
| **合计** | **6.0 / 10.0** | 当前源码设计审阅分 | 各维度达到满分表现和下文验收条件 |

### 全 App 交互盘点

| 场景 | 当前源码行为 | 改进方向 |
| --- | --- | --- |
| Today · 周条与点选日期 | 识别后横移至 36 pt 即提交 ±7 天，220 ms 自动走完余下的整页。出场动画期间挡住后续拖动。换周时有选择触感，点选日期直接更新。 [WeekStrip][week] | 首个试点。采用下文轻棘轮，松手决定是否换周，保留同一星期，一次只过一周。点天即时选中。 |
| Today · 纵向滚动与回到 Now | 有自动定位、人工触碰抢占和拖移时冻结快照，普通手势和行操作共用紧凑时间线。 [DayAgenda][agenda] | 回到 Now 是明确动作。查看、完成、Settle、删除或 Undo 后尽可能锚定当前行和屏幕位置。特别验证密集列表、跨 Morning／Afternoon、回到已在看的日期。 |
| Today · 长按移时、行侧滑与完成 | 自定义长按区分滚动、菜单与抬起后拖动。抬起和过槽都可给触感。完成行监听 `task.isDone`。取消、保存与撤销有各自的路径。 [TimelineHoldDrag][hold] · [共用任务行][rows] | 一次抬起、实际换槽才轻点。拖动时只预览时间，落位和数据提交用各自的状态；成功触感绑定真实写入来源。邻行移动时保持时间标签和身份可追踪。 |
| Calendar · 2 Day、Month、Year | 2 Day 的横滑限制为相邻一天，Month 垂直浏览相邻一个月并在 idle 提交。Year 是连续纵向浏览。2 Day 主时间轴与两日横向滚动并存。 [CalendarView][calendar] | 以现有原生物理为基础。日、月分页最多一页，年视图连续静音。统一标题、日期高亮、外层日程的提交时点。验证四／五／六行月份、跨年和竖向时间位置。 |
| Calendar · 空槽创建与编辑 | 长按空槽显示按 15 分钟对齐的预览，起手为中等 impact，槽位变化为 selection；松手打开编辑器。事件编辑有系统 DatePicker。 [空槽手势][slot] · [EventEditor][event] | 与 Today 拖移共用抬起和过格语义。分清选槽、打开草稿和保存。压缩空隙、空白、事件和系统菜单各有明确的手势所有权。 |
| Reminders · Smart Lists、固定列表、排序与侧滑 | 胶囊支持菜单、拖起和放置，放置和抬起有各自的中等 impact，列表里也有原生排序与侧滑。 [RemindersView][reminders] | 原生 Lift／Drop 有反馈时沿用系统。自定义插入线、当前目标与触感对齐。松手落空保持原位。添加菜单或 VoiceOver 等价的上移／下移。 |
| Reminders · 快加、时间预设与全编辑 | 快加网格用 date 的变化发 selection；系统 DatePicker、复发菜单和快捷时间同时存在。 [QuickReminderSheet][quick] · [TaskEditor][taskeditor] | 用户主动换档才给一次选中提示。首屏默认值、跨页面同步、相同值、取消均安静。键盘、菜单和保存沿用原生时序。 |
| Clock · 闹钟滚轮、开关与提示 | 新闹钟通常按 5 分钟，已有非五分钟闹钟可逐分钟保真编辑。轮会准备 UIKit 触感、限频、快速时减少刻度脉冲并支持 VoiceOver 可调。真正响铃有系统边界。 [TimeWheel][wheel] · [TimeWheelPicker][picker] · [AlarmEditor][alarmeditor] | 以该轮作为精确拨盘参考。保留可接管减速及慢拨精度。验证保存后的真实时间、闹钟许可和停止行为。轮的到格反馈与 AlarmKit 的响铃分别验收。 |
| Clock · World Clock | 低速每 10 pt 拨 1 分钟，快扫可跨更大范围；快甩收尾对齐 15 分钟，触碰能接管滑行。拖动和边界都没有显式触感。 [WorldClockScrub][worldcore] · [WorldClockView][world] | 保留安静浏览、Home／Now 参照与跨午夜的清晰日差。核实速度变化或重新按住时，慢拨精度和方向仍一致。 |
| Clock · Stopwatch | 原生横向分页切换模拟／数字表面，运行时更新读数，轻 impact 绑定总状态。 [StopwatchView][watch] | Start、Stop、Lap、Reset 各自精确确认一次。自动计时和每次重绘保持安静；两个表面共享同一计时。 |
| Clock · Timer、Today 的运行计时器 | Clock 有选择器、最近使用、进度环和按钮；Today 支持对应计时器行与侧滑操作。 [TimerSection][timer] · [TimerCard][timercard] · [Today TimerRows][timerrows] | Start／Pause／Resume／Stop 跨入口用同一结果语义。倒计时静默、低干扰，完成走系统的提醒路径。暂停时数字和环一致冻结。 |
| 顶／底栏、Drawer、Pill、Sheet | Tab 滑动到松手才切；边缘抽屉有轴向捕获、按投影落位、开关 impact；PressScale 在按下给 impact，Pill 分段另对选择变化发 feedback。 [HomeView][home] · [Drawer][drawer] · [PressScale][press] · [PillStyle][pill] | 一次动作的反馈只由一个控件负责。顶／底栏、边缘、日历内页、行侧滑和系统返回明确分区。复用原生 Sheet、导航和菜单；需要实时位移的交互尽早给视觉响应。 |
| Ask · 输入、卡片、批量提交 | 已有流式／状态更新、滚动到末尾、复制成功和批量 Added 的反馈点。 [AskView][ask] · [CaptureStack][capture] · [AskViewParts][askparts] | 等待开始与保存成功分开，流式文本保持安静。一次用户意图最多一次结果触感；批量部分成功回执显示发生了什么及可用 Undo。不抢离开底部阅读历史的滚动位置。 |
| Search、Activity 与 Undo | 搜索重用规划行组件。Activity 可逐项撤销，Undo toast 已有 Reduce Motion 路径。 [SearchView][search] · [ActivityView][activity] · [UndoToastView][undo] | 搜索结果更新、加载和筛选保持稳定。撤销在完成后确认一次，保住可见锚点，拒绝或冲突显示具体原因。 |
| Health、Settings | Health 有下拉刷新、图表切换、系统列表排序、管理指标。Settings 多复用系统菜单、表单和选择器。 [HealthView][health] · [SettingsView][settings] | 系统交互用系统反馈，普通浏览、拉取和图表自动更新保持安静。移除或重排时保住语义位置。权限拒绝和破坏性确认用清晰的状态与文字。 |
| Widget、锁屏、Share、Siri／Shortcuts | 外层使用系统动作。Live Activity 用 App Intents 按钮，Share 有系统 Add／Cancel，Siri 使用 Intent。 [Live Activity][widget] · [Share Extension][share] · [App Intents][intents] | 保持同一动作含义与准确回执。声音、触感和可用动作由已授权的系统入口控制；App 回到前台时安静地同步结果。 |

## 时间体验参考

| 参考 | 观察 | Today 应用 |
| --- | --- | --- |
| **机械潜水表 · Rolex Submariner** | 有明确的零点、固定刻度和动作约束，佩戴者边操作边知道测量基准。 [Rolex 手册](https://media.rolex.com/rolexcom/media/user-guides/submariner/rolex_submariner_en-us.pdf) | 周条和时间轴留下稳定参照。今天、当前浏览日期、Now 与选中时间各有可辨识的位置；分页支持双向微调。 |
| **机械 GMT · Rolex GMT-Master II** | 本地时针按小时向前或向后跳，参考时间保持独立，过午夜日期跟着变。 [Rolex GMT 说明](https://newsroom.rolex.com/watches/oyster-collection/gmt-master-ii) | 世界时钟跨城市比较应保留 Home／Now 参照，明确跨日前后；精调只作用于用户正在操作的值。 |
| **机械计时码表 · Patek Philippe** | 启动、停止、归零各有明确控制，列柱轮由按钮触发；飞返有特定的原子动作。 [Patek Philippe Chronographs](https://www.patek.com/en/manufacture/quality-and-fine-workmanship/chronograph-watches) | 计次、启停和归零各有确定、可见的状态。单次动作的连续反馈都服务于同一个结果。 |
| **连续走时 · Grand Seiko Spring Drive** | 发条供能、电子调速，秒针连续安静地扫过刻度。 [Grand Seiko Spring Drive](https://www.grand-seiko.com/us-en/collections/movement/springdrive) | 时间自然流逝时，让 Now 线、秒表指针或计时进度低干扰地更新。用户拨动或按下控制键时，反馈才变得明确。 |
| **Apple Watch · Digital Crown 和 Taptic Time** | 表冠用触感辅助滚动；Taptic Time 提供几种可独立理解的节奏，简洁模式用更少的脉冲表达更粗的时间。 [Crown Haptics](https://support.apple.com/en-gb/108368) · [Tell time on Apple Watch](https://support.apple.com/guide/watch/tell-time-apdb2c208edc/watchos) | 刻度的密度服从信息粒度。快速移动合并脉冲，避免一长串振动。关掉触感后，画面和读屏仍说明同一结果。 |
| **数字日历与任务 · Fantastical 和 Things** | DayTicker 浏览日期并联动下方日程；Things 结合手势起点和对象区分安排日期与选择项目。 [Fantastical Calendar Views](https://flexibits.com/fantastical-ios/help/calendar-views) · [Things Using Gestures](https://culturedcode.com/things/support/articles/2803582/) | 轻量的日期浏览保持位置。横滑起点在周条时翻周，在行内时操作行，在导航区时切换导航。 |
| **游戏 · Playdate 的 Crankin’** | 摇柄直接前进或回拨游戏时间。一位玩家评测肯定快转和精细回拨的组合；此为单条反馈。Apple 的游戏设计示例也将反馈绑定具体动作。 [Playdate](https://play.date/games/crankin/) · [玩家评测](https://gamefaqs.gamespot.com/playdate/317164-crankins-time-travel-adventure/reviews/175125) · [Apple 游戏触控](https://developer.apple.com/videos/play/wwdc2026/358/) | 复用试验动作：慢拨一格、快移、立即回拨。位置和动作方向同步，手停时预览停下，反馈由实际跨格或主动确认驱动。 |
| **视觉计时 · Time Timer** | 色盘随剩余时间缩小，过程安静，用户一瞥就看出还剩多少。 [Time Timer](https://www.timetimer.com/pages/time-timer-at-home) | 倒计时与日程空档提供一瞥可读的进度。背景时间安静流动，只在用户操作或已配置的时间事件发生时提示。 |

**浏览时间要安静，拨动时间要有刻度，提交时间要可信。** iPhone 的触感表达过档和状态，视觉位置与轻微吸附负责表现机械阻力。按 Apple 的一致性原则，触感、关键帧和状态变化应共享同一个事件。 [Apple HIG Haptics](https://developer.apple.com/design/human-interface-guidelines/playing-haptics) · [Apple HIG Motion](https://developer.apple.com/design/human-interface-guidelines/motion) · [Designing Fluid Interfaces](https://developer.apple.com/videos/play/wwdc2018/803/)

## 共用语义与默认规则

下表是建议的事件名和默认反馈。参数为原型起点，随实机证据修订。

| 事件 | 何时发生 | 画面与触感 |
| --- | --- | --- |
| `press` | 手指按中按钮、胶囊、图标 | 高亮或轻缩放即时开始。自定义普通按钮默认只做视觉回应，系统组件自行处理反馈；抬起、取消或滑出立即恢复。 |
| `selection` | 用户主动选择一个新日期、选项或离散档 | 立即显示新选择，点选日期的局部动效起点 100–140 ms。自定义控件至多一次系统 selection；重复选择、初始化、程序刷新保持安静。 |
| `detent` | 拨盘或拖动实际跨到有效刻度 | 一下短、清晰、轻的刻度反馈。预览内容同步，小幅反向去抖，真正反向跨格照常反馈。连续动作先试 45–60 ms 最短间隔，超速时合并，脉冲不排队。闹钟轮保留现有独立调校作对照。 |
| `lift` | 行或空槽已被抓起，手势所有权确定 | 抬起或描边与轻 impact 同时出现。系统已处理的抬起沿用系统反馈。 |
| `settle` | 周翻页完成，或移到可见的有效槽 | 落位反馈短而清楚。与最后一次过格太近时合并，优先保留落位。返回原位或系统取消时仅恢复画面。 |
| `commitSucceeded` | 用户发起的改动已经成功，且达成该操作所承诺的来源状态 | 稳定结果、必要的回执及 Undo。频繁的完成／暂停使用轻确认或系统默认，批量结果按一次用户意图最多确认一次。 |
| `commitFailed` | 用户发起的改动明确失败且需要处理 | 保留可恢复的草稿并说明原因，有行动空间时提供重试。确有需要时给一次系统 error／warning，与成功或刻度清晰有别。 |
| `silent` | 浏览、系统同步、滚动、倒计时运行、AI 流式文本、取消、无效尝试 | 视觉或可访问状态说明结果。普通应用内交互默认安静，用户指定的铃声、通知和声音试听由原有系统路径负责。 |

### 周条基准手势

- 横向意图成立后，处于手指下的两周连续跟随，不在距离阈值处锁定或加速。纵向滚动、系统边缘手势和日期点选保有各自的入口。
- 用日期格宽表达刻度，先试横移约一格和两格各给一次轻脉冲。松手超过约两格才选相邻周。回到原起点附近再松手会取消。设置小的反向去抖区，快速跨两格时合并为单次反馈。
- 一次手势最多换一周。松手收尾从当前可见位置开始，目标为相邻页或原页。先试 150–190 ms 的短收尾，末段基本无回弹。第二次触碰直接接管当前可见位置。快划降低等待感，日期落点保持可预测。
- 保留星期列和日期圆圈的对应关系。拖动时只预览，确认时日期和日程只提交一次。月份按该入口本身的定义显示，如 Today 的顶栏目前显示设备当月，Calendar 标题显示已浏览的周期。VoiceOver 继续有 Previous week／Next week 动作，Reduce Motion 保留日期与操作结果。

### 时间粒度、撤销与可访问性

- **浏览与调整。** 周条按周，Calendar 2 Day 按天，Month 按月，Year 连续浏览；World Clock 慢速逐分钟及可接管的快速浏览保持安静。触感密度与允许的时间步长有明确联系，同一功能从不同入口到达同一目标值。
- **时间正确性。** 按本地日历加天／周／月。验证跨月、跨年、周起始日、12／24 小时、夏令时不存在或重复的墙上时刻，以及本地和远端的日期差。现有非五分钟闹钟打开再保存时保真。拖移中的会议时长和其他项目保持原样。
- **手势所有权。** 系统返回和系统控制区优先，之后按起手区域归属抽屉、日期页、列表行或顶／底 Tab；识别方向后锁定坐标轴。纵向滚动优先于仍未成立的长按，已成立的拖动提供取消与明确落点。支持有意义的布局方向和原生导航行为。
- **状态与时序。** 按下、预览、提交中、成功、失败是不同状态。重排或移时的视觉结果可先行，成功反馈取自成功的写入回执。需要显式确认的参会者变更和整段重复系列继续沿用现有产品规则；Alarm Stop 和 Complete Reminder 各自表达不同状态。 [Today 产品原则][principles]
- **替代操作。** 自定义手势要有按钮、可访问动作或可调控件等价路径。紧凑控件核实实际命中区域，以 44×44 pt 为起点。允许触感关闭和减少动态效果各自独立运作；减少动态效果时保留选中状态、位置关系和确认文案，移除大位移装饰和回弹。确认提示可被读屏理解且不在高频刻度上打断播报。 [Apple HIG Gestures](https://developer.apple.com/design/human-interface-guidelines/gestures) · [Reduce Motion 验收](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/reduced-motion-evaluation-criteria)

## 如何落到 SwiftUI

这份 Markdown 负责统一**含义、可观察行为、例外和验收**。共享 Swift 层负责像设计令牌一样把含义兑现成运行时参数。以现有 [`ButtonConfiguration`／`PressScale`][press]、[`PillStyle`][pill] 和 [`TimeWheelTuning`][wheel] 为起点。

| 位置 | 推荐演进 |
| --- | --- |
| `TodayDesignSystem` | 增补一个集中定义的 Swift 文件，先放共享的按压、选择、分页收尾、落位语义和 Reduce Motion 映射。保留 SwiftUI ButtonStyle 和系统组件。 |
| iOS 触感映射 | 共享语义映射到系统 selection／impact／notification，手势会话拥有它自己的去重、冷却时间和事件 ID。UIKit 与 SwiftUI 的调用都消费同一语义。默认系统能力；仅在真机对照证明轻棘轮需要区分锐度和强弱时试 Core Haptics 的单个 transient，并提供情境等价的系统回退。 [Apple Core Haptics](https://developer.apple.com/design/human-interface-guidelines/playing-haptics#Custom-haptics) |
| Feature／`TodayCore` | 每个功能持有自己的手势状态和业务粒度，公开状态是位置、预览、落点及确认结果。复用现有的相邻分页、Clock 拨盘算术和领域事务。用稳定 ID 和本地时钟阻止过期动画完成回调或异步保存覆盖新操作。 |
| 文档与变更审查 | 修改一个交互时，在本文件维护该语义、例外和实测结果。新设计先引用已有语义。当前明确例外为 World Clock 的静音分钟浏览、闹钟的拨盘行为，以及系统通知／响铃。 |

第一批迁移让两个真实调用方开始复用同一个定义。先收拢最小的语义公共层，逐步移除重复的 View 级触发。原生分页与自定义滚轮各用适合自己的物理和识别方式。

首批由 [`InteractionFeedback`](../../ios/Sources/TodayDesignSystem/InteractionFeedback.swift) 统一日期选中、过齿和翻周落位反馈，WeekStrip 和 PillStyle 共用选择定义。周条在拖动中预览、松手时提交相邻周，使用 170 ms 落位、150 ms 取消收尾和 55 ms 刻度间隔作为初始参数。

## 到 10 分的路径

| 阶段 | 范围 | 完成证据 |
| --- | --- | --- |
| **先做 Today 周条与基线** | 主分支和「轻棘轮」对照。先解决过阈值接管、反向、第二次触碰和轻重两级；点天同步更新。 | 慢拖、取消、反向、快速连翻、跨月、按天点选均通过。实机能把控件策略造成的顿感和渲染 hitch 分开。 |
| **铺到高频交互** | 依次处理 Calendar 日／月、Today Timeline、Reminders 拖放、外壳导航。合并通用按压、Pill 选择和原生控件的多重触发。 | 上下滚动和横滑互不抢占。可撤销动作后任务身份和视口连续。同一种选择或落位在不同入口的视觉和触感时点一致。 |
| **把写入与 Clock 统一** | Alarm、Timer、Stopwatch、Ask、Activity、Undo；基于确实发生的命令结果发确认，World Clock 的安静浏览纳入回归。 | 单次及批量操作各有可信回执。慢保存、失败、部分成功、取消、快速重试和多入口操作均有记录。 |
| **跨设备完成校准** | 标准刷新率 iPhone 和 ProMotion iPhone，常规与密集的虚构数据。在相同设备和系统版本下对照基线及候选，并补无障碍检查。 | 分维度有真机、渲染、自动化和可访问性证据，以同一评分表复评。无为 UNKNOWN 的关键验收项。 |

### 验收方法

- **交互正确性。** 单测覆盖手指停住、反向、系统取消、接管正在收尾的手势、同齿抖动、确认一次和跨周历法。每批用 `./dev test unit` 跑相关逻辑，经 `./dev ui prepare` 准备的同一模拟器用 Device 面板走 3–5 条代表路径，复用现有夹具和构建。核对落点、视口锚点、焦点和真实可访问操作。
- **性能。** 针对按下到首帧反馈、持续输入到呈现、放手到落位、以及确认后的日程可用状态分别记录。普通按压反馈内部目标 P95 ≤50 ms，以可见帧为终点；持续手势以识别后的下一次可用刷新为目标，主线程交互更新工作先争取 <5 ms。按相同设备、刷新率、数据密度及冷暖条件采样，P95 样本不足时报告实际样本和最大值。高频路径用 Instruments Animation Hitches 测量，内部目标 ≤5 hitch ms/s；缺少指标记 UNKNOWN。 [Apple 响应性建议](https://developer.apple.com/documentation/xcode/improving-app-responsiveness) · [Apple hitch 指标](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app) · [Today 性能协议][perfprotocol]
- **触感与游戏式操作测试。** 首批用同机同数据盲测基线、原生分页、轻棘轮，覆盖惯用单手和忙碌场景。请不同使用习惯的人执行同样的动作并记录原话、误翻次数、松手后误触和连续翻页意愿。至少 8 人的小样本用于设计筛选，预设目标至少 7 人能一次完成慢拖取消、反向和连续换周的整组动作，同时正确判断日期走向；报告人数和设备，不把小样本推论为全体用户偏好。单独验证系统触感关闭、Reduce Motion、VoiceOver、大字体。软件事件记录与真机感受到的强度分别记。
- **证据记录。** 用 QA journal 记录 SHA、设备和系统版本、偏好、构建、可重放步骤及原始日志和视频路径。模拟器验证交互状态。实际触觉、真机掉帧和系统铃声单独记录。用既有 [QA 目录与保留规则][qa]。

[scenes]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/TodayScenes/SceneRegistry.swift
[coverage]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/docs/performance/page-coverage-v2.md
[performance]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/docs/performance/climb-targets-v5.md#missing-evidence-and-next-priorities
[perfprotocol]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/docs/performance/protocol.md
[qa]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/tests/qa/README.md
[principles]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/CLAUDE.md#product-principles-do-not-break-these
[week]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/TodayDesignSystem/WeekStrip.swift#L53-L98
[agenda]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/Features/FeatureToday/DayAgenda.swift
[hold]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/Features/FeatureToday/TimelineHoldDrag.swift
[rows]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/TodayPlannerUI/Rows.swift#L211-L230
[calendar]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/Features/FeatureCalendar/CalendarView.swift
[slot]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/Features/FeatureCalendar/CalendarView.swift#L2003-L2035
[event]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/Features/FeatureCalendar/EventEditor.swift
[reminders]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/Features/FeatureReminders/RemindersView.swift
[quick]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/Features/FeatureReminders/QuickReminderSheet.swift
[taskeditor]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/Features/FeatureReminders/TaskEditor.swift
[wheel]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/TodayCore/TimeWheel.swift
[picker]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/Features/FeatureClock/TimeWheelPicker.swift
[alarmeditor]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/Features/FeatureClock/AlarmEditor.swift
[worldcore]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/TodayCore/WorldClockScrub.swift
[world]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/Features/FeatureClock/WorldClockView.swift
[watch]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/Features/FeatureClock/StopwatchView.swift
[timer]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/Features/FeatureClock/TimerSection.swift
[timercard]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/Features/FeatureClock/TimerCard.swift
[timerrows]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/Features/FeatureToday/TimerRows.swift
[home]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/TodayShell/HomeView.swift
[drawer]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/TodayDesignSystem/Drawer.swift
[press]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/TodayDesignSystem/PressScale.swift
[pill]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/TodayDesignSystem/PillStyle.swift
[ask]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/Features/FeatureAsk/AskView.swift
[capture]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/Features/FeatureAsk/CaptureStack.swift
[askparts]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/Features/FeatureAsk/AskViewParts.swift
[search]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/Features/FeatureSearch/SearchView.swift
[activity]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/Features/FeatureActivity/ActivityView.swift
[undo]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/TodayPlannerUI/UndoToastView.swift
[health]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/Features/FeatureHealth/HealthView.swift
[settings]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/Features/FeatureSettings/SettingsView.swift
[widget]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/TodayWidgets/AlarmLiveActivity.swift
[share]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/ShareExtension/ShareViewController.swift
[intents]: https://github.com/luworks/today/blob/a9208a9f11a2d47d172e901f5abdb0f76a34d46d/ios/Sources/One/AppIntents.swift
