# 虚拟 amiibo 设计与数据契约

- 默认目录为空，数据由用户按游戏 Title ID 放入 `Documents/Amiibo/<TitleID>/amiibo.txt`；IPA 不打包任何预置角色目录。
- TXT 头固定为 `MELONX_AMIIBO_CATALOG 1`；每个条目由 `[名称]` 与下一行 16 位 ASCII 十六进制 ID 组成。
- iOS 目录解析、导入、动态刷新和自定义身份均在 Swift 完成；NativeAOT 核心只验证 ID 长度/字符并执行当前 NFP 会话注入。
- 用户数据不在 Git 仓库提供，不在 IPA 打包；示例只存在于 `docs/amiibo-catalog-example.txt`。
- 每个游戏独立目录，切换游戏时只读取当前 Title ID，防止角色目录串用。
- 导入使用原子替换，失败保留旧目录；替换前备份到 Documents 的 `备份` 目录。
- 打开“当前游戏目录”可在文件 App 中直接放入 `amiibo.txt`；返回应用或点击“刷新目录”后读取。应用激活时刷新一次，不持续监控文件系统。切换游戏会先清空上一游戏列表，只有新目录完整解析成功才替换当前列表。
- UI 的“使用”需要游戏处于等待 amiibo 状态；应用不会自动暂停或恢复游戏。
- 现有 HLE `VirtualAmiibo` 复用固定 UID 和 JSON 持久记录，但不导入外部标签应用区；狼林克心数等效果待实机验证。
- 构建使用固定 SDK、NativeAOT 新核心和未签名 IPA 门禁；Windows 不能执行 Xcode 构建。
