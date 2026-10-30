# W41：Anx 风格书架、手动导入与目录扫描

2026-10-30，根据用户要求调整书架，尽量对齐本地 Anx Reader 的布局细节，并加入多选文件导入和递归扫描目录。本次是插件增量；KOReader 阅读引擎与核心跟踪文件没有改动。

## 界面与操作

参考 `/data/anx-reader` 的 `bookshelf_page.dart`、`book_item.dart`、`book_cover.dart` 和首页导航实现，主书架采用紧凑搜索栏、右上角添加/排序按钮、已读完/正在读/未开始筛选、圆角封面、两行书名、作者与阅读百分比。封面网格使用 120 DPI 单位的目标列宽，间距为 20/30；元数据字号独立按 DPI 缩放，避免小屏文字被原 size scaling 再缩小。

底部导航顺序为书架、统计、AI、笔记、设置，选中项使用蓝色浅底，整体为白色圆角条；宽屏切换为侧栏，低矮横屏仍保留底栏。彩色、灰度与大字模式沿用原插件选项。此次五项导航和右上角菜单取代旧书架的四项导航及页头经典按钮；早期视觉冻结文档保留为对应批次记录。

- **手动导入**：点右上角“＋ → 导入电子书”，点文件多选，可跨目录累计，点左上角 ✓ 导入。标题显示已选数量，长按 ✓ 可选中当前目录中的全部电子书。
- **扫描目录**：点“＋ → 扫描电子书文件夹”，进入目标目录后点 ✓，再点“开始扫描”。默认包含子目录；进行时显示计数并可取消。
- **再次扫描**：点“＋ → 重新扫描已保存的文件夹”，用于加入新增电子书。已有路径自动跳过，完成后显示新增、重复、跳过和不可读数量。
- **书架操作**：搜索书名/作者/路径，按阅读状态筛选；菜单支持书名、作者、最近阅读、进度、导入顺序及方向切换，提供网格/列表、刷新和继续阅读。文件夹图标切换目录、历史、收藏或书单。
- **翻页与返回**：手机支持上下或左右滑动翻页，键盘支持 PageUp/PageDown，宽屏另有箭头；右上角菜单中的“经典界面”或系统返回键回到原文件管理器。原主菜单加粗的“打开 Anx 书架”继续保留。

实际画面：[书架预览](/data/koreader-anx-work/artifacts/android-bookshelf-01/bookshelf-preview.png)、[多选文件](/data/koreader-anx-work/evidence/W41-bookshelf/narrow-final02/shelf_import/multi-selection.png)、[扫描确认](/data/koreader-anx-work/evidence/W41-bookshelf/narrow-final02/shelf_import/scan-confirmation.png)。

这仍是 KOReader Lua 界面：书架使用有界分页和滑动翻页，没有复刻 Flutter 连续滚动、模糊玻璃或动画；选择文件和高级操作继续使用原生 KOReader 窗口。AI 入口沿用原来的可选 KOAssistant 桥接，没有新增模型服务。

## 数据和实现

导入只将原文件路径加入书架，不复制、搬移电子书或 sidecar。书架成员保存在原 `ReadCollection` 管理的专属书单中，通过 `anxui_library` 设置识别，不会占用用户已有的同名书单；扫描目录存于该书单的 `anxui_scan_roots`。不创建第二套书籍、阅读位置或批注数据库。

按规范化路径去重，保留不同目录里的同名书籍。扫描每批最多检查 60 项后让出 UI；跳过隐藏项、`.sdr`、独立图片和符号链接，目录深度限制为 32。扫描成功结束后一次性写入书单并读回核对；用户取消或页面关闭时丢弃暂存结果。无法保存时显示错误并撤回内存新增项，不把仅留在内存中的结果报告为已导入。

原生移动/重命名继续更新原书单，原批注与进度随原模块处理。“从书架移除”只删除成员关系，不删除文件。外部应用移动文件后，需要重新导入。扫描记住的目录不会在启动时自动全盘遍历。

实现入口：`plugins/anxui.koplugin/shelf.lua` 管理扫描与书单提交，`importer.lua` 管理选择器和进度窗口；`views/home.lua`、`widgets.lua`、`theme.lua` 负责书架布局；`library.lua` 复用原元数据、历史与阅读状态。

## 安装包

新版 [ARM64 APK](/data/koreader-anx-work/artifacts/android-bookshelf-01/koreader-anx-arm64-development.apk) 已内置插件，不需要另装 ZIP。版本名为 `v2026.07.2-297-g6c36d9b03_2026-10-30-anxui3`，版本码 `122462`，包名仍为 `org.koreader.launcher`。证书与上一版 `anxui2` 本地开发包一致、版本码提高、权限不变，可用于该开发包的覆盖更新；未进行真机覆盖安装实测。旧 `android-entry-01` 安装包保持不变。

APK SHA-256：`f5d913a5d4715910495e4b3f377d93a22d4737a6ce8bd7e7bd3a57cbd8897502`。内层 `version.txt` 和 `git-rev` 也更新为 `anxui3_android`，使原 launcher 能识别 Lua 资源更新。

源码与插件 ZIP 位于 [bookshelf-update-01](/data/koreader-anx-work/artifacts/bookshelf-update-01/artifacts.json)，使用 `snapshot` 阶段，不覆盖旧全量候选包或借用其关卡。源码基于本地已推送的插件提交 `6c36d9b03f9771ec6be912037225a79d3a821d4d`；其 KOReader 核心内容仍对应原固定版本 `dcb50ae439f2acd82aec213063e76739984eacb1`。

## 本次验证

| 检查 | 结果 |
| --- | --- |
| 插件单元回归 | 12 模块、69/69 用例；包含真实文件导入/去重/扫描取消/写入失败、原文件和 sidecar 字节不变、原生移动与移除、选择器隔离及失效回调 |
| 静态检查 | 28 个相关 Lua 文件，零警告、零错误；修改的 Python 工具编译检查通过，Git diff 空白检查通过 |
| 当前源码 SDL | 中文 360×640 导入+重启两个进程；中文 1280×800、中文灰度大字 640×360、英文 360×640 各一个进程，全部通过，64 张截图 |
| 实际输入 | X11 点击跨目录多选和目录选择，滑动与 PageUp/PageDown 翻页；扫描 7 本新增 6 本、1 本重复，再扫新增 0 本、7 本重复；合计书架 8 本 |
| 持久化与阅读 | 独立进程重启后 8 本书及扫描目录仍在；阅读筛选、原第 3 页和书签恢复，原阅读往返正常 |
| 布局与导航 | 最小点击尺寸 44 DPI 单位、控件边界、五项导航标签完整、键盘焦点；统计/笔记/设置/AI 页面与原阅读工具回归；稳定书架空闲期间无 Anx 主动刷新 |
| ARM64 | 构建重试成功；签名、ABI、外层/内层版本、全部插件文件摘要与当前源码、上一包证书及权限比对通过 |

完整证据见 [W41 summary.json](/data/koreader-anx-work/evidence/W41-bookshelf/summary.json)。首次构建进程退出 143，失败日志另存为 `android-arm64-build-attempt01.log`；成功重试日志为 `android-arm64-build-01.log`。修复前的选择器、菜单及布局失败记录也保留，不纳入通过项。

本轮没有重跑旧 838 用例全量、96 进程性能矩阵、全部格式/故障矩阵或 Android 模拟器。旧结果仍仅代表其原版本；当前 ARM64 APK 尚未运行于 Android 模拟器或真机。

## 复现

单元：`./kodev test -j 1 front 'anxui_*'`。真实 SDL：`tools/run-sdl-smoke.py --scenario shelf_import`（自动包含第二进程 `shelf_reopen`），其余使用 `--scenario visual`；必须指定新的隔离 runtime/evidence 目录及自制 EPUB。

```sh
env PARALLEL_JOBS=1 GRADLE_USER_HOME=/data/koreader-anx-work/gradle \
  make TARGET=android-arm64 KODEBUG= \
  VERSION=v2026.07.2-297-g6c36d9b03_2026-10-30-anxui3 \
  ANDROID_VERSION=12246 \
  GRADLE_FLAGS='--offline --console=plain --no-daemon --max-workers=1' update
python3 doc/anx-style-ui/tools/android-package.py \
  --abi arm64 --run-id arm64-bookshelf-01 --stage candidate --anx-revision 3
```

重新执行验包或源码打包时须换新的 run-id；工具拒绝覆盖已有成果。
