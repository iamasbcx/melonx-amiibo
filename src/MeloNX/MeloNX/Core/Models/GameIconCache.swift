import Foundation
import UIKit
import CoreGraphics
import ImageIO

/// 图标解码仅在主线程缓存；按目标像素尺寸区分缩略图和完整图，响应内存警告清空自有缓存。
/// 不在 GameInfo/Codable 中增加图片对象或修改原始 iconData，导出和保存原图语义保持不变。
@MainActor final class GameIconCache {
    static let shared = GameIconCache()
    private nonisolated struct Key: Hashable, Sendable { let path: URL; let pixels: Int; let rounded: Bool }
    private struct Entry { let source: Data; let image: UIImage }
    private var images = BoundedLRUCache<Key, Entry>(countLimit: 128, costLimit: 32 * 1024 * 1024)
    private var memoryObserver: NSObjectProtocol?

    private init() {
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.images.removeAll() }
            }
    }

    func image(for game: GameInfo, maxPixels: Int? = nil, rounded: Bool = false) -> UIImage? {
        guard let data = game.iconData, !data.isEmpty else { return nil }
        let pixels = maxPixels.map { min(4096, max(1, $0)) } ?? 0
        let key = Key(path: game.fileURL, pixels: pixels, rounded: rounded)
        // Data 保留同一存储时可快速比较；即使同名同版本图标被替换，也不会返回错误图片。
        if let entry = images.value(for: key), entry.source == data { return entry.image }
        let decoded: UIImage?
        if pixels == 0 {
            decoded = UIImage(data: data)
        } else if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixels,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) {
            decoded = UIImage(cgImage: thumbnail)
        } else { decoded = nil }
        guard var image = decoded else { return nil }
        if rounded {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let sourceImage = image
            image = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
                let rect = CGRect(origin: .zero, size: sourceImage.size)
                UIBezierPath(roundedRect: rect, cornerRadius: 12).addClip()
                sourceImage.draw(in: rect)
            }
        }
        if let cgImage = image.cgImage {
            let (decodedCost, multipliedOverflow) = cgImage.bytesPerRow.multipliedReportingOverflow(by: cgImage.height)
            let (cost, addedOverflow) = decodedCost.addingReportingOverflow(data.count)
            if !multipliedOverflow && !addedOverflow {
                images.insert(Entry(source: data, image: image), for: key, cost: cost)
            }
        }
        return image
    }
}
