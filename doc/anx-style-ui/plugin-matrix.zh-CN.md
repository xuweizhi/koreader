# 内置插件本地兼容矩阵

固定核心 dcb50ae439f2acd82aec213063e76739984eacb1；Linux SDL；证据 `/data/koreader-anx-work/evidence/W29/plugins-02/result.json`。

实际执行三个新进程：原入口打开与关闭 → 通过原管理器逐项禁用后重启 → 逐项启用后重启再次打开。33 个本环境可加载插件，4 个由原始源码/构建条件排除。每项具体记录见相应阶段 plugins.json，截图保存为 library/reader-插件ID。

| 插件 | 本地入口 | 禁用重启 | 启用重启 | 未验证范围 |
| --- | --- | --- | --- | --- |
| SSH | not applicable: missing bundled dropbear; not applicable: missing bundled dropbear | N/A：原条件排除 | N/A：原条件排除 | 未安装此构建的dropbear，不能外推为所有Linux均不支持 |
| archiveviewer | original entry opened and closed; original entry opened and closed | disabled restart verified | original entry opened and closed | 仅限已列本地入口范围 |
| autodim | original entry opened and closed; original entry opened and closed | disabled restart verified | original entry opened and closed | 实机硬件行为；SDL仅模拟 |
| autostandby | not applicable: PocketBook-only native plugin; not applicable: PocketBook-only native plugin | N/A：原条件排除 | N/A：原条件排除 | 实机硬件行为；SDL仅模拟 |
| autosuspend | original entry opened and closed; original entry opened and closed | disabled restart verified | original entry opened and closed | 实机硬件行为；SDL仅模拟 |
| autoturn | native document-only context; original entry opened and closed | disabled restart verified | original entry opened and closed | 仅限已列本地入口范围 |
| autowarmth | original entry opened and closed; original entry opened and closed | disabled restart verified | original entry opened and closed | 实机硬件行为；SDL仅模拟 |
| batterystat | original entry opened and closed; original entry opened and closed | disabled restart verified | original entry opened and closed | 实机硬件行为；SDL仅模拟 |
| bookshortcuts | original entry opened and closed; original entry opened and closed | disabled restart verified | original entry opened and closed | 仅限已列本地入口范围 |
| calibre | original entry opened and closed; original entry opened and closed | disabled restart verified | original entry opened and closed | 远程请求/账户闭环 |
| cloudstorage | original entry opened and closed; original entry opened and closed | disabled restart verified | original entry opened and closed | 远程请求/账户闭环 |
| coverbrowser | original entry opened and closed; native menu exists in file manager; instance available | disabled restart verified | native menu exists in file manager; instance available | 仅限已列本地入口范围 |
| coverimage | native document-only context; original entry opened and closed | disabled restart verified | original entry opened and closed | 实机硬件行为；SDL仅模拟 |
| docsettingtweak | original entry opened and closed; original entry opened and closed | disabled restart verified | original entry opened and closed | 仅限已列本地入口范围 |
| exporter | original entry opened and closed; original entry opened and closed | disabled restart verified | original entry opened and closed | 远程请求/账户闭环 |
| externalkeyboard | not applicable: SDL does not support the native external-keyboard hardware backend; not applicable: SDL does not support the native external-keyboard hardware backend | N/A：原条件排除 | N/A：原条件排除 | 实机硬件行为；SDL仅模拟 |
| gestures | original entry opened and closed; original entry opened and closed | disabled restart verified | original entry opened and closed | 仅限已列本地入口范围 |
| hello | not applicable: example source unconditionally disabled; not applicable: example source unconditionally disabled | N/A：原条件排除 | N/A：原条件排除 | 仅限已列本地入口范围 |
| hotkeys | original entry opened and closed; original entry opened and closed | disabled restart verified | original entry opened and closed | 仅限已列本地入口范围 |
| httpinspector | original entry opened and closed; original entry opened and closed | disabled restart verified | original entry opened and closed | 远程请求/账户闭环 |
| japanese | original entry opened and closed; original entry opened and closed | disabled restart verified | original entry opened and closed | 仅限已列本地入口范围 |
| keepalive | original entry opened and closed; original entry opened and closed | disabled restart verified | original entry opened and closed | 实机硬件行为；SDL仅模拟 |
| kosync | native document-only context; original entry opened and closed | disabled restart verified | original entry opened and closed | 远程请求/账户闭环 |
| movetoarchive | original entry opened and closed; original entry opened and closed | disabled restart verified | original entry opened and closed | 仅限已列本地入口范围 |
| newsdownloader | original entry opened and closed; original entry opened and closed | disabled restart verified | original entry opened and closed | 远程请求/账户闭环 |
| opds | original entry opened and closed; native menu exists in file manager; instance available | disabled restart verified | native menu exists in file manager; instance available | 远程请求/账户闭环 |
| perceptionexpander | native document-only context; original entry opened and closed | disabled restart verified | original entry opened and closed | 仅限已列本地入口范围 |
| profiles | original entry opened and closed; original entry opened and closed | disabled restart verified | original entry opened and closed | 仅限已列本地入口范围 |
| qrclipboard | original entry opened and closed; original entry opened and closed | disabled restart verified | original entry opened and closed | 仅限已列本地入口范围 |
| readtimer | original entry opened and closed; original entry opened and closed | disabled restart verified | original entry opened and closed | 仅限已列本地入口范围 |
| statistics | original entry opened and closed; original entry opened and closed | disabled restart verified | original entry opened and closed | 仅限已列本地入口范围 |
| systemstat | original entry opened and closed; original entry opened and closed | disabled restart verified | original entry opened and closed | 仅限已列本地入口范围 |
| terminal | original entry opened and closed; original entry opened and closed | disabled restart verified | original entry opened and closed | 命令执行；本次只打开菜单 |
| texteditor | original entry opened and closed; original entry opened and closed | disabled restart verified | original entry opened and closed | 仅限已列本地入口范围 |
| timesync | native action visible; system-time mutation not run; native action visible; system-time mutation not run | disabled restart verified | native action visible; system-time mutation not run | 远程请求/账户闭环；实机硬件行为；SDL仅模拟；系统时间修改未执行 |
| vocabbuilder | original entry opened and closed; original entry opened and closed | disabled restart verified | original entry opened and closed | 仅限已列本地入口范围 |
| wallabag | original entry opened and closed; original entry opened and closed | disabled restart verified | original entry opened and closed | 远程请求/账户闭环 |

组合范围：33 个可加载内置插件 + anxui 同进程；禁用全部这33个后的 Anx 书架/阅读；重新启用后的相同组合。KOAssistant 的固定版本组合见 W27；未测试 SimpleUI/Bookshelf 等接管首页的第三方插件。

首次矩阵在阅读器中查找 OPDS 菜单失败；对照 `plugins/opds.koplugin/main.lua:74` 确认原菜单仅在 FileManager 注册。修正验收上下文后全部三阶段通过，未修改 OPDS 或核心。
