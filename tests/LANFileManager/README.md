# 局域网网页文件管理 Mock 契约测试

Node 测试不需要 Xcode 或真机，执行内置网页 JavaScript，覆盖 500 MiB 顺序分片、响应丢失续传、完成收据、恢复指纹及凭据拒绝、文件名安全展示和下载链接不泄漏认证 token。目录批量下载测试检查串行发送、失败暂停与重复点击保护。

```powershell
node --test tests/LANFileManager/LANWebBundleContract.test.js
```

macOS/Xcode 环境执行 `bash scripts/test-lan-file-manager.sh`，运行真实临时目录存储测试、下载状态机测试、本地 NanoHTTP 磁盘请求体测试，并按 App 的 MainActor 默认隔离设置检查 Swift 集成。该脚本已加入 Codemagic，Windows 未运行这些 Swift 检查。

真机验证仍需使用 Codemagic 构建后，在 MeloNX 菜单“局域网网页文件管理 → 启动服务”打开地址测试；Mock 测试不替代 500 MiB 网络传输、Range 下载和 iOS 前后台生命周期测试。
