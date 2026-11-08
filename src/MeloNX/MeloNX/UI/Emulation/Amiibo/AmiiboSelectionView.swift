//
//  AmiiboSelectionView.swift
//  MeloNX
//
//  游戏内虚拟 amiibo 选择界面。只在本视图可见时轮询状态，保持游戏运行，
//  不自动暂停或恢复游戏，也不要求用户准备实体卡、NFC 或标签文件。
//

import SwiftUI
import UniformTypeIdentifiers

struct AmiiboSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var ryujinxController: RyujinxController
    @ObservedObject private var service = AmiiboService.shared
    @State private var searchText = ""
    @State private var selectedId: String?
    @State private var showImporter = false
    @State private var showCustomEditor = false
    @Environment(\.scenePhase) private var scenePhase

    private var selectedEntry: AmiiboCatalogEntry? {
        service.entries.first { $0.id == selectedId }
    }

    private var filteredEntries: [AmiiboCatalogEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return service.orderedEntries }
        return service.orderedEntries.filter { $0.searchText.contains(query) }
    }

    private var canUse: Bool {
        selectedEntry != nil && service.catalogError == nil &&
        service.state.isRunning && !service.state.isPaused &&
        service.state.isSearching && !service.isSubmitting
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(statusText, systemImage: statusSymbol)
                        .foregroundColor(service.state.isSearching ? .green : .secondary)
                    Text("先在游戏中开启 amiibo 能力并进入读取状态，再选择角色并点“使用”。无需实体卡或 NFC。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("目录") {
                    if let titleId = service.activeTitleId {
                        Text("游戏 ID：\(titleId)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Button("导入 TXT 目录") { showImporter = true }
                    Button("添加自定义虚拟身份") { showCustomEditor = true }
                    Button("打开当前游戏目录") { service.openCatalogDirectory() }
                    Button("刷新目录") { service.refreshCatalog() }
                    Text("导入失败会保留原目录；相同 ID 优先使用自定义名称，其次外部目录。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                if let error = service.catalogError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundColor(.red)
                    }
                }

                if filteredEntries.isEmpty && service.catalogError == nil {
                    Section {
                        Text(service.entries.isEmpty ? "尚无 amiibo，请导入 TXT 目录或手动添加。" : "没有匹配的 amiibo。")
                            .foregroundColor(.secondary)
                    }
                } else {
                    Section(searchText.isEmpty ? "角色目录" : "搜索结果") {
                        ForEach(filteredEntries) { entry in
                            entryRow(entry)
                        }
                    }
                }

                if let message = service.lastMessage {
                    Section("操作结果") {
                        Text(message)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("虚拟 amiibo")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索角色名称或 ID")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if let entry = selectedEntry {
                        Text(entry.note)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        if let entry = selectedEntry { service.use(entry) }
                    } label: {
                        HStack {
                            if service.isSubmitting { ProgressView() }
                            Text(service.isSubmitting ? "正在提交…" : "使用所选 amiibo")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canUse)
                }
                .padding()
                .background(.regularMaterial)
            }
            .onAppear {
                if case .started(let game, _) = ryujinxController.isRunning {
                    service.start(titleId: game.titleId)
                } else {
                    service.start(titleId: "")
                }
                selectedId = service.orderedEntries.first?.id
            }
            .onDisappear { service.stopPolling() }
            .onChange(of: scenePhase) { phase in
                if phase == .active { service.refreshCatalog() }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.plainText], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { service.importCatalog(from: url) }
                case .failure(let error):
                    service.reportImportFailure(error)
                }
            }
            .sheet(isPresented: $showCustomEditor) {
                AmiiboCustomEditor(service: service)
            }
        }
    }

    private func entryRow(_ entry: AmiiboCatalogEntry) -> some View {
        Button {
            selectedId = entry.id
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selectedId == entry.id ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundColor(selectedId == entry.id ? .accentColor : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name)
                        .foregroundColor(.primary)
                    Text(entry.id)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 8)
                if service.recentIds.contains(entry.id) {
                    Text("最近使用")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if service.customIds.contains(entry.id) {
                    Text("自定义")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(entry.name)
        .accessibilityValue(selectedId == entry.id ? "已选择" : "未选择")
        .swipeActions(edge: .trailing) {
            if service.customIds.contains(entry.id) {
                Button("删除自定义", role: .destructive) { service.removeCustom(id: entry.id) }
            }
        }
    }

    private var statusText: String {
        if service.isSubmitting { return "正在提交虚拟身份" }
        if !service.state.isRunning { return "游戏尚未运行" }
        if service.state.isPaused { return "游戏已暂停，请先继续游戏" }
        if service.state.isSearching { return "游戏正在等待 amiibo，可以使用" }
        return "游戏当前没有等待 amiibo"
    }

    private var statusSymbol: String {
        if service.state.isSearching { return "checkmark.circle" }
        if service.state.isPaused { return "pause.circle" }
        return "info.circle"
    }
}

private struct AmiiboCustomEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var service: AmiiboService
    @State private var name = ""
    @State private var id = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("自定义虚拟身份") {
                    TextField("名称（最多 60 个字符）", text: $name)
                    TextField("16 位 amiibo ID", text: $id)
                        .textInputAutocapitalization(.characters)
                        .disableAutocorrection(true)
                    Text("这里输入的是 amiibo 身份 ID，不是金手指代码或任意游戏数据。游戏是否接受由游戏决定。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                if let error { Section { Text(error).foregroundColor(.red) } }
            }
            .navigationTitle("添加自定义")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do { try service.addCustom(name: name, id: id); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }
}
