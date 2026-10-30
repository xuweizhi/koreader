# 可选 KOAssistant：固定版本与接口审计

W26 本地审计对象为 `zeeyado/koassistant.koplugin` 的完整提交 `b89a60daf52bc9c3b33419607f48bbecde302461`，元数据版本 `0.25.0-dev`。不是对所有同名版本的兼容承诺。源码保存在 `/data/koreader-anx-work/vendor/koassistant.koplugin`；完整跟踪文件 SHA-256 见 `/data/koreader-anx-work/evidence/W26/audit/source-manifest.json`。原仓库 LICENSE 是 GNU GPL Version 3 文本。Anx 插件不默认打包或自动安装 KOAssistant；发布材料保留来源与许可。

Anx 使用 `koassistant-lock.lua` 核对 main、元数据及 `koassistant/` 下 138 个运行时 Lua 文件。只在用户进入 AI 页面时检查；缓存仅含路径与文件属性，不含界面、文档或凭据。文件发生变化时重算摘要。该检查是兼容性版本门禁，不是隔离第三方插件执行的安全沙箱：KOReader 已在此前加载它，插件本身仍有原有权限。

| 接口或行为 | 固定源码位置 | 接入边界 |
| --- | --- | --- |
| 通用对话 | `main.lua:7204 onKOAssistantGeneralChat` | 清理前一输入框与上下文、调用原 composer；Anx 不传 prompt_type、不自动发送 |
| 当前书籍对话 | `main.lua:7235 onKOAssistantBookChat`、`:1089 showKOAssistantDialogForFile` | 使用当前 ReaderUI 的路径、元数据和阅读进度；不自行拼接另一套书籍上下文 |
| 设置 | `main.lua:6434 addToMainMenu` | 打开原 `koassistant` 菜单 ID，原 schema/设置管理器执行修改 |
| 选段解释、翻译、保存到笔记 | `main.lua:295–335`、`koassistant/ui/dialogs.lua` | 保留原长按选段菜单 `koassistant_dialog`；由原插件保存 pos0/pos1 等定位信息和执行动作，不复制成 Anx 批注 |
| 初次配置 | `main.lua:23573 ensureInitialized`、`koassistant/ui/setup_wizard.lua:403–443 probeRaw` | 显示原配置向导；只读取 provider 配置布尔状态，配置存在不等于连接可用 |
| 凭据 | `koassistant/api/base.lua:577 listApiKeys`、`:596 getApiKey` | 由原 GUI settings / apikeys.lua / 原 OAuth 管理；Anx 不复制、不输出、不写入自己的设置 |
| 输入框取消 | `koassistant/ui/dialogs.lua:11269–11339` | 原 `onCloseDialog` 清除 current_input_dialog 和会话上下文；Anx 所打开 composer 随 owner scope 关闭时调用同一路径 |
| 输入框刷新/旋转 | `koassistant/ui/dialogs.lua:10917–10948`、`:11311–11318` | 固定版本会关闭旧框并重新创建。Anx 仅包装自己打开的 composer 实例关闭钩子，以 `_koa_internal_close` 识别此交接，下一 tick 接管替代框；owner 在交接前关闭时也通过原 `onCloseDialog` 取消替代框。普通手动关闭不接管后来从原插件另开的聊天 |
| 请求取消 | `koassistant/request/stream_handler.lua:996 _closeStreamDialog`、`:770` | 原停止按钮负责结束轮询、报告取消；Anx 不维护第二个请求状态机；真实请求与异常在 W38 验证 |
| 切书清理 | `main.lua:16734 onCloseDocument` | 原插件撤销 X-Ray 定时任务并取消其请求；未发送 composer 的 owner 切换可本地验证，不能据此宣称所有网络请求切书已通过 |

已确认的生命周期和冲突点：`init` 会调用 `patchDocSettingsForChatIndex`（24171）、`patchReadHistoryForFolderMoves`（24294），安装分组钩子，并设置模块级 X-Ray 回调；`addToMainMenu` 还调整原工具菜单顺序。不能把这一插件描述为完全局部、随时卸载即撤销所有补丁。原插件管理器关闭它后，Anx 立即拒绝旧实例入口；全局钩子的完全卸载仍遵循原重启要求。

自动更新检查在 `init` 延后 20 秒执行，除非原配置 `features.auto_check_updates=false`。隔离验收明确关闭此项，未注入任何服务密钥。原数据访问控制在 `koassistant/ui/data_access.lua`，分享正文/笔记等沿用原提示，Anx 不替用户批准、不自动扫描上传书库。

W27 的本地结果必须记录真实固定插件的菜单、composer、取消、切书、版本变化及禁用分支。缺失状态可以无插件验证；mock 只能证明适配器防御，不得算真实 AI 请求成功。W38 未提供服务时保留等待，独立于本地实现。

W33 只读复查发现：仅在入口调用结束时收集窗口，不能覆盖 composer 后续的关闭重建。修复限定在 Assistant 实例及其已拥有输入框的关闭钩子，没有修改第三方源码、UIManager 或全局类。新增单元场景检查交接前关闭与正常关闭后的窗口隔离；真实 `assistant` 流程另外执行原 `onScreenResize` 重建，等待首次接管后再重建并立即返回书库，以及接管后实时禁用 Anx。这个输入框生命周期验证不涉及网络请求成功、服务取消或 AI 回答质量。

2026-10-30 的最终复测证据：`/data/koreader-anx-work/evidence/W33/assistant-refresh-02/result.json`，真实 SDL + 固定 KOAssistant，`passed: true` / exit 0。未配密钥、未触发发送；重建前后的窗口身份、当前窗口引用、owner 失效和交接任务失效均有断言。此前 `assistant-refresh` 也通过；最终记录包含交接去重的小修。新增单元用例交由根代理统一串行回归，本分支没有执行 `kodev test`。
