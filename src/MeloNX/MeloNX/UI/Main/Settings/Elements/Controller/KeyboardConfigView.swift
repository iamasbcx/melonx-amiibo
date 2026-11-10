//
//  KeyboardConfigView.swift
//  MeloNX
//
//  Created by Stossy11 on 23/6/2026.
//

import SwiftUI

private func keyboardConfigURL(gameId: String?) -> URL {
    guard let gameId = ControllerInputProfile.normalizedGameId(gameId) else { return .keyboardConfigURL }
    return URL.configFolderURL.appendingPathComponent(gameId).appendingPathComponent("keyboardConfig.json")
}

/// 当前游戏没有键盘覆盖时读取全局；损坏文件明确记录错误，不改写原文件。
func pullKeyboardConfig(gameId: String? = nil) -> KeyboardConfigNative {
    let url = keyboardConfigURL(gameId: gameId)
    guard FileManager.default.fileExists(atPath: url.path) else {
        return ControllerInputProfile.normalizedGameId(gameId) == nil ? Ryujinx.defaultKeyboard : pullKeyboardConfig(gameId: nil)
    }
    do { return try JSONDecoder().decode(KeyboardConfigNative.self, from: Data(contentsOf: url)) }
    catch {
        NSLog("Keyboard configuration read failed: %@", error.localizedDescription)
        return Ryujinx.defaultKeyboard
    }
}

func writeKeyboardConfig(_ config: KeyboardConfigNative, gameId: String?) throws {
    if let error = keyboardConfigReadError(gameId: gameId) { throw InputConfigurationError.unreadable(error) }
    let url = keyboardConfigURL(gameId: gameId)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(config).write(to: url, options: .atomic)
}

func keyboardConfigReadError(gameId: String?) -> String? {
    let url = keyboardConfigURL(gameId: gameId)
    guard FileManager.default.fileExists(atPath: url.path) else {
        return ControllerInputProfile.normalizedGameId(gameId) == nil ? nil : keyboardConfigReadError(gameId: nil)
    }
    do {
        _ = try JSONDecoder().decode(KeyboardConfigNative.self, from: Data(contentsOf: url))
        return nil
    } catch {
        return "keyboardConfig.json (\(ControllerInputProfile.normalizedGameId(gameId) ?? "global")): \(error.localizedDescription)"
    }
}

func hasKeyboardConfigOverride(gameId: String) -> Bool {
    FileManager.default.fileExists(atPath: keyboardConfigURL(gameId: gameId).path)
}

func resetKeyboardConfig(gameId: String?) throws {
    let url = keyboardConfigURL(gameId: gameId)
    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
}

struct KeyboardConfigView: View {
    let gameId: String?
    @State var keyboardConfig: KeyboardConfigNative = Ryujinx.defaultKeyboard
    @Environment(\.dismiss) var dismiss
    @State private var dirty = false
    @State private var saveError: String?

    init(gameId: String? = nil) { self.gameId = ControllerInputProfile.normalizedGameId(gameId) }

    private var configBinding: Binding<KeyboardConfigNative> {
        Binding(get: { keyboardConfig }, set: { keyboardConfig = $0; dirty = true })
    }
 
    var body: some View {
        NavigationStack {
            List {
                Section("Right Joycon") {
                    KeyboardRightJoyconView(keyboardConfig: configBinding)
                }
                
                Section("Right Stick") {
                    KeyboardRightJoyconStickView(keyboardConfig: configBinding)
                }
                
                Section("Left Joycon") {
                    KeyboardLeftJoyconView(keyboardConfig: configBinding)
                }
                
                Section("Left Stick") {
                    KeyboardLeftJoyconStickView(keyboardConfig: configBinding)
                }
                
            }
            .navigationTitle("Keyboard Mapping")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        do {
                            if dirty { try writeKeyboardConfig(keyboardConfig, gameId: gameId) }
                            dirty = false
                            dismiss()
                        } catch { saveError = error.localizedDescription }
                    } label: {
                        Text("Done")
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        do {
                            try resetKeyboardConfig(gameId: gameId)
                            keyboardConfig = pullKeyboardConfig(gameId: gameId)
                            dirty = false
                        } catch { saveError = error.localizedDescription }
                    } label: {
                        Text("Reset")
                    }
                }
            }
            .onAppear() {
                self.keyboardConfig = pullKeyboardConfig(gameId: gameId)
                if let error = keyboardConfigReadError(gameId: gameId) {
                    saveError = InputConfigurationError.unreadable(error).localizedDescription
                }
            }
            .interactiveDismissDisabled(dirty)
            .alert("Input Settings Error", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(verbatim: saveError ?? "")
            }
        }
    }
}


struct KeyboardLeftJoyconView: View {
    @Binding var keyboardConfig: KeyboardConfigNative
    
    var body: some View {
        Picker("DPad Up", selection: $keyboardConfig.LeftJoycon.DpadUp) {
            ForEach(Key.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
        .pickerStyle(.menu)
        
        Picker("DPad Down", selection: $keyboardConfig.LeftJoycon.DpadDown) {
            ForEach(Key.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
        .pickerStyle(.menu)
        
        Picker("DPad Left", selection: $keyboardConfig.LeftJoycon.DpadLeft) {
            ForEach(Key.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
        .pickerStyle(.menu)
        
        
        Picker("DPad Right", selection: $keyboardConfig.LeftJoycon.DpadRight) {
            ForEach(Key.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
        .pickerStyle(.menu)
        
        Picker("Minus", selection: $keyboardConfig.LeftJoycon.ButtonMinus) {
            ForEach(Key.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
        .pickerStyle(.menu)
        
        Picker("L", selection: $keyboardConfig.LeftJoycon.ButtonL) {
            ForEach(Key.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
        .pickerStyle(.menu)
        
        Picker("Zl", selection: $keyboardConfig.LeftJoycon.ButtonZl) {
            ForEach(Key.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
        .pickerStyle(.menu)
        
        Picker("Sl", selection: $keyboardConfig.LeftJoycon.ButtonSl) {
            ForEach(Key.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
        .pickerStyle(.menu)
        
        Picker("Sr", selection: $keyboardConfig.LeftJoycon.ButtonSr) {
            ForEach(Key.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
        .pickerStyle(.menu)
    }
}

struct KeyboardLeftJoyconStickView: View {
    @Binding var keyboardConfig: KeyboardConfigNative
    
    var body: some View {
        Picker("Stick Up", selection: $keyboardConfig.LeftJoyconStick.StickUp) {
            ForEach(Key.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
        .pickerStyle(.menu)
        
        Picker("Stick Down", selection: $keyboardConfig.LeftJoyconStick.StickDown) {
            ForEach(Key.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
        .pickerStyle(.menu)
        
        Picker("Stick Left", selection: $keyboardConfig.LeftJoyconStick.StickLeft) {
            ForEach(Key.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
        .pickerStyle(.menu)
        
        
        Picker("Stick Right", selection: $keyboardConfig.LeftJoyconStick.StickRight) {
            ForEach(Key.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
        .pickerStyle(.menu)
        
        Picker("Stick Button", selection: $keyboardConfig.LeftJoyconStick.StickButton) {
            ForEach(Key.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
        .pickerStyle(.menu)
    }
}

struct KeyboardRightJoyconView: View {
    @Binding var keyboardConfig: KeyboardConfigNative
    
    var body: some View {
        Picker("A", selection: $keyboardConfig.RightJoycon.ButtonA) {
            ForEach(Key.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
        .pickerStyle(.menu)
        
        Picker("B", selection: $keyboardConfig.RightJoycon.ButtonB) {
            ForEach(Key.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
        .pickerStyle(.menu)
        
        Picker("X", selection: $keyboardConfig.RightJoycon.ButtonX) {
            ForEach(Key.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
        .pickerStyle(.menu)
        
        
        Picker("Y", selection: $keyboardConfig.RightJoycon.ButtonY) {
            ForEach(Key.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
        .pickerStyle(.menu)
        
        Picker("Plus", selection: $keyboardConfig.RightJoycon.ButtonPlus) {
            ForEach(Key.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
        .pickerStyle(.menu)
        
        Picker("R", selection: $keyboardConfig.RightJoycon.ButtonR) {
            ForEach(Key.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
        .pickerStyle(.menu)
        
        Picker("Zr", selection: $keyboardConfig.RightJoycon.ButtonZr) {
            ForEach(Key.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
        .pickerStyle(.menu)
        
        Picker("Sl", selection: $keyboardConfig.RightJoycon.ButtonSl) {
            ForEach(Key.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
        .pickerStyle(.menu)
        
        Picker("Sr", selection: $keyboardConfig.RightJoycon.ButtonSr) {
            ForEach(Key.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
        .pickerStyle(.menu)
    }
}

struct KeyboardRightJoyconStickView: View {
    @Binding var keyboardConfig: KeyboardConfigNative
    
    var body: some View {
        Picker("Stick Up", selection: $keyboardConfig.RightJoyconStick.StickUp) {
            ForEach(Key.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
        .pickerStyle(.menu)
        
        Picker("Stick Down", selection: $keyboardConfig.RightJoyconStick.StickDown) {
            ForEach(Key.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
        .pickerStyle(.menu)
        
        Picker("Stick Left", selection: $keyboardConfig.RightJoyconStick.StickLeft) {
            ForEach(Key.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
        .pickerStyle(.menu)
        
        
        Picker("Stick Right", selection: $keyboardConfig.RightJoyconStick.StickRight) {
            ForEach(Key.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
        .pickerStyle(.menu)
        
        Picker("Stick Button", selection: $keyboardConfig.RightJoyconStick.StickButton) {
            ForEach(Key.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
        .pickerStyle(.menu)
    }
}
