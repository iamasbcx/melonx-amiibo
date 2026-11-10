// 手机完整运动采样的 C ABI。Swift 与 NativeAOT 必须使用同一份参数顺序。
#ifndef MLX_MOTION_BRIDGE_H
#define MLX_MOTION_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

// id 为已连接手柄的非拥有标识；标量参数按值复制，不保留调用方内存。
// acceleration 是调用方提供的游戏加速度，可包含平移方向校正；gravity 是未经该校正的独立重力。
// acceleration/gravity 使用同一 driver 坐标（g），gyroscope 为 deg/s。
// 可从运动串行队列调用；核心锁内保存完整帧，无效/已断开的 id 不更新状态。
// rotationFactor 使用核心屏幕 X/Y/Z，取值仅 -1/0/+1，不随 driver 换轴；按值复制。
void set_gamepad_motion_sample_with_controls(void *id,
                              float accelerationX, float accelerationY, float accelerationZ,
                              float gyroscopeX, float gyroscopeY, float gyroscopeZ,
                              float gravityX, float gravityY, float gravityZ,
                              float rotationFactorX, float rotationFactorY, float rotationFactorZ);

// 编辑会话挂起运动：清除瞬时输入但保留重力和控制姿态，恢复首帧不积分暂停时长。
// id 为非拥有标识；无效/已断开的 id 不更新状态；新采样自动解除挂起。
void suspend_gamepad_motion(void *id);

#ifdef __cplusplus
}
#endif

#endif
