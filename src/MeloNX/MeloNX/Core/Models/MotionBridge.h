// 手机完整运动采样的 C ABI。Swift 与 NativeAOT 必须使用同一份参数顺序。
#ifndef MLX_MOTION_BRIDGE_H
#define MLX_MOTION_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

// id 为已连接手柄的非拥有标识；标量参数按值复制，不保留调用方内存。
// acceleration/gravity 使用同一 driver 坐标（g），gyroscope 为 deg/s。
// 可从运动串行队列调用；核心锁内保存完整帧，无效/已断开的 id 不更新状态。
void set_gamepad_motion_sample(void *id,
                              float accelerationX, float accelerationY, float accelerationZ,
                              float gyroscopeX, float gyroscopeY, float gyroscopeZ,
                              float gravityX, float gravityY, float gravityZ);

#ifdef __cplusplus
}
#endif

#endif
