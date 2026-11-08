#!/usr/bin/env bash
# 仅为本项目准备固定版本的 .NET SDK；下载摘要来自 Microsoft 10.0 发布元数据。
# 默认安装在已被 gitignore 排除的 build/，不修改系统 SDK 或 shell 配置。
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SDK_VERSION="10.0.100"
SDK_SHA512="0ee9c774f9c63601844619b67d6ca829d70fa26b9949b808e801380c35edb12e4c9418baf8e2ef8ba1dc6dc7d307dbf5830fb0f4f97666032a391c5c097ee607"
SDK_URL="https://builds.dotnet.microsoft.com/dotnet/Sdk/${SDK_VERSION}/dotnet-sdk-${SDK_VERSION}-osx-arm64.tar.gz"
SDK_ROOT="${PROJECT_ROOT}/build/tools/dotnet-${SDK_VERSION}"
CACHE_ROOT="${PROJECT_ROOT}/build/downloads"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "固定 SDK 构建入口需要 Apple Silicon macOS。" >&2
  exit 1
fi
mkdir -p "${CACHE_ROOT}" "${SDK_ROOT}"
ARCHIVE="${CACHE_ROOT}/dotnet-sdk-${SDK_VERSION}-osx-arm64.tar.gz"
if [[ ! -f "${ARCHIVE}" ]]; then
  curl --fail --location --retry 3 --proto '=https' --tlsv1.2 "${SDK_URL}" -o "${ARCHIVE}.partial"
  mv "${ARCHIVE}.partial" "${ARCHIVE}"
fi
printf '%s  %s\n' "${SDK_SHA512}" "${ARCHIVE}" | shasum -a 512 -c -
if [[ ! -x "${SDK_ROOT}/dotnet" ]]; then
  tar -xzf "${ARCHIVE}" -C "${SDK_ROOT}"
fi
if [[ "$("${SDK_ROOT}/dotnet" --version)" != "${SDK_VERSION}" ]]; then
  echo "固定 SDK 校验失败；请检查 build/tools 中的 SDK 安装。" >&2
  exit 1
fi
echo "项目 SDK 已准备：${SDK_ROOT}"
