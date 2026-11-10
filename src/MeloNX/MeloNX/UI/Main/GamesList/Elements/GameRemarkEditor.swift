//
//  GameRemarkEditor.swift
//  MeloNX
//
//  游戏库备注编辑器：草稿与已保存值分离，取消不会覆盖备注，清空并保存会隐藏备注行。
//

import SwiftUI

struct GameRemarkEditor: View {
    let game: GameInfo
    @ObservedObject private var remarks = GameRemarksStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    private var isOverLimit: Bool { draft.count > 500 }

    init(game: GameInfo) {
        self.game = game
        self._draft = State(initialValue: GameRemarksStore.shared.note(for: game))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(game.titleName)
                        .font(.headline)
                    TextEditor(text: $draft)
                        .frame(minHeight: 150)
                        .accessibilityLabel(Text("Game Note"))
                    Text(verbatim: "\(draft.count)/500")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(isOverLimit ? .red : .secondary)
                } header: {
                    Text("Game Note")
                } footer: {
                    Text("Shown below the game name and developer. Leave empty to hide the note. Up to 500 characters.")
                    if isOverLimit {
                        Text("Note is too long. Remove \(draft.count - 500) characters before saving.")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save Note") {
                        if remarks.setNote(draft, for: game) {
                            dismiss()
                        }
                    }
                    .disabled(isOverLimit)
                }
            }
        }
    }
}

/// 展示行共用同一仓库；内容按原文显示，不把用户备注当作本地化键。
struct GameRemarkLine: View {
    let game: GameInfo
    @ObservedObject private var remarks = GameRemarksStore.shared

    var body: some View {
        let note = remarks.note(for: game)
        if !note.isEmpty {
            Text(verbatim: note)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(Text("Game Note"))
                .accessibilityValue(Text(verbatim: note))
        }
    }
}
