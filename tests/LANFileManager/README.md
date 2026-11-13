# 局域网网页文件管理 Mock 契约测试

这些测试不需要 Xcode 或真机，检查内置网页资源是否继续遵守 Swift 服务端的 HTTP 契约：静态资源入口、删除/移动二次确认、500 MiB 顺序分片、恢复头和下载 token 不落 URL。

```powershell
node --test tests/LANFileManager/LANWebBundleContract.test.js
```

真机验证仍需使用 Codemagic 构建后，在 MeloNX 菜单“局域网网页文件管理 → 启动服务”打开地址测试；Mock 测试不替代 500 MiB 网络传输、Range 下载和 iOS 前后台生命周期测试。
