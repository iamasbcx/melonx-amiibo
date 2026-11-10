//
//  Untitled.swift
//  MeloNX
//
//  Created by Stossy11 on 21/12/2024.
//

import SwiftUI
import Combine

@MainActor
class MemoryUsageMonitor: ObservableObject {
    @Published private(set) var memoryUsage: UInt64 = 0
    @Published private(set) var donatedMemory: UInt64 = 0
    private var task: Task<Void, Never>?
    
    init() {
        task = Task {
            await monitorMemoryUsage()
        }
    }
    
    deinit {
        task?.cancel()
    }
    
    private func monitorMemoryUsage() async {
        while !Task.isCancelled {
            updateMemoryUsage()
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
    
    private func updateMemoryUsage() {
        var taskInfo = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride) / 4
        
        let result: kern_return_t = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        
        if result == KERN_SUCCESS {
            memoryUsage = taskInfo.phys_footprint
        } else {
            print("Failed to get memory usage: \(result)")
            memoryUsage = 0
        }
        
        donatedMemory = MLXRamDonor.sharedIfExists?.donatedBytes() ?? 0 // i'm just locked in :3
    }
    
    func formatMemorySize(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

/// 紧凑性能条：所有指标合并为一行，外观读取当前有效范围，渲染与设置预览共用同一视图。
struct PerformanceOverlayView: View {
    @StateObject private var memorymonitor = MemoryUsageMonitor()
    // 与宿主的位置/总开关共用同一设置实例，游戏缺省项由存储层回退到全局。
    @ObservedObject var nativeSettings: NativeSettingsManager
    @ObservedObject var statisticsHandler: StatisticsHandler
    
    @State private var batteryLevel: Int?

    private var summary: String {
        var items = [String(format: "FPS %.1f", statisticsHandler.fps)]
        if nativeSettings.performanceFrameTime(true).bool {
            items.append(String(format: "%.1fms", statisticsHandler.frameTime))
        }
        if nativeSettings.performanceRam(true).bool {
            items.append("RAM " + compactMemory(memorymonitor.memoryUsage))
            if memorymonitor.donatedMemory > 0 {
                items.append("扩展 " + compactMemory(memorymonitor.donatedMemory))
            }
        }
        if nativeSettings.performanceFIFO(false).bool {
            items.append(String(format: "FIFO %.1f%%", statisticsHandler.fifo))
        }
        if nativeSettings.showBatteryPercentage(false).bool, let batteryLevel {
            items.append("电量 \(batteryLevel)%")
        }
        return items.joined(separator: " · ")
    }

    private func compactMemory(_ bytes: UInt64) -> String {
        memorymonitor.formatMemorySize(bytes).replacingOccurrences(of: " ", with: "")
    }

    private func updateBatteryLevel() {
        let level = UIDevice.current.batteryLevel
        // 系统尚未提供电量时隐藏该项，不能把 -1 显示成 -100%。
        batteryLevel = (0...1).contains(level) ? Int((level * 100).rounded()) : nil
    }
    
    var body: some View {
        PerformanceOverlayLine(text: summary, appearance: PerformanceOverlayAppearance(settings: nativeSettings))
            .onAppear {
                UIDevice.current.isBatteryMonitoringEnabled = true
                updateBatteryLevel()
            }
            // 订阅随视图销毁自动取消，反复旋转或开关性能条不会积累观察者。
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification).receive(on: RunLoop.main)) { _ in
                updateBatteryLevel()
            }
    }
}

