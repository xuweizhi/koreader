# AI 实施入口：保留 KOReader 功能，获得 Anx 风格

修订：v2，2026-10-29。实施已启动，实际进度以执行状态及其证据为准。

本文件是 AI 执行本项目的入口。产品目标见[实施方案](implementation-plan.zh-CN.md)，批次契约见[任务表](tasks.zh-CN.md)，判定标准见[验收矩阵](acceptance.zh-CN.md)，实际进度见[执行状态](execution-state.json)。用户已要求开始实施，按下列流程持续推进。

## 1. 固定决策与执行边界

- 默认在 KOReader 中新增 `plugins/anxui.koplugin`，使用 Lua 组件实现 Anx 风格；保留阅读引擎、ReaderUI、UIManager、原数据写入方及高级菜单。
- `/data/anx-reader` 是 UI 与交互参考，默认只读。首版不嵌入 Flutter，不迁移阅读引擎，不重写全部高级窗口，不承诺完整跨 Anx 同步。
- Linux SDL 是先行开发和自动化环境；Android 彩屏是首发目标。Android 工具链、Android 实机、墨水屏实机、AI 服务凭据分别验证，互不充当 Linux 开发的前置条件。
- 先完成“原菜单打开新首页 → 打开 EPUB/PDF → 返回 → 数据保持正确”的真实闭环，再增加组件、页面与适配器。推荐目录是演进结果，不要求先创建所有空文件。
- SimpleUI、Bookshelf 不作为必装依赖。KOAssistant 是可选集成，先审计固定版本并调用原入口；不能凭名称猜测 API。
- 默认不修改核心。若已有接入方式确有可复现限制，执行 W09 的最小扩展流程；常规局部适配无需重新要求用户选架构。引入 Flutter、更换引擎、削减首发平台等改变目标的决定需用户明确变更范围。
- 技术关卡不要求逐项用户审批。完成一批后继续下一批；只有缺失信息确实阻断当前工作且没有其他可执行任务时，才请求所需信息。工具权限审批仍遵从运行环境规则。

## 2. 每次开始和续接

1. 先读当前适用的仓库指令、用户最新要求、本文件和 `execution-state.json`；核对实际 git 工作区。保留用户已有修改，不清理未跟踪文件，不自动 reset、覆盖或切换有冲突的工作区。
2. 核对核心 HEAD、子模块、已改文件内容和证据的源代码身份。如果源码变化，标出受影响的验证已过期，再决定最小重验范围；不能只因 JSON 写着“通过”就跳过。
3. 从任务表选择依赖已满足的一批。优先 `next_batch`；它被外部条件阻断时，选择其他就绪批次并记录原因。W09 是条件任务，W34 可提前执行。
4. 只读该批输入及必要调用链。修改前核实真实函数参数、事件时机、读写归属和关闭路径。读不到依赖源码时记录未知，禁止把拟议接口当成现成接口。
5. 明确这批的可观察结果，完成最小实现和适当验证，保存证据，更新状态，再继续。不要用反复扩写计划代替代码和运行结果。

一批以一个可以独立验证的行为为单位，通常只改少量业务文件；文件数不是硬限制。如果一批明显过大，可拆为 `Wxx.1`、`Wxx.2` 子步骤写入父批的 `substeps`，父批全部完成后才通过，不创建冲突的第二套进度表。

## 3. 输入目录索引

下列都是阅读入口，具体接口必须以执行时源码为准。相对路径均基于 `/data/koreader`，标明 Anx 的除外。

| 输入代码 | 先读内容 | 要确认的问题 |
| --- | --- | --- |
| R00 | `kodev`、`doc/Building.md`、`doc/Building_targets.md`、`.gitmodules`、git 状态 | 依赖、可用构建目标、当前测试运行器与已有改动 |
| R01 | `frontend/pluginloader.lua`、`frontend/apps/filemanager/filemanager.lua`、`filemanagermenu.lua` | 插件注册、菜单入口、post-init 与 Show 时序、启停 |
| R02 | `frontend/apps/reader/readerui.lua`、`frontend/ui/uimanager.lua`、`frontend/dispatcher.lua` | 当前实例、窗口栈、动作注册、阅读打开/关闭与返回 |
| R03 | `frontend/ui/widget/`、`frontend/ui/size.lua`、Anx 的 `lib/page/home_page.dart` 和 `lib/page/home_page/` | 布局、缩放、焦点、主题、Anx 实际页面结构 |
| R04 | `frontend/readhistory.lua`、`frontend/readcollection.lua`、`frontend/docsettings.lua`、根目录 `datastorage.lua` | 原数据路径、写入方、文件身份和 sidecar |
| R05 | `plugins/coverbrowser.koplugin/bookinfomanager.lua`、文件管理器收藏/历史模块 | 元数据、缓存、原文件动作和失效通知 |
| R06 | `frontend/apps/reader/modules/readerannotation.lua`、`readerbookmark.lua`、`readerhighlight.lua`、`readertoc.lua`、`readermenu.lua` | 锚点、当前内存状态、原批注/目录/菜单能力 |
| R07 | `plugins/statistics.koplugin/main.lua`、`plugins/exporter.koplugin/`、`plugins/kosync.koplugin/`、`plugins/cloudstorage.koplugin/` | 计时唯一来源、导出和同步各自范围 |
| R08 | W26 获取并锁定的 KOAssistant 源码、许可、入口与生命周期 | 当前版本的可调用方法、取消、凭据归属；此前不假设存在 |
| R09 | `spec/unit/readerui_spec.lua`、`readerannotation_spec.lua`、`readerbookmark_spec.lua`、`pluginloader_spec.lua`、`uimanager_spec.lua`；初始化后的测试运行器 | 可复用测试、真实 fixture、过滤语法及实际用例数 |
| R10 | `frontend/device/`、`platform/android/`、验收矩阵及受影响插件源码 | 输入/屏幕/设备能力、打包、插件条件分支 |

`filemanagermenu.lua` 与文件管理器收藏/历史模块位于 `frontend/apps/filemanager/`；R06 中的模块均位于 `frontend/apps/reader/modules/`。不要在仓库根目录猜测同名文件。

已知需要特别核实的点：FileManager post-init 早于其静态实例赋值及窗口显示；开书应沿原有 `FileManager:openFile` / `ReaderUI:showReader` 路径；不可直接再创建一套 ReaderUI；文件管理与阅读插件实例的生命周期不同。

## 4. 可修改范围

| 范围代码 | 允许内容 |
| --- | --- |
| S0 | `doc/anx-style-ui/` 的必要规格、状态、说明；计划使用 `/data/koreader-anx-work/` 保存运行配置、测试书副本、日志、截图与依赖审计资料 |
| S1 | `plugins/anxui.koplugin/_meta.lua`、`main.lua`、`views/home.lua`；后续按批次扩展 |
| S2 | 插件内的 `theme.lua`、`widgets/`、`assets/` 及实际需要的 gettext 文案 |
| S3 | 插件内的 `lifecycle.lua`、`navigation.lua`、`capabilities.lua`、`settings.lua`、`compat/core.lua` 及入口接线 |
| S4 | 插件内的 `adapters/library.lua`、`compat/coverbrowser.lua`、书架/详情页面与封面管理 |
| S5 | 插件内的 `adapters/reader.lua`、`adapters/annotations.lua`、阅读工具栏/目录/笔记页面与可重建索引 |
| S6 | 插件内的统计/AI 适配、`compat/statistics.lua`、`compat/koassistant.lua`、统计/设置页面 |
| S7 | `spec/unit/anxui_*_spec.lua`；证明现有行为受影响时，可修改对应现有测试；本地辅助脚本限定在 `doc/anx-style-ui/tools/` 或外部工作目录 |
| S8 | W09 已证明必要的核心调用点及对应测试；先写明文件、调用链、必要性与禁用后的原路径，再修改 |
| S9 | 经证据证明需要的 Android 构建/打包文件及测试；不借打包任务改变其他平台行为 |

每批隐含允许 S0，以及该批行为需要的 S7。范围限制用于控制任务，不妨碍合理修复：超出时先把具体理由与最小新增路径写进该批记录，再继续。涉及阅读引擎、原数据格式或产品目标的变更不能通过“扩大范围”自动批准。第三方依赖源码默认不原地改写，必须改时记录固定来源、补丁和可恢复方式。

## 5. 检查命令与运行证据

以下命令都是未来执行入口，不代表已经运行成功。工作目录为 `/data/koreader`；依赖安装按执行时仓库文档确定，网络或写入受限时按工具审批机制处理，不绕过限制。

| 检查代码 | 命令/动作 | 使用时机 |
| --- | --- | --- |
| K00 | `git status --short`、`git rev-parse HEAD`、`git submodule status`、`git diff --check`，另检查新建未跟踪文件 | 开始、结束与续接；diff 不覆盖未跟踪文件，不能据此称它们已检查 |
| K01 | 按构建文档准备依赖，必要时 `git submodule update --init --recursive`，再 `./kodev build` | W01；之后仅在依赖/原生代码变化或运行结果要求时重建 |
| K02 | 启动真实 Linux SDL 应用，按本批场景操作并保存日志/截图 | 首个可运行变更、交互变化、阶段验收 |
| K03 | 使用 W01 从当前测试运行器确认的精确命令运行受影响测试，核对匹配用例数大于零 | 有逻辑/数据/生命周期变化时；记录完整命令，不能只写“测试通过” |
| K04 | `./kodev check` | 相关代码检查及阶段验收；记录与基线已有问题的区别 |
| K05 | `./kodev test front` | 本地候选交付及重要集成回归；不机械地对每个间距调整全跑 |
| K06 | `./kodev release android-arm64` | W34 及最终代码版本打包；成功构建不代表模拟器或实机通过 |
| K07 | 在指定目标设备/模拟器实际安装、启动、操作、恢复，记录设备和包校验值 | W35–W37；使用授权的测试设备，不自动部署到未知个人设备 |
| K08 | 使用固定插件版本和已配置服务完成一次明确的 AI 选段请求、取消和失败场景 | W38；凭据不写入日志/文档，离线模拟结果不能代替真实服务 |

隔离运行示例，执行前创建目录并准备测试书副本：

```bash
env KO_HOME=/data/koreader-anx-work/runtime/baseline ./kodev run -W 540 -H 720 -D 160
env KO_HOME=/data/koreader-anx-work/runtime/anxui ./kodev run -W 540 -H 720 -D 160
env KO_HOME=/data/koreader-anx-work/runtime/anxui ./kodev run -W 1280 -H 800 -D 160
```

两份配置从同一基准准备，baseline 明确禁用新插件，其他设置保持一致。KO_HOME 只隔离配置，书旁 sidecar 仍可能写入原书目录，必须使用书籍及 sidecar 的副本。故障注入仅针对这些隔离数据。

W01 必须记录当前测试过滤的实际语法。`./kodev test front` 是已知完整入口；选择性运行依赖初始化后的 `base/test-runner/runtests`，不可预编不存在的参数。无法可靠过滤时，使用已确认可运行的完整前端入口，并明确运行范围。

K02 已新增 `tools/run-sdl-smoke.py`，用于隔离配置、真实 SDL 截图与程序化调用原 UI 动作；执行结果以日志为准，脚本存在不代表运行通过。物理输入另行验证。没有显示服务或自动交互工具时，静态检查与单元测试只能标记相应部分通过，不能宣称“UI 实测”。SDL 模拟设备参数也不能证明真实墨水屏刷新或硬件键正确。

## 6. 每批执行契约

每次只推进一个主批次，遵循以下顺序；外部耗时构建可独立进行，但没有要求使用多个 AI 或并行修改工作区。

1. **输入与预检**：读任务表中的 R 项，确认依赖的有效证据；在状态中记为 `in_progress`，记录本批目标和将修改的路径。
2. **实现**：按 S 范围完成可运行行为。接口按实际源码适配，能力缺失是显式状态，不用空函数或硬编码成功值凑验收。
3. **检查**：运行适用 K 项与验收切片。数据/异步逻辑需要有意义的回归；纯图标、颜色或间距以真实截图检查为主，不增加镜像实现的低价值测试。
4. **比较**：与同基线经典界面核对；发现失败先复现和定位。把原版已有失败单列，但不得用这一标签掩盖新引入的数据错误。
5. **留证与续接**：写证据、状态、未解决问题和下一动作。满足本批范围才验证通过，再继续就绪批次；不因达到一个阶段就结束用户授权的整个目标。

阶段关卡未通过时，修复它的必要条件；不能大量堆叠依赖该关卡的新页面。外部验证等待则继续无依赖的本地批次。若 Linux 环境也不可运行，仍可做不依赖运行结果的检查或实现，但 G0 不得标为通过。

不要反复盲目重试同一错误。记录错误输出、根因判断和下一次不同的验证。无法获得设备/服务时说明具体条件；不得把“等待外部条件”转换成“取消该要求”或“测试通过”。

并行执行时，普通源码分析、隔离文件编辑和轻量静态检查可分配给子代理；需要提权的 GUI、模拟器或网络执行由根代理统一发起，子代理先提交精确命令。本工作环境曾出现子代理在提权调用上长时间等待、无法及时接收协调消息的情况。不要把等待审批当作测试正在运行；以实际会话、日志和进程为准。正式性能测量期间暂停 native 编译、Gradle 和模拟器，只保留测量进程。

## 7. 状态与证据格式

`execution-state.json` 是唯一进度来源，任务表不再同步维护一套勾选状态。JSON 中的版本值只是规划时快照，W00 必须重新核实。

批次状态使用：

| 状态 | 含义 |
| --- | --- |
| `not_started` | 尚未执行 |
| `in_progress` | 正在实施，有具体下一动作 |
| `implemented` | 实现已落地，但本批验证不完整 |
| `verified` | 本批明确范围已验证，必须带 `verified_scope` 与证据；不代表其他平台通过 |
| `blocked` | 此批缺少具体外部条件；填写原因及可恢复动作，其他批次可继续 |
| `not_applicable` | 仅适用于已证明不需要的条件项，例如 W09；有理由和证据 |

验证过后源码变化：保留历史证据，标记受影响证据 `stale`，将相应批次和关卡退回待验证状态。不能重写历史日志来对应新代码。缺少实机或 API Key 不是 N/A 的理由。

每批证据放在 `/data/koreader-anx-work/evidence/Wxx/<run-id>/`，JSON 引用文件路径。最少包含：

```text
batch_id / run_id / 时间
输入：核心 HEAD、子模块 SHA、第三方完整版本、样本 ID 与 SHA256
源码身份：全部相关修改/新建文件的路径和 SHA256、tracked diff 文件、未跟踪文件清单
环境：操作系统、真实设备/模拟器/SDL、DPI、配置快照、插件启停状态
改动：行为、涉及路径、原接口调用依据
验证：完整命令、退出码、实际用例数；场景 ID + 阶段 + 覆盖范围
结果：实际输出、原始日志/截图路径、通过/失败/未测、已知限制
恢复：清理测试资源、回退验证结果；下一批及下一条可执行动作
```

不能只用 git HEAD 指认未提交实现；必须同时保存变更快照和文件校验值。无需为了记录进度强制创建提交，也不自动推送。证据需可重现且不包含服务密钥或私人书籍内容；样本使用可合法测试的副本。

运行日志必须真实存在。模型自行生成的“预期输出”、UI 设计图、mock 返回、没有执行的脚本不能成为真实集成通过的证据。AI 无法观察某个画面时记录未验证，不填写人工检查通过。

## 8. 阶段结束与最终交付

- G0–G4：只验证[验收切片](acceptance.zh-CN.md#10-ai-执行的关卡切片与证据)，不提前要求尚未实现的页面。
- G5-local：当前代码的本地功能、性能、故障恢复及完整前端回归有证据，可以交付注明范围的本地候选成果。
- G5-release：W39 汇总实际设备、服务和版本矩阵。Android 是默认首发目标，缺 Android 实机时不能把本地候选宣布为已完成 Android 发布验收。墨水屏和真实 AI 只声明已实测范围，未满足条件继续保留待验证项。
- 发布关卡通过不自动授权上传、推送、商店发布或向他人发送消息；这些动作按用户明确指令处理。

暂停或上下文切换前，至少写清：当前批次、已经落地的文件、最后一次有效验证、失败/等待条件、下一条动作。续接后验证状态对应当前文件，直接继续，不重新做全部选型。

可用于启动实施的指令：

> 按 `/data/koreader/doc/anx-style-ui/ai-execution.zh-CN.md` 开始实施，读取 `execution-state.json` 并从下一批继续。每批完成实现、验证和留证后自主推进。遇到设备、服务或权限限制时如实记录，并继续不受阻的任务；不要把未执行的检查标为通过。
