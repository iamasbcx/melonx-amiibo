#!/usr/bin/env bash
# Xcode Legacy target 的核心构建入口。CI 已完成发布时必须匹配本次核心摘要，
# 普通本地构建仍使用固定 SDK 执行发布；不加载个人 shell 配置或改写搜索顺序。
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
CORE_DYLIB="${PROJECT_ROOT}/src/Ryujinx.Library/bin/Release/net10.0/ios-arm64/native/Ryujinx.Library.dylib"
cd "${PROJECT_ROOT}"

if [[ -n "${MLX_FIXED_DOTNET:-}" ]]; then
  DOTNET="${MLX_FIXED_DOTNET}"
elif [[ -x "${PROJECT_ROOT}/build/tools/dotnet-10.0.100/dotnet" ]]; then
  DOTNET="${PROJECT_ROOT}/build/tools/dotnet-10.0.100/dotnet"
else
  DOTNET="$(command -v dotnet || true)"
fi
if [[ -z "${DOTNET}" || ! -x "${DOTNET}" ]]; then
  echo "缺少固定 .NET SDK；请执行 bash scripts/bootstrap-dotnet.sh。" >&2
  exit 1
fi
if [[ "$("${DOTNET}" --version)" != "10.0.100" ]]; then
  echo "核心构建仅接受 .NET SDK 10.0.100。" >&2
  exit 1
fi

# 只有显式提供本次 publish 的 SHA-256 才允许复用；不存在或摘要不符立即失败。
if [[ "${MLX_PREBUILT_CORE_SHA256+x}" == "x" ]]; then
  if [[ -z "${MLX_FIXED_DOTNET:-}" || ! "${MLX_PREBUILT_CORE_SHA256}" =~ ^[0-9a-f]{64}$ || ! -s "${CORE_DYLIB}" ]]; then
    echo "受控核心复用参数或文件无效。" >&2
    exit 1
  fi
  ACTUAL_CORE_SHA256="$(shasum -a 256 "${CORE_DYLIB}" | awk '{print $1}')"
  if [[ "${ACTUAL_CORE_SHA256}" != "${MLX_PREBUILT_CORE_SHA256}" ]]; then
    echo "Xcode 依赖目标检测到核心与本次发布摘要不一致，拒绝重复编译或继续打包。" >&2
    exit 1
  fi
  echo "Xcode 核心依赖已匹配本次发布摘要：${ACTUAL_CORE_SHA256}"
  exit 0
fi

"${DOTNET}" publish -c Release -r ios-arm64 \
  -p:ExtraDefineConstants=DISABLE_UPDATER src/Ryujinx.Library --self-contained true

