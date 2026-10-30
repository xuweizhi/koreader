# 最终本地回归记录

核心固定为 `dcb50ae439f2acd82aec213063e76739984eacb1`。当前最终源码身份为 [source-current-final.json](/data/koreader-anx-work/evidence/W33/checks/source-current-final.json)，并保存了对应源码副本。旧 `source-files.json` 和 `source-current-comparison.json` 属于内存优化前的历史记录，不能代替当前身份。Android 平台另行验收。

## 当前最终版本

完整非联网前端集合使用 `env PARALLEL_JOBS=1 ./kodev test -b -j 1 -t '!internet' -o <front-current.xml> front`，99 模块、838/838 用例通过，其中 Anx 的 11 模块、59/59 用例通过。证据为 [完整统计](/data/koreader-anx-work/evidence/W33/checks/front-current-summary.json)、[原始日志](/data/koreader-anx-work/evidence/W33/checks/front-current.log)及同目录 JUnit/各模块原始输出。原联网翻译的已知问题保留在下节，不宣称远程服务稳定。

最终版真实 SDL 复验通过：[书库与卡片](/data/koreader-anx-work/evidence/W33/library-current/result.json)、[原生文件操作](/data/koreader-anx-work/evidence/W33/file-actions-current/result.json)、[12 阶段故障恢复](/data/koreader-anx-work/evidence/W33/faults-current/result.json)，以及四尺寸中英文、彩色/灰度大字的视觉与原焦点操作，见 [当前视觉记录](visual-review.zh-CN.md)。原书籍笔记、位置、收藏和已有统计行保持一致。

当前源码的 [full-02 正式性能矩阵](/data/koreader-anx-work/evidence/W31/full-02/summary.json) 完成 96/96 进程，全部执行及预算通过；详见 [性能报告](performance-results.zh-CN.md)。`kodev-check-current.log` 显示 619 Lua 文件零警告、零错误，尺寸/gettext 检查通过；总退出码仍因下述两处原 ShellCheck 问题为 1。

## 历史完整联网测试

命令：

```sh
env PARALLEL_JOBS=1 ./kodev test -b -j 1 \
  -o /data/koreader-anx-work/evidence/W33/checks/front-final.xml front
```

实际运行使用允许网络访问的执行环境。99 个测试模块中 98 个成功，846 个用例中 845 个成功；新增插件的 11 个模块、55 个用例全部成功。唯一错误在原 `translator_spec.lua` 的拼音翻译请求，原网络层返回 `wantread`。同模块另外 3 个联网用例通过。前一次仅翻译模块的重试遇到 HTTP 429，失败的是另一个请求；两次结果均保留，未改原测试断言或绕过请求。

证据：`checks/front-final.xml`、`checks/front-final.log`、`checks/front-final-testlog.json` 和 `checks/front-final-summary.json`。上述路径均相对于 `/data/koreader-anx-work/evidence/W33/`。JUnit 外层统计的是模块，实际用例数从每个模块的 busted 输出解析，不能混称为 99 个用例。

完整非联网集合另行运行，使用原测试工具 `-t '!internet'` 过滤，99 个模块、834 个用例全部通过，结果保存为 `checks/front-offline.xml` 和 `checks/front-offline-summary.json`。这是本地边界的补充检查，不能代替上面的全部测试记录或证明远程服务稳定。

## 内存优化后的分阶段回归

上节联网 846/845、离线 834/834 结果均属于旧源码。随后 W31 暴露大书库 RSS 超预算，分三步修正，独立验证记录如下；各行不能合并为“当前版本全量已通过”。

| 阶段 | 产品变化 | 已完成验证 | 证据与适用源码 |
| --- | --- | --- | --- |
| 第一轮 | 全库条目移除动作闭包，仅给可见卡片创建回调；减少空查询临时分配 | 完整非联网前端集合 99 模块、836/836 用例通过，其中 Anx 57 例 | [front-memory-01-summary.json](/data/koreader-anx-work/evidence/W33/checks/front-memory-01-summary.json)、[JUnit](/data/koreader-anx-work/evidence/W33/checks/front-memory-01.xml)；源码身份为 [source-memory-01.json](/data/koreader-anx-work/evidence/W33/checks/source-memory-01.json) |
| 第二轮 | 复用实例内纯值条目数组，每次刷新原数据，关闭时解除 `book_items` | Home / Library / Lifecycle 三模块 27/27 用例通过 | [memory-reuse-unit.xml](/data/koreader-anx-work/evidence/W33/checks/memory-reuse-unit.xml)、[逐模块日志](/data/koreader-anx-work/evidence/W33/checks/memory-reuse-unit-testlog.json)；相应性能源码快照见 [gray5000-05 identity](/data/koreader-anx-work/evidence/W31/gray5000-05/identity.json) |
| 第三轮 | Home 释放旧组件引用，在重建/关闭完成后按 GC 运行状态单次推进 `step, 512` | Home 16 例、Library 7 例、Lifecycle 4 例，共 27/27 通过 | [memory-step-unit.xml](/data/koreader-anx-work/evidence/W33/checks/memory-step-unit.xml)、[逐模块日志](/data/koreader-anx-work/evidence/W33/checks/memory-step-unit-testlog.json)；相应性能源码快照见 [gray-library-06 identity](/data/koreader-anx-work/evidence/W31/gray-library-06/identity.json) |

836/836 的完整非联网回归只有上述一次；第二、三轮只有各自的定向三模块记录，没有第二次 836/836 全量结果。测试日志及旧源码快照保留，不用最新文件替换历史身份。

第三轮先释放旧子树及 `cards` / `layout` 等引用，关闭时再清除页面数据引用；只在 `collectgarbage("isrunning")` 为真时调用一次 `collectgarbage("step", 512)`，没有改 pause / stepmul，也没有增加后台定时器。`512` 是软性工作量提示，可能进入 atomic 阶段或执行终结器，定向单元测试不能保证其耗时上限；真实交互 P95 和完整新性能矩阵仍是必要条件。

[full-01](/data/koreader-anx-work/evidence/W31/full-01/summary.json) 的 96 进程全部执行通过，但仅灰度 1000 / 5000 路径增量 RSS 两项超预算，不能签收。第三轮修正后的 [gray-library-06](/data/koreader-anx-work/evidence/W31/gray-library-06/summary.json) 四场景通过，仍只是子集。随后正式 `full-02` 全部通过，且当前完整前端回归与代码检查已按上节重验。所有历史失败及中间结果保留；详细边界见 [Linux 测量记录](linux-measurement.zh-CN.md)。

## 环境问题及处理

首次完整回归为 96/99 模块成功，除联网翻译外，还有两个环境问题：

| 问题 | 实际原因与处理 | 重验 |
| --- | --- | --- |
| 扫描 PDF 划词 OCR | 旧构建下载目录里的 `eng.traineddata` 为 0 字节。取得 tessdata `4.1.0` 精确提交文件，SHA-1 与原 `base/Makefile` 固定值完全一致，补齐构建缓存。原 runner 会覆盖 `TESSDATA_PREFIX`，仅给外层进程设置环境变量无效 | `readerhighlight-ocr-04.xml`：21/21；最终完整回归再次成功 |
| 当前版本规范化 | 本地没有 Git 标签，原构建生成 `v0000.00`。补取上游真实标签后，按原 `tools/describe.sh` 和 Makefile 规则重新生成安装目录的 `git-rev`，结果 `v2026.07.2-296-gdcb50ae43_2026-10-28_emulator` | 最终完整回归 `version`：9/9 |

两项均没有修改原产品源码。OCR 模型信息保存在 `checks/ocr-model.json`；版本元数据及 Git 行为保存在 `checks/version-metadata.json`。原 OCR 测试主动禁用其他插件，只加载原 Japanese 支持；原翻译测试只加载原 Translator 模块。相关测试和原模块与 HEAD 的比较记录在 `checks/original-failure-source-comparison.json`。

## 代码检查

`./kodev check` 的最终结果：619 个 Lua 文件，0 警告、0 错误；尺寸检查和 gettext 警告检查通过。首次发现的新列表空文案 gettext 提取告警已修复。

命令总退出码仍为 1，因为原 `platform/bookeen/wlan.sh` 的 ShellCheck SC2317 和 `platform/mac/do_mac_bundle.sh` 的 SC2002。这两处在 W01 原版检查中已经失败，当前字节仍与固定 HEAD 和 W01 哈希相同。没有为使检查变绿而修改不在本任务范围内的设备脚本。

原检查会生成 `l10n/templates/koreader.pot`；每次保留生成补丁后还原该生成文件，翻译子模块的固定提交及原内容保持不变。最终日志为 `checks/kodev-check-current.log`，历史检查日志继续保留。W31 后续只修正测量工具的注释和 `boundary` 描述，明确产品触发的 GC 已计入动作时间；[逐行核验](/data/koreader-anx-work/evidence/W31/measurement-wording-correction/result.json)证明计算和时序未变。

## 本轮实际修复

AI composer 在旋转或会话选项刷新时，原 KOAssistant 会关闭旧框并重建输入框。此前只跟踪初始窗口，owner 关闭可能遗漏替代框。现在按固定版本的实例刷新路径重新登记窗口，并覆盖交接 tick 前立即关闭 owner 的情况。正常取消后不接管用户后来从原插件打开的独立聊天。

真实固定 KOAssistant 的两次旋转、返回书架及实时禁用已通过 `assistant-refresh-02/result.json`；相关 Assistant/Scope 单元测试共 8 个用例通过 `checks/assistant-refresh-unit.xml`。没有发送模型请求；原插件初始化向导及远程请求生命周期不属于此项通过范围。

外观设置中的“KOReader 设置”入口已改为通过原稳定菜单 ID 定位，`settings-02/result.json` 验证真实打开以及新进程读回外观选项。

阅读数据/格式及原插件适配器未因内存优化改变；W24、W29 等原证据保留。受影响的书架、文件操作、四尺寸视觉及故障恢复已用当前源码重新运行，W31 正式性能也已通过。本地候选仅声明这些实际验证范围，不代替 Android、实机或服务验收。
