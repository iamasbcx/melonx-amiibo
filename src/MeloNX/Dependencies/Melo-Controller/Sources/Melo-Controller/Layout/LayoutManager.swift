//
//  LayoutManager.swift
//  Melo-Controller
//
//  Created by Stossy11 on 04/12/2025.
//

import Foundation
import UniformTypeIdentifiers

enum LayoutTransferError: LocalizedError {
    case encodingFailed
    case decodingFailed(underlying: Error)
    case fileWriteFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode the layout."
        case .decodingFailed(let e):
            return "The file doesn't appear to be a valid layout: \(e.localizedDescription)"
        case .fileWriteFailed(let e):
            return "Could not write the layout file: \(e.localizedDescription)"
        }
    }
}

/// App-Side editable types
public class LayoutExporter {
    public static var fileType = "meloLayout"

    public static var meloLayout = UTType(exportedAs: "com.stossy11.melocontroller.layout",
                                   conformingTo: .data)
}

public final class LayoutManager {
    public static let shared = LayoutManager()
    private init() {}

    private var baseURL: URL {
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docDir.appendingPathComponent("controller_layouts")
    }

    private func fileURL(for gameId: String?, orientation: LayoutOrientation) -> URL {
        let baseName = gameId?.isEmpty == false ? gameId! : "default"
        let fileName = "\(baseName)-\(orientation.rawValue).json"
        return baseURL.appendingPathComponent(fileName)
    }

    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    @discardableResult
    func save(_ layout: LayoutConfig, for gameId: String?, orientation: LayoutOrientation) -> Bool {
        ensureDirectoryExists()
        do {
            let data = try JSONEncoder().encode(layout)
            try data.write(to: fileURL(for: gameId, orientation: orientation), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func load(for gameId: String?, orientation: LayoutOrientation) -> LayoutConfig {
        let url = fileURL(for: gameId, orientation: orientation)
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(LayoutConfig.self, from: data) else {
            if gameId != nil {
                return load(for: nil, orientation: orientation)
            }
            return LayoutConfig()
        }
        return config
    }

    /// 返回游戏对应的滑动视角区域；单游戏没有独立布局时自动回退全局布局。
    public static func touchLookLayout(for gameId: String?, orientation: LayoutOrientation) -> TouchLookLayout {
        var layout = shared.load(for: gameId, orientation: orientation).touchLook
        layout.clamp()
        return layout
    }

    func reset(for gameId: String?, orientation: LayoutOrientation) {
        try? FileManager.default.removeItem(at: fileURL(for: gameId, orientation: orientation))
    }

    func resetAll() {
        try? FileManager.default.removeItem(at: baseURL)
    }

    func hasCustomLayout(for gameId: String, orientation: LayoutOrientation) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: gameId, orientation: orientation).path)
    }

    func copyLayout(from sourceGameId: String?, to targetGameId: String?, orientation: LayoutOrientation) {
        save(load(for: sourceGameId, orientation: orientation), for: targetGameId, orientation: orientation)
    }

    func getAllGameLayouts() -> [String] {
        ensureDirectoryExists()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return files.compactMap { url in
            let filename = url.lastPathComponent
            guard filename.hasSuffix(".json"), filename != "default.json" else { return nil }
            let base = String(filename.dropLast(5))
            guard !base.hasPrefix("default-"), base.hasSuffix("-portrait") || base.hasSuffix("-landscape") else { return nil }
            return base.replacingOccurrences(of: "-portrait", with: "")
                .replacingOccurrences(of: "-landscape", with: "")
        }
        .reduce(into: Set<String>()) { $0.insert($1) }
        .sorted()
    }

    func exportLayout(for gameId: String? = nil, orientation: LayoutOrientation) throws -> Data {
        let layout = load(for: gameId, orientation: orientation)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(layout) else {
            throw LayoutTransferError.encodingFailed
        }
        return data
    }

    func exportFileName(for gameId: String? = nil) -> String {
        exportFileName(for: gameId, orientation: .landscape)
    }

    func exportFileName(for gameId: String? = nil, orientation: LayoutOrientation) -> String {
        let base = gameId?.isEmpty == false ? gameId! : "default"
        return "\(base)-\(orientation.rawValue).\(LayoutExporter.fileType)"
    }

    @discardableResult
    func importLayout(from data: Data, for gameId: String? = nil, orientation: LayoutOrientation) throws -> LayoutConfig {
        do {
            let layout = try JSONDecoder().decode(LayoutConfig.self, from: data)
            save(layout, for: gameId, orientation: orientation)
            return layout
        } catch {
            throw LayoutTransferError.decodingFailed(underlying: error)
        }
    }
}
