#!/usr/bin/env bash
# 在 macOS 使用应用的实际 Foundation parser，验证格式边界与文档 TXT 示例。
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
mkdir -p "${PROJECT_ROOT}/build/tests"
swiftc -parse-as-library \
  "${PROJECT_ROOT}/src/MeloNX/MeloNX/Core/Amiibo/AmiiboCatalogParser.swift" \
  "${PROJECT_ROOT}/tests/AmiiboCatalogParserTests.swift" \
  -o "${PROJECT_ROOT}/build/tests/AmiiboCatalogParserTests"
"${PROJECT_ROOT}/build/tests/AmiiboCatalogParserTests" \
  "${PROJECT_ROOT}/docs/amiibo-catalog-example.txt"
