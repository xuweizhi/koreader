# W30 / W33：Linux SDL 视觉检查记录

2026-10-30。检查对象是 KOReader Lua 插件的实际画面；目标见 [visual-spec.zh-CN.md](visual-spec.zh-CN.md)。本轮覆盖四类页面、窄屏/宽屏、彩色/模拟灰度、中英文、大字与当前可本地复现的空态和错误态。已修复中文工具栏断行、书架导航缺少统计和宽屏搜索过长的问题，并补齐导航及笔记类型的图标与文字。不据此宣称与 Anx 像素相同，也不签收 Android、墨水屏或远程服务。

## 环境和证据身份

- Linux x86_64，真实 SDL3 软件绘制，Xvfb；DPI 固定 160。运行时书籍、配置和 sidecar 均在独立 `runtime/W30-*` 中。
- KOReader：`dcb50ae439f2acd82aec213063e76739984eacb1`。子模块及每次实际命令见各目录 `result.json`；未提交插件、脚本和测试快照保存在同目录 `source/`，不以 Git HEAD 代替这些文件的身份。
- UI：KOReader 内置 Noto Sans / Noto Sans CJK SC 后备；正常文字倍率 1，大字 1.25。阅读正文仍由原引擎使用原字体配置。
- 样本：`S01-中文阅读测试.epub`，SHA-256 `9e582686f9a3b0dce8749d0a120429f2d2de402a106e317ecaa45cb6541b7671`。没有借用用户书籍或真实 AI 密钥。
- Anx 参考：`0c7fc1ad4551f7dbbeba6a6468f69d830957fa2a` 的 `docs/images/zh/mobile1.png`、`wide1.png`。设备外框和宣传排版不作为逐像素比较基准；图标、书籍封面资源未复制。
- 证据根目录：[`/data/koreader-anx-work/evidence/W30`](/data/koreader-anx-work/evidence/W30)。每次结果包含命令、退出码、版本、快照校验值、日志和截图。

## 修改与复测

| 实查问题 | 修改 | 结果 |
| --- | --- | --- |
| 360 窗口下“添加／取消书签”“返回上一位置”拆成难读的短行 | 工具按钮用“书签”“返回位置”；动作仍调用原书签/位置模块 | `reader-narrow-updated` 与四个 `final-*` 工具栏截图可读，中文按钮未再出现单字尾行 |
| 书架底部/侧栏只有书架、笔记、设置、经典，未按目标接入统计 | 固定为书架、笔记、统计、设置；经典移至页头，宽屏位于搜索右侧 | 四种布局均实际打开统计、笔记、设置，再通过经典按钮返回原 FileManager |
| 宽屏搜索铺满内容区，经典入口不在页头 | 搜索上限 `scaleBySize(480)`，经典入口保留独立点击区 | 1280×800 实际宽度 640 物理像素；640×360 为 288，均是同一逻辑上限，无标题/关闭按钮重叠 |
| 导航与笔记类型缺少规格要求的图标 | 局部图文导航复用 `book.opened`、`edit`、`appbar.pageview`、`appbar.settings`；备注/划线/书签复用 `edit`、`appbar.typeset`、`bookmark` | 保留文字、原点击区和焦点轮廓；跨书笔记元信息补上类型文字，仍保留书名和位置 |

产品修改涉及 `i18n.lua`、`views/home.lua`、`widgets.lua`，以及主流程添加 `on_statistics` 回调。工具栏原布局保持；图标直接使用 KOReader 内置 SVG 和原 IconWidget，没有更改全局主题、图标缓存、菜单、手势或阅读正文。修改后的局部 Lua lint 为 0 warnings / 0 errors。

## 运行矩阵

以下路径均相对于证据根目录，每个目录的 `result.json` 均为 `passed: true`。

| 目录 | 场景 | 窗口 / 语言 / 显示 | 本轮结论 |
| --- | --- | --- | --- |
| `icons-portrait-03` | visual | 540×720 / 中文 / 彩色 / 正常字 | 图文导航、四类页面、列表/网格、空态和统计可达 |
| `icons-narrow-03` | visual | 360×640 / 中文 / 灰度 / 大字 | 工具栏、图文导航和笔记操作均在屏幕内 |
| `icons-landscape-03` | visual | 640×360 / 中文 / 灰度 / 大字 | 侧栏、工具栏、笔记和统计可用；设置 6 组以 2 页承载 |
| `icons-wide-03` | visual | 1280×800 / 英文 / 彩色 / 正常字 | 图文导航无文字截断，搜索有限宽；英文工具名称允许两行 |
| `components-updated` | components | 540×720 / 中文 / 彩色 | 真实 X11 键盘/鼠标开书、搜索/清空、空目录、文件失效提示通过 |
| `resize-updated` | resize | 540×720 → 1280×800 → 360×640 → 640×360 / 中文 / 彩色 / 大字 | 真实窗口尺寸改变后保留查询和当前书籍，边界检查通过 |
| `icons-reader` | reader_tools | 360×640 / 中文 / 灰度 / 大字 | 备注/划线图标可读；原文定位、目录、笔记编辑/删除/导出和关闭后翻页通过 |
| `settings-narrow-large` | settings_groups | 360×640 / 中文 / 彩色 / 大字 | 原设置读写、能力禁用解释与返回路径通过；此轮早于书架导航调整，分组页面未变 |

`reader-landscape-gray`、`reader-wide-english` 是短文案修正前的通过记录；`final-*`、`reader-narrow-updated` 是加入图标前的通过记录。保留用于比较，不把旧书架截图当作最终图标版证据。`components-updated` 与 `resize-updated` 的执行早于图标组件，输入/旋转结果只代表当时版本；图标版焦点与导航另在 `icons-*-03` 验证。

`icons-{portrait,narrow,landscape,wide}` 和对应 `-02` 是视觉脚本调试失败记录：第一轮错误假设 SDL 触屏模式会由 `refocusWidget` 自动画键盘焦点；第二轮错误假设原 IconWidget 保留绝对 `dimen`。分别改用原 `FORCED_FOCUS` 事件路径和居中容器的内容尺寸后复测。两轮没有据失败结果改动产品设备判断，也没有删除失败日志。

`visual-smoke.lua` 每场记录 11 个新 UI 画面中的全部焦点控件坐标，并额外保存导航焦点和返回经典界面的截图；允许屏幕边缘 ±2 像素取整误差，检查点击区宽、高均不小于 `scaleByDPI(44)`，图标与文字组合未超出点击区、文字未截断、没有图标缺失占位。通过原 FocusManager 焦点事件和 `onPress` → 原手势派发实际打开统计页。此检查不证明所有文字排版正确，因此另外实际查看以下截图。

书架稳定 3.2 秒后，再观察 3.2 秒的 `anxui` 控件 `setDirty` 次数：四场均为 **0**。范围是已加载书架；未把原 ReaderUI、设备计时器或屏幕物理刷新纳入此结论，也不将短观察窗称为长期稳定性测试。

## 实际看过的关键画面

下表保留首轮审图路径，用于核对空态、错误和原布局；图标版最终审图另见表后补充，不混用其源码身份。

| 页面/状态 | 截图路径 | 观察 |
| --- | --- | --- |
| 竖屏网格与列表 | `final-portrait/visual/library-grid.png`、`library-list.png` | 两行中文标题、作者、进度区分明确；无封面时写明“暂无封面”。列表首次加载可短暂显示文件名/作者未知 |
| 窄屏书架 | `final-narrow/visual/library-grid.png` | 经典/关闭、搜索/过滤和四项底栏均可达；大字不挤掉主动作 |
| 宽屏书架 | `final-wide/visual/library-grid.png`、`resize-updated/resize/wide-selected-query.png` | 左侧导航、有限宽搜索与右侧经典按钮分区清楚；单本书未被铺成巨型封面 |
| 横屏书架 | `final-landscape/visual/library-grid.png` | 低高度下封面占位压缩，书名/作者/进度保留；不是手机竖屏效果的等比缩小 |
| 工具栏 | `final-landscape/visual/reader-toolbar.png`、`final-wide/visual/reader-toolbar.png`、`reader-narrow-updated/reader_tools/anx-reader-toolbar.png` | 原正文仍在后方；中文短标签与英文两行标签可读，继续阅读按钮清楚 |
| 目录 | `final-portrait/visual/reader-contents.png` | 层级/页码与标题分开；经典入口和阅读工具可达 |
| 笔记 | `final-portrait/visual/reader-notes.png`、`final-wide/visual/reader-notes.png`、`final-landscape/visual/reader-notes.png` | 原书签文字、类型、页码/时间可见；宽屏沿用单栏 |
| 摘录和备注 | `reader-narrow-updated/reader_tools/native-highlight-in-anx-list.png`；另参考 W23 `index/note_index/cross-book-notes.png` | 摘录与备注分别展示；数据一致性以原阅读流程断言为准，单张图不替代该断言 |
| 搜索无结果/空目录 | `components-updated/components/no-search-results.png`、`empty-folder.png` | 分别显示“清空搜索”和“文件浏览器”动作，原因没有混用 |
| 文件消失 | `components-updated/components/missing-file-error.png` | 明确提示返回经典界面刷新目录，原文件浏览器仍可到达 |
| 未建索引/无笔记 | `final-narrow/visual/notes-index-empty.png`、`reader-notes-empty.png` | 未建索引有“重建索引”，无笔记有经典界面和阅读工具入口 |
| 设置与统计 | `final-narrow/visual/settings-groups.png`、`final-landscape/visual/settings-groups.png`、`statistics-from-library.png`、`final-portrait/visual/statistics-from-library.png` | 6 个设置分组和 6 个统计数值均可读；没有用虚构数据填充空统计 |
| 插件禁用 | `settings-narrow-large/settings_groups/disabled-cloud-storage.png` | 行内和提示窗写明已在插件管理中禁用 |
| AI 缺失 | `final-narrow/visual/assistant-state.png` | 显示“当前页面不可用”；不显示虚构对话或回答 |
| 导出未配置 | `reader-narrow-updated/reader_tools/export-not-configured.png` | 提示先在经典菜单选择导出格式，原阅读页仍可用 |
| 损坏 PDF | 参考 W24 `formats/S09-broken-pdf/broken/broken/original-open-error.png` | 原引擎拒绝文件，提示文件无效并留在 FileManager；这是旧批次证据，不宣称本轮重跑 |

截图保留原始时间戳，人工对照忽略批注时间等动态内容；没有执行带动态内容的跨系统逐像素差分。加载态与缺失封面分别有明确文案，选中筛选用底色和粗体共同表示。键盘/鼠标行为由 `components-updated` 和尺寸切换流程实际执行，不能从静态截图推断触摸手感。

图标版实际看过 `icons-portrait-03/visual/library-grid.png`、`reader-notes.png`、`icons-narrow-03/visual/navigation-focused.png`、`icons-landscape-03/visual/library-grid.png`、`reader-notes.png`、`icons-wide-03/visual/library-grid.png`、`reader-notes.png`，以及 `icons-reader/reader_tools/anx-notes.png`、`native-highlight-in-anx-list.png`。导航图标与文本均保留；焦点使用黑色轮廓，与书架当前选中态区分；备注、划线、书签的图标旁仍有类型文字，未挤掉摘录、备注或位置。

## W33：当前源码复验

2026-10-30，在书库条目复用、可见卡片回调及 Home 退役组件释放/GC step 修正后，重新运行四种布局。上文 W30 仍是历史版本证据，本节使用新的 `/data/koreader-anx-work/evidence/W33/visual-*`，没有用旧截图代替本轮检查。四场 `result.json` 均为 `passed: true`、进程退出码 0；其各自保存的 44 个插件、测试和 SDL 工具文件 SHA-256，逐一与本次复验时的工作区文件核对一致。Home 的 SHA-256 为 `00dd9df9fdd397b16c3aa0d107c2b352d375bcd1624b8aceb24fe34d5c8ec1d4`，其余身份和完整命令以各场结果为准。

| 新证据 | 窗口 / 语言 / 显示 | 焦点控件检查 |
| --- | --- | --- |
| [visual-portrait/result.json](/data/koreader-anx-work/evidence/W33/visual-portrait/result.json) | 540×720 / 中文 / 彩色 / 正常字 | 11 页、121 个控件记录，最小宽高 44 px |
| [visual-narrow/result.json](/data/koreader-anx-work/evidence/W33/visual-narrow/result.json) | 360×640 / 中文 / 灰度 / 大字 | 11 页、121 个控件记录，最小宽高 44 px |
| [visual-landscape/result.json](/data/koreader-anx-work/evidence/W33/visual-landscape/result.json) | 640×360 / 中文 / 灰度 / 大字 | 11 页、115 个控件记录，最小宽高 44 px |
| [visual-wide/result.json](/data/koreader-anx-work/evidence/W33/visual-wide/result.json) | 1280×800 / 英文 / 彩色 / 正常字 | 11 页、120 个控件记录，最小宽高 64 px |

四场 `visual/visual-geometry.json` 均无超出屏幕 ±2 px 容差的焦点控件，点击区均满足 44 DPI 单位下限。原 FocusManager 的 `FORCED_FOCUS` 路径选中统计导航并画出黑色轮廓，`onPress` 激活后实际打开统计页；导航图标、文字顺序、标签未截断和内容未超出点击区的断言均通过。这是原焦点与动作派发路径检查，本场景没有重新注入 X11 键盘/鼠标，也不能代替实体按键测试。

实际查看了 24 张新截图，关键结果与链接如下：

| 画面 | 新截图 | 观察 |
| --- | --- | --- |
| 窄屏书架与焦点 | [书架](/data/koreader-anx-work/evidence/W33/visual-narrow/visual/library-grid.png)、[焦点](/data/koreader-anx-work/evidence/W33/visual-narrow/visual/navigation-focused.png) | 四项底栏保留图标与文字；统计黑框焦点和书架选中底色可区分，页头/搜索可达 |
| 窄屏阅读与设置 | [工具栏](/data/koreader-anx-work/evidence/W33/visual-narrow/visual/reader-toolbar.png)、[笔记](/data/koreader-anx-work/evidence/W33/visual-narrow/visual/reader-notes.png)、[设置](/data/koreader-anx-work/evidence/W33/visual-narrow/visual/settings-groups.png) | 中文短标签无单字尾行，底部动作未被大字挤出；书签图标、类型和位置可读 |
| 横屏书架与焦点 | [书架](/data/koreader-anx-work/evidence/W33/visual-landscape/visual/library-grid.png)、[焦点](/data/koreader-anx-work/evidence/W33/visual-landscape/visual/navigation-focused.png) | 低高度切换侧栏，书名和进度保留；搜索宽 288 px，经典入口独立，焦点无重叠 |
| 横屏阅读与设置 | [工具栏](/data/koreader-anx-work/evidence/W33/visual-landscape/visual/reader-toolbar.png)、[笔记](/data/koreader-anx-work/evidence/W33/visual-landscape/visual/reader-notes.png)、[目录](/data/koreader-anx-work/evidence/W33/visual-landscape/visual/reader-contents.png)、[设置](/data/koreader-anx-work/evidence/W33/visual-landscape/visual/settings-groups.png) | 工具卡片在屏内，继续阅读可达；目录和设置按剩余高度分页，页码与底部动作未遮挡 |
| 宽屏书架与焦点 | [网格](/data/koreader-anx-work/evidence/W33/visual-wide/visual/library-grid.png)、[列表](/data/koreader-anx-work/evidence/W33/visual-wide/visual/library-list.png)、[焦点](/data/koreader-anx-work/evidence/W33/visual-wide/visual/navigation-focused.png) | 搜索宽 640 px，对应原 480 逻辑单位上限；侧栏文字完整，单本书没有拉成全宽封面；列表截图仍可出现加载初期文件名/未知作者 |
| 宽屏阅读 | [工具栏](/data/koreader-anx-work/evidence/W33/visual-wide/visual/reader-toolbar.png)、[笔记](/data/koreader-anx-work/evidence/W33/visual-wide/visual/reader-notes.png) | 英文长工具名两行可读，书签类型和位置保留；笔记仍为已说明的单栏形式 |
| 竖屏四类页面 | [书架](/data/koreader-anx-work/evidence/W33/visual-portrait/visual/library-grid.png)、[目录](/data/koreader-anx-work/evidence/W33/visual-portrait/visual/reader-contents.png)、[笔记](/data/koreader-anx-work/evidence/W33/visual-portrait/visual/reader-notes.png)、[统计](/data/koreader-anx-work/evidence/W33/visual-portrait/visual/statistics-from-library.png) | 卡片、层级/页码、类型元信息和六项统计数值均可读，零统计没有填充示例数据 |
| 空态与能力缺失 | [搜索无结果](/data/koreader-anx-work/evidence/W33/visual-narrow/visual/library-search-empty.png)、[未建跨书索引](/data/koreader-anx-work/evidence/W33/visual-narrow/visual/notes-index-empty.png)、[本书无笔记](/data/koreader-anx-work/evidence/W33/visual-landscape/visual/reader-notes-empty.png)、[AI 不可用](/data/koreader-anx-work/evidence/W33/visual-landscape/visual/assistant-state.png) | 原因和清空搜索/重建索引/原界面入口区分明确，未展示虚构 AI 回答 |

本次已查看的画面没有发现新增遮挡或布局越界。四场均在书架稳定 3.2 秒后再观察 3.2 秒，记录 `anx_widget_dirty_calls=0`；范围仍仅是已加载的书架，不包含原 ReaderUI/设备计时器，不据此宣称长期无刷新。新的视觉复验覆盖上述布局和状态，不重新签收 W30 中的动态窗口 resize、真实 X11 输入、损坏文件或联网 AI 链路；这些需分别核对对应场景证据。Android、墨水屏及下节未测边界保持不变。

## 与目标规格的差异和未测范围

- 宽屏笔记保留单栏，没有实现可选的书籍/详情两栏。阅读工具栏采用按需卡片内书名和底部“继续阅读”，没有另铺顶部工具条；关闭后完整交还原阅读界面。这是当前容器形式的取舍，不列为已像素复刻。
- 原高级设置、导出、文件错误和第三方插件窗口保留 KOReader 外观。其可达性属于功能保留，不属于这些窗口已换肤。
- AI 缺失/版本不符和插件禁用可以本地观察；真实服务断网、超时、鉴权失败的完整画面链路仍待服务验证。SDL 不提供实体设备 Wi-Fi、灯光等能力，相关项没有伪记为设备通过。
- 灰度截图只证明灰度配色和排版可读；彩墨色阶、残影、局刷、触摸、硬件翻页键、睡眠/唤醒均需 W37 真机验证。Android 系统缩放、输入法、返回键和不同 DPI 不在本轮 Linux 结论内。
- 文本覆盖为中英文与内置 CJK 后备；RTL、所有 Unicode 缺字、超长混合语言书名和未测试分辨率没有完整覆盖。不能将本轮 4 个窗口样本外推为所有设备。

本报告支撑 W30 的 Linux 适用切片；发布签收仍按 [acceptance.zh-CN.md](acceptance.zh-CN.md) 区分 G5-local 与 G5-release。

## W35：Android 模拟器实际画面复验

2026-10-30，实际查看最终通过的 `android-candidate-05` 全部 **9 张**截图。本节仅引用 05 的画面，先前看过的 03 不代替最终运行证据。[完整结果](/data/koreader-anx-work/evidence/W35/android-candidate-05/result.json) 的 `ui` / `reopen` 两阶段通过，14 个显式检查均为真，测试应用已停止并禁用自动化补丁。

环境为专用 `anxui-api30` AVD：Android 11 / API 30 / x86_64，软件 CPU/GPU 模拟，竖屏 480×800、横屏 800×480，DPI 160，中文彩色界面。运行的是开发签名 x86_64 APK，SHA-256 为 `da0dd8d71686aafebe5e347840f28b43146631de1ad0d6bc8a6ef3fa2001e6e7`；核心、包内插件身份及版本检查见 [package.json](/data/koreader-anx-work/evidence/W35/android-candidate-05/package.json)。这是真实 Android 应用绘制，不是 SDL 截图，也不是 ARM64 实机结果。

| 实际截图 | 可从画面确认的观察 |
| --- | --- |
| [竖屏书架](/data/koreader-anx-work/evidence/W35/android-candidate-05/ui/library-portrait.png) | 页头、搜索/筛选、分页和四项图文底栏完整可见；首次加载明确显示“封面加载中…”，书名暂为文件名并带省略号 |
| [虚拟键盘](/data/koreader-anx-work/evidence/W35/android-candidate-05/ui/virtual-keyboard.png) | 输入框内可见 `a` 和光标，取消/搜索按钮位于键盘上方，未被遮挡；这是 KOReader 内置键盘，不是 Android 系统 IME |
| [横屏书架](/data/koreader-anx-work/evidence/W35/android-candidate-05/ui/library-landscape.png) | 切换为左侧四项导航，保留查询 `a`；搜索、经典入口和分页在屏内；封面状态变为“暂无封面”，长书名明确省略，没有无提示硬裁切 |
| [阅读工具](/data/koreader-anx-work/evidence/W35/android-candidate-05/ui/reader-toolbar.png) | 中文正文无缺字方框，11 个工具按钮及“继续阅读”完整可读；“书签”“返回位置”没有单字尾行，卡片按设计覆盖部分正文 |
| [Anx 笔记](/data/koreader-anx-work/evidence/W35/android-candidate-05/ui/anx-notes.png) | `Android emulator preserved note` 备注全文可见，备注图标/类型、页 3 和时间保留；搜索、筛选和底部四项动作无重叠 |
| [前后台恢复后的正文](/data/koreader-anx-work/evidence/W35/android-candidate-05/ui/reader-after-background.png) | 显示原正文第 3/18 页，无残留 Anx 工具卡片或键盘遮挡 |
| [返回书架](/data/koreader-anx-work/evidence/W35/android-candidate-05/ui/returned-library.png) | 查询 `a` 保留，作者与 17% 进度可读，页头和底栏完整 |
| [经典界面读回](/data/koreader-anx-work/evidence/W35/android-candidate-05/ui/classic-note-readback.png) | 显示原正文第 3/18 页及右上书签角标；此图没有打开备注内容窗口，不能仅凭它确认备注全文 |
| [禁用后新进程重开](/data/koreader-anx-work/evidence/W35/android-candidate-05/reopen/classic-disabled-reopen.png) | 仍显示原正文第 3/18 页，无 Anx 浮层；与前一图一样，不直接展示备注文字 |

九张图中没有发现明确的中文缺字、按钮遮挡或横屏布局错误。数据一致性另由 [ui 阶段结果](/data/koreader-anx-work/evidence/W35/android-candidate-05/ui/result.json) 和 [reopen 阶段结果](/data/koreader-anx-work/evidence/W35/android-candidate-05/reopen/result.json) 核对：同一本规范化路径的书籍、相同 xpointer 锚点、页码 3，以及相同备注文本。前后台确实切换到 Launcher 再返回应用，由 Android 当前前台组件记录佐证；这些脚本断言与静态截图的可见内容分别成立，不能互相替代。

本节不声明系统 IME、中文输入法、其他 Android 版本/DPI、ARM64 实机、触摸手感、墨水屏刷新或真实 AI 服务通过；也不从九张画面推断 Android 长期性能和续航。实机与服务仍按 W36/W37/W38 独立验收，W35 模拟器通过不等于 G5-release 签收。
