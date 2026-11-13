# iOS 局域网网页文件管理开源复用调研

## 结论

当前项目是 MIT 许可证，适合采用 MIT 或 BSD-3-Clause 代码并保留原版权、许可证和第三方通知。不能把“直接抄”理解为删除署名或忽略许可证；也不能直接引入 GPL、AGPL 或没有许可证的项目。

本项目采用两层复用策略：

1. 用 [`objecthub/swift-nanohttp`](https://github.com/objecthub/swift-nanohttp) 作为 Swift HTTP 和文件流底层。
2. 参考 [`MeloDreek/GCDWebServer_Swift`](https://github.com/MeloDreek/GCDWebServer_Swift) 的网页文件管理 UI 和目录 CRUD，再加入 MeloNX 自己的覆盖确认、Origin/路径保护和断点会话。服务启动后，同局域网设备打开 `http://IP:端口` 即可直接管理 Documents，无需登录。

`Upload-Id + Content-Range + .melo-upload.part`、Range/ETag 续传、前后台恢复和防熄屏仍需要本项目实现，不能把任何候选项目宣称为完整成品。

## 候选项目对比

| 项目 | 许可证/平台 | 已有能力 | 不能直接满足的部分 | 结论 |
| --- | --- | --- | --- | --- |
| [`objecthub/swift-nanohttp`](https://github.com/objecthub/swift-nanohttp) | BSD-3-Clause；纯 Swift；iOS 15+；无第三方依赖 | HTTP 路由、流式 response、文件浏览、`HEAD`、`ETag`、`Last-Modified`、`Range 206/416`、路径越界和符号链接保护 | 没有本项目网页 UI、删除/移动业务和 `Upload-Id` 断点上传；multipart 默认请求体约 64MiB | **选作 HTTP/Range 底座** |
| [`MeloDreek/GCDWebServer_Swift`](https://github.com/MeloDreek/GCDWebServer_Swift) | MIT；SwiftNIO；iOS 14+ | 浏览、上传、下载、重命名、删除、新建文件夹、刷新；multipart 流式写临时文件 | 当前下载只有 64KiB 流式读取，没有 `Range/ETag`；上传断线会清理临时文件，没有跨网页续传；依赖 SwiftNIO；网页资源还包含 BSD/MIT 第三方组件 | **参考 UI/CRUD，不能直接作为大文件实现** |
| [`swisspol/GCDWebServer`](https://github.com/swisspol/GCDWebServer) | New BSD；Objective-C；项目已归档 | `GCDWebUploader` 已有浏览器文件管理、上传、下载、删除、移动、新建目录；文件响应支持 Range；磁盘流式 multipart | 老 Objective-C 集成；没有 `Upload-Id` 分片恢复；默认同名文件改名而不是覆盖；需要保留 BSD 和网页第三方通知 | **功能参考，不作为首选依赖** |
| [`tus/tus-js-client`](https://github.com/tus/tus-js-client) | MIT；浏览器 JavaScript | `PATCH`/offset、重试、`localStorage` 指纹、关闭网页后查找历史上传 | 只提供客户端；必须有 tus 服务器；协议字段要适配本项目 API | **参考网页断点状态机** |
| [`tus/tusd`](https://github.com/tus/tusd) | MIT；Go | 完整 tus 上传服务和 offset/HEAD/终止语义 | Go 服务不能直接嵌入 iOS Swift App | **参考协议，不直接引入** |
| [`okamyuji/large-file-upload`](https://github.com/okamyuji/large-file-upload) | 未发现许可证；SwiftUI 客户端 + Go 服务端 | session、chunk、checksum、status、complete、delete、强制退出恢复 | 服务端是 Go，单片实现和当前网页服务不一致 | **参考恢复状态和测试** |
| [`swhitty/FlyingFox`](https://github.com/swhitty/FlyingFox) | MIT；现代 Swift | 文件 `GET/HEAD`、Range 206、异步 body | 没有网页文件管理 UI、删除/移动和上传会话；需要较新的 Swift 工具链 | **备用 HTTP 底座** |
| [`moontechs/files-nest`](https://github.com/moontechs/files-nest) | AGPL-3.0 | 有可恢复上传方向 | AGPL 不适合直接混入当前 MIT 项目 | **禁止直接复制** |
| `seedds/ios-ftp-server` | 未发现许可证；FTP | 有 FTP `REST` 续传思路 | 不是 HTTP 网页服务，且无许可证 | **只能阅读思路** |

## 具体复用边界

### 可以复用

- `swift-nanohttp` 的 HTTP 请求解析、流式响应、文件 `Range`、`ETag`、`Last-Modified`、路径规范化和符号链接拒绝代码。
- `MeloDreek/GCDWebServer_Swift` 的网页布局、列表刷新、文件夹选择和基本 CRUD 调用方式。
- `tus-js-client` 的分片重试、`localStorage`/`IndexedDB` 恢复记录和 `nextOffset` 交互思路。
- `GCDWebServer` 的文件句柄流式响应和 Range 头处理实现，移植时保留 New BSD 版权声明。

### 必须自己写

- `resumeToken` 上传会话恢复、`confirmationToken` 删除/破坏性移动确认，以及对应的会话生命周期管理。
- `POST /api/v1/transfers/uploads`、分片 `PUT`、状态查询、完成、取消接口。
- `.melo-upload.part`、`.melo-upload.json` 的落盘顺序、fsync、偏移校验和原子改名。
- 上传覆盖/跳过/取消、删除二次确认、移动替换、目录合并和服务停止后的会话过期清理。
- 传输 lease、防熄屏、App 进入后台暂停、回到前台重连和 `http://IP:端口` 地址显示。

## 许可证交付要求

正式源码中必须保留：

- `swift-nanohttp` 的 BSD-3-Clause 许可证和版权声明。
- 任何复制的 `MeloDreek/GCDWebServer_Swift` Swift 代码的 MIT 许可证声明。
- 其网页资源中的 GCDWebUploader BSD-3-Clause、jQuery/Bootstrap 等 MIT 版权和 `THIRD_PARTY_NOTICES.md`。
- SwiftNIO 及其依赖的 Apache-2.0 `LICENSE`/`NOTICE`（如果最终采用 SwiftNIO 路线）。

当前调研副本只放在项目 `_杂项/开源调研/`，不参与 MeloNX 构建；正式引入前固定 commit/tag，记录来源、许可证和本地修改点。
