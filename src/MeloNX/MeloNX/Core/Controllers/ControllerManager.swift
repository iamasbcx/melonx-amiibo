//
//  ControllerManager.swift
//  MeloNX
//
//  Created by Stossy11 on 19/10/2025.
//

import Foundation
import Combine
import GameController
import SwiftUI

class ControllerManager: ObservableObject {
    static var shared = ControllerManager()
    let virtualController = BaseController(nativeController: nil)
    @AppStorage("isVirtualController") var isVCA: Bool = true

    private let controllerQueue = DispatchQueue(label: "com.stossy11.melonx.controllermanager", attributes: .concurrent)

    private var _privAllControllers: [BaseController] = []
    /// 仅 controllerQueue 访问；保留设备引用直到解绑，防止断开时指针提前释放。
    private struct AttachedController {
        let controller: BaseController
        let playerIndex: Int
        let type: ControllerType
    }
    private var attachedControllers: [String: AttachedController] = [:]
    @Published var allControllers: [BaseController] = []

    @Published var selectedControllers: [String] = []
    private var didInitControllerObservers = false
    private let scopeLock = NSLock()
    private var _activeGameId: String?

    var activeGameId: String? {
        scopeLock.lock()
        defer { scopeLock.unlock() }
        return _activeGameId
    }

    @Published private(set) var hasPhysicalController = false

    private var menuListeners: [(id: UUID, handler: (MenuNavigation) -> Void)] = []
    private var menuNavigator: MenuNavigator?


    func initAll() {
        refreshControllersList()
        initControllerObservers()
        SteamControllerBackend.shared.start()
    }

    private init() {
        // 虚拟手柄是固定的应用级对象，必须在 init 返回前加入内部列表。
        // 原实现异步追加，快速启动游戏时 attachAllControllers 可能先看到空列表。
        _privAllControllers = [virtualController]
        allControllers = [virtualController]
    }


    func refreshControllersList() {
        let connectedNativeControllers = GCController.controllers()
        let connectedSet = Set(connectedNativeControllers)
        let steamControllers = Thread.isMainThread ? SteamControllerBackend.shared.controllers : DispatchQueue.main.sync { SteamControllerBackend.shared.controllers }

        controllerQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }

            var controllersToRemove: [BaseController] = []
            for controller in self._privAllControllers where !controller.virtual {
                if let steam = controller as? SteamController {
                    if !steamControllers.contains(where: { $0 === steam }) {
                        controllersToRemove.append(controller)
                    }
                    continue
                }
                if let native = controller.nativeController, !connectedSet.contains(native) {
                    controllersToRemove.append(controller)
                }
            }

            for controller in controllersToRemove {
                controller.cleanup()
                self._privAllControllers.removeAll { $0 === controller }
            }

            for nativeController in connectedNativeControllers {
                if !self._privAllControllers.contains(where: { $0.nativeController === nativeController }) {
                    let newController = NativeController(nativeController: nativeController)
                    self._privAllControllers.append(newController)
                }
            }

            for controller in steamControllers where !self._privAllControllers.contains(where: { $0 === controller }) {
                self._privAllControllers.append(controller)
            }

            let virtualControllers = self._privAllControllers.filter { $0.virtual }
            let physical = self._privAllControllers
                .filter { !$0.virtual }
                .sorted { lhs, rhs in
                    let lhsIndex = connectedNativeControllers.firstIndex { $0 === lhs.nativeController } ?? (connectedNativeControllers.count + (steamControllers.firstIndex { $0 === lhs } ?? steamControllers.count))
                    let rhsIndex = connectedNativeControllers.firstIndex { $0 === rhs.nativeController } ?? (connectedNativeControllers.count + (steamControllers.firstIndex { $0 === rhs } ?? steamControllers.count))
                    return lhsIndex < rhsIndex
                }
            self._privAllControllers = virtualControllers + physical

            // Full Keyboard Support may come eventually, i'm just too lazy :3
            // _privAllControllers.append(KBController()) // This was just an experiment, yes it did work, no i'm not bothered to fully implement it.

            let controllers = Array(self._privAllControllers.prefix(7))

            DispatchQueue.main.async {
                self.allControllers = controllers
                // 刷新完成时读取最新运行范围，避免启动/关闭设置期间的异步结果覆盖新范围。
                let selectedControllerIds = self.resolvedControllerIds(controllers: controllers, gameId: self.activeGameId)
                self.selectedControllers = selectedControllerIds
                self.hasPhysicalController = controllers.contains { !$0.virtual }
                if RyujinxController.shared.isRunning.isRunning(), !RyujinxController.shared.isStopping {
                    self.attachAllControllers(selectedControllerIds: selectedControllerIds)
                }
            }
        }
    }

    func attachAllControllers() {
        guard !RyujinxController.shared.isStopping else { return }
        let selectedControllerIds = controllerQueue.sync {
            resolvedControllerIds(controllers: Array(_privAllControllers.prefix(7)), gameId: activeGameId)
        }
        DispatchQueue.main.async { [weak self] in self?.selectedControllers = selectedControllerIds }
        attachAllControllers(selectedControllerIds: selectedControllerIds)
    }

    /// 启动前只激活缓存，禁止在 native 输入系统就绪前调用 attach 或键盘接口。
    func activateInputProfile(gameId: String?) {
        let gameId = ControllerInputProfile.normalizedGameId(gameId)
        scopeLock.lock()
        _activeGameId = gameId
        scopeLock.unlock()
        ControllerMappingStore.shared.activate(gameId: gameId)
    }

    /// 在主线程、游戏仍暂停时应用设置；所有编辑页退出后统一由此恢复输入。
    func applyInputProfile(gameId: String?) {
        precondition(Thread.isMainThread)
        activateInputProfile(gameId: gameId)
        selectedControllers = selectedControllerIds(gameId: activeGameId)
        guard RyujinxController.shared.isRunning.isRunning(), !RyujinxController.shared.isStopping else { return }
        Ryujinx.setKeyboardConfig(pullKeyboardConfig(gameId: activeGameId))
        attachAllControllers(selectedControllerIds: selectedControllers)
    }

    func selectedControllerIds(gameId: String?) -> [String] {
        resolvedControllerIds(controllers: allControllers, gameId: gameId)
    }

    func selectController(_ controller: BaseController, gameId: String?) {
        var ids = selectedControllerIds(gameId: gameId)
        guard !ids.contains(controller.id) else { return }
        ids.append(controller.id)
        persistSelection(ids, gameId: gameId)
    }

    func deselectController(_ controller: BaseController, gameId: String?) {
        persistSelection(selectedControllerIds(gameId: gameId).filter { $0 != controller.id }, gameId: gameId)
    }

    private func persistentKeys(controllers: [BaseController]) -> [String: String] {
        var counts: [String: Int] = [:]
        var keys: [String: String] = [:]
        for controller in controllers {
            let name = ControllerMappingStore.key(for: controller)
            let index = counts[name, default: 0]
            counts[name] = index + 1
            keys[controller.id] = controller.virtual ? "virtual" : "\(name)#\(index)"
        }
        return keys
    }

    private func resolvedControllerIds(controllers: [BaseController], gameId: String?) -> [String] {
        let off = ControllerInputProfile.virtualControllerOff(gameId: gameId)
        if let saved = ControllerInputProfile.selection(gameId: gameId) {
            let keys = persistentKeys(controllers: controllers)
            var ids = saved.compactMap { savedKey in controllers.first(where: { keys[$0.id] == savedKey })?.id }
            if off { ids.removeAll { $0 == virtualController.id } }
            if !off, !ids.contains(virtualController.id) { ids.append(virtualController.id) }
            return ids
        }
        let physical = controllers.filter { !$0.virtual }.map(\.id)
        return physical.isEmpty && !off ? [virtualController.id] : physical
    }

    private func persistSelection(_ ids: [String], gameId: String?) {
        precondition(Thread.isMainThread)
        let keys = persistentKeys(controllers: allControllers)
        ControllerInputProfile.setSelection(ids.compactMap { keys[$0] }, gameId: gameId)
        let suffix = ControllerInputProfile.normalizedGameId(gameId) ?? ""
        UserDefaults.standard.set(!ids.contains(virtualController.id), forKey: "virtualControllerOffDefault" + suffix)
        objectWillChange.send()
        if !RyujinxController.shared.isRunning.isRunning() { applyInputProfile(gameId: nil) }
    }

    private func attachAllControllers(selectedControllerIds: [String]) {
        let gameId = activeGameId
        controllerQueue.sync(flags: .barrier) {
            var desired: [String: AttachedController] = [:]
            var playerIndex = 0
            for controllerId in selectedControllerIds {
                guard let cont = _privAllControllers.first(where: { $0.id == controllerId }) else { continue }
                let resolvedType = ControllerInputProfile.type(index: playerIndex, gameId: gameId)
                desired[controllerId] = AttachedController(controller: cont, playerIndex: playerIndex, type: resolvedType)
                playerIndex += 1
            }

            // 标量参数和布局变化不重新创建 native 运动设备，保留陀螺仪姿态与重力基准。
            for (id, attached) in attachedControllers {
                if let next = desired[id], next.playerIndex == attached.playerIndex, next.type == attached.type { continue }
                Ryujinx.detachGamepad(attached.controller.pointer)
            }
            for id in selectedControllerIds {
                guard let next = desired[id] else { continue }
                if let previous = attachedControllers[id], previous.playerIndex == next.playerIndex, previous.type == next.type {
                    if let native = next.controller as? NativeController {
                        let mapping = ControllerMappingStore.shared.runtimeMapping(for: native)
                        if native.activeMapping != mapping {
                            let motionChanged = native.activeMapping.motionEnabled != mapping.motionEnabled
                            native.applyMapping(mapping)
                            if motionChanged { native.refreshMotion() }
                        }
                    }
                } else {
                    next.controller.controllerType = next.type
                    next.controller.attach(next.playerIndex, controllerType: next.type)
                }
            }
            attachedControllers = desired
        }
    }

    /// 在模拟线程完成退出后解绑所有输入设备，避免旧窗口已销毁时仍向 native 层发送输入。
    func detachAllControllers() {
        controllerQueue.sync(flags: .barrier) {
            for attached in attachedControllers.values { Ryujinx.detachGamepad(attached.controller.pointer) }
            attachedControllers.removeAll()
        }
    }


    var resolvedSelection: [(id: String, controller: BaseController)] {
        selectedControllers.compactMap { id in
            guard let controller = allControllers.first(where: { $0.id == id }) else { return nil }

            return (id, controller)
        }
    }

    private func selectedControllerIdsSnapshot() -> [String] {
        if Thread.isMainThread {
            return selectedControllers
        }

        return DispatchQueue.main.sync {
            selectedControllers
        }
    }

    func controllerAndIndexForString(_ id: String) -> (BaseController, Int)? {
        return controllerQueue.sync {
            guard let controller = _privAllControllers.first(where: { $0.id == id }),
                  let index = _privAllControllers.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            return (controller, index)
        }
    }

    func controllerForString(_ id: String) -> BaseController? {
        return controllerQueue.sync {
            return _privAllControllers.first(where: { $0.id == id })
        }
    }

    func firstControllerForName(_ name: String) -> BaseController? {
        return controllerQueue.sync {
            return _privAllControllers.first(where: { $0.nativeController?.vendorName ?? UUID().uuidString == name })
        }
    }

    func hasVirtualController() -> Bool {
        let selectedControllerIds = selectedControllerIdsSnapshot()

        return controllerQueue.sync {
            return selectedControllerIds.contains(_privAllControllers.first(where: { $0.virtual })?.id ?? "Failed to find virtual controller!")
        }
    }

    func initControllerObservers() {
        guard !didInitControllerObservers else { return }
        didInitControllerObservers = true

        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.1) {
                self.refreshControllersList()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.1) {
                self.refreshControllersList()
            }
        }
    }

    @MainActor
    func beginMenuNavigation(_ id: UUID, handler: @escaping (MenuNavigation) -> Void) {
        if let index = menuListeners.firstIndex(where: { $0.id == id }) {
            menuListeners[index].handler = handler
        } else {
            menuListeners.append((id, handler))
        }

        syncMenuNavigation()
    }

    @MainActor
    func endMenuNavigation(_ id: UUID) {
        menuListeners.removeAll { $0.id == id }

        syncMenuNavigation()
    }

    @MainActor
    private func syncMenuNavigation() {
        guard !menuListeners.isEmpty else {
            menuNavigator?.stop()
            menuNavigator = nil

            return
        }

        let navigator = menuNavigator ?? MenuNavigator()

        menuNavigator = navigator

        navigator.start { [weak self] event in
            self?.menuListeners.last?.handler(event)
        }
    }

    func toggleController(_ baseController: BaseController) {
        if selectedControllers.contains(baseController.id) {
            deselectController(baseController, gameId: activeGameId)
        } else {
            selectController(baseController, gameId: activeGameId)
        }
        applyInputProfile(gameId: activeGameId)
    }
}
