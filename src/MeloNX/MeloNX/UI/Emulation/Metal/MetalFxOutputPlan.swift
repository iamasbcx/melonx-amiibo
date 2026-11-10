/// MetalFX 精确输出路径的资格判断，不改变升频倍率、画质或跨 API 同步。
/// 只有输出覆盖整张可写 drawable 时才直接编码；带黑边、二次缩放或 usage 不足均保留中间纹理。
nonisolated enum MetalFxOutputPlan {
    static func canWriteDirectly(renderWidth: Int, renderHeight: Int,
                                outputWidth: Int, outputHeight: Int,
                                destinationWidth: Int, destinationHeight: Int,
                                destinationX: Int, destinationY: Int,
                                destinationUsage: UInt, requiredUsage: UInt) -> Bool {
        renderWidth > 0 && renderHeight > 0 &&
            renderWidth == outputWidth && renderHeight == outputHeight &&
            outputWidth == destinationWidth && outputHeight == destinationHeight &&
            destinationX == 0 && destinationY == 0 &&
            destinationUsage & requiredUsage == requiredUsage
    }
}
