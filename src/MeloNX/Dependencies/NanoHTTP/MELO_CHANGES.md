# MeloNX 使用的 NanoHTTP

上游：<https://github.com/objecthub/swift-nanohttp>

版本：`2.1.2`，commit `a8cb617fcc333e1aa3ca31d5bf794a9c6db73c74`。

许可证为 BSD-3-Clause，原始版权声明保留在各源码和 `LICENSE`。

本地修改：

- 仅保留 `NanoHTTP` 产品，避免把演示应用和无关模块加入 MeloNX 构建。
- `Configuration.requestBodyPolicy` 在请求头解析后、正文读取前调用，用于鉴权和存储策略选择。
- 磁盘正文要求 `Content-Length`，按最多 1 MiB 每次读取并写入唯一 `.melo-request.part`，不缓存完整 500 MiB 分片。
- 请求正文传输失败、对象释放和响应完成会清理请求临时文件。进程被杀时的孤儿文件由 MeloNX 下一次启动清理。
- 其他路由可以独立限制内存正文大小，避免大文件限额放大 JSON 请求的内存开销。
- 提前检查 Host/Origin，并把正文策略抛出的 HTTP 错误映射为拒绝响应。
- 固定长度文件响应遇到源文件截短时立即抛出短写错误，避免下载状态误报完成；仍使用原生文件发送路径。

在 macOS 上执行 `swift test --package-path src/MeloNX/Dependencies/NanoHTTP` 可运行磁盘正文测试。Windows 本地没有 Swift SDK，未在本机执行这些测试。
