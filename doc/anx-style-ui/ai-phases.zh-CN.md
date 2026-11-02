# W44–W46：内置 AI 后续阶段

此更新在 W43 的内置聊天基础上加入模型配置切换、书籍问答、跨书检索和阅读工具。全部使用 KOReader 自带 Lua 界面、文档引擎和网络库，不需要安装 KOAssistant。APK 内置 Anx 插件，密钥需在设备上自行填写。

## 使用入口

1. **Anx 书架 → AI → 模型 → 模型配置 → 添加 DeepSeek 配置**。预设地址为 `https://api.deepseek.com`、模型为 `deepseek-flash`，填入 Key 后保存。也可自定义兼容 Chat Completions 的服务。最多保存 8 组配置；长按配置可编辑、重命名或删除。“测试连接”发送一条短请求，不写入聊天历史。
2. AI 消息的 **⋯** 提供全文、复制；最后一条提问可编辑并重新发送。回复支持标题、列表、强调和代码块；流式生成时先显示文本。历史记录可搜索、重命名、删除；阅读中默认仅显示当前书的会话，可切换全部。
3. 阅读中进入 AI，点击顶部的参考内容按钮：可选当前章节、指定章节、已有笔记或书内文字检索。预览显示将发送的内容；选择新内容会开启新对话。回答引用使用 `[S1]` 等编号，通过 **来源 · 打开原文** 跳转到原书相应位置。
4. 对需要跨书检索的书，分别打开后选择 **索引本书，用于跨书检索**。**检索已索引的书籍** 支持本地词语/短语查找，结果可附到对话并跨书跳回原文。**管理书籍索引** 可移除缓存；书籍与笔记不删除。文件大小、修改时间或位置变化后需要重新索引。
5. 附上文本后，选择 **阅读报告 / 思维导图 / 对照翻译**。报告要求模型说明材料范围并引用来源；思维导图以树状大纲展示；对照翻译在消息全文中显示双栏。中文界面的默认译文为中文，英文界面为英文。自由提问可指定其他目标语言。
6. **启用阅读工具** 后，模型可在发送问题时自行读取当前书目录、章节、笔记，检索当前书或已建立的跨书索引。界面会显示调用状态，消息菜单可查看调用记录。每个新对话默认关闭工具；历史会话保留原开关。

模型预设依据 [DeepSeek 官方接口说明](https://api-docs.deepseek.com/) 和 [模型列表接口](https://api-docs.deepseek.com/api/list-models)；真实联调中该账号返回 `deepseek-flash` 与 `deepseek-v4-pro`。预设关闭 thinking 以适合短阅读任务；兼容服务不接收此 DeepSeek 专用参数。

## 数据范围与限制

| 项目 | 本次实现 |
| --- | --- |
| 对话 | 最近 10 个会话，每会话 10 轮；输入 8000 UTF-8 字节；服务输出默认 2048 token，解析上限 32768 UTF-8 字节，截断会提示 |
| 参考内容 | 最多约 16000 字节、30 个来源；章节最多 30 个显示页；工具单次片段最多 6000 字节 |
| 本地索引 | 最多 50 本书，每本最多 2000 页或 2 MiB 文本；有界提取、可取消，不自动扫描或上传全书 |
| 检索 | SQLite 文字查找，返回最多 8 个片段；不是语义向量检索，英文字母采用基础大小写匹配 |
| 阅读工具 | 明确允许的 6 类只读操作；每个问题最多 3 轮、每轮最多 4 次；无文件写入、命令执行或任意网址访问工具 |
| 图与翻译 | 树状大纲最多 6 层、100 节点；双栏按片段分页，不保证模型输出逐句对齐，不提供整书翻译或可拖动图形画布 |
| 格式 | EPUB 等可提取文字文档；PDF/DjVu 使用嵌入文本层，扫描页不自动 OCR |

启用工具后的请求可以包含工具取得的书籍片段；未启用时只发送当前会话和手动附加的内容。模型只收到来源标题、标签和文字，不收到索引的本地文件路径。跳转由本地保存的原生锚点完成；源文件变化时拒绝使用旧锚点。模型生成的超链接、图片和外部资源不会自动加载。

`config.json` 升级为包含多个配置的 schema 2，旧单配置可读并在保存时迁移；`history.json` 继续兼容原会话。`books.sqlite3` 是可删除的本地文本缓存，和配置、聊天存于同一私有 `anxui-ai/` 目录。该目录不参与书架同步。删除索引不影响原书，卸载或清除应用数据会删除私有 AI 数据。更多见[恢复说明](recovery.zh-CN.md)。

## 安装及验证

新版 [ARM64 开发 APK](/data/koreader-anx-work/artifacts/android-ai-02/koreader-anx-arm64-development.apk) 使用 `anxui6`，版本码 `122512`。旧包继续保留。源码和插件 ZIP 见[成果清单](/data/koreader-anx-work/artifacts/ai-update-02/artifacts.json)。此 APK 已带插件，无需再安装 ZIP。

最终验证与摘要见 [W46 summary.json](/data/koreader-anx-work/evidence/W46-ai-tools/summary.json)。范围包括 Anx 与原阅读器相关单元回归、真实 SDL 章节/笔记/来源导航、跨书索引、取消、工具循环、阅读任务、小屏大字展示、聊天历史重启，以及 Android 专用模拟器中的迁移与交互。原始失败与修复后的结果分别保留，不覆盖记录。最终 144 个单元用例与 42 个 Lua 文件静态检查通过；Android 覆盖安装切片见 `android-ai-02`，完整交互从设备取回于 `android-ai-06/collected-ui.json`，重启见 `android-ai-06/result.json`。

真实 DeepSeek 使用本机私有调试凭据验证原生 Lua HTTPS、中文流式回答、401、取消和实际工具调用；证据不记录 Key，安装包不包含 Key。固定回答的 UI 截图来自本地测试服务；真实服务输出截图另列于 `live02`。这些测试验证调用链，不评价模型的书籍理解质量。

Android 运行验证使用 Android 11 / API30 / x86_64 专用模拟器；ARM64 包完成构建、签名、资源版本和插件摘要核对。Android 真机、墨水屏真机和旧全量性能矩阵不由本轮结果替代，仍需分别复测。

## 复现入口

- 单元：`./kodev test -j 1 front 'anxui_*' readerui readerannotation readerbookmark readerhighlight`。测试环境应移除无关凭据变量，避免测试工具将环境保存到日志。
- SDL：`tools/run-sdl-smoke.py` 的 `ai_chat`、`ai_book`、`ai_tools` 与 `ai_live` 场景；每次使用新的隔离 runtime/evidence 目录。`ai_live` 只读取工具约定的私有 Key 文件，结束后移除隔离运行目录中的服务配置。
- Android：`tools/android-ai-smoke.py --previous <旧版x86_64 APK> --apk <新版x86_64 APK> --book <自制EPUB> --run-id <新名称>`；只操作已验证身份的专用模拟器，不清除应用数据。已经升级的模拟器可用 `--resume-ui` 复测交互；`--reopen-only --collect-ui-run <原运行名>` 用于收集设备上真实完成的交互结果并接着核对重启。这些续接模式不重新证明覆盖安装，必须保留原 seed 与升级证据。
- 构建：`TARGET=android-arm64 KODEBUG= VERSION=v2026.07.2-299-g51465ffcf_2026-10-30-anxui6 ANDROID_VERSION=12251`。验包：`tools/android-package.py --abi arm64 --anx-revision 6 --stage candidate --run-id <新名称>`。
