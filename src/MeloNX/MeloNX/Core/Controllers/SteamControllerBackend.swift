//
//  SteamControllerBackend.swift
//  MeloNX
//
//  Created by Stossy11 on 02/10/2026.
//

import CoreBluetooth
import Foundation
import UIKit
import Combine

/// 配对页状态只在主线程发布；蓝牙状态机仍由专用串行队列持有。
@MainActor final class SteamControllerDiscoveryState: ObservableObject {
    @Published var isDiscovering = false
    @Published var message = "点击搜索，将 Steam 手柄置于蓝牙配对模式。"
}

nonisolated final class SteamControllerBackend: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    @MainActor static let shared = SteamControllerBackend(discovery: SteamControllerDiscoveryState())
    
    @MainActor private(set) var controllers: [SteamController] = []
    @MainActor let discovery: SteamControllerDiscoveryState
    
    private let queue = DispatchQueue(label: "com.stossy11.melonx.steam-ble", qos: .userInteractive)
    
    private var central: CBCentralManager?
    private var sessions: [UUID: SteamBLESession] = [:]
    private var retryAfter: [UUID: TimeInterval] = [:]
    private var scanWork: DispatchWorkItem?
    private var foreground = true
    private var discoveryPolicy = SteamDiscoveryPolicy()
    private var reconnectWork: [UUID: DispatchWorkItem] = [:]
    private var reconnectAttempts: [UUID: Int] = [:]
    
    @MainActor private var started = false
    @MainActor private var observers: [NSObjectProtocol] = []
    
    private let knownKey = "steamControllerBLEIdentifiers"
    private static let service = CBUUID(string: "100F6C32-1735-4313-B402-38567131E5F3")

    /// 显式在主线程构造发布给 SwiftUI 的状态，蓝牙状态机实例随后仅通过 queue 使用。
    @MainActor private init(discovery: SteamControllerDiscoveryState) {
        self.discovery = discovery
        super.init()
    }
    
    @MainActor func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        
        guard !started else { return }
        
        started = true
        
        let active = UIApplication.shared.applicationState != .background
        
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.queue.async { [weak self] in self?.suspend() } })
        
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.foreground = true
                self.discoveryPolicy.foreground = true
                self.reconnectKnownControllers()
            }
        })
        
        
        queue.async {
            self.foreground = active
            self.discoveryPolicy.foreground = active
            self.central = CBCentralManager(delegate: self, queue: self.queue,
                                            options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }
    
    /// 自动路径只连接缓存标识；没有用户发起配对时不扫描周围所有广播。
    private func reconnectKnownControllers() {
        let known = (UserDefaults.standard.stringArray(forKey: knownKey) ?? []).compactMap(UUID.init(uuidString:))
        guard discoveryPolicy.shouldReconnect(knownDeviceCount: known.count), let central else { return }
        for peripheral in central.retrievePeripherals(withIdentifiers: known) { connect(peripheral) }
        for peripheral in central.retrieveConnectedPeripherals(withServices: [Self.service]) {
            if known.contains(peripheral.identifier) { connect(peripheral) }
        }
    }

    @MainActor func beginPairing() {
        start()
        queue.async { [weak self] in
            guard let self else { return }
            self.discoveryPolicy.pairingRequested = true
            self.beginScan()
        }
    }

    @MainActor func endPairing() {
        queue.async { [weak self] in self?.stopDiscovery(message: "搜索已停止，已连接手柄仍可使用。") }
    }

    private func publishDiscovery(_ scanning: Bool, _ message: String) {
        Task { @MainActor [weak self] in
            self?.discovery.isDiscovering = scanning
            self?.discovery.message = message
        }
    }

    private func stopDiscovery(message: String) {
        discoveryPolicy.pairingRequested = false
        scanWork?.cancel()
        scanWork = nil
        central?.stopScan()
        publishDiscovery(false, message)
    }

    private func beginScan() {
        guard discoveryPolicy.shouldScan, let central else {
            if central == nil || central?.state == .unknown || central?.state == .resetting {
                publishDiscovery(true, "正在初始化蓝牙，请稍候；可以随时停止搜索。")
            } else {
                discoveryPolicy.pairingRequested = false
                publishDiscovery(false, "请开启蓝牙并允许此应用访问蓝牙，然后重试搜索。")
            }
            return
        }
        scanWork?.cancel()
        // 显式发现仍兼容不广播 Valve 服务的设备，但禁止重复广播回调。
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        publishDiscovery(true, "正在搜索 Steam 手柄，请保持手柄处于蓝牙配对模式。")
        let stop = DispatchWorkItem { [weak self] in
            self?.stopDiscovery(message: "本次搜索已结束。未找到时可再次搜索，并确认手柄处于配对模式。")
        }
        scanWork = stop
        queue.asyncAfter(deadline: .now() + 30, execute: stop)
    }
    
    private func suspend() {
        foreground = false
        discoveryPolicy.foreground = false
        stopDiscovery(message: "应用进入后台，搜索已停止。")
        for work in reconnectWork.values { work.cancel() }
        reconnectWork.removeAll()
        for session in Array(sessions.values) {
            removeController(session)
            session.shutdown { [weak self, weak session] in
                guard let self, let session else { return }
                self.central?.cancelPeripheralConnection(session.peripheral)
            }
        }
    }
    
    private func connect(_ peripheral: CBPeripheral) {
        guard foreground, sessions[peripheral.identifier] == nil, sessions.count < 8,
              (retryAfter[peripheral.identifier] ?? 0) <= ProcessInfo.processInfo.systemUptime else { return }
        
        let session = SteamBLESession(peripheral: peripheral, queue: queue)
        
        sessions[peripheral.identifier] = session
        
        session.onReady = { [weak self, weak session] in
            guard let self, let session, self.foreground,
                  self.sessions[peripheral.identifier] === session else { return }
            
            var known = UserDefaults.standard.stringArray(forKey: self.knownKey) ?? []
            
            if !known.contains(peripheral.identifier.uuidString) {
                known.append(peripheral.identifier.uuidString)
                UserDefaults.standard.set(Array(known.suffix(8)), forKey: self.knownKey)
            }
            self.reconnectAttempts[peripheral.identifier] = nil
            self.reconnectWork.removeValue(forKey: peripheral.identifier)?.cancel()
            if self.discoveryPolicy.pairingRequested { self.stopDiscovery(message: "Steam 手柄已连接，可在手柄选择中添加。") }
            
            let identifier = peripheral.identifier
            
            DispatchQueue.main.async { [session] in
                let controller = SteamController(peripheralID: identifier,
                                                 setMotionEnabled: { [weak session] enabled in
                    self.queue.async { [weak session] in session?.setMotion(enabled) }
                }, sendRumble: { [weak session] data in
                    self.queue.async { [weak session] in session?.rumble(data) }
                }, stopRumble: { [weak session] in
                    self.queue.async { [weak session] in session?.stopRumble() }
                })
                
                self.controllers.append(controller)
                
                ControllerManager.shared.refreshControllersList()
                
                self.queue.async {
                    guard self.sessions[identifier] === session, !session.stopping else { return }
                    session.controller = controller
                    session.deliverLatestState()
                }
            }
        }
        session.onFailure = { [weak self, weak session] reason in
            guard let self, let session, self.sessions[peripheral.identifier] === session else { return }
            NSLog("Steam Controller BLE: %@", reason)
            session.invalidate()
            self.removeController(session)
            
            self.retryAfter[peripheral.identifier] = ProcessInfo.processInfo.systemUptime + 15
            self.central?.cancelPeripheralConnection(peripheral)
        }
        central?.connect(peripheral)
        session.armConnectionTimeout()
    }
    
    private func removeController(_ session: SteamBLESession) {
        session.controller = nil
        let identifier = session.peripheral.identifier
        
        DispatchQueue.main.async {
            let removed = self.controllers.filter { $0.peripheralID == identifier }
            guard !removed.isEmpty else { return }
            
            self.controllers.removeAll { $0.peripheralID == identifier }
            
            for controller in removed { controller.cleanup() }
            
            ControllerManager.shared.refreshControllersList()
        }
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        NSLog("Steam Controller BLE: central state %ld.", central.state.rawValue)
        if central.state == .poweredOn {
            discoveryPolicy.bluetoothReady = true
            reconnectKnownControllers()
            if discoveryPolicy.pairingRequested { beginScan() }
        } else {
            discoveryPolicy.bluetoothReady = false
            // 初始化/重置是过渡态，保留用户刚发起的请求，poweredOn 后自动开始本次搜索。
            if central.state == .unknown || central.state == .resetting {
                scanWork?.cancel()
                scanWork = nil
                central.stopScan()
                publishDiscovery(discoveryPolicy.pairingRequested, "正在初始化蓝牙，请稍候。")
            } else {
                stopDiscovery(message: central.state == .unauthorized ? "蓝牙权限未允许，请在系统设置中开启。" : "蓝牙不可用，请开启蓝牙后重新搜索。")
            }
            for work in reconnectWork.values { work.cancel() }
            reconnectWork.removeAll()
            
            for session in sessions.values {
                session.invalidate()
                removeController(session)
            }
            
            sessions.removeAll()
            retryAfter.removeAll()
            if central.state == .unauthorized {
                NSLog("Steam Controller BLE: Bluetooth permission is unavailable.")
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard discoveryPolicy.shouldScan else { return }
        let names = [advertisementData[CBAdvertisementDataLocalNameKey] as? String, peripheral.name].compactMap { $0 }
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        
        guard names.contains(where: { $0.lowercased().hasPrefix("steam") }) || services.contains(Self.service) else { return }
        
        
        connect(peripheral)
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard foreground, let session = sessions[peripheral.identifier], !session.stopping else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        NSLog("Steam Controller BLE: connected; discovering Valve service.")
        peripheral.discoverServices([Self.service])
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        NSLog("Steam Controller BLE: connection failed: %@", error?.localizedDescription ?? "unknown error")
        disconnected(peripheral)
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        NSLog("Steam Controller BLE: disconnected: %@", error?.localizedDescription ?? "connection closed")
        disconnected(peripheral)
    }
    
    private func disconnected(_ peripheral: CBPeripheral) {
        guard let session = sessions.removeValue(forKey: peripheral.identifier) else { return }
        session.invalidate()
        removeController(session)
        retryAfter[peripheral.identifier] = ProcessInfo.processInfo.systemUptime + 5
        scheduleKnownReconnect(peripheral.identifier)
    }

    private func scheduleKnownReconnect(_ id: UUID) {
        let known = UserDefaults.standard.stringArray(forKey: knownKey) ?? []
        guard known.contains(id.uuidString), discoveryPolicy.shouldReconnect(knownDeviceCount: known.count) else { return }
        reconnectWork[id]?.cancel()
        let attempt = reconnectAttempts[id, default: 0]
        reconnectAttempts[id] = attempt + 1
        let delay = SteamDiscoveryPolicy.reconnectDelay(attempt: attempt)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.discoveryPolicy.shouldReconnect(knownDeviceCount: 1), let central = self.central else { return }
            self.reconnectWork[id] = nil
            if let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first { self.connect(peripheral) }
        }
        reconnectWork[id] = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

private nonisolated final class SteamBLESession: NSObject, CBPeripheralDelegate, @unchecked Sendable {
    let peripheral: CBPeripheral
    let queue: DispatchQueue
    weak var controller: SteamController?
    var onReady: (() -> Void)?
    var onFailure: ((String) -> Void)?
    private(set) var latestState: SteamControllerState?
    private(set) var stopping = false
    private var decoder = SteamControllerDecoder()
    
    private var reportID: UInt8 = 0
    private var input: CBCharacteristic?
    private var output: CBCharacteristic?
    private var rumbleOutput: CBCharacteristic?
    private var configuring = false
    private var configured = false
    private var motionEnabled = false
    private var loggedInput = false
    private var loggedRumbleError = false
    private var timeout: DispatchWorkItem?
    private var writeTimeout: DispatchWorkItem?
    private var closeCompletion: (() -> Void)?
    private var keepAliveTimer: DispatchSourceTimer?
    private var rumbleTimer: DispatchSourceTimer?
    private var rumbleUntil: TimeInterval = 0
    private var rumblePayload: Data?
    
    private enum Purpose { case lizard, motion, rumble }
    private struct Write {
        let characteristic: CBCharacteristic
        let data: Data
        let purpose: Purpose
    }
    private var writes: [Write] = []
    private var inFlight: Write?
    
    private static let serviceUUID = CBUUID(string: "100F6C32-1735-4313-B402-38567131E5F3")
    private static let input45 = CBUUID(string: "100F6C7A-1735-4313-B402-38567131E5F3")
    private static let input47 = CBUUID(string: "100F6C7C-1735-4313-B402-38567131E5F3")
    private static let outputUUID = CBUUID(string: "100F6C34-1735-4313-B402-38567131E5F3")
    
    // Valve maps output report IDs to characteristic suffix 0x35 + report ID.
    private static let rumbleUUID = CBUUID(string: "100F6CB5-1735-4313-B402-38567131E5F3")
    
    init(peripheral: CBPeripheral, queue: DispatchQueue) {
        self.peripheral = peripheral
        self.queue = queue
        super.init()
        peripheral.delegate = self
    }
    
    func armConnectionTimeout() {
        let work = DispatchWorkItem { [weak self] in self?.fail("Connection or pairing timed out.") }
        timeout = work
        queue.asyncAfter(deadline: .now() + 60, execute: work)
    }
    
    func invalidate() {
        stopping = true
        timeout?.cancel()
        writeTimeout?.cancel()
        
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        rumbleTimer?.cancel()
        rumbleTimer = nil
        
        writes.removeAll()
        
        inFlight = nil
        controller = nil
        peripheral.delegate = nil
        closeCompletion = nil
    }
    
    func shutdown(_ completion: @escaping () -> Void) {
        guard !stopping else { completion(); return }
        
        stopping = true
        timeout?.cancel()
        
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        rumbleTimer?.cancel()
        rumbleTimer = nil
        
        writes.removeAll()
        
        if configured, let output {
            if let rumbleOutput {
                writes.append(Write(characteristic: rumbleOutput, data: SteamControllerProtocol.rumble(left: 0, right: 0), purpose: .rumble))
            }
            
            writes.append(Write(characteristic: output, data: SteamControllerProtocol.setting(48, value: 0), purpose: .motion))
            
            writes.append(Write(characteristic: output, data: SteamControllerProtocol.setting(9, value: 1), purpose: .lizard))
        }
        
        closeCompletion = completion
        let work = DispatchWorkItem { [weak self] in self?.finishClosing() }
        
        timeout = work
        queue.asyncAfter(deadline: .now() + 1, execute: work)
        writeNext()
    }
    
    private func finishClosing() {
        guard let completion = closeCompletion else { return }
        closeCompletion = nil
        timeout?.cancel()
        writeTimeout?.cancel()
        completion()
    }
    
    private func fail(_ message: String) {
        if stopping { finishClosing() } else { onFailure?(message) }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard !stopping else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            fail("Valve service discovery failed: \(error?.localizedDescription ?? "service missing")"); return
        }
        
        NSLog("Steam Controller BLE: found Valve service; discovering characteristics.")
        peripheral.discoverCharacteristics([Self.input45, Self.input47, Self.outputUUID, Self.rumbleUUID], for: service)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard !stopping else { return }
        let characteristics = service.characteristics ?? []
        NSLog("Steam Controller BLE: characteristics %@", characteristics.map { $0.uuid.uuidString }.joined(separator: ", "))
        
        input = characteristics.first { $0.uuid == Self.input47 } ?? characteristics.first { $0.uuid == Self.input45 }
        output = characteristics.first { $0.uuid == Self.outputUUID }
        
        rumbleOutput = characteristics.first { $0.uuid == Self.rumbleUUID && $0.properties.contains(.write) }
        
        guard error == nil, let input, let output,
              input.properties.contains(.notify), output.properties.contains(.write) else {
            fail("New Steam Controller input/configuration characteristics are missing."); return
        }
        
        reportID = input.uuid == Self.input47 ? 0x47 : 0x45
        
        peripheral.setNotifyValue(true, for: input)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard !stopping, characteristic === input else { return }
        guard error == nil, characteristic.isNotifying else {
            fail("Could not subscribe to input: \(error?.localizedDescription ?? "notifications disabled")"); return
        }
        
        NSLog("Steam Controller BLE: subscribed to report 0x%02x; configuring.", Int(reportID))
        
        configure()
    }
    
    private func configure() {
        guard !configuring, !configured, !stopping, let output else { return }
        configuring = true
        
        // Triton uses raw feature payloads
        writes = [
            Write(characteristic: output, data: SteamControllerProtocol.disableLizardMode, purpose: .lizard),
            // 初次连接只启用按键；当前游戏实际绑定且需要运动时才打开传感器。
            Write(characteristic: output, data: SteamControllerProtocol.setting(48, value: 0), purpose: .motion),
        ]
        
        writeNext()
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !stopping, characteristic === input else { return }
        
        guard error == nil, let data = characteristic.value else { fail("Input notification failed."); return }
        
        if !loggedInput {
            loggedInput = true
            NSLog("Steam Controller BLE: first 0x%02x input (%ld bytes).", Int(reportID), data.count)
        }
        
        guard let state = decoder.decode(data, reportID: reportID) else { return }
        
        latestState = state
        configure()
        deliverLatestState()
    }
    
    func deliverLatestState() {
        guard let state = latestState, let controller else { return }
        
        DispatchQueue.main.async { [weak controller] in controller?.receive(state) }
    }
    
    private func writeNext() {
        guard inFlight == nil else { return }
        
        guard !writes.isEmpty else {
            if stopping { finishClosing() }
            
            else if configuring {
                configuring = false
                configured = true
                
                timeout?.cancel()
                
                startKeepAliveTimer()
                onReady?()
            }
            return
        }
        
        guard peripheral.state == .connected else { fail("Disconnected during output."); return }
        
        let write = writes.removeFirst()
        
        guard write.data.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
            fail("Controller's negotiated write length is too small for a feature report."); return
        }
        
        inFlight = write
        
        peripheral.writeValue(write.data, for: write.characteristic, type: .withResponse)
        
        let work = DispatchWorkItem { [weak self] in self?.fail("Controller write timed out.") }
        
        writeTimeout = work
        queue.asyncAfter(deadline: .now() + 5, execute: work)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let write = inFlight, characteristic === write.characteristic else { return }
        
        writeTimeout?.cancel()
        inFlight = nil
        
        if let error {
            if write.purpose == .rumble {
                if !loggedRumbleError { NSLog("Steam Controller BLE: rumble unavailable: %@", error.localizedDescription) }
                
                loggedRumbleError = true
                rumblePayload = nil
                rumbleTimer?.cancel()
                rumbleTimer = nil
                
                writes.removeAll { $0.purpose == .rumble }
            } else {
                fail("Controller rejected configuration: \(error.localizedDescription)")
                return
            }
        }
        writeNext()
    }
    
    private func enqueue(_ data: Data, on characteristic: CBCharacteristic, purpose: Purpose) {
        writes.removeAll { $0.purpose == purpose }
        writes.append(Write(characteristic: characteristic, data: data, purpose: purpose))
        writeNext()
    }
    
    private func startKeepAliveTimer() {
        keepAliveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, self.configured, !self.stopping, let output = self.output else { return }
            self.enqueue(SteamControllerProtocol.disableLizardMode, on: output, purpose: .lizard)
        }
        keepAliveTimer = timer
        timer.resume()
    }

    private func startRumbleTimer() {
        guard rumbleTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(40), repeating: .milliseconds(40), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.updateRumble() }
        rumbleTimer = timer
        timer.resume()
    }

    private func updateRumble() {
        guard configured, !stopping else { return }
        guard let payload = rumblePayload, let rumbleOutput,
              ProcessInfo.processInfo.systemUptime < rumbleUntil else { stopRumble(); return }
        enqueue(payload, on: rumbleOutput, purpose: .rumble)
    }

    func stopRumble() {
        let wasActive = rumblePayload != nil || rumbleTimer != nil
        rumblePayload = nil
        rumbleTimer?.cancel()
        rumbleTimer = nil
        guard wasActive, configured, !stopping, !loggedRumbleError, let rumbleOutput else { return }
        enqueue(SteamControllerProtocol.rumble(left: 0, right: 0), on: rumbleOutput, purpose: .rumble)
    }

    func setMotion(_ enabled: Bool) {
        guard configured, !stopping, enabled != motionEnabled, let output else { return }
        motionEnabled = enabled
        enqueue(SteamControllerProtocol.setting(48, value: enabled ? 0x18 : 0), on: output, purpose: .motion)
    }
    
    func rumble(_ data: RumbleData) {
        guard configured, !stopping, !loggedRumbleError, let rumbleOutput else { return }
        
        let payload = SteamControllerProtocol.rumble(left: data.lowFrequency, right: data.highFrequency)
        let active = InputPowerPolicy.hasVibration(durationMs: data.durationMs, amplitudes: [data.lowFrequency, data.highFrequency])
        
        rumbleUntil = ProcessInfo.processInfo.systemUptime + Double(data.durationMs) / 1000
        rumblePayload = active ? payload : nil
        if active { startRumbleTimer() } else { rumbleTimer?.cancel(); rumbleTimer = nil }
        
        enqueue(active ? payload : SteamControllerProtocol.rumble(left: 0, right: 0), on: rumbleOutput, purpose: .rumble)
    }
}
