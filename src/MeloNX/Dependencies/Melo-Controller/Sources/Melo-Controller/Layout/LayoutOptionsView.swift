//
//  LayoutOptionsView.swift
//  Melo-Controller
//
//  Created by Stossy11 on 26/1/2026.
//

import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static var meloLayout: UTType { LayoutExporter.meloLayout }
}

struct LayoutOptionsView: View {
    let gameId: String?
    var gameName: String? = nil
    @Binding var layout: LayoutConfig
    @Environment(\.presentationMode) var presentationMode

    @State private var showingResetAlert = false
    @State private var showingCopySheet = false
    @State private var showingFileImporter = false

    @State private var exportItem: LayoutExportItem?

    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showingAlert = false

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                if let gameId = gameId {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("当前游戏")
                            .font(.headline)
                        HStack {
                            Image(systemName: "gamecontroller.fill")
                                .foregroundColor(.blue)
                            Text(gameName ?? gameId)
                                .font(.subheadline)
                            Spacer()
                            if LayoutManager.shared.hasCustomLayout(for: gameId) {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text("自定义布局")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                            } else {
                                Text("使用默认布局")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("布局操作")
                        .font(.headline)

                    Button(action: { showingCopySheet = true }) {
                        HStack {
                            Image(systemName: "doc.on.doc")
                            Text("从其他布局复制…")
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .padding()
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .cornerRadius(8)
                    }

                    Button(action: exportCurrentLayout) {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("导出布局…")
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .padding()
                        .background(Color.purple.opacity(0.1))
                        .foregroundColor(.purple)
                        .cornerRadius(8)
                    }
                    .sheet(item: $exportItem) { item in
                        ShareSheet(activityItems: [item.url])
                    }

                    Button(action: { showingFileImporter = true }) {
                        HStack {
                            Image(systemName: "square.and.arrow.down")
                            Text("导入布局…")
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .padding()
                        .background(Color.teal.opacity(0.1))
                        .foregroundColor(.teal)
                        .cornerRadius(8)
                    }
                    .fileImporter(
                        isPresented: $showingFileImporter,
                        allowedContentTypes: [.meloLayout, .json],
                        allowsMultipleSelection: false
                    ) { result in
                        handleImport(result: result)
                    }

                    Button(action: {
                        layout = LayoutManager.shared.load(for: nil)
                    }) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("恢复默认布局")
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .padding()
                        .background(Color.orange.opacity(0.1))
                        .foregroundColor(.orange)
                        .cornerRadius(8)
                    }

                    Button(action: { showingResetAlert = true }) {
                        HStack {
                            Image(systemName: "trash")
                            Text("删除自定义布局")
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .foregroundColor(.red)
                        .cornerRadius(8)
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle("布局选项")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("完成") {
                presentationMode.wrappedValue.dismiss()
            })
        }
        .alert("删除自定义布局", isPresented: $showingResetAlert) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                LayoutManager.shared.reset(for: gameId)
                layout = LayoutManager.shared.load(for: gameId)
            }
        } message: {
            Text("这将删除当前游戏的自定义布局并恢复默认布局。")
        }
        .alert(alertTitle, isPresented: $showingAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .sheet(isPresented: $showingCopySheet) {
            CopyLayoutView(targetGameId: gameId, layout: $layout)
        }
    }

    private func exportCurrentLayout() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(layout)

            let fileName = LayoutManager.shared.exportFileName(for: gameId)
            let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            try data.write(to: tmpURL, options: .atomic)
            exportItem = LayoutExportItem(url: tmpURL)
        } catch {
            alertTitle = "导出失败"
            alertMessage = error.localizedDescription
            showingAlert = true
        }
    }

    private func handleImport(result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            alertTitle = "导入失败"
            alertMessage = error.localizedDescription
            showingAlert = true

        case .success(let urls):
            guard let url = urls.first else { return }

            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }

            do {
                let data = try Data(contentsOf: url)
                let imported = try LayoutManager.shared.importLayout(from: data, for: gameId)
                layout = imported
                alertTitle = "导入成功"
                alertMessage = "布局已应用\(gameId.map { "到 \($0)" } ?? "")。"
                showingAlert = true
            } catch {
                alertTitle = "导入失败"
                alertMessage = error.localizedDescription
                showingAlert = true
            }
        }
    }
}

private struct LayoutExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
