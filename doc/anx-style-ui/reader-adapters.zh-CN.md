# 阅读与笔记适配契约（W18–W24）

实现状态及测试范围以 `execution-state.json` 为准。以下接口来自固定的 KOReader 源码。

- `reader.lua` 的会话同时校验 owner scope、`ReaderUI.instance`、Document 身份与 teardown 状态。关闭后清空文档引用；不把 ReaderUI 放入模块全局变量。分页/重排/文本模式只影响显示，页码与进度来自原模块。
- 工具栏由原菜单中的“Anx 阅读工具”打开。关闭后不保留输入覆盖层，也不重写原翻页、选字或菜单手势。排版、页码输入、搜索、高级菜单继续使用原窗口。
- 目录来自 `ReaderToc:fillToc()` 后的原目录。选择时再次确认原目录条目存在，先 `ReaderLink:addCurrentLocationToStack()`，再发送原 `GotoXPointer` 或 `GotoPage`。不把 EPUB 锚点转换为百分比。
- 当前书笔记取 `ui.annotation.annotations`。书签附注和划线是不同类型，备注单独显示；搜索同时检索摘录和备注。点击跳转，长按/Shift+Enter 编辑或删除。动作执行时按对象身份重新寻找索引，避免删除其他笔记后索引移动。
- 编辑委托 `ReaderBookmark:setBookmarkNote()`；删除确认后调用 `removeItem()`，保留 PDF 内嵌批注处理及原修改事件。导出调用已启用 exporter 的原入口；原 exporter 只导出划线及其附注，不导出普通页书签。未配置格式时显示原因。测试只启用本地 Text，不调用远端目标。
- `noteindex.lua` 使用独立的 `anxui-notes.sqlite3` 搜索缓存；删除它不会删除原笔记。扫描范围为当前目录、历史及收藏中已知路径，不宣称扫描全设备。查询按 SQL 分页读取，只为可见行创建组件。
- 重建每批最多处理 50 条批注、间隔 10 ms；可通过按钮或离页取消，整个重建事务回滚到上次完整缓存。原书籍和 sidecar 从不写入。当前活动书使用内存批注；其他书使用 `DocSettings.openSettingsFile()` 的只读入口，避免 `DocSettings:open()` 删除损坏候选的副作用。旧批注格式、损坏或超过 2 MiB 的 sidecar 跳过并计数；旧格式仍可在原书中由原模块迁移后重新索引。
- 从索引打开书前验证路径、文件 stat 签名。跨 ReaderUI/FileManager 只传原锚点值；通过原 `after_open_callback` 获取新 ReaderUI，再在下一事件循环校验会话并定位。锚点引擎类型不符、条目删除、匹配不唯一时显示提示，不猜测最近位置。原 rolling dogear 匹配没有比较 page，适配器额外校验精确 page 和种类，防止同秒书签串位。
- 已测试的实链路包括 EPUB/PDF 工具栏关闭后的真实点击翻页、目录返回、备注往返、真实选区生成划线、导出内容、PDF 重排，以及同名不同路径的跨书切换。测试输出保存源码副本和 SHA-256；这些记录不等同于 Android/墨水屏实机验收。

保留失败证据：首次读者测试用英文按键驱动中文输入法，输入被原输入法正常转换；测试改为明确选用原英文键盘后通过，没有修改产品输入法行为。
