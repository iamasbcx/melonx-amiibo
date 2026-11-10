#ifndef MLX_PERFORMANCE_BRIDGE_H
#define MLX_PERFORMANCE_BRIDGE_H
#include <stdint.h>

// 0 关闭普通统计，1 启用 5 Hz 统计；首次呈现通知不受此开关影响。
void set_statistics_enabled(int32_t enabled);
#endif
