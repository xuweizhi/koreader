# 来源与许可记录

此清单记录当前代码与测试材料的实际来源。成果包保留 KOReader 根目录的 `COPYING`；完整应用仍保留其原有字体、图标、引擎与第三方许可文件。

| 内容 | 固定来源 | 本次使用 |
| --- | --- | --- |
| KOReader | `https://github.com/koreader/koreader`，`dcb50ae439f2acd82aec213063e76739984eacb1`；根目录 `COPYING` 为 AGPL v3 文本 | 插件在原 Lua widget/原模块之上实现；核心跟踪文件无产品改动 |
| 新增 Anx UI 插件、测试与文档 | 本仓库新增目录/文件，成果清单逐文件记录 SHA-256 | 沿用 KOReader 项目的 AGPL v3 许可；可审查完整 Lua 源码 |
| Anx Reader | `/data/anx-reader`，`0c7fc1ad4551f7dbbeba6a6468f69d830957fa2a` | 仅作界面与功能参考；本插件没有打包 Flutter 代码、Anx 图像或应用品牌资源 |
| 图标与字体 | KOReader 自带 `resources/icons/`、`resources/fonts/`，固定子模块版本见成果清单 | 通过原 IconWidget/Font 使用现有资源，插件包没有额外复制位图或字体 |
| KOAssistant | `https://github.com/zeeyado/koassistant.koplugin`，`b89a60daf52bc9c3b33419607f48bbecde302461`；该版本 `LICENSE` 为 GPL v3 文本 | 可选适配目标，138 个运行时 Lua 文件 SHA-256 锁定；不随 Anx 插件包分发 |
| 测试书籍 | `tools/create-fixtures.py`、`tools/create-format-fixtures.py`、`tools/create-performance-fixture.py` 自行生成 | 格式样本、离线词典和复杂矢量 PDF 仅用于隔离验证，未使用个人书籍；嵌入字体另附 DejaVu 许可 |
| OCR 回归模型 | Tesseract tessdata `4.1.0`，提交 `4767ea922bcc460e70b87b1d303ebdfed0897da8` | 仅用于原前端测试；模型 SHA-1 与 `base/Makefile` 的 `007b522901a665bc2037428602d4d527f5ead7ed` 一致，不放入 Anx 插件包 |

KOReader 原资源许可保留在原路径，包括 `resources/icons/src/license.txt`、`resources/icons/src/menu-icon-license.txt`、`resources/icons/mdlight/` 下的许可，以及 `resources/fonts/{noto,freefont,urw,nerdfonts}/` 内的许可文本。此处不将全部资源笼统改标为同一种许可。

本地 Android 签名密钥和口令保存在独立工作目录。Android 成果目录单独提供 APK 与公开证书校验记录；`anxui-plugin.zip` 和 `anxui-source-and-verification.zip` 不包含 APK。插件包包含插件 Lua 源码、安装与验证说明、执行记录和 `COPYING`；源码包另含测试与复测工具。每个 ZIP 内的 `anx-manifest.json` 只列出本包实际文件（不含清单自身），外置 `manifest.json` 保存源码总集身份。成果中不包含签名私钥、服务凭据或用户配置。构建及测试工具链安装在工作环境中，不属于插件交付内容。

两个 ZIP 都是针对上述固定 KOReader 提交的增量包，不包含完整 KOReader 主程序。包内说明文档的相对文档链接随包提供；实施方案中指向原核心源码和构建文档的引用另列于清单 `external_core_links`，需要放回该固定版本的完整仓库中阅读。绝对 `/data/koreader-anx-work/evidence/` 链接是本地执行证据位置，不表示原始日志、截图或设备数据已装入 ZIP。
