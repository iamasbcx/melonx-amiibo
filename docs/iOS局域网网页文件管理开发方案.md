# MeloNX iOS 局域网网页文件管理开发方案

## 1. 目标和范围

在 iOS 中提供一个由用户主动启动的局域网网页文件管理器。电脑或同一局域网内的手机打开 MeloNX 显示的地址后，可以管理应用的“程序文件根目录”：

- 浏览根目录下的文件和文件夹。
- 打开文件夹继续浏览；普通文件可预览或下载。
- 下载单个文件时直接流式传输；文件夹默认逐文件下载，只有用户明确选择“打包下载”时才生成 ZIP。
- 删除文件和文件夹。删除前必须显示警告并二次确认，文件夹要说明递归删除范围。
- 上传文件和文件夹，保留文件夹相对路径。
- 上传遇到同名项时支持覆盖、跳过或取消，默认不静默覆盖。
- 移动文件和文件夹；目标存在时支持替换、合并、跳过或取消。
- 上传和下载期间禁止自动熄屏；传输结束、取消、失败或服务停止后恢复原来的熄屏设置。

本功能只开放用户数据目录，不开放 App Bundle、`Library`、`Caches`、系统目录或任意绝对路径。第一版要求 MeloNX 保持在前台运行；iOS 进入后台后停止接受新连接，并取消或收尾当前传输，不能宣称支持后台持续传输。

## 2. 对 PPSSPP 实现的调研结论

PPSSPP 当前的相关实现位于 `Core/WebServer.cpp/.h`、`Common/Net/HTTPServer.cpp/.h` 和 `UI/UploadScreen.cpp`：

- `UploadScreen` 打开一个临时网页服务，页面使用 `multipart/form-data` 上传文件，也支持浏览器的 `webkitdirectory` 目录选择和上传进度。
- 服务端通过固定上传目录、路径组件校验、断线清理半成品和进度表保护上传流程。
- Remote ISO 页面支持目录列表和带 Range 的文件读取。
- PPSSPP 当前没有通用的删除、移动、替换覆盖 API；同名上传会进入 dry-run，读取请求但不会覆盖原文件。
- 上传服务主要依赖页面生命周期和 flag，不能直接满足本项目的鉴权、删除确认、移动替换和覆盖语义。

参考实现：

- [PPSSPP `Core/WebServer.cpp`](https://github.com/hrydgard/ppsspp/blob/master/Core/WebServer.cpp)
- [PPSSPP 上传网页](https://github.com/hrydgard/ppsspp/blob/master/assets/upload/index.html)
- [PPSSPP `UI/UploadScreen.cpp`](https://github.com/hrydgard/ppsspp/blob/master/UI/UploadScreen.cpp)

MeloNX 应借鉴 PPSSPP 的 HTTP 生命周期、multipart 解析、进度统计和断线清理，但必须重新设计权限、路径和写操作确认，不能复制未鉴权的 `/upload_file` 语义。

## 3. 当前仓库基线和根目录定义

当前仓库已经有：

- `URL.documentsDirectory`，位于 `RyujinxController.swift`，用于 `roms`、`system`、`config`、`games`、日志等用户数据。
- `Info.plist` 中的 `UIFileSharingEnabled`，系统“文件”App 可以访问共享文档。
- `OpenInFiles.swift`，可以把目录交给系统“文件”App 打开。
- `FilePicker`，负责从系统文档选择器导入文件。

当前没有可供浏览器连接的 HTTP 文件服务，也没有传输任务级的防熄屏管理。`MetalView.swift` 在创建 Metal 视图时直接设置 `UIApplication.shared.isIdleTimerDisabled = true`，后续文件服务不能简单地把它改回 `false`，否则会误伤游戏画面的防熄屏状态。

本方案把 `URL.documentsDirectory` 定义为网页根目录 `/`：

```text
网页 /
└── Documents/
    ├── roms/
    ├── system/
    ├── config/
    ├── games/
    └── logs/
```

网页只使用相对路径，例如 `roms/demo.nsp`。不把 Bundle、`Library`、`Caches` 和临时工作目录映射到网页。临时上传文件放在 Documents 下的隐藏工作目录中，但该目录必须从列表中隐藏且禁止用户直接访问。

## 4. 用户交互设计

### 4.1 iOS 设置页

新增“局域网网页文件管理”设置页，包含：

| 控件 | 行为 |
| --- | --- |
| 启用服务 | 默认关闭；只在用户主动打开时启动监听 |
| 启动/停止服务 | 显示 `starting`、`running`、`stopping`、`stopped`、`failed` 状态 |
| 端口 | 默认随机可用端口；允许用户设置固定端口时必须处理占用失败 |
| 当前地址 | 显示 `http://局域网地址:端口/`，提供复制按钮和二维码 |
| 当前会话 | 显示一次性 token 的有效状态，不在日志中打印完整 URL 或 token |
| 活动传输 | 显示上传、下载数量和总进度；传输中禁止停止服务，除非用户确认取消 |
| 使用说明 | 明确提示电脑和 iPhone 必须在同一局域网，传输时保持 MeloNX 前台并避免锁屏 |

服务停止后立即关闭 listener、取消未完成操作、清理临时文件并使当前 token 失效。App 重启后不自动启动服务，也不沿用上一次 token。

### 4.2 网页文件列表

网页资源打包在 App 内，API 与静态资源分离。页面包含：

- 顶部面包屑路径、返回上级、刷新、当前目录地址。
- “上传文件”“上传文件夹”“新建文件夹”按钮。
- 表格列：名称、类型、大小、修改时间、操作。
- 文件夹单击或双击进入；文件点击“打开”时按 MIME 类型预览，无法安全预览的类型直接下载。
- 每一行提供下载、移动、删除；多选后可以批量下载、移动、删除。
- 所有用户可见文件名都使用 HTML 转义，不能把文件名拼接为 HTML 或脚本。

文件夹下载不默认生成 ZIP。单个大型游戏文件直接流式下载；只有用户明确选择“打包下载”时才生成 ZIP。由于当前 `Zip.swift` 只有解压能力，实施时需要扩展现有 native ZIP 能力或加入经过审查的 ZIP writer；不能把目录路径直接当作文件流返回。

### 4.3 删除确认

删除流程必须是两阶段：

1. 页面请求删除预览，服务端返回目标类型、名称、项目数、估算总大小和不可恢复提示。
2. 页面显示确认对话框。文件夹必须显示“将递归删除其中的文件和子目录”；用户明确点击确认后，页面携带短期确认 token 发起删除。

服务端即使收到 `confirmed=true` 也要检查确认 token，不能只依赖网页 JavaScript。用户取消、token 过期或目标状态发生变化时，操作失败且不删除任何内容。

### 4.4 上传和覆盖

网页支持单文件、多文件、文件夹选择和桌面拖放。文件夹上传使用浏览器的 `webkitRelativePath`，服务端只接受相对于当前目录的安全路径。

遇到同名目标时默认返回冲突，不静默覆盖。网页显示：

- 覆盖：替换同名文件；目录可选择合并或替换整个目录。
- 跳过：保留目标，继续其他文件。
- 取消：终止本次批量上传。

目录覆盖必须区分“合并目录”和“替换整个目录”：

- 合并目录：保留目标目录中未被上传内容覆盖的项目。
- 替换整个目录：先完成源目录校验，再以原子步骤替换目标目录；失败时保留原目标。

### 4.5 移动、替换和覆盖

移动对话框显示源路径和目标路径，目标存在时要求选择：

- 文件替换。
- 目录合并。
- 替换整个目录。
- 跳过或取消。

禁止把目录移动到自身或自身子目录；禁止源和目标相同；禁止用目录覆盖文件或用文件覆盖非空目录而不经过明确确认。移动前重新读取目标的修改时间和大小，避免网页确认后目标已经被其他操作改变。

## 5. 服务和模块设计

第一版采用 [`objecthub/swift-nanohttp`](https://github.com/objecthub/swift-nanohttp) 作为 HTTP/1.1 底层，不再自写请求解析器。它是 BSD-3-Clause、纯 Swift、无第三方依赖并支持 iOS 15；使用其流式 response、`HEAD`、`ETag`、`Range` 和路径安全实现。上传分片会话、鉴权、覆盖语义和恢复元数据仍由 MeloNX 路由层实现，依赖版本必须锁定并纳入 Xcode 工程和 Codemagic 构建。


开源复用结论：优先采用 [`objecthub/swift-nanohttp`](https://github.com/objecthub/swift-nanohttp) 作为 HTTP 和文件 Range 底层。该项目为 BSD-3-Clause、纯 Swift、iOS 15+、无第三方依赖，已有 `HEAD`、`ETag`、`Last-Modified`、`Range 206/416`、流式文件响应、路径越界和符号链接防护。它没有本项目需要的网页文件管理、鉴权和 `Upload-Id` 断点上传，因此只复用底层能力，分片会话、`.part` 临时后缀、覆盖确认和前后台恢复由 MeloNX 自己实现。网页 UI 和目录 CRUD 可参考 MIT 的 [`MeloDreek/GCDWebServer_Swift`](https://github.com/MeloDreek/GCDWebServer_Swift)，但该项目当前下载实现没有 `Range/ETag`，上传中断也不支持跨网页恢复，不能直接当作 10–40GB 传输实现。所有复制或引入的第三方代码必须保留原版权、许可证和第三方通知文件；无许可证、GPL 或 AGPL 项目不直接复制。
模块边界：

```text
LANFileManagerViewModel (@MainActor)
  ├─ LANFileServer (NanoHTTP server、HTTP 路由、鉴权)
  ├─ FileSystemActor (路径校验、目录读写、冲突和原子替换)
  ├─ TransferManager (流式传输、进度、取消、临时文件)
  ├─ TransferActivityCoordinator (防熄屏引用计数)
  └─ WebBundle (HTML/CSS/JavaScript 静态资源)
```

### 5.1 LANFileServer

- 监听只在用户启动时创建，端口绑定失败要返回明确错误。
- 每个连接解析请求行、headers、`Content-Length`、必要的 chunked body，并限制 header、请求体和并发连接数量。
- 只实现需要的 `GET`、`HEAD`、`POST`、`DELETE`、`OPTIONS`；其余返回 `405`。
- API 返回统一 JSON 错误结构，例如：

```json
{
  "error": {
    "code": "conflict",
    "message": "目标已经存在",
    "details": { "path": "roms/demo.nsp", "kind": "file" }
  }
}
```

- 不把本地完整路径、token、用户文件内容写入日志；日志只保留操作类型、相对路径摘要和结果码。

### 5.2 FileSystemActor

所有文件系统操作经过同一个 actor 或等价串行协调器，公共接口契约如下：

- `list(relativePath)`：只列当前目录，不跟随越界符号链接。
- `stat(relativePath)`：返回类型、大小、修改时间、可读写状态和稳定的版本摘要。
- `openForRead(relativePath)`：返回受控的读取句柄，不把绝对路径交给网页。
- `prepareDelete(relativePath)` / `delete(relativePath, confirmation)`。
- `mkdir(relativePath)`。
- `prepareUpload` / `commitUpload`。
- `prepareMove` / `commitMove`。

写操作按规范化相对路径加锁，避免两个请求同时替换同一目标。读取可以并发，但删除、移动和替换开始后要阻止新的读取句柄进入提交阶段。

### 5.3 TransferManager

上传和下载都采用流式读写，不能把整个文件加载到内存。每个任务记录：任务 ID、方向、相对路径、总字节数、已完成字节数、速度、开始时间、取消状态和错误。

- 小文件可使用 `multipart/form-data` 兼容上传；10–40GB 游戏必须使用分片会话上传，不能把整个请求体一次性作为一个任务。
- 下载：文件逐块写入 HTTP response；支持 `Range`、`HEAD` 和断开检测。
- 单个大型游戏文件禁止先打包 ZIP，直接按原文件流式下载；文件夹默认逐文件下载，只有用户明确选择“打包下载”时才生成 ZIP。
- 客户端断开、请求取消、服务停止和 App 离开前台都必须触发取消，并在 `defer` 中清理临时文件和活动计数。

### 5.4 10–40GB 大型游戏传输策略

ZIP 不是大型游戏传输格式。文件夹在 HTTP 中不是一个单独文件，ZIP 只解决“把多个文件作为一个下载项交给浏览器”的兼容问题；它不会让已经压缩过的 `.xci`、`.nsp`、`.nsz` 等游戏明显变小。对 10–40GB 单个游戏先打 ZIP 会额外占用接近一份完整文件的临时空间，增加打包时间、发热和失败重来成本，因此禁止作为默认路径。

PPSSPP 的实现也不是先打包游戏：Remote ISO 直接以文件句柄流式读取，并使用 `HEAD` 和 `Range` 返回分段内容；上传则是 `multipart/form-data` 边接收边写入目标文件。它没有通用的上传断点续传协议，所以 MeloNX 不能只复制 PPSSPP 的一次性 multipart 上传。

#### 单文件下载

- 服务端使用 64 位整数记录文件大小和偏移，返回 `Content-Length`、`ETag`、`Last-Modified`、`Accept-Ranges: bytes`。
- 客户端先发送 `HEAD`，再把数据写入本地 `游戏名.ext.melo-download.part`；文件未完整校验前不得显示为成功文件。
- 断线后使用 `Range: bytes=<已写入偏移>-` 和 `If-Range: <ETag>` 继续；大小、ETag 或修改时间变化时删除旧 `.melo-download.part`，从零开始。
- 收到完整大小并通过可选 SHA-256 校验后，客户端才把临时文件原子改名为原始文件名。浏览器无法控制下载目录时，网页至少要显示“未完成”状态，不得把 HTTP 连接结束当作成功。

#### 单文件上传

上传采用会话和分片，而不是一个持续数小时的 multipart 请求：

1. `POST /api/v1/transfers/uploads` 预检目标相对路径、总大小、冲突策略和可选 SHA-256，服务端返回 `uploadId`、建议分片大小（默认 32MiB）、`nextOffset` 和过期时间。
2. 客户端用 `File.slice()` 读取单片，通过 `PUT /api/v1/transfers/uploads/{uploadId}` 携带 `Content-Range: bytes start-end/total`。服务端只接受 `start == nextOffset` 的顺序片段，写入 `payload.melo-upload.part`，成功后返回新的 `nextOffset`。
3. 网络中断后调用 `GET /api/v1/transfers/uploads/{uploadId}` 查询偏移，从该偏移继续；不得从不确定的位置覆盖写入。
4. `POST /api/v1/transfers/uploads/{uploadId}/complete` 关闭临时文件，校验总大小和可选 SHA-256，随后在同一卷内原子替换目标。`DELETE .../{uploadId}` 或超时只清理临时文件。

临时文件必须使用明显不同的后缀，例如 `payload.melo-upload.part`、`payload.melo-upload.json`，并放在隐藏的 `.melo-transfer-temp/<uploadId>/` 中；目录列表隐藏该目录，但状态接口必须能显示“未完成/可继续”。完成前绝不创建正式的 `.nsp`、`.xci` 等目标名，避免用户误以为上传成功。覆盖已有文件时保留旧目标，直到新文件校验完成；失败时只删除 `.melo-upload.part`，原文件不受影响。

分片建议 8–64MiB，默认 32MiB；大型传输默认并发 1，避免同时占用多份缓冲区。所有数据都流式读写，不把 10–40GB 文件装入内存。

#### 文件夹与 ZIP

文件夹上传按文件逐个建立上述分片会话，保留 `relativePath`，不先压缩。文件夹下载默认显示清单并逐项下载；只有用户主动选择“打包下载”时才生成 ZIP。ZIP 任务必须先检查空间，采用 Zip64，失败或取消时删除临时包；10GB 以上目录默认提示需要接近一份额外空间，第一阶段可以直接禁用打包，不能宣称支持断点续传。

#### 空间和设备状态

开始上传前通过 `volumeAvailableCapacityForImportantUsage` 预检可用空间：至少覆盖临时分片、校验和覆盖提交所需余量；目标替换需要同时考虑旧目标仍占用的空间。空间不足在写入前返回 `insufficientStorage`，不能写出不可清理的半成品。传输期间持有防熄屏 lease，MeloNX 必须保持前台；进入后台、服务停止或用户取消时停止新分片，保留可过期的 `.melo-upload.part` 会话供服务重新启动后继续，并清理过期孤儿。

### 5.5 中断、网页关闭和 App 后台恢复

传输状态统一使用 `uploading`、`paused`、`disconnected`、`verifying`、`completed`、`failed`、`cancelled`、`expired`。只有进入 `completed` 并完成大小/哈希校验后，才允许出现正式文件名。

每个上传分片必须按以下顺序提交：写入 `.melo-upload.part`、刷新文件数据、原子写入包含 `nextOffset` 的 `.melo-upload.json`，然后才向客户端返回该分片成功。这样即使 App 崩溃或设备断电，元数据也不会声称已经写入实际不存在的字节。服务端只从最后一个已确认的 `nextOffset` 继续。

- **网络断线或网页关闭**：当前 HTTP 请求标记为 `disconnected`，保留 `.melo-upload.part` 和元数据，不创建正式目标文件。网页把 `uploadId` 和一次性 `resumeToken` 存入 `localStorage` 或 `IndexedDB`；用户重新打开地址并完成当前会话鉴权后，先查询状态，再从 `nextOffset` 继续。恢复凭据不放入 URL、日志或文件名。
- **iOS 切到后台**：进入后台时停止发起新分片，允许当前分片尽快收尾，然后关闭连接并标记 `paused`。iOS 后台执行时间不受应用保证，不能承诺 10–40GB 传输会在后台继续；回到前台后重新连接并续传。防熄屏只在 App 位于前台且存在活动传输时生效。
- **App 被系统终止、崩溃或设备重启**：下次启动服务时扫描 `.melo-transfer-temp`，校验临时文件长度和元数据一致性，恢复未过期会话。旧的 HTTP bearer token 必须失效；服务重新启动后用新的会话 token 加上本地保存的 `resumeToken` 继续，不能复用旧 token。
- **用户主动停止服务或取消**：停止服务先关闭 listener 和连接，默认保留未完成会话到过期时间；用户点击“放弃并删除”或会话过期时，才删除 `.melo-upload.part`、`.melo-upload.json`。取消不会删除原有目标文件。
- **临时会话过期**：默认保留 72 小时，启动服务和定时任务清理过期孤儿；过期前网页显示剩余时间，过期后返回 `expired`，只能重新上传。

下载的恢复边界不同：服务端不会保存客户端已经收到的字节。服务端提供 `HEAD`、`ETag` 和 `Range`，桌面浏览器下载器或支持文件写入的客户端可以用本地 `游戏名.ext.melo-download.part` 继续；普通网页关闭后，Safari 等浏览器可能丢失页面控制的本地临时数据，此时页面必须显示“无法确认本地进度，需要重新开始或由浏览器下载器恢复”，不能把服务器连接结束当成下载成功。下载完成后仍要通过大小/哈希校验，再改名为正式文件。
## 6. HTTP API 契约

所有 `/api/v1/*` 请求都要携带：

```http
Authorization: Bearer <session-token>
```

静态网页可以通过启动 URL 中的一次性 token 完成首次握手，网页随后把 token 放到内存中；不要把 token 写入持久化配置或 URL 日志。

### 6.1 状态和目录

```http
GET /api/v1/status
GET /api/v1/files/list?path=roms
GET /api/v1/files/stat?path=roms/demo.nsp
```

`list` 返回名称、相对路径、类型、大小、修改时间和可执行操作。根目录请求使用空路径或 `/`，服务端不接受绝对路径。

### 6.2 打开和下载

```http
GET  /api/v1/files/open?path=config/settings.json
HEAD /api/v1/files/download?path=roms/demo.nsp
GET  /api/v1/files/download?path=roms/demo.nsp
```

`open` 仅对允许预览的 MIME 类型使用 `Content-Disposition: inline`，未知类型统一下载。单个文件下载直接返回原文件并支持 Range；文件夹默认逐项下载，用户明确选择“打包下载”时才返回临时 ZIP。服务端要处理 Range、文件不存在、目标变更和客户端提前断开。

### 6.3 创建目录和上传

```http
POST /api/v1/files/mkdir
Content-Type: application/json

{"path":"roms/new-folder"}
```

```http
POST /api/v1/files/upload?path=roms&conflict=ask
Content-Type: multipart/form-data; boundary=...
```

上传字段至少包括：

- `file`：文件内容。
- `relativePath`：文件夹上传时的相对路径。
- `size`：客户端声明的大小，仅用于进度和预检，不能代替服务端统计。
- `operationId`：批量上传 ID，用于进度和取消。

目标已存在时返回 `409 conflict` 和冲突列表。用户选择覆盖后重试时必须携带短期确认 token，以及预检返回的目标版本摘要；目标在此期间发生变化则再次返回 `409`。

### 6.4 删除

```http
POST /api/v1/files/delete/prepare
{"path":"games/old-cache"}

DELETE /api/v1/files/item?path=games/old-cache&confirmation=<short-lived-token>
```

删除 token 绑定会话、规范化路径、目标版本和过期时间，只能使用一次。服务端递归删除前再次统计并检查根路径保护，根目录本身不能删除。

### 6.5 移动、替换和覆盖

```http
POST /api/v1/files/move
Content-Type: application/json

{
  "source": "roms/old/demo.nsp",
  "destination": "roms/new/demo.nsp",
  "conflict": "ask",
  "confirmation": null
}
```

`conflict` 取值为 `ask`、`skip`、`replaceFile`、`mergeDirectory`、`replaceDirectory`。目标存在时先返回冲突预览和一次性确认 token，确认请求必须带回源、目标和双方版本摘要。源目录不能移动到自身子目录；目标为目录时要明确选择合并或整目录替换。

### 6.6 大文件断点续传 API

```http
POST /api/v1/transfers/uploads
Content-Type: application/json

{"path":"roms/game.nsp","size":42949672960,"sha256":"...","conflict":"replace"}
```

响应至少包含 `uploadId`、`nextOffset`、`resumeToken` 和 `expiresAt`。`resumeToken` 只保存在网页的 `localStorage`/`IndexedDB`，恢复请求通过请求头发送，不放入 URL。

```http
PUT /api/v1/transfers/uploads/{uploadId}
Content-Range: bytes 0-33554431/42949672960
Content-Type: application/octet-stream
```

```http
GET  /api/v1/transfers/uploads/{uploadId}
POST /api/v1/transfers/uploads/{uploadId}/complete
DELETE /api/v1/transfers/uploads/{uploadId}
```

`GET` 返回 `nextOffset`、总大小、临时文件状态和过期时间；`complete` 只允许在大小及校验通过后提交。任何分片序号错误、目标版本变化、空间不足或会话过期都返回明确错误，客户端保留 `.melo-download.part` 或服务端 `.melo-upload.part`，不能把错误响应重命名为正式文件。

下载接口沿用：

```http
HEAD /api/v1/files/download?path=roms/game.nsp
GET  /api/v1/files/download?path=roms/game.nsp
Range: bytes=33554432-
If-Range: "<etag>"
```

服务端对有效 Range 返回 `206 Partial Content` 和 `Content-Range`；不支持或失效的 Range 不得静默返回错误内容。
## 7. 路径和安全策略

### 7.1 规范化和越界防护

所有 API 的 path 参数都经过以下顺序处理：

1. URL 解码一次，拒绝 NUL 字符、反斜杠、盘符、协议前缀和绝对路径。
2. 按 `/` 分段，拒绝空白异常段、`.`、`..` 和双重编码后仍能变成 `..` 的输入。
3. 拼接到 `URL.documentsDirectory` 后 `standardizedFileURL`，检查结果仍位于根目录并保留路径边界。
4. 逐级检查符号链接；不允许符号链接把访问带出根目录。最安全的第一版可以直接拒绝用户根目录中的符号链接。
5. 对文件名长度、目录深度、单次项目数、单文件大小和批量总大小设置上限。

必须覆盖这些测试：根目录、`%2e%2e`、双编码、反斜杠、绝对路径、符号链接、空共享根、源等于目标、移动到自身子目录、删除根目录和跨请求目标变化。

### 7.2 会话鉴权

- 每次启动生成至少 32 字节的系统随机 token。
- 只允许局域网客户端访问；连接层拒绝非本地接口或非局域网地址，并在请求层再次检查 token。
- 停止服务、App 被终止、服务重启和 token 轮换时立即使旧 token 失效；仅进入后台不提交新请求，回到前台后可在当前服务会话内恢复。
- 不把 token 写入系统日志、崩溃日志、分析事件或持久化配置。
- `Info.plist` 增加 `NSLocalNetworkUsageDescription`，说明用于同一局域网文件管理；第一版不启用 Bonjour，避免额外的 `NSBonjourServices` 配置，直接显示 IP 和端口。

这是局域网明文 HTTP 服务，不能当作互联网安全通道。UI 要明确提示用户只在可信网络开启，后续如需在不可信网络使用，再单独设计 TLS 或配对机制。

## 8. 覆盖、原子性和恢复

临时目录固定为 `Documents/.melo-transfer-temp/<session>/<operation>/`，列表和 API 都拒绝访问该目录。启动服务时清理超过保留时间的孤立临时目录；停止服务时关闭 listener 和当前连接，但默认保留未过期的可恢复会话，用户显式取消或会话过期后再清理。

### 文件上传和文件替换

1. 在目标同一文件系统创建唯一临时文件。
2. 流式写入并统计字节数；必要时计算 SHA-256。
3. 完整写入、关闭和校验成功后，使用同卷原子替换。
4. 覆盖前再次检查目标版本；版本不一致返回冲突，不删除新目标。
5. 任何错误、取消、断线或磁盘不足都只删除临时文件，保留原文件。

### 目录上传和目录替换

- 目录上传逐项写入临时目录，先完成结构和路径校验，再按冲突策略提交。
- 合并目录逐项原子替换；单项失败要返回失败列表，不静默报告成功。
- 替换整个目录时先把旧目录移动到同一临时工作区，完成新目录提交后再删除旧目录；提交失败时尝试回滚。
- 不允许把上传临时目录直接移动到用户根目录而跳过路径校验。

### 移动

- 同一卷优先使用原子 `moveItem` 或等价 rename。
- 目标替换前保存目标版本，提交时再次验证。
- 跨卷移动采用“复制到临时目录、校验、原子提交、删除源”的顺序；源删除失败要报告为部分完成。
- 目录移动不能跟随外部符号链接，也不能将源目录复制进自身子目录。

## 9. 传输期间防熄屏和 App 生命周期

新增 `TransferActivityCoordinator`，以引用计数或 lease 管理传输期间的防熄屏状态：

```text
activeTransferCount == 0
  └─ acquire() → 保存当前 isIdleTimerDisabled，设置 true
activeTransferCount > 0
  ├─ 新任务 acquire() → 只增加引用，不重复覆盖原值
  └─ release() → 引用减一
activeTransferCount == 0
  └─ 恢复 acquire 前保存的原值
```

每一个上传或下载任务必须拥有独立 lease，并在完成、取消、失败、断线、HTTP response 关闭和服务停止路径中释放。进入后台时先暂停新分片并释放网络连接，临时会话由恢复协议管理；计数不能直接用网页连接数代替，因为一个连接可以有多个文件传输。

当前 Metal 视图直接修改 `UIApplication.shared.isIdleTimerDisabled`，实施时要先收拢到同一个 coordinator，或者至少让游戏显示和文件传输各自持有 lease，避免文件传输结束时错误地把游戏场景改回可熄屏。

场景进入非 active 状态时：

- 停止接受新连接和新传输。
- 取消或收尾已有任务，释放全部 lease。
- 停止 listener 并使 token 失效。
- 在主线程恢复原来的 `isIdleTimerDisabled`。
- 网页和 iOS 页面显示“请保持 MeloNX 前台，传输期间不要锁屏”。

不能依赖后台执行时间保证大文件传输完成，也不能在后台继续暴露写入接口。

## 10. 错误、日志和资源限制

统一错误码至少包括：`badRequest`、`unauthorized`、`forbiddenPath`、`notFound`、`conflict`、`invalidConfirmation`、`tooLarge`、`busy`、`cancelled`、`expired`、`incomplete`、`insufficientStorage`、`ioError`、`serverStopping`。

日志只记录：请求方法、API 路由、相对路径哈希或脱敏路径、字节数、耗时和错误码。文件名可以包含隐私信息，默认不写完整文件名；异常消息返回用户可理解的短文本，详细系统路径只留在本地调试日志。

实现前确定并测试：最大请求头、最大连接数、最大上传文件、批量文件数、目录递归深度、临时空间保留量、单个任务超时和服务空闲超时。超过限制时在写入前拒绝，不能写出不可清理的半成品。

## 11. 验证计划

### 单元和集成测试

- 路径：中文、空格、特殊字符、URL 编码、双编码、`..`、反斜杠、绝对路径、符号链接和根目录保护。
- 列表：空目录、大目录、权限异常、文件和目录同名冲突、修改时间和大小读取。
- 下载：小文件、大文件、Range、HEAD、浏览器断开、文件在读取中被删除或替换、分片续传、网页关闭、App 后台、临时后缀和目录打包清理。
- 上传：单文件、多文件、文件夹、空文件夹、中文相对路径、断点取消、网页关闭后恢复、App 后台暂停后恢复、App 重启后恢复、分片偏移错位、磁盘不足和临时后缀清理。
- 删除：文件确认、递归目录确认、确认 token 过期、目标版本变化、根目录拒绝。
- 移动：同卷、跨卷回退、文件替换、目录合并、整目录替换、源等于目标、移动到自身子目录。
- 鉴权：缺失 token、错误 token、停止服务后的旧 token、后台后的旧连接。
- 防熄屏：并发上传下载、单任务失败、客户端断开、服务停止、场景切后台后计数归零并恢复原值。

### 真机验收

至少验证 iPhone 与 Windows/macOS 浏览器在同一 Wi-Fi 下的连接、二维码和复制地址；验证锁屏、切换 App、弱 Wi-Fi、Wi-Fi 切换、前后台、低磁盘空间和大文件。Windows 环境不能替代 Xcode、iOS 沙盒和真实局域网验收。

## 12. 分阶段开发顺序

### 阶段一：契约和只读闭环

1. 定义 `LANFileServer`、`FileSystemActor`、统一错误码和路径测试。
2. 引入锁定版本的 `swift-nanohttp`、一次性 token、`NSLocalNetworkUsageDescription` 和服务设置页。
3. 实现网页静态资源、状态、目录列表、文件 stat、打开和下载。
4. 验证服务停止、token 失效、根目录不能越界。

### 阶段二：上传和进度

1. 实现分片会话上传、`Content-Range`、文件夹相对路径、临时后缀和原子替换；`multipart/form-data` 仅作为小文件兼容路径。
2. 加入冲突预检、覆盖/跳过/取消和网页进度。
3. 实现 `TransferManager` 与取消、断线、磁盘错误清理。

### 阶段三：删除、移动和目录覆盖

1. 实现删除预览、二次确认 token 和递归统计。
2. 实现移动、文件替换、目录合并和整目录替换。
3. 加入版本检查、回滚和并发写冲突处理。

### 阶段四：防熄屏、生命周期和交付

1. 重构现有 Metal 防熄屏逻辑，接入 `TransferActivityCoordinator`。
2. 验证前后台、服务停止、任务取消和状态恢复。
3. 完成 Xcode 编译、真机局域网验证、压力测试和交付说明。

本阶段只完成开发文档和方案确认，不修改运行时代码；下一步应按阶段一先落地只读服务和安全路径测试，再进入写操作。
