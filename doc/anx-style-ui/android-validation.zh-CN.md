# Android 构建与隔离模拟器验收

本页记录 Android 工作流与当前限制，不代替 `execution-state.json` 的批次状态。所有运行只使用 `/data/koreader-anx-work` 中的构建输出、测试书籍、证书和专用 AVD；尚未检测到授权 Android 实机。

## 已准备的环境

- SDK：`base/toolchain/android-sdk-linux`，build-tools 34.0.0、Android 30 platform；NDK r23c；JDK 17。
- 模拟器：Android Emulator 37.2.12，系统镜像包 `system-images;android-30;default;x86_64`。SDK `package.xml` 标 revision 11，镜像内 `source.properties` 标 revision 10，原文差异保存在 `/data/koreader-anx-work/evidence/W35/toolchain/installed-inventory.json`。实际启动后另记录 Android fingerprint。
- 宿主机在沙箱外也无 `/dev/kvm`。实际使用 CPU TCG + SwiftShader 软件渲染；模拟器性能不能作为 Android 实机性能结果。
- 首次 SDK 下载报无效 ZIP。使用独立 `ANDROID_USER_HOME` 后，SDK 日志报告 emulator 与系统镜像安装完成；工具会话随后返回 143，故保留该退出码，并以实际安装文件清单作准备证据，不能将安装视为启动验收通过。
- 旧 ARM64 中间 APK 早于最终界面，保留为历史结果；两个架构均已用当前源码重新打包并完成下面的签名与身份检查。

## W34 / W35 基线包

以下是 `android-candidate-02` 基线包；后续 `anxui2` 的入口增强、构建命令和增量验证见[入口更新记录](entry-update.zh-CN.md)。下述 Android 模拟器流程仅对应基线包。

版本名均为 `v2026.07.2-296-gdcb50ae43_2026-10-28`。ARM64 最终构建退出 0、Gradle 成功；x86_64 的 Gradle 成功并完成 APK 复制，但工具外层返回 143，来源尚未确定，保留 [分项记录](/data/koreader-anx-work/evidence/W34/build/x86-final-build-result.json)，不改记为 0。两个产物随后分别完成开发签名、zipalign/apksigner、版本/ABI/权限、内层版本及插件逐文件校验，均通过。

| ABI / 版本码 | 实际 APK 字节数 | 身份证据 |
| --- | --- | --- |
| arm64-v8a / 122422 | 30,207,631 | [ARM64 package.json](/data/koreader-anx-work/evidence/W34/packages/arm64-candidate-01/package.json) |
| x86_64 / 122424 | 31,112,833 | [x86_64 package.json](/data/koreader-anx-work/evidence/W34/packages/x86-candidate-01/package.json) |

便于交付的独立副本、SHA-256、公开签名检查记录和安装范围见 [Android 成果清单](/data/koreader-anx-work/artifacts/android-candidate-02/artifacts.json)。包内插件与通过 Linux 最终回归的源码相同。x86_64 已完成下述 API 30 软件模拟器流程；ARM64 当前只完成构建、签名和包身份检查，两个架构都没有 Android 实机验收。

专用 AVD 首次启动较慢，后续实际确认 `sys.boot_completed=1`、Android 11 / API 30 / x86_64。启动器将 INI 改写为等号两侧带空格，工具已修正逐键值去空格解析；身份条件未放宽。probe 保留每次部分结果及超时，只有启动、API、ABI 和 AVD 名均符合才记为完成。相关诊断在 [启动目录](/data/koreader-anx-work/evidence/W35/emulator/20261029T183249Z)；应用流程单列。

## 应用测试与保留的失败

每轮使用同一个已验包的 x86_64 APK，运行目录、设置和测试工具快照独立保存，不覆盖失败记录。

| 运行 | 实际结果 | 后续处理 |
| --- | --- | --- |
| [android-candidate-01](/data/koreader-anx-work/evidence/W35/android-candidate-01/result.json) | 原系统 System UI 出现 ANR，点击一次 Wait 后进入应用；安装后插件摘要通过，但测试在首页延迟任务执行前断言失败 | 测试等待首页已经显示并完成首次绘制；预置原颜色设置，避免无关首次提示。没有主动调用打开首页来绕过启动验证 |
| [android-candidate-02](/data/koreader-anx-work/evidence/W35/android-candidate-02/result.json) | 真实启动、插件摘要、触摸键盘、搜索、横屏和竖屏恢复通过；点击书卡后等待开书超时 | 输入记录显示点击坐标为 `(72,125)`，取自旋转重建后尚未绘制的卡片；修正测试在读取点击位置前完成绘制，并补齐异步等待和 Android 文件路径别名比较 |
| [android-candidate-03](/data/koreader-anx-work/evidence/W35/android-candidate-03/result.json) | 上述检查及真实触摸开书通过，阅读工具栏截图正常；读取宿主回应时 JSON 解码结果为 nil，测试脚本取字段报错 | 回应改为同目录临时文件推送后原子改名；Lua 只有解码得到 table 才读取请求 ID，继续保留超时失败 |
| [android-candidate-04](/data/koreader-anx-work/evidence/W35/android-candidate-04/interruption.json) | 宿主测试进程返回 143，没有完整结果；独立检查确认模拟器仍运行、首页已显示 | 保留现场，发送方和原因未确定，不记成应用流程通过。第五轮用新目录、同一 APK 和同一测试源码重新运行 |
| [android-candidate-05](/data/koreader-anx-work/evidence/W35/android-candidate-05/result.json) | 两个阶段完整通过，宿主退出 0；12 项界面检查、2 项禁用重启/文件 intent 检查均为 true，原备注、锚点及第 3 页一致 | 测试应用已停止，自动补丁已禁用，数据副本已拉取；验证后向专用模拟器发送停止命令并收到成功确认 |

第二轮记录到首次观察 `show_pending=true`、没有首页；下一次观察首页已显示且首次绘制完成，直接证明第一轮的初始断言早于显示任务。失败记录均保留原日志、输入与截图；不能将部分检查通过记成完整 W35 通过。

第五轮使用与第三/四轮相同的产品源码；21 个插件 Lua 文件与 W31/W33 当前版本一致。触摸开书时路径为 `/storage/emulated/0/...`，经典打开与文件 intent 使用 `/sdcard/...`，实际 realpath 一致。备注 `Android emulator preserved note`、原 xpointer `/body[1]/DocFragment[1]/body[1]/p[12]/text()[1].50` 及第 3 页，在经典读回与禁用重启后均一致。后台记录真实观察到 `org.koreader.launcher → com.android.launcher3 → org.koreader.launcher`；返回书架也记录了等待显示到首次绘制完成的变化。9 张实际截图及输入记录见该运行目录，视觉结论见[视觉检查](visual-review.zh-CN.md)。

## 构建和签名

在 `/data/koreader` 下执行。`-i` 避免 release 流程自行更新 l10n 子模块；当前核心和子模块保持固定版本。

```bash
env PARALLEL_JOBS=1 GRADLE_USER_HOME=/data/koreader-anx-work/gradle ./kodev release -i android-x86_64
env PARALLEL_JOBS=1 GRADLE_USER_HOME=/data/koreader-anx-work/gradle ./kodev release -i android-arm64
python3 doc/anx-style-ui/tools/android-package.py --abi x86_64 --run-id x86-candidate-01 --stage candidate
python3 doc/anx-style-ui/tools/android-package.py --abi arm64 --run-id arm64-candidate-01 --stage candidate
```

每次构建日志保存至 W34 独立文件。最终版本名采用 `tools/describe.sh` 中 `git describe --match='v[0-9]*' HEAD` 规则；`ota` 标签不应代替该规则。

`android-package.py` 从实际 Gradle 输出复制 APK，使用工作目录中的本地开发证书签名，执行 zipalign/apksigner 验证，提取实际 appId、权限（含 maxSdkVersion）、版本名/版本码及 ABI。工具同时检查 ZIP 原生库目录、`assets/module/version.txt`、内层 `git-rev`，并提取 APK 内的 Anx 插件逐文件比对当前源码。版本名遵循 `tools/describe.sh`，版本码遵循当前 `git rev-list --count HEAD × 10 + ABI 后缀`；任一版本、ABI、插件身份不符均失败。包身份结果、核心与子模块版本及原始 aapt 输出保留在 W34。签名密钥和密码文件限 0600/0700 权限，不写入日志或源码。该开发证书不是官方 KOReader 发布证书，应用 ID 仍为 `org.koreader.launcher`。

## 模拟器与实际输入测试

以下为复测入口；已执行的通过范围以 `android-candidate-05` 为准。复测须选用新的 run-id，旧目录不会被覆盖。

```bash
python3 doc/anx-style-ui/tools/android-emulator.py start
python3 doc/anx-style-ui/tools/android-emulator.py probe
python3 doc/anx-style-ui/tools/android-smoke.py --apk <开发签名的x86_64包> --book /data/koreader-anx-work/fixtures/g0-v1/S01-中文阅读测试.epub --run-id <新的运行编号>
python3 doc/anx-style-ui/tools/android-emulator.py stop
```

专用 AVD 名 `anxui-api30`，预设 480×800、160 DPI；serial 固定 `emulator-5584`。启动工具仅创建或复用带本工具创建标记的 AVD，并检查目录、系统镜像和 API/ABI；不会接管同名旧 AVD。测试和停止操作先核对启动记录、创建标记、PID 启动时间、命令参数及 AVD_HOME，再核对 ADB 返回的 AVD 名。测试另检查 `ro.kernel.qemu=1`、API 30 和 x86_64，不选择任意已连接设备。

测试只接受 `android-package.py` 已检查通过、哈希一致且插件源码未再改变的 x86_64 包。它在这个隔离模拟器里安装 APK，确认 `pm clear` 成功，授予测试所需文件访问，并推入自制书籍与测试 patch。旧的 `/sdcard/koreader` 会移动保留到本次远程证据目录的 `previous-koreader`；已存在的同名测试目录会使脚本退出。清理私有测试数据是为了避免 launcher 按相同版本号保留旧 Lua 资源；应用运行后还逐文件核对实际安装的插件摘要。结束后停掉测试应用，并保留但禁用自动测试 patch；清理失败也不会给通过结论。

`android-smoke.lua` 负责观察真实 Android 进程中的界面、文档与批注状态；宿主 `android-smoke.py` 通过指定 serial 的 adb 执行实际触摸、返回/回车键、前后台切换和截图。已通过的流程包括：启动书架、触摸搜索键盘、搜索、原生旋转、触摸开书、系统返回关闭工具栏、原翻页、原批注编辑、新笔记列表、前后台恢复、返回书架、经典界面读回；第二次进程禁用 Anx，通过 Android 文件 intent 打开同书并核对位置与笔记。

测试混合使用系统输入和进程内原接口：搜索、键盘、开书、翻页及系统返回使用 adb 输入；旋转发送原 `SetRotationMode` 事件，批注编辑使用真实原窗口和保存回调，返回书架及经典读回调用原导航接口。它验证这些真实接口的组合，不表示每个菜单都已经人工逐项触摸。后台恢复另保存 `dumpsys activity top`：必须依次观察到 KOReader、其他应用、KOReader 成为唯一 resumed Activity；Lua 再核对同一阅读实例、页码和备注。

截图、输入请求/回应、命令退出码、logcat、书籍和 sidecar 副本、APK 摘要、插件源码快照全部保留在对应 W35 run 目录。超时或断言失败保存现场，不给通过结论。该流程没有覆盖真实设备触摸手感、硬件性能、系统文件选择器的所有 URI 来源、电子墨水刷新或真实 AI 服务。

Linux 正式性能采样时必须暂停 native 编译并停止模拟器，避免 CPU 和 I/O 争用污染基线比较。
