# W43：内置 AI 一期

这是 W43 历史记录。当前版本的模型配置、书籍问答、跨书检索与阅读工具见[W44–W46 更新](ai-phases.zh-CN.md)。

2026-10-30，基于 KOReader 原 Lua 界面和网络能力实现 Anx 风格的内置 AI。新版 `anxui5` APK 已包含此功能，无需安装 `anxui-plugin.zip` 或 KOAssistant。

## 使用

1. 从 Anx 书架底部进入 **AI**，点击右上角 **模型**。填写服务的接口基础地址、模型 ID 和 API Key，保存即可。地址接受以 `/v1` 结尾的基础地址或完整的 `/chat/completions` 地址；只支持 OpenAI 兼容 Chat Completions 流式协议。本地免鉴权服务可留空密钥。
2. 点击 **输入消息…**，输入问题后发送；生成时点击 **停止** 保留部分回答，**重试** 重新发送最后一问，**新对话** 开始独立会话。**历史记录** 可继续旧对话，长按条目可删除。
3. 阅读时长按并选中文字，在原选文菜单点击 **Anx AI**，会打开附有选文的聊天页。点击 **解释 / 翻译 / 总结** 才发送请求。中文界面的快捷翻译目标为简体中文，英文界面为英文，也可在输入框明确指定目标语言。
4. 从阅读工具进入 AI，点击顶部参考内容按钮，选择 **使用当前章节**。选择 **预览已附内容** 可查看将附带的原文；选择 **通用对话** 则新建不带书籍内容的对话。没有目录时明确显示“当前页内容”。

默认只有接口地址示例，不带可用模型配置或密钥。只有主动发送、重试或点击解释等快捷操作才请求服务；打开 AI、设置模型、选文和提取章节都不会自动发送。每次发送包含当前会话及已附文本，不会自动读取其他书籍、全书或全部笔记。

## 实现与边界

- 内置彩色/灰度聊天页、模型设置、连续对话、流式显示、停止、重试和最近 10 个对话。每个对话最多 10 轮，单条输入最多 8000 UTF-8 字节；回复纯文本显示，不包含 Markdown 渲染、附件或图片输入。
- 通过独立子进程执行网络和解码，UI 只轮询已有管道数据；关闭窗口、退出书籍、禁用插件会关闭管道并终止/回收请求进程。整体请求上限 90 秒；网络连接与读取采用原 socket 超时机制。
- HTTPS 使用原系统 CA 与 LuaSec 校验，不关闭证书校验；不自动跟随重定向。服务返回的原始错误体不会进入错误提示或聊天记录，只显示通用错误及 HTTP 状态码。
- 当前章节以当前目录项到下一项为边界，最多 30 个显示页、约 16000 UTF-8 字节，超限显示“已截取部分”。这是有界节选，不能当作已经读完整本书。选择新参考内容会新建对话。
- EPUB 使用原 xpointer 提取，提取书末文字时恢复引擎位置；PDF/DjVu 只读取嵌入文本层。扫描页不在 UI 线程自动启动 OCR，空文本会提示无法提取。原阅读位置、书签和批注仍由 KOReader 管理。
- Android 将配置与历史保存在应用私有数据目录下的 `anxui-ai/`，避开 launcher 升级时重建的资源目录；其他平台放在设置目录。原子写入 JSON，限制权限，损坏文件保留。密钥本地明文保存，不宣称加密；位置、恢复及卸载行为见[恢复说明](recovery.zh-CN.md)。
- 本期不包含 Anx 的自动工具执行、跨书 Agent、向量检索、思维导图、原生 Claude/Gemini 协议或双语对照排版。原 KOAssistant 桥接移到“更多工具 → KOAssistant（可选）”，保持独立配置。

## 安装与证据

[ARM64 开发 APK](/data/koreader-anx-work/artifacts/android-ai-01/koreader-anx-arm64-development.apk)，版本名 `v2026.07.2-299-g51465ffcf_2026-10-30-anxui5`，版本码 `122502`。包的签名、权限、ABI、内外资源版本及全部插件摘要核对结果见[成果清单](/data/koreader-anx-work/artifacts/android-ai-01/artifacts.json)。旧版 APK 保留在原目录。

截图：[聊天](/data/koreader-anx-work/evidence/W43-ai/chat-final02/ai_chat/ai-general-answer.png)、[选文解释](/data/koreader-anx-work/evidence/W43-ai/chat-final02/ai_chat/ai-explain.png)、[章节问答](/data/koreader-anx-work/evidence/W43-ai/chat-final02/ai_chat/ai-chapter-answer.png)、[小屏模型配置](/data/koreader-anx-work/evidence/W43-ai/narrow-final02/ai_chat/ai-model-settings.png)。这些回答来自明确标记的本地测试服务，截图不代表真实模型输出质量。

原始结果汇总在 [W43 summary.json](/data/koreader-anx-work/evidence/W43-ai/summary.json)。本轮 87 个 Anx 单元用例与 49 个原阅读器相关用例通过；本地协议流程、布局、章节边界、可选桥接和 APK 各有独立记录。最终源码快照和插件 ZIP 见[源码成果](/data/koreader-anx-work/artifacts/ai-update-01/artifacts.json)。

本轮未使用真实外部模型凭据，也未复测新版 APK 的 Android 运行或真机覆盖安装；旧性能、格式、故障及 Android 模拟器记录仍只代表对应旧版源码。当前结果不代替 W36/W37/W38 或发布验收。

## 复现

单元命令：`./kodev test -j 1 front 'anxui_*' readerui readerannotation readerbookmark readerhighlight`。集成工具 `tools/run-sdl-smoke.py --scenario ai_chat` 自动创建仅监听回环地址的 HTTP/SSE 测试服务，验证 429、中文跨字节分片、断流、停止、关闭与历史；超时场景修改测试请求的起始时刻，验证真实子进程的超时回收，不虚称等待了 90 秒。`--scenario ai_context` 验证自制 EPUB/PDF 首尾文本及取消。需要传入自制书籍和新的隔离 runtime/evidence 目录。

构建参数为 `TARGET=android-arm64 KODEBUG= VERSION=v2026.07.2-299-g51465ffcf_2026-10-30-anxui5 ANDROID_VERSION=12250`，验包使用 `tools/android-package.py --abi arm64 --anx-revision 5 --stage candidate`。源码包使用 `tools/package-candidate.py --stage snapshot`；每次使用新 run-id。
