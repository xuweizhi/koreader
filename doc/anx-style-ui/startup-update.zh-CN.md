# W42：原生初始界面中的 Anx 书架

2026-10-30，在 KOReader 原生“初始界面”菜单中加入“Anx 书架”单选项。本次只改插件，不改核心启动脚本或原生菜单源码。

## 使用

在经典文件浏览器中打开顶部菜单，进入第一个分页，点击“初始界面”，选择“Anx 书架”。父菜单随即显示“初始界面：Anx 书架”，下次正常启动直接进入书架。切回文件浏览器、历史记录、收藏、文件夹快捷方式或最近文档，仍从同一菜单选择。

“Anx 外观 → 启动时打开 Anx 书架”保留，与原生单选项共用一个设置。关闭该开关时，当前选的是 Anx 才改回文件浏览器，其他已选原生首页保持原样。更改外观选项时也保持 W41 书架的 DPI 字号和布局。

实际截图：[选中 Anx 书架](/data/koreader-anx-work/evidence/W42-startup/menu-02/startup_menu/startup-selection-saved.png)、[父菜单文字](/data/koreader-anx-work/evidence/W42-startup/menu-02/startup_menu/native-start-with-label.png)、[小屏选项](/data/koreader-anx-work/evidence/W42-startup/menu-narrow/startup_menu/startup-selection-saved.png)。

## 配置与兼容

- 统一使用原 `settings.reader.lua` 中的 `start_with`。Anx 值为 `anxui`，原生选项仍使用原值；选中状态和父菜单文字动态读取同一个值。
- 升级时迁移旧 `anxui.startup`。旧开关已开启且原首页为文件浏览器时，转为 Anx；原来明确选择历史、收藏或最近文档等首页时保留原选择。成功迁移后移除旧开关，避免将来选择文件浏览器又被旧配置覆盖。
- 损坏、未知版本或未完成打开的 Anx 配置仍走原恢复流程，迁移不改写这些异常状态。
- 显式打开文件、目录或 URI、首次使用指南以及已经运行的会话保持原路由。禁用或移除插件后，`start_with=anxui` 经原核心默认分支回到文件浏览器。
- 菜单通过插件现有 `addToMainMenu` 扩展点追加；重复构建不重复添加。实例结束时移除自己的选项并恢复原文字函数，已失效的回调不再写设置。

## 安装包

[ARM64 APK](/data/koreader-anx-work/artifacts/android-startup-01/koreader-anx-arm64-development.apk) 已内置插件，无需另装 ZIP。版本名 `v2026.07.2-298-g793637614_2026-10-30-anxui4`，版本码 `122482`。签名证书与上一版 `anxui3` 本地开发包相同，权限不变，内层 Lua 资源版本也已提高。此前包保留在原目录。

包身份、SHA-256 与公开签名结果见 [Android 成果清单](/data/koreader-anx-work/artifacts/android-startup-01/artifacts.json)。源码与插件 ZIP 见 [startup-update-01](/data/koreader-anx-work/artifacts/startup-update-01/artifacts.json)，以 `snapshot` 阶段归档。

## 本轮验证

| 检查 | 结果 |
| --- | --- |
| 插件回归 | 12 模块、73/73 用例；含单选互斥、重复注册、两入口同步、停止后清理/失效回调、配置迁移和原首页保留 |
| 静态检查 | 8 个相关 Lua 文件零警告、零错误；Python 编译检查和 Git diff 空白检查通过 |
| 原生菜单操作 | 中文 480×800、360×640，实际点击原生单选项；每种尺寸分别用 3 个新进程验证经典选择 Anx、重启进入 Anx 后改选经典、再次重启回经典 |
| 启动分支 | 18/18 个独立进程通过，包含原 12 种旧配置分支和 6 种原生 Anx 选项分支：正常书架、首次指南、显式文件、显式目录、恢复、禁用 |
| ARM64 验包 | 版本名/码、内外层资源版本、ABI、全部插件摘要、签名证书和权限核对；构建重试成功 |

原始证据见 [W42 summary.json](/data/koreader-anx-work/evidence/W42-startup/summary.json)。首次菜单脚本错误读取已被原 MenuSorter 移走的平面条目，调整为查找排序后的真实菜单，失败记录保留为 `menu-01`；产品代码未因此改变。首次构建 Gradle 报成功，但外层进程退出 143，日志保留为 `android-arm64-build-attempt01.log`，正常重试见 `android-arm64-build-01.log`。

此次是启动选项的增量验证，没有重跑 W41 的导入/扫描矩阵、早期完整性能/格式/故障矩阵或 Android 模拟器。新版 APK 尚未做 Android 真机运行与覆盖安装实测。

复现单元测试：`./kodev test -j 1 front 'anxui_*'`。实际菜单流程：`tools/run-sdl-smoke.py --scenario startup_menu`；启动矩阵：`--scenario startup --startup-case all`。均需指定自制测试书及新的隔离运行、证据目录。

构建使用原 make 命令行覆盖：`VERSION=v2026.07.2-298-g793637614_2026-10-30-anxui4 ANDROID_VERSION=12248`；验包工具使用 `--abi arm64 --stage candidate --anx-revision 4`。每次验包及源码打包须使用新的 run-id，避免覆盖既有成果。
