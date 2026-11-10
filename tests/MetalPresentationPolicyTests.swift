import Foundation
import CoreGraphics

/// 直接编译生产几何去重与 MetalFX 输出策略；不替代真实 drawable、GPU 同步和功耗验证。
@main
struct MetalPresentationPolicyTests {
    static func main() {
        checkGeometryUpdates()
        checkInvalidGeometry()
        checkDirectOutputEligibility()
        print("MetalPresentationPolicyTests: geometry deduplication, invalid bounds and MetalFX output eligibility passed")
    }

    static func checkGeometryUpdates() {
        var state = MetalViewConfigurationState()
        let initial = state.update(size: CGSize(width: 390.8, height: 844.7), frameRate: 120)
        precondition(initial.size == CGSize(width: 390, height: 844) && initial.frameRate == 120)

        // 触摸、布局或小数抖动反复上报相同整数尺寸，不再跨原生边界重设尺寸/节拍。
        for _ in 0..<100 {
            let repeated = state.update(size: CGSize(width: 390.2, height: 844.1), frameRate: 120)
            precondition(repeated.size == nil && repeated.frameRate == nil)
        }

        let rotated = state.update(size: CGSize(width: 844, height: 390), frameRate: 120)
        precondition(rotated.size == CGSize(width: 844, height: 390) && rotated.frameRate == nil)
        let externalScreen = state.update(size: CGSize(width: 844, height: 390), frameRate: 60)
        precondition(externalScreen.size == nil && externalScreen.frameRate == 60)
        let changedBoth = state.update(size: CGSize(width: 1920, height: 1080), frameRate: 120)
        precondition(changedBoth.size == CGSize(width: 1920, height: 1080) && changedBoth.frameRate == 120)
    }

    static func checkInvalidGeometry() {
        var state = MetalViewConfigurationState()
        let validSize = CGSize(width: 800, height: 600)
        _ = state.update(size: validSize, frameRate: 60)
        let invalidSizes: [CGSize] = [
            .zero, CGSize(width: -1, height: 600), CGSize(width: 800, height: 0.5),
            CGSize(width: CGFloat.nan, height: 600), CGSize(width: 800, height: CGFloat.infinity),
            CGSize(width: CGFloat(Int32.max) + 1, height: 600)
        ]
        for size in invalidSizes {
            let invalid = state.update(size: size, frameRate: 60)
            precondition(invalid.size == nil && invalid.frameRate == nil)
            let restored = state.update(size: validSize, frameRate: 60)
            precondition(restored.size == nil && restored.frameRate == nil)
        }
        let boundary = state.update(size: CGSize(width: CGFloat(Int32.max), height: 1), frameRate: 0)
        precondition(boundary.size == CGSize(width: CGFloat(Int32.max), height: 1) && boundary.frameRate == 1)
        let normalized = state.update(size: .zero, frameRate: -20)
        precondition(normalized.size == nil && normalized.frameRate == nil)
    }

    static func checkDirectOutputEligibility() {
        func canWrite(renderWidth: Int = 1920, renderHeight: Int = 1080,
                      outputWidth: Int = 1920, outputHeight: Int = 1080,
                      destinationWidth: Int = 1920, destinationHeight: Int = 1080,
                      x: Int = 0, y: Int = 0, usage: UInt = 0b111, required: UInt = 0b110) -> Bool {
            MetalFxOutputPlan.canWriteDirectly(
                renderWidth: renderWidth, renderHeight: renderHeight,
                outputWidth: outputWidth, outputHeight: outputHeight,
                destinationWidth: destinationWidth, destinationHeight: destinationHeight,
                destinationX: x, destinationY: y, destinationUsage: usage, requiredUsage: required)
        }
        precondition(canWrite())
        precondition(canWrite(usage: 0b110))
        precondition(!canWrite(usage: 0b010))
        precondition(!canWrite(usage: 0))
        precondition(!canWrite(renderWidth: 2560, renderHeight: 1440))
        precondition(!canWrite(outputWidth: 1600, outputHeight: 900))
        precondition(!canWrite(destinationWidth: 2048, destinationHeight: 1536))
        precondition(!canWrite(destinationWidth: 1600))
        precondition(!canWrite(x: 10))
        precondition(!canWrite(y: 10))
        precondition(!canWrite(x: -1))
        precondition(!canWrite(renderWidth: 0, outputWidth: 0, destinationWidth: 0))
        precondition(!canWrite(renderHeight: -1, outputHeight: -1, destinationHeight: -1))
    }
}
