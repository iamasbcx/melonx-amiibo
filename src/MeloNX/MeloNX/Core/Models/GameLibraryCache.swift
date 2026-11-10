import Foundation

/// 应用内增量元数据缓存。native 解析仍串行执行，不与游戏启动并行访问核心文件系统。
/// 缓存仅保存 native 原值；文件读取失败及无有效标题的结果不缓存，后续刷新允许重试。
@MainActor final class GameLibraryCache {
    private var cache = LibraryMetadataCache<GameInfo>()
    private var scopedFolders: [URL: URL] = [:]
    private var lastKeysDigest: String?

    func load(systemLanguage: String) -> [GameInfo] {
        let files = FileManager.default
        do { try files.createDirectory(at: .romsURL, withIntermediateDirectories: true) }
        catch { NSLog("Game library: cannot create ROM directory: %@", error.localizedDescription) }
        let roots = accessibleRoots()
        let environment: String
        do {
            let keys = try ["prod.keys", "title.keys"].map {
                try LibraryDependencyFingerprint.digestFile(URL.keysFolderURL.appendingPathComponent($0))
            }.joined(separator: ":")
            if let previous = lastKeysDigest, previous != keys { Ryujinx.reloadKeySet() }
            lastKeysDigest = keys
            environment = keys + ":" + systemLanguage + ":" + Locale.preferredLanguages.joined(separator: ",")
        } catch {
            // 无法确认密钥来源时，使用本次独有环境避免返回旧缓存，并保留原解析错误行为。
            environment = UUID().uuidString
            NSLog("Game library: cannot inspect key files: %@", error.localizedDescription)
        }
        var result: [GameInfo] = []
        var seen = Set<String>()
        for root in roots {
            guard let enumerator = files.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                errorHandler: { _, error in NSLog("Game library enumeration failed: %@", error.localizedDescription); return true }) else { continue }
            for case let original as URL in enumerator {
                guard GameFileType.isSupported(fileExtension: original.pathExtension) else { continue }
                let url = original.standardizedFileURL
                guard seen.insert(url.path).inserted else { continue }
                do {
                    let stamp = try LibraryFileStamp.read(url)
                    let previous = cache.previous(for: url.path)
                    let dependency = updateDependency(titleId: previous?.titleId)
                    let signature = LibraryMetadataSignature(file: stamp, environment: environment, dependency: dependency)
                    if let cached = cache.value(for: url.path, matching: signature) {
                        result.append(cached)
                        continue
                    }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer {
                        do { try handle.close() }
                        catch { NSLog("Game library: could not close ROM: %@", error.localizedDescription) }
                    }
                    let info = Ryujinx.getGameInfo(arg0: handle.fileDescriptor, arg1: url.pathExtension as NSString, path: url)
                    result.append(info)
                    if !info.titleId.isEmpty, info.titleId != "0000000000000000",
                       !info.titleName.isEmpty, info.titleName != "Unknown" {
                        let finalSignature = LibraryMetadataSignature(file: stamp, environment: environment,
                            dependency: updateDependency(titleId: info.titleId))
                        cache.store(info, for: url.path, signature: finalSignature)
                    } else { cache.remove(url.path) }
                } catch {
                    cache.remove(url.path)
                    NSLog("Game library: could not read %@: %@", url.lastPathComponent, error.localizedDescription)
                }
            }
        }
        cache.retain(keys: seen)
        return result
    }

    /// 外部 ROM 运行期间仍需要目录授权；每个配置目录只持有一次，移除配置后配对释放。
    private func accessibleRoots() -> [URL] {
        let manager = ROMFolderManager.shared
        manager.loadBookmarks()
        var roots = [URL.romsURL.standardizedFileURL]
        var active = Set<URL>()
        for bookmark in manager.bookmarks {
            guard let original = manager.getUrl(from: bookmark) else { continue }
            let key = original.standardizedFileURL
            guard active.insert(key).inserted else { continue }
            if scopedFolders[key] != nil { roots.append(key) }
            else if original.startAccessingSecurityScopedResource() {
                scopedFolders[key] = original
                roots.append(key)
            }
        }
        for key in scopedFolders.keys.filter({ !active.contains($0) }) {
            scopedFolders.removeValue(forKey: key)?.stopAccessingSecurityScopedResource()
        }
        return roots
    }

    private func updateDependency(titleId: String?) -> String {
        do { return try LibraryDependencyFingerprint.update(titleId: titleId, documents: .documentsDirectory) }
        catch {
            // 无法确认更新依赖时仍交给 native 解析；本次唯一签名阻止旧缓存掩盖错误。
            NSLog("Game library: cannot inspect update metadata: %@", error.localizedDescription)
            return UUID().uuidString
        }
    }

}
