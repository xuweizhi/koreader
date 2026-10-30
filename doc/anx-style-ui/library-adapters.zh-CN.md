# 书架适配契约（W10–W17）

本文件描述当前实现边界，验收状态仍以 execution-state.json 为准。

- library.lua 只复制 FileChooser.item_table、ReadHistory.hist、ReadCollection.coll；路径是身份，不按标题合并。同名不同路径保留两本；最近阅读中的失效路径保留可解释的占位，打开时再次检查。目录范围为当前目录，界面不会把它标成设备中的全部书籍。
- 快照不保存 UI/Document 实例。查询与分页只处理副本。原生历史、书单、sidecar、统计库始终由原模块写入。外部变更在重新打开视图/刷新时重新取快照，点击操作前验证文件存在。
- 缓存书名/作者以每批 50 条、间隔 10 ms 只读查询原生 bookinfo_cache.sqlite3；校验文件大小/修改时间。关闭或切源后关闭 SQL handle 并取消待执行批次。查询文本改变后使用当时最新文本，不保存过期查询结果。
- 封面先逐个读取可见项，UI 首屏使用占位；读取原生 SQLite 缓存，不新建权威书籍数据库。解码前检查尺寸、stride、类型、压缩字节数和 zstd frame 长度。单封面原始数据不超过 2 MiB，页面保留分配及最坏四字节缩放副本预算，总限额灰度 8 MiB/彩色 24 MiB；缩放不放大原图。离页先释放显示组件，再释放原始缓存。
- 缺失或过小缩略图复用已启用的 coverbrowser 的原生 BookInfoManager.extractInBackground。仅在原管理器没有活动 worker 时启动，等待/轮询均有次数上限；记录本页创建的 PID，取消只终止这些 PID，不调用会停止其他所有者的 terminateBackgroundJobs。原管理器继续负责 waitpid/standby 计数、临时缓存清理和损坏文档重试上限。插件禁用时不加载它，不调用原生提取。
- covers.lua 对当前固定版本的缓存列有局部依赖：未来 schema 不兼容时只读异常降级为占位；不创建/迁移/改写原 schema。灰度预算仅是软件验证，硬件内存与残影在后续实机验证。
- 每次重排有独立 render_scope，输入动作、封面回调失效；每个数据源有独立 source_scope，元数据索引与页面绘制生命周期分离。选择路径、源、查询、排序、网格/列表及页码可作为纯值跨原 ReaderUI/FileManager 往返；不保存关闭的对象。
- 长按或 Shift+Enter 打开书籍动作。详情、收藏与书单、原生更多菜单均委托现有模块；调用原生窗口前关闭新书架。重命名/移动继续调用原 FileManager 和 DocSettings.updateLocation，插件没有自己的 sidecar 搬运实现。
- 启动首页默认关闭。开启后只替代首次普通 FileManager 启动；已选最后一本/历史/收藏/目录快捷方式、首次指南、显式文件/目录/URI、恢复标记保持原行为。原生 modal 通知仍置顶。W17 已通过 12 种 Linux 真实启动分支；Android 意图另验。

已保留的失败记录包括：W11 测试工具误解 SQLite BLOB 所有权造成测试 double-free（测试复制为 malloc 所有权后修复，生产读取器未写 BLOB）；W13 键盘驱动原先假设返回焦点在关闭按钮，调整为实际恢复的书籍焦点后通过；W17 首次原生缓存提示阻止自动首页，调整为在 modal 下显示首页后完整矩阵通过。
