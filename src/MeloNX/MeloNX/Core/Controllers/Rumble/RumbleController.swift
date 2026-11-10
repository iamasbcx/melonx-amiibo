//
//  RumbleController.swift
//  MeloNX
//
//  Created by MediaMoots on 2025/5/24.
//

import CoreHaptics
import Foundation

/// 主线程创建和持有对象；初始化后所有播放器、定时器及震动状态由 hapticQueue 串行访问。
/// stop 会持有对象至排队停止完成，解除绑定不会遗留循环定时器或活动播放器。
/// @unchecked Sendable 仅承诺此队列所有权：可变成员全部私有，公开输出只入队；最后一个强引用释放后析构独占资源。
nonisolated final class RumbleController: @unchecked Sendable {
    private nonisolated final class HapticChannel {
        private let engine: CHHapticEngine
        private let hapticEventDuration: TimeInterval
        private var lowHapticPlayer: CHHapticPatternPlayer?
        private var highHapticPlayer: CHHapticPatternPlayer?
        private var engineStarted = false
        var isPlaying: Bool { engineStarted && lowHapticPlayer != nil && highHapticPlayer != nil }
        
        init?(engine: CHHapticEngine?, hapticEventDuration: TimeInterval) {
            guard let engine else { return nil }
            
            self.engine = engine
            self.hapticEventDuration = hapticEventDuration
            // 未收到有效震动时不启动引擎；系统也可在空闲后自动关闭硬件资源。
            engine.isAutoShutdownEnabled = true
        }
        
        private func restart() -> Bool {
            do {
                try lowHapticPlayer?.stop(atTime: CHHapticTimeImmediate)
                try highHapticPlayer?.stop(atTime: CHHapticTimeImmediate)
                
                try engine.start()
                engineStarted = true
                try createPlayers()
                return true
            } catch {
                stop()
                NSLog("MeloNX haptics: could not start vibration: %@", error.localizedDescription)
                return false
            }
        }

        func restartIfPlaying() -> Bool {
            !engineStarted || restart()
        }
        
        func stop() {
            guard engineStarted || lowHapticPlayer != nil || highHapticPlayer != nil else { return }
            try? lowHapticPlayer?.stop(atTime: CHHapticTimeImmediate)
            try? highHapticPlayer?.stop(atTime: CHHapticTimeImmediate)
            lowHapticPlayer = nil
            highHapticPlayer = nil
            engine.stop(completionHandler: nil)
            engineStarted = false
        }
        
        func update(
            lowAmplitude: Float,
            lowFrequency: Float,
            highAmplitude: Float,
            highFrequency: Float,
            rumbleMultiplier: Float
        ) {
            guard InputPowerPolicy.hasVibration(durationMs: nil, amplitudes: [lowAmplitude, highAmplitude]) else {
                stop()
                return
            }
            do {
                if lowHapticPlayer == nil || highHapticPlayer == nil {
                    try engine.start()
                    engineStarted = true
                    try createPlayers()
                }
                try sendParameters(
                    lowAmplitude: lowAmplitude,
                    lowFrequency: lowFrequency,
                    highAmplitude: highAmplitude,
                    highFrequency: highFrequency,
                    rumbleMultiplier: rumbleMultiplier
                )
            } catch {
                guard restart() else { return }
                do {
                    try sendParameters(lowAmplitude: lowAmplitude, lowFrequency: lowFrequency,
                        highAmplitude: highAmplitude, highFrequency: highFrequency, rumbleMultiplier: rumbleMultiplier)
                } catch {
                    stop()
                    NSLog("MeloNX haptics: could not apply vibration: %@", error.localizedDescription)
                }
            }
        }
        
        private func sendParameters(
            lowAmplitude: Float,
            lowFrequency: Float,
            highAmplitude: Float,
            highFrequency: Float,
            rumbleMultiplier: Float
        ) throws {
            let lowIntensity = Self.clamp(lowAmplitude * rumbleMultiplier)
            let highIntensity = Self.clamp(highAmplitude * rumbleMultiplier)
            
            try lowHapticPlayer?.sendParameters([
                CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: lowIntensity, relativeTime: 0),
                CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: Self.sharpness(for: lowFrequency, fallback: 0), relativeTime: 0),
            ], atTime: 0)
            
            try highHapticPlayer?.sendParameters([
                CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: highIntensity, relativeTime: 0),
                CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: Self.sharpness(for: highFrequency, fallback: 1), relativeTime: 0),
            ], atTime: 0)
        }
        
        private func createPlayers() throws {
            lowHapticPlayer = try createPlayer(sharpness: 0)
            highHapticPlayer = try createPlayer(sharpness: 1)
            
            try sendParameters(lowAmplitude: 0, lowFrequency: 160, highAmplitude: 0, highFrequency: 320, rumbleMultiplier: 1)
            
            try lowHapticPlayer?.start(atTime: 0)
            try highHapticPlayer?.start(atTime: 0)
        }
        
        private func createPlayer(sharpness: Float) throws -> CHHapticPatternPlayer {
            let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1)
            let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [intensity, sharpness],
                relativeTime: 0,
                duration: hapticEventDuration
            )
            
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            
            return try engine.makePlayer(with: pattern)
        }
        
        private static func sharpness(for frequency: Float, fallback: Float) -> Float {
            guard frequency.isFinite, frequency > 0 else { return fallback }
            
            let minHz: Float = 40
            let maxHz: Float = 1252
            let normalized = (log2(clamp(frequency, minHz, maxHz)) - log2(minHz)) / (log2(maxHz) - log2(minHz))
            
            return clamp(normalized)
        }
        
        private static func clamp(_ value: Float, _ lower: Float = 0, _ upper: Float = 1) -> Float {
            value.isFinite ? min(upper, max(lower, value)) : lower
        }
    }
    
    private var leftChannel: HapticChannel?
    private var rightChannel: HapticChannel?
    private var fallbackChannel: HapticChannel?
    private let rumbleMultiplier: Float
    private let hapticQueue = DispatchQueue(label: "com.stossy11.MeloNX.rumble", qos: .userInteractive)
    
    private let hapticEventDuration: TimeInterval = 20
    private let restartGracePeriod: TimeInterval = 1.0
    private var playerRestartTimer: DispatchSourceTimer?
    private var durationWork: DispatchWorkItem?
    private var currentVibration: (left: RumbleData.VibrationValue, right: RumbleData.VibrationValue)?
    
    init (engine: CHHapticEngine?, rumbleMultiplier: Float) {
        self.rumbleMultiplier = rumbleMultiplier
        
        fallbackChannel = HapticChannel(engine: engine, hapticEventDuration: hapticEventDuration)
    }
    
    init(leftEngine: CHHapticEngine?, rightEngine: CHHapticEngine?, fallbackEngine: CHHapticEngine?, rumbleMultiplier: Float) {
        self.rumbleMultiplier = rumbleMultiplier
        
        leftChannel = HapticChannel(engine: leftEngine, hapticEventDuration: hapticEventDuration)
        rightChannel = HapticChannel(engine: rightEngine, hapticEventDuration: hapticEventDuration)
        
        if leftChannel == nil || rightChannel == nil {
            leftChannel = nil
            rightChannel = nil
            fallbackChannel = HapticChannel(engine: fallbackEngine, hapticEventDuration: hapticEventDuration)
        }
        
    }
    
    deinit {
        playerRestartTimer?.cancel()
        playerRestartTimer = nil
        durationWork?.cancel()
        
        leftChannel?.stop()
        rightChannel?.stop()
        fallbackChannel?.stop()
    }
    
    /// 仅在持续震动期间维持播放器时长；停止后不再为零强度播放器唤醒线程。
    private func setupPlayerRestartTimer() {
        dispatchPrecondition(condition: .onQueue(hapticQueue))
        guard playerRestartTimer == nil else { return }
        let restartInterval = hapticEventDuration - restartGracePeriod
        guard restartInterval > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: hapticQueue)
        timer.schedule(deadline: .now() + restartInterval, repeating: restartInterval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.restartPlayers()
        }
        playerRestartTimer = timer
        timer.resume()
    }
    
    public func rumble(lowFreq: Float, highFreq: Float, durationMs: UInt32? = nil) {
        let vibration = RumbleData.VibrationValue(
            amplitudeLow: lowFreq,
            frequencyLow: 160,
            amplitudeHigh: highFreq,
            frequencyHigh: 320
        )
        
        rumble(left: vibration, right: vibration, durationMs: durationMs)
    }
    
    public func rumble(data: RumbleData) {
        rumble(left: data.left, right: data.right, durationMs: data.durationMs)
    }
    
    private func rumble(left: RumbleData.VibrationValue, right: RumbleData.VibrationValue, durationMs: UInt32?) {
        hapticQueue.async { [weak self] in
            guard let self else { return }
            self.durationWork?.cancel()
            self.durationWork = nil
            let active = InputPowerPolicy.hasVibration(durationMs: durationMs,
                amplitudes: [left.amplitudeLow, left.amplitudeHigh, right.amplitudeLow, right.amplitudeHigh])
            guard active, self.leftChannel != nil || self.rightChannel != nil || self.fallbackChannel != nil else {
                self.stopOnQueue()
                return
            }
            self.currentVibration = (left, right)
            self.applyVibration(left: left, right: right)
            guard self.leftChannel?.isPlaying == true || self.rightChannel?.isPlaying == true ||
                  self.fallbackChannel?.isPlaying == true else {
                self.stopOnQueue()
                return
            }
            self.setupPlayerRestartTimer()
            if let durationMs, durationMs > 0, durationMs != UInt32.max {
                let work = DispatchWorkItem { [weak self] in self?.stopOnQueue() }
                self.durationWork = work
                self.hapticQueue.asyncAfter(deadline: .now() + Double(durationMs) / 1000, execute: work)
            }
        }
    }

    private func applyVibration(left: RumbleData.VibrationValue, right: RumbleData.VibrationValue) {
        dispatchPrecondition(condition: .onQueue(hapticQueue))
        if leftChannel != nil, rightChannel != nil {
            leftChannel?.update(
                lowAmplitude: left.amplitudeLow,
                lowFrequency: left.frequencyLow,
                highAmplitude: left.amplitudeHigh,
                highFrequency: left.frequencyHigh,
                rumbleMultiplier: rumbleMultiplier
            )
            rightChannel?.update(
                lowAmplitude: right.amplitudeLow,
                lowFrequency: right.frequencyLow,
                highAmplitude: right.amplitudeHigh,
                highFrequency: right.frequencyHigh,
                rumbleMultiplier: rumbleMultiplier
            )
        } else {
            fallbackChannel?.update(
                lowAmplitude: max(left.amplitudeLow, right.amplitudeLow),
                lowFrequency: weightedFrequency(left.frequencyLow, left.amplitudeLow, right.frequencyLow, right.amplitudeLow, fallback: 160),
                highAmplitude: max(left.amplitudeHigh, right.amplitudeHigh),
                highFrequency: weightedFrequency(left.frequencyHigh, left.amplitudeHigh, right.frequencyHigh, right.amplitudeHigh, fallback: 320),
                rumbleMultiplier: rumbleMultiplier
            )
        }
    }
    
    private func restartPlayers() {
        dispatchPrecondition(condition: .onQueue(hapticQueue))
        guard let vibration = currentVibration else { return }
        guard leftChannel?.restartIfPlaying() != false,
              rightChannel?.restartIfPlaying() != false,
              fallbackChannel?.restartIfPlaying() != false else {
            stopOnQueue()
            return
        }
        applyVibration(left: vibration.left, right: vibration.right)
    }
    
    /// 解绑、暂停或退出必须主动调用；队列顺序保证此前的震动写入先完成，再统一停止。
    func stop() {
        hapticQueue.async { [self] in stopOnQueue() }
    }

    private func stopOnQueue() {
        dispatchPrecondition(condition: .onQueue(hapticQueue))
        durationWork?.cancel()
        durationWork = nil
        playerRestartTimer?.cancel()
        playerRestartTimer = nil
        currentVibration = nil
        leftChannel?.stop()
        rightChannel?.stop()
        fallbackChannel?.stop()
    }
    
    private func weightedFrequency(_ firstFrequency: Float, _ firstAmplitude: Float, _ secondFrequency: Float, _ secondAmplitude: Float, fallback: Float) -> Float {
        let totalAmplitude = firstAmplitude + secondAmplitude
        
        guard totalAmplitude > 0 else { return fallback }
        
        return ((firstFrequency * firstAmplitude) + (secondFrequency * secondAmplitude)) / totalAmplitude
    }
}
