# iOS 局域网网页文件管理

当前设计与实现契约（2026-11-13）。本文取代此前阶段草案，真机验收结果见独立验收文档。

## 入口与范围

游戏库左上角三个点 →「打开 MeloNX 文件夹」下面的「局域网网页文件管理」→「启动服务」→显示地址和二维码。可以再次打开地址页、复制地址或停止服务。

共享根目录为 MeloNX 的 Documents（用户可管理的程序数据目录），不暴露 App 安装包、系统目录或其他应用沙盒。网页支持目录浏览、刷新、新建文件夹、文件预览/下载、文件及文件夹上传、删除确认、移动、文件覆盖、目录合并和整体替换。

网页不使用 CDN，也不要求部署其他服务器。HTML/CSS/JavaScript 编入 App。所有用户文件名通过 textContent 显示，不能注入页面脚本。

## 模块

| 模块 | 职责 |
| --- | --- |
| LANFileManagerCoordinator | 主线程 UI、启停、地址二维码、前后台恢复 |
| TransferActivityCoordinator | 主线程常亮 lease、后台失效与原状态恢复 |
| LANFileServer | HTTP 路由、鉴权、请求体策略、错误响应 |
| LANFileSystemStore | actor 串行管理浏览、确认凭据、删除及移动 |
| LANUploadStore | actor 管理断点、临时文件、提交与恢复收据 |
| LANFileMutationLock | 上传和文件管理两个 actor 之间的同步文件操作互斥 |
| LANWebBundle | 网页 UI、传输进度、本地恢复记录 |

NanoHTTP 来源为 [objecthub/swift-nanohttp](https://github.com/objecthub/swift-nanohttp)，基于 2.1.2、revision a8cb617fcc333e1aa3ca31d5bf794a9c6db73c74，BSD-3-Clause。源码作为本地 Swift Package 放在 src/MeloNX/Dependencies/NanoHTTP，保留原版权与许可证。MeloNX 扩展了磁盘请求体，不能改回上游远程包而丢失这一扩展。

## 500 MiB 分片与大文件

- 上传每个 HTTP 分片为 **500 MiB = 524,288,000 字节**，最后一片按剩余大小发送；网页按文件、按分片串行发送，不打 ZIP。
- 浏览器使用 Blob.slice 和 XMLHttpRequest；upload.onprogress 显示当前片已发送字节，只有服务器返回的 nextOffset 才代表已确认进度。
- 原 NanoHTTP 将整个正文读入内存，不能直接扩大 maxBodyBytes。当前本地扩展先检查请求头、鉴权和分片偏移，再以 1 MiB 读取缓冲把正文写入 .melo-request.part。
- 完整请求到达后，LANUploadStore 以 1 MiB 缓冲合并到 payload.melo-upload.part，synchronize 后原子保存进度。不会把整个 500 MiB 分片或 40 GiB 文件读入内存。
- 请求临时片和累计上传文件短暂共存，预检为完整文件加最多 500 MiB 工作空间，再保留少量元数据空间。覆盖旧文件时，旧文件在提交前仍占用空间。
- 单文件协议上限为 256 GiB；64 位偏移支持 10–40 GiB 场景。上限是代码限制，不等于已通过相应容量或吞吐实测。
- 完成必须收到完整字节数。API 支持可选的整文件 SHA-256；网页当前用头尾抽样指纹防止误选恢复文件，不能将抽样指纹称为整文件校验。
- 同卷 rename 提交正式文件；提交前重新检查原目标身份、大小和修改时间。上传期间目标发生变化则拒绝覆盖。

## 中断与恢复

| 情况 | 处理 |
| --- | --- |
| 网络断开、网页关闭 | 保留已确认片；重新选择原文件后 GET 会话，再从 nextOffset 继续 |
| 当前 500 MiB 片未接收完 | 当前请求临时文件清理；最多重传当前一片 |
| 累计文件已写入但进度尚未提交 | 恢复时截断超过已确认偏移的尾部，再重传该片 |
| rename 成功但完成收据未保存 | 根据提交前记录的文件身份恢复为 completed |
| 完成响应丢失 | GET/complete 可读取完成收据，重复提交不重复覆盖 |
| App 切后台或手动锁屏 | 关闭 listener 和连接，停止常亮；iOS 后台不保证继续接收 |
| App 回到前台 | 自动恢复此前开启的服务，优先复用端口和当前服务凭据 |
| 手动停止后再开、App 重启 | 新服务凭据；持久上传会话仍可用独立 resumeToken 恢复 |

临时目录为 Documents/.melo-transfer-temp。上传会话和完成收据按最后更新后 72 小时过期；清理不会删除已经提交的正式文件。临时目录及 .melo- 内部名称不允许普通文件 API 访问。

浏览器把恢复记录保存在 localStorage。浏览器重开后必须重新选择原文件，网页没有权限自行重新打开用户磁盘文件。IP/端口变化会改变浏览器 origin；网页提供恢复记录导出/导入解决跨 origin 恢复。清除浏览器数据也会丢失恢复记录。

## 下载与文件夹

单文件直接使用流式 HTTP 下载，支持 HEAD、Range、If-Range、ETag、Last-Modified 和 206；不通过 fetch().blob() 缓存整个游戏。浏览器下载器负责落盘和断点管理，网页不能在普通局域网 HTTP 下保证所有浏览器关闭页面后的续传行为。

下载未完成的本地后缀由浏览器控制，例如 .crdownload 或 .part；网页不能强制所有浏览器都使用 .melo-download.part。服务器不会因连接关闭就宣称客户端已下载完成。重新开启服务后，如浏览器丢失认证，可重新打开地址页完成认证，再恢复支持 Range 的下载。

文件夹上传按 webkitRelativePath 保留相对目录，每个文件独立提交。普通目录选择器不会返回空目录，空目录可以通过「新建文件夹」创建。文件夹下载提供递归清单及逐文件原始下载，不生成 ZIP。普通浏览器不能保证自动保留所有本地子目录和空目录，清单保留相对路径供用户整理。

## HTTP API

所有 /api/v1/*（auth 除外）必须具有 Authorization: Bearer 或服务 HttpOnly cookie。地址 fragment 携带初始凭据，网页 POST auth 后设置 SameSite=Strict cookie，以支持浏览器原生下载。

| 方法 | 路径 | 请求/含义 |
| --- | --- | --- |
| POST | /api/v1/auth | token，换取当前服务 cookie |
| GET | /api/v1/status | 运行状态、根目录、chunkSize |
| GET | /api/v1/files/list?path= | entries，日期按 Unix 秒 |
| GET | /api/v1/files/stat?path= | 文件/目录元数据 |
| GET/HEAD | /api/v1/files/open?path= | 白名单类型预览，其他类型下载 |
| GET/HEAD | /api/v1/files/download?path= | 原文件下载及 Range |
| POST | /api/v1/files/mkdir | path |
| POST | /api/v1/files/delete/prepare | path，返回 confirmationToken 和递归统计 |
| DELETE | /api/v1/files/item | JSON：path、confirmationToken |
| POST | /api/v1/files/move/prepare | sourcePath、destinationPath、conflict |
| POST | /api/v1/files/move | 同上，加 confirmationToken |
| POST | /api/v1/transfers/uploads | path、size、sha256?、conflict、clientFingerprint? |
| GET | /api/v1/transfers/uploads/:uploadID | X-Resume-Token，查询偏移 |
| PUT | /api/v1/transfers/uploads/:uploadID | X-Resume-Token、Content-Length、Content-Range、二进制正文 |
| POST | /api/v1/transfers/uploads/:uploadID/complete | X-Resume-Token，提交或读取完成收据 |
| DELETE | /api/v1/transfers/uploads/:uploadID | X-Resume-Token，放弃会话并清理临时数据 |

Content-Range 示例：bytes 0-524287999/42949672960。服务在接收正文前核对总大小、偏移和分片上限。普通 JSON 请求最多 1 MiB。

上传冲突策略为 ask / skip / replace，网页遇到冲突先展示明确覆盖选择。移动策略为 ask / skip / replaceFile / mergeDirectory / replaceDirectory。删除及破坏性移动使用五分钟、一次性的确认凭据，绑定操作和目标版本，变化后需要重新确认。

## 路径与生命周期

相对路径逐段校验，拒绝 ..、NUL、反斜杠、绝对路径、内部保留目录、符号链接和悬空链接；保护根目录，拒绝将目录移到自身子目录。文件管理操作与上传提交共享同步锁，持锁时禁止 await。

服务使用局域网 HTTP，凭据不能用于互联网暴露。Origin 检查在读取大请求体之前执行，静态页面配置 CSP、nosniff 和 no-referrer。预览只允许安全类型，不将上传的 HTML/SVG 作为同源可执行页面提供。

服务运行且 App 在前台时持有常亮 lease，覆盖整个请求体接收、分片合并和响应发送过程。停止或进入后台释放并恢复原状态；失效的旧 lease 不得释放新服务的常亮引用。用户手动切后台/锁屏仍会暂停，这是 iOS 生命周期边界。

## 构建与验证

Codemagic 使用 Xcode 26.2。scripts/test-lan-file-manager.sh 在构建 IPA 前编译并运行存储契约测试、构建本地 NanoHTTP；JavaScript 测试位于 tests/LANFileManager。Windows 本地无法执行 Xcode/iOS 真机编译，不将静态检查或模拟浏览器测试写成真机通过。

必须在真机验证：初次局域网授权、二维码地址、500 MiB + 1 字节分片边界、10/40 GiB 上传下载、关闭网页后续传、后台恢复、磁盘不足、覆盖目标变化、下载器 Range、目录操作、传输常亮和停止后的状态恢复。
