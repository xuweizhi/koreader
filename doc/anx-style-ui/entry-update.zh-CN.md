# W40：更明显的 Anx 书架入口

2026-10-30，根据用户对返回书架入口的反馈完成本次增量更新。

## 界面变化

经典书架和阅读界面的原主菜单中，第一个分页和“工具”分页顶部均显示加粗的“打开 Anx 书架”。整行可点击，下方有分隔线；点击后原菜单关闭，沿用已有的保存阅读位置和返回书架流程。原“更多工具 → Anx 书架”入口继续保留。

只改动插件的 `main.lua` 与 `i18n.lua`，没有修改 KOReader 核心。菜单顺序通过原插件扩展点插入本插件自己的 ID，重复构建不重复插入；原自定义菜单顺序仍可覆盖默认排列。禁用插件后不提供这些可操作入口，旧回调也无法重新打开页面。

实际截图：[经典书架菜单](/data/koreader-anx-work/evidence/W40-entry/portrait-01/entry_points/filemanager-first-tab.png)、[窄屏阅读菜单](/data/koreader-anx-work/evidence/W40-entry/narrow-01/entry_points/reader-first-tab.png)。

## 安装包与升级

新版 [ARM64 APK](/data/koreader-anx-work/artifacts/android-entry-01/koreader-anx-arm64-development.apk) 已内置插件，不需要另装 ZIP。退出应用后可覆盖安装此前的本地开发签名包，无需卸载或清空数据。旧 `android-candidate-02` 文件保留不变。

- 版本名：`v2026.07.2-296-gdcb50ae43_2026-10-28-anxui2`
- 版本码：`122442`（旧 ARM64 为 `122422`）
- SHA-256：`6224488a821c0205458a18cedd16e502e75589477f90e73c7f7841030396f953`
- 包名及开发证书与前一开发包相同，权限列表相同。
- 内层 `version.txt` 和 `git-rev` 同步变为带 `anxui2_android` 后缀的版本，使原 Android launcher 能识别资源更新。

官方 KOReader 与此开发包的证书不同，上述覆盖安装说明仅针对之前交付的本地开发包。若使用旧包，仍从“更多工具”进入书架。

## 本次验证

| 检查 | 结果 |
| --- | --- |
| 当前 Anx 单元回归 | 11 模块、60 用例通过；包含真实 MenuSorter 排序、重复注册、禁用后无入口及旧回调拒绝 |
| 修改相关 Lua | 5 文件，luacheck 零警告、零错误；两个 Python 工具编译检查通过 |
| 真实 SDL / Xvfb | 中文 480×800、360×640；每种尺寸分别实际点击经典书架和阅读界面的首分页、工具分页四个入口，共 8 次；标签完整、加粗、几何及返回均通过 |
| ARM64 构建 | 第三次命令退出 0，Gradle `BUILD SUCCESSFUL`；此前一次受沙箱本地端口限制，一次进程退出 143，失败日志保留 |
| 签名与包身份 | zipalign、apksigner、ABI、外层/内层版本及全部插件文件摘要与当前源码比对通过；确认与旧包证书相同且版本码提高 |

完整记录：[W40 summary.json](/data/koreader-anx-work/evidence/W40-entry/summary.json)、[包身份](/data/koreader-anx-work/evidence/W34/packages/arm64-entry-01/package.json)、[交付清单](/data/koreader-anx-work/artifacts/android-entry-01/artifacts.json)。

本次是菜单入口的增量验证，没有重跑旧基线的 838 用例全量、96 进程性能矩阵、全部格式/故障矩阵或 Android 模拟器流程。那些结果仍对应原基线版本；此 ARM64 包未做 Android 运行或实机覆盖安装实测。源码/插件 ZIP 以 `snapshot` 阶段打包，不把新产品摘要替换进旧全量关卡。

## 复现构建

在固定核心 `/data/koreader` 中运行，下一次执行应使用新的 run-id。`VERSION` 和 `ANDROID_VERSION` 是原构建系统支持的命令行覆盖项，未修改核心构建文件。

```sh
env PARALLEL_JOBS=1 GRADLE_USER_HOME=/data/koreader-anx-work/gradle \
  make TARGET=android-arm64 KODEBUG= \
  VERSION=v2026.07.2-296-gdcb50ae43_2026-10-28-anxui2 \
  ANDROID_VERSION=12244 \
  GRADLE_FLAGS='--offline --console=plain --no-daemon --max-workers=1' update
python3 doc/anx-style-ui/tools/android-package.py \
  --abi arm64 --run-id arm64-entry-01 --stage candidate --anx-revision 2
```

本次 `anx-revision=2`：版本名追加 `-anxui2`，版本码按 `(当前核心提交数 + 2) × 10 + ABI 后缀` 检查；ARM64 后缀为 2。验包工具仍检查实际 APK 中的值，不能只靠传参声明版本一致。
