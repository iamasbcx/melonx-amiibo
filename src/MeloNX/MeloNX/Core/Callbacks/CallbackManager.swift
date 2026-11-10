//
//  CallbackManager.swift
//  MeloNX
//
//  Created by Stossy11 on 4/4/2026.
//

import Foundation

@dynamicMemberLookup
nonisolated final class CallbackManager: @unchecked Sendable {
    private static let storage = CallbackManager()
    private let lock = NSLock()
    // 每个固定名称仅保留一个槽；即使 native 已取得旧地址，也始终有有效对象可访问。
    private var registrations: [String: CallbackHandlerSlot<CallbackData>] = [:]
    
    static subscript(dynamicMember name: String) -> (@escaping @Sendable (CallbackData) -> Void) -> Void {
        return { handler in
            register(name: name, handler: handler)
        }
    }
    
    /// 回调在 native 调用线程同步执行；借用 packet 指针不得被异步任务持有，UI 更新须先复制数据。
    static func register(name: String, handler: @escaping @Sendable (CallbackData) -> Void) {
        slot(for: name).replace(handler)
    }

    private static func slot(for name: String) -> CallbackHandlerSlot<CallbackData> {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        if let box = storage.registrations[name] { return box }
        let box = CallbackHandlerSlot<CallbackData>()
        storage.registrations[name] = box
        let userData = Unmanaged.passUnretained(box).toOpaque()
        
        let fn: DataCallbackFn = { rawPtr, userData in
            guard let userData else { return }
            let box = Unmanaged<CallbackHandlerSlot<CallbackData>>.fromOpaque(userData).takeUnretainedValue()
            let data = rawPtr.map { $0.load(as: CallbackData.self) } ?? CallbackData(ptr: nil, len: 0)
            box.invoke(data)
        }
        
        name.withCString { RegisterCallback($0, fn, userData) }
        return box
    }
    
    static func unregister(name: String) {
        storage.lock.lock()
        let box = storage.registrations[name]
        storage.lock.unlock()
        // 入口常驻，仅关闭分发；native 已取到的地址仍然有效，重新启用不再注册第二次。
        box?.replace(nil)
    }
}
