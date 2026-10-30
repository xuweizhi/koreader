# Linux 测量边界 v1（G0）

环境：Ubuntu 24.04 x86_64、2 vCPU；debug 构建、SDL3 软件渲染、Xvfb、540×720、160 DPI，默认内置插件组合，仅切换 anxui 启停。数据使用自动生成的 EPUB/PDF 副本。这里的数据不是 Android 或墨水屏性能结论。

## 启动与首页

1. 启动总时长：Python 即将创建 `xvfb-run ./kodev run -b` 子进程的单调时钟 → 原 UIManager 完成第一个 FileManager/ReaderUI 重绘。包含 Xvfb、启动脚本和进程初始化，不等同 Lua 页面构建耗时。测量补丁只放在隔离的 KO_HOME，不修改产品核心。
2. 内部首屏：执行 late patch → 上述主窗口首次重绘。用于分析启动分段，不能代替启动总时长。
3. 热首页：原菜单关闭后、调用 anxui 入口前 → `UIManager:forceRePaint()` 完成。包含页面数据准备、组件创建和绘制提交，排除测试脚本的等待、截图写盘、Xvfb 启动及物理刷新。原型阶段一页只列一个测试文件；不能据此宣布大书库性能满足要求。
4. 本轮各启动使用新 KO_HOME，OS 页缓存共享；这是“新配置启动”，不是每次清空内核缓存的磁盘冷启动。初次原封面缓存提示可能覆盖已完成绘制的主窗口，截图在其自动消失后采集。
5. 同一组测试顺序执行，保留逐次值、源文件副本和命令。原始值见 `/data/koreader-anx-work/evidence/W04/g0-summary/performance.json`；中断且没有完整 PASS/指标的样本不参加分位数计算。分位数使用 nearest-rank。

## 冻结的 Linux 预算

保留验收矩阵中的初始预算，未因原型测量放宽：

| 项目 | 边界/预算 | 完整验证批次 |
| --- | --- | --- |
| 热首页首屏 | 上述第 3 项，≤500 ms；含千本书库首批结果，后续索引单列 | W31 |
| 普通本地动作 | 动作分发至下一次绘制提交，P95≤150 ms；不含截图/测试等待 | W31 |
| 阅读翻页 | 相同书、字体、屏幕、页序列，工具栏关闭时 P95≤max(经典 P95×1.10，经典 P95+20 ms) | W31 |
| 彩屏封面缓存 | 原始 BlitBuffer 分配总量上限 24 MiB；大对象不得先无限解码后再计数 | W11/W31 |
| 灰度封面缓存 | 上限 8 MiB；模拟灰度只验软件预算 | W11/W31 |
| 增量常驻内存 | 彩屏 48 MiB、灰度 16 MiB；进程 RSS 与 Lua/封面内存分别记录 | W31 |
| 重复操作 | 100 次开书/关书、100 次工具页开关；预热/GC 后增量≤max(2 MiB，预热后 5%)，末段不持续单调增长 | W31 |

新配置启动总时长暂不设绝对合格线，只保存经典/新 UI 对照；500 ms 仅约束热首页，不能将包含整个进程启动的秒级数值直接与它比较。最终候选复测至少 20 次启动、100 次交互/翻页，覆盖完整页面和压力库；G0 的原型采样不能替代。

## 变化处理

更改字体、DPI、构建类型、显示后端或插件组合后另建组，不混算。界面代码变化后保留 G0 作为历史基线，最终页面生成新源码身份和新结果。后续若预算确需改变，记录原值、证据、原因和新值，不静默调整。

## W31 测量补充与原生既有保留

正式矩阵要求彩色和灰度两组、每组经典/Anx 各 20 次新进程启动，以及 1000/5000 路径、实际相对翻页和 100 次书籍/工具开关，共 96 个独立进程。每类普通动作和每类工具单独计算 P95；取消计入绘制，不能被其他快速动作稀释。逐次值、预热标识、动作身份、交互后 RSS、Lua 内存、窗口及弱引用记录一并保存。部分矩阵或未结束的中间结果不能签收。

书库压力路径复用自制格式样本内容，不能称为 5000 本内容各异的真实藏书。封面原生进程取消另使用独立的自制单页 PDF（50 万个矢量矩形，约 1.27 MB），放在书库目录外，标明是适配器压力输入。其原引擎解析/渲染提供真实工作，不插入 sleep、暂停进程或伪造未完成状态。它不改变书库计数或普通交互延迟样本；原始文件 SHA 和生成器保留。

在原版经典流程发现一项既有保留：`FileManagerShortcuts.provider_props` 首次注册的 `cloudstorage`、`cloudstorage_upload`、`exporter`、`movetoarchive` 的 8 个 get/set 闭包，均通过原插件 `self.ui` 持有初始 FileManager。W31 `owner-diag-02/stability-color-classic-13-01/memory.jsonl` 实际用 `debug.getupvalue` 验证了每条路径。它已关闭、无文档、不是当前实例；旧 ReaderUI 全部回收。没有修改原回调或手动清引用来制造通过。

按验收文件“原版已有失败单列”的规则，最终对照需继续核对新旧两组是同一组原生路径，仅允许这个精确的初始 FileManager 记作既有保留，原始残留计数仍保留为 1。其他旧 FileManager、全部旧 ReaderUI、旧页面和窗口必须为零；Anx 的附属插件必须已停止，scope 的任务、窗口、关闭器和清理集合全部为空，不再引用阅读会话或页面。不能把仍被原生对象持有的插件或空 scope 描述成已经 GC。

这是一项明确的 Q04 原版既有问题，不能宣称“没有任何残留对象”。所有时间、缓存、RSS 和长期增长预算保持上表原值；是否满足其余要求仍须以正式矩阵实际结果为准。

## W31 灰度大书库内存优化记录（正式验收前）

2026-10-30 的三轮定向对照均使用本机上述环境、5000 条书库路径，分别运行经典/Anx 两个独立进程。Anx 每轮包含 20 次热开首页和 100 次普通书库动作，五类动作各 20 次。增量 RSS 的计算是“Anx 交互前后及最终采样中的最大 RSS − 本轮经典书库首次稳定后的 RSS”，不是 Anx 结束值减启动值，也不是只比较 Lua 堆。灰度上限始终为 16,777,216 bytes（16 MiB）。

| 批次 | 当轮变化 | 增量 RSS | 热首页 P95 / 最大值 | 结论 |
| --- | --- | --- | --- | --- |
| [gray5000-03](/data/koreader-anx-work/evidence/W31/gray5000-03/summary.json) | 优化前对照 | 45,617,152 bytes（43.50 MiB） | 59 / 62 ms | 执行完成，RSS 超预算 |
| [gray5000-04](/data/koreader-anx-work/evidence/W31/gray5000-04/summary.json) | 仅为可见卡片创建动作回调；减少空查询临时分配 | 23,384,064 bytes（22.30 MiB） | 39 / 40 ms | 执行完成，RSS 仍超预算；额外诊断已开启 |
| [gray5000-05](/data/koreader-anx-work/evidence/W31/gray5000-05/summary.json) | 再复用当前插件实例的纯值条目数组 | 14,073,856 bytes（13.42 MiB） | 29 / 35 ms | 本子集执行和预算通过，完整 W31 尚未签收 |

三轮的经典基线 / Anx 峰值分别为 184,422,400 / 230,039,552、184,975,360 / 208,359,424、185,376,768 / 199,450,624 bytes。完整命令、环境及源码身份保存在各轮 [03 identity](/data/koreader-anx-work/evidence/W31/gray5000-03/identity.json)、[04 identity](/data/koreader-anx-work/evidence/W31/gray5000-04/identity.json)、[05 identity](/data/koreader-anx-work/evidence/W31/gray5000-05/identity.json) 中；三轮产品和诊断工具快照并不完全相同，不能混合为一组分位数。

优化依据与实现边界：

1. [03 内存记录](/data/koreader-anx-work/evidence/W31/gray5000-03/library-gray-anx-5000-01/memory.jsonl) 中，首次稳定后 RSS 为 181.25 MiB，Lua 活跃内存约 20.61 MiB；20 次热开后再完成 10 次动作，RSS 已到 217.38 MiB，Lua 活跃内存反而约 19.56 MiB。对象回收后的 Lua 计数没有同步增长，不能据此认定差额全部是原生泄漏；分配器保留已申请内存也会抬高 RSS。该现象促使检查重复分配，而非扩大封面预算或强制裁剪全局缓存。
2. 首轮优化移除了整库每条数据上的打开/长按回调及其 scope 包装。原来 5000 条数据每次热开约创建 20,000 个闭包；现在数据保持纯值，只给当前页可见卡片建立回调，并捕获该卡片的文件路径。空查询直接收集条目，不再为每条数据构造临时搜索字段表、连接和转小写；非空查询保留原搜索语义。
3. 次轮优化复用插件实例自己的条目数组，每次仍读取原目录、历史或收藏源、按文件路径去重并刷新字段。只有相同位置且文件身份相同的条目才复用，旧字段先清空，源中消失的尾项移除；更换文件不会把旧条目对象改成另一部书。异步元数据重新填充，插件关闭时清除 `book_items`，不写回 KOReader 原始数据，也不增加全局书库缓存。
4. 复用依赖当前页面调用约定：`loadItems()` 先关闭旧元数据 scope，所有现有调用紧接着在同一 Lua 执行段内 `rebuild()`，其间不让出事件循环；重建关闭旧渲染 scope，旧异步回调失效。若以后将加载与重建拆到不同事件周期，须重新验证旧卡片和旧封面回调对复用条目的访问，不能直接沿用本次结论。

04 的 [hot-memory.jsonl](/data/koreader-anx-work/evidence/W31/gray5000-04/library-gray-anx-5000-01/hot-memory.jsonl) 保存 20 次热开前后共 40 条诊断。采样没有额外调用 GC，记录 Lua KB、`/proc/self/smaps_rollup` 的 RSS / Anonymous / Private_Dirty，以及可用时的 `mallinfo2`。首次热开前到末次热开后，RSS 从 185,593,856 增至 203,538,432 bytes，Anonymous / Private_Dirty 从 90,095,616 增至 104,792,064 bytes；对应 `mallinfo2.uordblks` 仅从 58,013,936 增至 59,568,576 bytes。诊断支持继续排查分配高水位，但不能精确归因每一字节；`mallinfo2` 也不代表所有 LuaJIT 与映射内存。诊断读数在动作计时区间之外，仍可能扰动整个进程，因此显式诊断模式禁止用于正式 full，04 只作定位证据。05 未启用该诊断。

05 是单次配对的灰度 5000 路径子集，距 RSS 上限约 2.58 MiB，不代表所有主题、库规模、启动、翻页和长时间操作均通过。[stability-03](/data/koreader-anx-work/evidence/W31/stability-03/summary.json) 的经典/Anx 两组试跑执行和预算也通过，但每组仅有 2 次预热、10 次计数的开书/返回，Anx 工具开关共 10 次；它不能替代正式 100 次稳定性要求。已知初始 FileManager 保留仍按上一节单列。

上述子集的 `final_gate_eligible` 都是 `false`。随后完成的正式 `full-01` 及新一轮修正见下节；子集结果保留为当时源码的过程证据。本机 debug SDL 软件渲染结果不能外推到 Android、实体彩屏或墨水屏设备。

## full-01 失败与第三轮内存修正

[full-01 汇总](/data/koreader-anx-work/evidence/W31/full-01/summary.json) 的 96 个进程全部执行通过，动作完整性和其他预算检查通过，但灰度书库的两项增量 RSS 超过 16 MiB：1000 路径为 16,879,616 bytes（16.10 MiB），5000 路径为 18,223,104 bytes（17.38 MiB）。因此 `budgets_passed=false`、`final_gate_eligible=false`，这轮完整矩阵未签收。它也说明先前 05 的单次子集通过不足以保证下一轮测量通过。

后续仅在 Home 的页面替换与关闭路径处理退役组件：清除旧子树（含 `[1]`）、`cards` 和焦点 `layout` 等引用，关闭时同时解除 `filtered`、`item_table` 引用；完成原组件释放和 scope 关闭后，若 `collectgarbage("isrunning")` 为真，单次执行 `collectgarbage("step", 512)`。每次重建完成或关闭各调用一次，没有新增定时器，不修改 GC 的 pause / stepmul，也不在 GC 被外部停止时重新启动它。

`512` 是软性工作量提示，不能理解为严格的内存回收量或毫秒上限。该步可能进入 atomic 阶段或执行终结器，所以引用释放和单次 step 本身不能证明交互不卡顿；其成本须保留在真实操作至绘制的计时内，继续检查各类 P95 和完整新矩阵。没有调整 RSS、延迟或长期增长预算。

[gray-library-06](/data/koreader-anx-work/evidence/W31/gray-library-06/summary.json) 使用上述修正后的 [源码身份](/data/koreader-anx-work/evidence/W31/gray-library-06/identity.json)，完成灰度 1000 / 5000 路径的经典/Anx 四场景。每个 Anx 场景仍测 20 次热开和 100 次普通动作；实际结果如下：

| 路径数 | 经典 RSS 基线 / Anx RSS 峰值（bytes） | 增量 RSS | 热首页 P95 / 最大值 |
| --- | --- | --- | --- |
| 1000 | 174,567,424 / 184,889,344 | 10,321,920 bytes（9.84 MiB） | 17 / 22 ms |
| 5000 | 184,127,488 / 196,059,136 | 11,931,648 bytes（11.38 MiB） | 33 / 36 ms |

06 的执行和预算检查通过，但它仍只是四进程灰度书库子集，`final_gate_eligible=false`，不能代替完整矩阵。随后 [full-02](/data/koreader-anx-work/evidence/W31/full-02/summary.json) 完成 96/96 进程，全部执行和预算通过，`final_gate_eligible=true`；灰度 1000 / 5000 增量 RSS 为 10,039,296 / 11,665,408 bytes。完整结果、原始值和限定范围见 [最终性能报告](performance-results.zh-CN.md)。当前完整本地回归为 838/838，通过记录及源码身份见 [本地回归记录](local-regression.zh-CN.md)；不沿用 `full-01` 或旧 `source-files.json` 为当前版本背书。
