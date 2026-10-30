# W31 Linux 性能验收结果：full-02

2026-10-30 完成的正式矩阵 `full-02`，96 个独立进程、676 项检查全部通过；`suite_complete`、`full_96_case_contract`、`execution_passed`、`budgets_passed`、`final_gate_eligible` 均为 `true`。这是冻结 Linux 测量边界下的通过结论。Q04 有一项经经典版对照证实的原生初始 FileManager 保留，按“原版已有失败”单列，不能解读为所有旧对象均已回收。[完整汇总][summary]

本报告只使用 full-02 的实际数据，不把旧版本或诊断子集混入分位数。报告编制时独立复算了 `samples.jsonl` 的 68 个非启动动作分组，P50/P95/max 全部与结果一致；80 次启动的原始值也逐项与汇总核对。下表时间单位均为毫秒，分位数采用 nearest-rank；1 MiB = 1,048,576 bytes。

## 环境、源码与样本边界

| 项目 | 本轮记录 |
| --- | --- |
| 平台 | Ubuntu 24.04 x86_64，Linux 6.8.0-146-generic，glibc 2.39；2 vCPU，约 7.71 GiB 内存 |
| 构建与显示 | debug 构建，SDL 软件渲染 / Xvfb，应用窗口 540×720，160 DPI |
| 主题 | color 彩色、gray 软件灰度；均有经典版 / Anx 对照 |
| 配置与缓存 | 每场新建隔离 KO_HOME，默认内置插件组合，仅切换 Anx；OS 页缓存共享，同场热循环复用缓存 |
| 批次开始 | 2026-10-30 02:03:38 +08:00（identity 原值为 2026-10-29T18:03:38.396789+00:00） |
| core HEAD | `dcb50ae439f2acd82aec213063e76739984eacb1` |
| Home SHA-256 | `00dd9df9fdd397b16c3aa0d107c2b352d375bcd1624b8aceb24fe34d5c8ec1d4` |
| Python 测量工具 SHA-256 | `e00a477ca185ae485be7317a426d50cd6dd71674a412f58f6fb5ebac1a849299` |
| 实测冻结版 Lua 工具 SHA-256 | `70a02716ad5e10da747d90d0e19edeb30aa097f67214b39ede8981d34e35076e` |

完整的插件文件散列、子模块版本、环境与负载观察边界在 [identity][identity]；测量时使用的 [Home 副本][home-source]、[Python 工具副本][python-source]、[Lua 工具副本][lua-source] 和 [工作区差异][source-diff] 已保存。96 场的 `source_unchanged` 均为 `true`。本轮关闭额外热内存诊断，协调者确认其他构建、测试和模拟器已停止；每场启动前及运行中每秒检查已知编译器、Java、模拟器和 SDL 进程，未发现竞争负载。自己的 Xvfb、LuaJIT 和封面子进程按本场进程组 / session 单独记录并排除。这不是对共享宿主所有后台工作的穷尽证明。[源码及环境身份][identity]

矩阵构成为：两主题 × 两模式 × 20 次启动 = 80 场；两主题 × 两模式 × 两种书库规模 = 8 场；两主题 × 两模式的阅读翻页 = 4 场；两主题 × 两模式的重复开关 = 4 场，共 96 场。

书库由 13 个自制合法格式文件循环复制组成，其中仅有 **12 份不同内容**。1000/5000 指不同路径数量，不能称为 5000 本内容独立的真实藏书。复制中的硬链接仅存在于同一隔离场景内，不链接共享原样本；没有预填全库元数据。格式分布如下，逐路径来源和散列见 [1000 路径清单][corpus-1000]、[5000 路径清单][corpus-5000]。

| 路径数 | EPUB | PDF | DjVu | CBT | CBZ | FB2 | MOBI | TXT |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1000 | 384 | 154 | 77 | 77 | 77 | 77 | 77 | 77 |
| 5000 | 1923 | 770 | 385 | 385 | 385 | 384 | 384 | 384 |

本机结果不是 Android、实体彩屏或墨水屏结果；没有测量电池功耗、物理面板刷新、真实触摸至显示延迟，也不是清空 OS 页缓存后的磁盘冷启动。冻结预算和详细测量约定见 [Linux 测量边界](linux-measurement.zh-CN.md)。

## 启动与热首页（Q01）

启动从 Python 即将创建 `xvfb-run ./kodev run -b` 子进程计时：经典版止于原主窗口首次绘制完成；Anx 止于 Anx 首页首次绘制完成。包含 Xvfb、启动脚本及进程初始化。每格 20 个新进程；该项没有设绝对合格线，不能套用热首页的 500 ms 门槛。[20 次逐样本及分位数][summary]

| 主题 / 模式 | 样本数 | P50 | P95 | 最大值 |
| --- | ---: | ---: | ---: | ---: |
| 彩色 / 经典 | 20 | 1656.22 | 1739.98 | 1802.42 |
| 彩色 / Anx | 20 | 1679.87 | 1722.07 | 1742.33 |
| 灰度 / 经典 | 20 | 1662.41 | 1714.50 | 1741.12 |
| 灰度 / Anx | 20 | 1667.61 | 1697.83 | 1707.03 |

热首页从调用 Anx 入口开始，到 `forceRePaint()` 完成，包含数据扫描、组件构建和绘制提交。每场 20 次，包括首次打开；20 次都须 ≤500 ms。后续元数据 / 可见封面完成时间单列，不计入首批可交互内容时延。

| 主题 / 路径数 | 样本数 | P50 | P95 | 最大值 / 上限 | 首次打开后异步稳定等待 |
| --- | ---: | ---: | ---: | ---: | ---: |
| [彩色 / 1000][lib-c1] | 20 | 15 | 16 | 32 / 500 | 6768 |
| [彩色 / 5000][lib-c5] | 20 | 27 | 31 | 44 / 500 | 6973 |
| [灰度 / 1000][lib-g1] | 20 | 16 | 18 | 23 / 500 | 6760 |
| [灰度 / 5000][lib-g5] | 20 | 25 | 32 | 38 / 500 | 6995 |

最后一列是首次打开结束后，等待 source / render scope 任务清空及原封面工作进程结束的实测等待，含轮询调度；它不是全库全文索引耗时，也不是完整书库全部封面生成耗时。笔记索引只在后续取消场景中验证启动与取消，未据此宣称全库索引完成性能。

## 普通操作与实际翻页（Q02）

每个 Anx 书库场景完成 100 次普通操作：搜索、清搜索、书架翻页、排序、网格 / 列表切换各 20 次。下表给出该主题两种库规模中较慢的一组 P95，**没有混合两组原始样本重算**。每种动作独立检查 P95≤150 ms。[彩色 1000][lib-c1]、[彩色 5000][lib-c5]、[灰度 1000][lib-g1]、[灰度 5000][lib-g5]

| 动作 | 彩色最慢 P95 | 灰度最慢 P95 | 上限 |
| --- | ---: | ---: | ---: |
| 搜索 | 17 | 17 | 150 |
| 清搜索 | 19 | 21 | 150 |
| 书架翻页 | 19 | 19 | 150 |
| 排序 | 17 | 21 | 150 |
| 网格 / 列表切换 | 17 | 15 | 150 |

工具页来自稳定性场景，每主题预热 10 轮后，五类各测 20 次打开和 20 次关闭。每个子类型分别计算并检查 P95，不能用其他快操作掩盖某一类慢操作。[彩色工具样本][stability-c-anx-samples]、[灰度工具样本][stability-g-anx-samples]

| 工具子类 | 彩色打开 / 关闭 P95 | 灰度打开 / 关闭 P95 | 每项上限 |
| --- | ---: | ---: | ---: |
| 阅读工具栏 `reader_panel` | 15 / 17 | 13 / 17 | 150 |
| 目录 `toc` | 16 / 17 | 16 / 17 | 150 |
| 笔记 `notes` | 12 / 17 | 12 / 17 | 150 |
| 统计 `statistics` | 13 / 17 | 12 / 17 | 150 |
| 设置 `settings` | 14 / 17 | 16 / 17 | 150 |

普通动作的计时区间包含实际回调和绘制提交。测量器在计时区间外执行用于内存采样的 GC；**产品 Home 中 `collectgarbage("step", 512)` 的执行成本仍在动作计时区间内**。full-02 原始证据保留了实测冻结版 `boundary` 的 “no GC included” 描述；这里排除的仅是测试采样 GC，产品自然 GC 或主动 step 的耗时没有被剔除。

正式测量完成后，当前工具的顶部注释和 `result.boundary` 已改为明确“product GC included”及“sampling GC excluded”，修正后 SHA-256 为 `4e16f5f80f86f73f54864998002bde6f0bf60bc47027957e1ac16fc7bfa31400`。排除这两处文案后代码逐字相同；产品源码、执行时序、计时、预算和样本均未变，也未重写 full-02 的冻结副本及原始结果。这是后续描述修正，没有作为新测量批次重跑。[修正核验][wording-result]、[仅文案差异][wording-diff]

阅读使用同一自制中文 EPUB（S01，SHA-256 `34505e21df7da43ff4b53243a83d7872ba1904d464eaaf372428beb36603771a`）、相同配置与屏幕，工具栏关闭。通过原 `GotoViewRel` 相对翻页事件在前 25 页往返，预热 10 次，正式 100 次；经典 / Anx 的 page、delta、方向序列相同。上限为 `max(经典 P95×1.10, 经典 P95+20 ms)`。

| 主题 | 经典 P50 / P95 / 最大值 | Anx P50 / P95 / 最大值 | Anx P95 上限 |
| --- | ---: | ---: | ---: |
| 彩色 | 6 / 12 / 16 | 6 / 13 / 15 | 32 |
| 灰度 | 6 / 13 / 14 | 6 / 13 / 15 | 33 |

逐次翻页证据：[彩色经典][reader-c-classic]、[彩色 Anx][reader-c-anx]、[灰度经典][reader-g-classic]、[灰度 Anx][reader-g-anx]。这些数据验证该 EPUB 路径的相对翻页性能，不能替代所有格式、字体、文件复杂度的阅读基准。

## RSS、Lua 与封面缓存（Q03）

增量 RSS = **Anx 所有规定内存采样中的最大 RSS − 同主题同规模经典进程的 `library_settled` RSS**。采样包括首次稳定、每 10 次普通动作、交互稳定和取消后的最终状态，均在测量器 GC 后读取。它是规定采样点的常驻内存对照，不是连续捕获的瞬时分配峰值；没有只取 Anx 最终值或只比较 Lua 堆。

| 主题 / 路径数 | 经典 RSS 基线 bytes | Anx RSS 最大采样值 bytes | 增量 bytes（MiB） | 原预算 MiB | 余量 MiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| 彩色 / 1000 | 174,354,432 | 185,860,096 | 11,505,664（10.973） | 48 | 37.027 |
| 彩色 / 5000 | 185,659,392 | 196,698,112 | 11,038,720（10.527） | 48 | 37.473 |
| 灰度 / 1000 | 174,841,856 | 184,881,152 | 10,039,296（9.574） | 16 | 6.426 |
| 灰度 / 5000 | 186,146,816 | 197,812,224 | 11,665,408（11.125） | 16 | 4.875 |

四组 Anx RSS 最大采样值均出现在 `final`。同组经典稳定 / Anx 最大采样 Lua 内存分别为：彩色 1000：11.857 / 13.085 MiB；彩色 5000：15.831 / 18.204 MiB；灰度 1000：11.823 / 12.799 MiB；灰度 5000：15.748 / 17.898 MiB。Lua 与 RSS 分开记录，不相加，也不把两者差值直接解释为泄漏。[RSS 判定][summary]；内存明细：[彩色 1000][mem-c1]、[彩色 5000][mem-c5]、[灰度 1000][mem-g1]、[灰度 5000][mem-g5]

封面每页按原始解码缓冲及可能发生的四字节缩放缓冲保守预留，先检查尺寸 / 预留上限再分配。本轮实际展示 PDF / 图片书页面并成功解码，不能靠“没有解码，所以 0 bytes”通过。

| 主题 / 路径数 | 峰值预留 bytes（MiB） | 上限 MiB | 成功解码调用数 |
| --- | ---: | ---: | ---: |
| 彩色 / 1000 | 4,291,584（4.093） | 24 | 178 |
| 彩色 / 5000 | 4,346,364（4.145） | 24 | 186 |
| 灰度 / 1000 | 4,291,584（4.093） | 8 | 177 |
| 灰度 / 5000 | 4,291,584（4.093） | 8 | 178 |

解码调用包含重复页面，不是不同封面数量；缓存预留也不是进程 RSS。实际结果和 `cover_exercise` 所指页面见 [四组书库结果][lib-c1]、[彩色 5000][lib-c5]、[灰度 1000][lib-g1]、[灰度 5000][lib-g5]。

## 真实任务取消与空闲刷新

每个 Anx 书库场景分别执行一次元数据取消、原生封面工作进程取消、笔记索引取消。它们独立计时并包含绘制，每类只有 1 个样本，因此这里报告单次值，不把它包装成有统计稳定性的 P95；也不与 100 次普通操作混合。

| 主题 / 路径数 | 元数据取消 | 封面取消 | 笔记索引取消 | 每项上限 |
| --- | ---: | ---: | ---: | ---: |
| 彩色 / 1000 | 8 | 12 | 13 | 150 |
| 彩色 / 5000 | 8 | 13 | 17 | 150 |
| 灰度 / 1000 | 7 | 13 | 12 | 150 |
| 灰度 / 5000 | 7 | 14 | 15 | 150 |

四场均证实：元数据及索引至少开始一个实际批次；取消前存在 1 个存活的自有原生封面 worker；取消后 worker 被原回收路径回收，`worker_gone_after=true`；每场 3 次迟到回调被 scope 拒绝，scope 清理断言通过。上述封面取消时延止于取消动作和绘制提交，**不等于 worker 完全退出耗时**；退出由后续独立断言确认。[取消字段与结果][lib-g5]

为可靠观察运行中取消，封面取消使用书库目录外的自制单页 PDF，含 500,000 个矢量矩形，1,271,355 bytes。SHA-256 为 `369013bd5ab189079e9566807a754853f912eb781552dab6b3b96554acdfbb7c`，复制前后核对散列。它是原 MuPDF 引擎的独立适配器压力输入，在普通书库测量完成后使用，不改变书库计数，不是 UI 可见页内容；没有以 sleep 或暂停子进程伪造工作中状态。[压力文件身份与用途][cancel-fixture]

两主题的 Anx 书库、阅读和稳定性场景共 8 场，各观察空闲 5 秒；`anx_dirty_calls=0`，实际绘制次数也均为 0。这里仅说明这些 5 秒观察窗内没有持续刷新，不能外推为无限时长后台活动证明。[空闲检查][summary]

## 100 次重复开关与既有对象保留（Q04）

经典版和 Anx 在每个主题均先预热 10 次开书 / 返回，再计数 100 次；Anx 同时完成预热后 100 次工具页打开 / 关闭，五类工具各 20 次。经典版没有 Anx 工具页，不能宣称其也执行了这组工具操作。开书 / 返回耗时包含原阅读器准备和异步就绪轮询，单独列出，不冒充纯本地按钮动作。

| 主题 / 模式 | 开书 P50 / P95 / 最大值 | 返回 P50 / P95 / 最大值 |
| --- | ---: | ---: |
| 彩色 / 经典 | 73 / 90 / 103 | 35 / 48 / 53 |
| 彩色 / Anx | 94 / 103 / 110 | 50 / 67 / 113 |
| 灰度 / 经典 | 71 / 83 / 103 | 34 / 47 / 51 |
| 灰度 / Anx | 93 / 103 / 110 | 50 / 73 / 78 |

内存采样在操作回调退栈后的新事件周期执行两次测量 GC。增长按 `max(cycles_complete, final) − warm` 计算，分别受 `max(2 MiB, warm×5%)` 限制。以下均为 MiB。

| 主题 / 模式 | 预热后 RSS | RSS 增长 / 上限 | 预热后 Lua | Lua 增长 / 上限 |
| --- | ---: | ---: | ---: | ---: |
| 彩色 / 经典 | 176.664 | −0.340 / 8.833 | 12.057 | −0.691 / 2.000 |
| 彩色 / Anx | 182.109 | +0.641 / 9.105 | 11.709 | +0.531 / 2.000 |
| 灰度 / 经典 | 176.711 | +0.238 / 8.836 | 11.717 | −0.065 / 2.000 |
| 灰度 / Anx | 182.602 | −0.102 / 9.130 | 12.388 | −0.339 / 2.000 |

四场 RSS 和 Lua 的最后 5 个周期采样均未出现“全段非递减且末值大于首值”，尾段增长检查通过。经典窗口栈从预热到结束保持 1 个，Anx 保持 2 个（当前原文件管理器和当前 Anx 首页）；旧工具窗口为 0，不能把仍在显示的窗口误算为泄漏。逐周期记录：[彩色经典][stability-c-classic-mem]、[彩色 Anx][stability-c-anx-mem]、[灰度经典][stability-g-classic-mem]、[灰度 Anx][stability-g-anx-mem]。

**原生既有保留的精确例外：** 两主题、两模式的 `warm`、`cycles_complete`、`final` 均保留 1 个初始 FileManager，原始 `retained_old_owners` 仍记录为 1。该对象仅为弱引用记录 index 2，已经关闭、无文档、不是当前 FileManager 或 ReaderUI。实际 upvalue 检查证明 `FileManagerShortcuts.provider_props` 首次注册的下列 8 个原生 get/set 闭包，通过各自插件 `self.ui` 指向它：

| 原生 provider | 闭包源码 | get / set 行号 |
| --- | --- | --- |
| cloudstorage | `plugins/cloudstorage.koplugin/main.lua` | 32 / 36 |
| cloudstorage_upload | `plugins/cloudstorage.koplugin/main.lua` | 44 / 48 |
| exporter | `plugins/exporter.koplugin/main.lua` | 109 / 112 |
| movetoarchive | `plugins/movetoarchive.koplugin/main.lua` | 30 / 34 |

正式判定核对了每条 provider / method / source / line / upvalue 和初始对象身份，并核对经典 / Anx 路径集合完全相同。不是“容许任意一个旧对象”的宽泛例外；`unexpected_old_owners=0`，旧 ReaderUI、其他旧 FileManager、旧工具窗口都为 0。附属于这个原生初始 FileManager 的 Anx 插件已停止，scope 已关闭，任务 / 窗口 / closers / cleanups 集合为空，home、reader、工具页、索引、`book_items` 等引用均已清除。[原始对象与 upvalue 证据][stability-g-anx-mem]；[两模式匹配和 `known_native_retention` 分类][summary]

这个插件对象和空 scope 仍可能随原生 FileManager 被持有，不能称为已经 GC。按验收中“原版已有失败单列”的规则，本轮结论是**除明确原生既有保留外没有新增残留，且原内存与增长预算全部通过**，不是 Q04 字面意义上的“零例外回收”。

## 与此前失败批次的关系

[full-01][full-01] 的 96 场执行通过，但灰度 1000 / 5000 路径增量 RSS 为 16,879,616 / 18,223,104 bytes，均超过原 16 MiB 上限；它仍保留为失败结果，没有删除、改阈值或只重跑挑选较低值。

随后产品仅在 Home 重建 / 关闭时清除退役组件引用、完成原资源及 scope 释放，并在 GC 正常运行时执行一次 `collectgarbage("step", 512)`。`512` 是工作量提示，LuaJIT 的 atomic 阶段或终结器仍可能带来额外耗时；没有修改全局 pause / stepmul、增加常驻定时器或循环执行完整 GC。此前已减少整库回调、临时搜索字符串和条目表重复分配，完整过程见 [内存优化记录](linux-measurement.zh-CN.md)。

full-02 对修正后的源码重新执行了完整 96 场，原门槛保持不变，所有动作和翻页延迟包含产品新增回收成本。通过结论仅对应本报告记录的源码、样本和 Linux 环境；后续源码、构建、插件、字体 / DPI、设备或缓存边界改变时，应建立新组复测。

[summary]: /data/koreader-anx-work/evidence/W31/full-02/summary.json
[identity]: /data/koreader-anx-work/evidence/W31/full-02/identity.json
[source-diff]: /data/koreader-anx-work/evidence/W31/full-02/source.diff
[home-source]: /data/koreader-anx-work/evidence/W31/full-02/source/plugins/anxui.koplugin/views/home.lua
[python-source]: /data/koreader-anx-work/evidence/W31/full-02/source/doc/anx-style-ui/tools/run-performance.py
[lua-source]: /data/koreader-anx-work/evidence/W31/full-02/source/doc/anx-style-ui/tools/performance-smoke.lua
[corpus-1000]: /data/koreader-anx-work/evidence/W31/full-02/library-gray-anx-1000-01/corpus.json
[corpus-5000]: /data/koreader-anx-work/evidence/W31/full-02/library-gray-anx-5000-01/corpus.json
[lib-c1]: /data/koreader-anx-work/evidence/W31/full-02/library-color-anx-1000-01/result.json
[lib-c5]: /data/koreader-anx-work/evidence/W31/full-02/library-color-anx-5000-01/result.json
[lib-g1]: /data/koreader-anx-work/evidence/W31/full-02/library-gray-anx-1000-01/result.json
[lib-g5]: /data/koreader-anx-work/evidence/W31/full-02/library-gray-anx-5000-01/result.json
[mem-c1]: /data/koreader-anx-work/evidence/W31/full-02/library-color-anx-1000-01/memory.jsonl
[mem-c5]: /data/koreader-anx-work/evidence/W31/full-02/library-color-anx-5000-01/memory.jsonl
[mem-g1]: /data/koreader-anx-work/evidence/W31/full-02/library-gray-anx-1000-01/memory.jsonl
[mem-g5]: /data/koreader-anx-work/evidence/W31/full-02/library-gray-anx-5000-01/memory.jsonl
[reader-c-classic]: /data/koreader-anx-work/evidence/W31/full-02/reader-color-classic-13-01/samples.jsonl
[reader-c-anx]: /data/koreader-anx-work/evidence/W31/full-02/reader-color-anx-13-01/samples.jsonl
[reader-g-classic]: /data/koreader-anx-work/evidence/W31/full-02/reader-gray-classic-13-01/samples.jsonl
[reader-g-anx]: /data/koreader-anx-work/evidence/W31/full-02/reader-gray-anx-13-01/samples.jsonl
[cancel-fixture]: /data/koreader-anx-work/evidence/W31/full-02/library-gray-anx-5000-01/cancel-stress-fixture.json
[stability-c-anx-samples]: /data/koreader-anx-work/evidence/W31/full-02/stability-color-anx-13-01/samples.jsonl
[stability-g-anx-samples]: /data/koreader-anx-work/evidence/W31/full-02/stability-gray-anx-13-01/samples.jsonl
[stability-c-classic-mem]: /data/koreader-anx-work/evidence/W31/full-02/stability-color-classic-13-01/memory.jsonl
[stability-c-anx-mem]: /data/koreader-anx-work/evidence/W31/full-02/stability-color-anx-13-01/memory.jsonl
[stability-g-classic-mem]: /data/koreader-anx-work/evidence/W31/full-02/stability-gray-classic-13-01/memory.jsonl
[stability-g-anx-mem]: /data/koreader-anx-work/evidence/W31/full-02/stability-gray-anx-13-01/memory.jsonl
[full-01]: /data/koreader-anx-work/evidence/W31/full-01/summary.json
[wording-result]: /data/koreader-anx-work/evidence/W31/measurement-wording-correction/result.json
[wording-diff]: /data/koreader-anx-work/evidence/W31/measurement-wording-correction/wording.diff
