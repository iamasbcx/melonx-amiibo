//
//  AmiiboBridge.h
//  MeloNX
//
//  iOS 界面与 NativeAOT 核心之间的虚拟 amiibo 固定 ABI。
//  结构体只使用固定宽度整数和内嵌数组，避免 Swift/C# 的自然对齐与托管指针差异。
//

#ifndef MELO_NX_AMIIBO_BRIDGE_H
#define MELO_NX_AMIIBO_BRIDGE_H

#include <stdint.h>

#define MLX_AMIIBO_ABI_VERSION 1u

enum {
    MLX_AMIIBO_OK = 0,
    MLX_AMIIBO_ABI_MISMATCH = 1,
    MLX_AMIIBO_INVALID_ARGUMENT = 2,
    MLX_AMIIBO_BUFFER_TOO_SMALL = 3,
    MLX_AMIIBO_NOT_RUNNING = 4,
    MLX_AMIIBO_PAUSED = 5,
    MLX_AMIIBO_NOT_SEARCHING = 6,
    MLX_AMIIBO_STALE_SESSION = 7,
    MLX_AMIIBO_STALE_DETECTION = 8,
    MLX_AMIIBO_BUSY = 9,
    MLX_AMIIBO_INTERNAL_ERROR = 10
};

enum {
    MLX_AMIIBO_FLAG_RUNNING = 1u << 0,
    MLX_AMIIBO_FLAG_PAUSED = 1u << 1,
    MLX_AMIIBO_FLAG_SEARCHING = 1u << 2
};

typedef struct {
    uint32_t abi_version;
    uint32_t struct_size;
    uint32_t session_id;
    uint32_t detection_epoch;
    uint32_t flags;
    int32_t last_result;
} MlxAmiiboState;

typedef struct {
    uint32_t abi_version;
    uint32_t struct_size;
    uint32_t session_id;
    uint32_t detection_epoch;
    uint8_t amiibo_id[16];
} MlxAmiiboScanRequest;

// 调用方拥有全部缓冲区；核心只在本次调用期间读取输入并写入输出。
// get_state/scan 均可能等待核心锁；scan 还可能创建虚拟卡存档，必须在 UI 线程之外调用。
// 请求携带当次会话与检测代数，防止旧菜单提交到新的游戏读取请求。
int32_t mlx_amiibo_get_abi(uint32_t *version, uint32_t *capabilities);
int32_t mlx_amiibo_get_state(MlxAmiiboState *out_state, uint32_t state_size);
int32_t mlx_amiibo_scan(const MlxAmiiboScanRequest *request, uint32_t request_size);

#if defined(__cplusplus)
static_assert(sizeof(MlxAmiiboState) == 24, "MlxAmiiboState ABI size changed");
static_assert(sizeof(MlxAmiiboScanRequest) == 32, "MlxAmiiboScanRequest ABI size changed");
#else
_Static_assert(sizeof(MlxAmiiboState) == 24, "MlxAmiiboState ABI size changed");
_Static_assert(sizeof(MlxAmiiboScanRequest) == 32, "MlxAmiiboScanRequest ABI size changed");
#endif

#endif /* MELO_NX_AMIIBO_BRIDGE_H */
