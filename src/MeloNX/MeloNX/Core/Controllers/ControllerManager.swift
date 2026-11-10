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
    @Published var allControllers: [BaseController] = []

    @Published var selectedControllers: [String] = []
    private var didInitControllerObservers = false

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


    func refreshControllersList(_ inGameSelector: Bool = false) {
        let nativeSettingsManager: NativeSettingsManager = .shared
        let connectedNativeControllers = GCController.controllers()
        let connectedSet = Set(connectedNativeControllers)
        let steamControllers = Thread.isMainThread ? SteamControllerBackend.shared.controllers : DispatchQueue.main.sync { SteamControllerBackend.shared.controllers }
        let previousSelection = selectedControllerIdsSnapshot()

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

            let physicalControllers = self._privAllControllers.prefix(7).filter { !$0.virtual }.compactMap(\.id) as [String]
            let controllers = Array(self._privAllControllers.prefix(7))
            var selectedControllerIds: [String]

            // 游戏运行期间设备连接/断开只刷新可用列表，不应把用户当前选择重置为
            // 物理手柄列表，否则虚拟手柄会在后台刷新后从 UI 和底层 attach 列表消失。
            let preserveSelection = inGameSelector || RyujinxController.shared.isRunning.isRunning()
            if preserveSelection {
                let known = Set(self._privAllControllers.map(\.id))
                selectedControllerIds = previousSelection.filter { known.contains($0) }
                if selectedControllerIds.isEmpty, !self.virtualControllerDefaultOff {
                    selectedControllerIds = [self.virtualController.id]
                }
            } else if !nativeSettingsManager.virtualControllerOffDefault(ProcessInfo.processInfo.isiOSAppOnMac).value {
                selectedControllerIds = physicalControllers.isEmpty ? [self.virtualController.id] : physicalControllers
            } else {
                selectedControllerIds = physicalControllers
            }

            DispatchQueue.main.async {
                self.allControllers = controllers
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
        var selectedControllerIds = selectedControllerIdsSnapshot()
        // refreshControllersList 使用后台队列，启动很快时可能尚未回写选择列表。
        // 只有“默认启用虚拟手柄”时才补齐，用户明确关闭默认选择后仍保持空列表。
        if selectedControllerIds.isEmpty, !virtualControllerDefaultOff {
            selectedControllerIds = [virtualController.id]
            DispatchQueue.main.async { [weak self] in
                self?.selectedControllers = selectedControllerIds
            }
        }
        attachAllControllers(selectedControllerIds: selectedControllerIds)
    }

    /// 更新当前选择的控制器，并在游戏运行时立即重新绑定到底层输入系统。
    /// 虚拟手柄的对象 ID 由内存地址生成，不能直接持久化；选择虚拟手柄时同步保存
    /// 现有的“默认取消选择虚拟手柄”开关，应用重启后由刷新流程恢复选择。
    func selectController(_ controller: BaseController) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !self.selectedControllers.contains(controller.id) else { return }
            self.selectedControllers.append(controller.id)
            self.persistVirtualControllerSelection()
            if RyujinxController.shared.isRunning.isRunning() { self.attachAllControllers() }
        }
    }

    /// 移除当前控制器，并在游戏运行时同步解除后重新绑定控制器列表。
    func deselectController(_ controller: BaseController) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.selectedControllers.removeAll { $0 == controller.id }
            self.persistVirtualControllerSelection()
            if RyujinxController.shared.isRunning.isRunning() { self.attachAllControllers() }
        }
    }

    private func persistVirtualControllerSelection() {
        let selected = selectedControllers.contains(virtualController.id)
        // 必须通过 NativeSettingsManager 写入当前作用域。运行游戏时该对象可能绑定到
        // titleId，直接写裸 UserDefaults 会造成界面状态与游戏实际使用的设置不一致。
        NativeSettingsManager.shared.virtualControllerOffDefault(ProcessInfo.processInfo.isiOSAppOnMac).value = !selected
    }

    /// 当前作用域的“默认取消虚拟手柄”设置。游戏专属配置优先，全局配置作为回退。
    private var virtualControllerDefaultOff: Bool {
        NativeSettingsManager.shared.virtualControllerOffDefault(ProcessInfo.processInfo.isiOSAppOnMac).value
    }

    private func attachAllControllers(selectedControllerIds: [String]) {
        // 游戏运行时优先使用当前游戏配置，避免全局配置覆盖游戏专属控制器类型。
        let config = RyujinxController.shared.currentSettings
        controllerQueue.sync {
            for controller in _privAllControllers { Ryujinx.detachGamepad(controller.pointer) }
            var playerIndex = 0
            for controllerId in selectedControllerIds {
                guard let cont = _privAllControllers.first(where: { $0.id == controllerId }) else { continue }
                let configuredType = config.controllerType(for: playerIndex)
                let configuredTypeIsInvalid = configuredType == nil || configuredType?.rawValue == ControllerType.none.rawValue
                // 旧配置缺少 controllerType 时会解码为 None。虚拟手柄使用 None
                // 会被底层 Npad 当作未连接，界面仍会显示但所有按键都会被丢弃。
                let fallbackType = cont.controllerType == ControllerType.none ? ControllerType.proController : cont.controllerType
                let resolvedType = configuredTypeIsInvalid ? fallbackType : (configuredType ?? fallbackType)
                cont.controllerType = resolvedType
                cont.attach(playerIndex, controllerType: resolvedType)
                playerIndex += 1
            }
        }
    }

    /// 在模拟线程完成退出后解绑所有输入设备，避免旧窗口已销毁时仍向 native 层发送输入。
    func detachAllControllers() {
        controllerQueue.sync {
            for controller in _privAllControllers {
                Ryujinx.detachGamepad(controller.pointer)
            }
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
            deselectController(baseController)
        } else {
            selectController(baseController)
        }
    }
}
