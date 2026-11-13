# 局域网网页文件管理 Mock 契约测试

Node 测试不需要 Xcode 或真机，执行内置网页 JavaScript，覆盖 IP/端口直接访问、500 MiB 顺序分片、响应丢失续传、完成收据、恢复指纹及上传会话 resumeToken 拒绝、文件名安全展示和原生下载链接。目录批量下载测试检查串行发送、失败暂停与重复点击保护。测试数量及通过情况以当前命令实际输出为准。

```powershell
node --test tests/LANFileManager/LANWebBundleContract.test.js
```

当前本地执行结果：14/14 通过（以命令实际输出为准）。

macOS/Xcode 环境执行 `bash scripts/test-lan-file-manager.sh`，运行真实临时目录存储测试、下载状态机测试、本地 NanoHTTP 磁盘请求体测试，并按 App 的 MainActor 默认隔离设置检查 Swift 集成。该脚本已加入 Codemagic，Windows 未运行这些 Swift 检查。

真机验证仍需使用 Codemagic 构建后，在 MeloNX 菜单“局域网网页文件管理 → 启动服务”复制 `http://IP:端口` 地址，由同局域网浏览器直接打开并管理 Documents，无需登录。上传会话 resumeToken 和删除/破坏性移动的 confirmationToken 仍保留各自的内部校验流程。Mock 测试不替代 500 MiB 网络传输、Range 下载和 iOS 前后台生命周期测试。
