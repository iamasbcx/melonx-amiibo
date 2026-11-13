#!/bin/bash
# 在 Codemagic 的 macOS/Xcode 26.2 环境编译并运行真实存储测试，同时编译本地 HTTP 包。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$ROOT/build/lan-tests"
mkdir -p "$OUTPUT"
CORE="$ROOT/src/MeloNX/MeloNX/Core/LANFileManager"
xcrun swiftc -swift-version 5 -parse-as-library \
  "$CORE/LANFileMutationLock.swift" \
  "$CORE/LANUploadStore.swift" \
  "$CORE/LANFileSystemStore.swift" \
  "$ROOT/tests/LANFileManager/StoreChecks.swift" \
  -o "$OUTPUT/StoreChecks"
"$OUTPUT/StoreChecks"
swift test --package-path "$ROOT/src/MeloNX/Dependencies/NanoHTTP" --scratch-path "$OUTPUT/nanohttp"
MODULES="$(swift build --package-path "$ROOT/src/MeloNX/Dependencies/NanoHTTP" --scratch-path "$OUTPUT/nanohttp" --show-bin-path)/Modules"
# 使用与 App 相同的默认 actor 隔离检查 HTTP 集成，避免仅测试独立 actor 时漏掉调用错误。
xcrun swiftc -swift-version 5 -typecheck -default-isolation MainActor -I "$MODULES" \
  "$CORE/LANFileMutationLock.swift" "$CORE/LANUploadStore.swift" "$CORE/LANFileSystemStore.swift" \
  "$CORE/LANWebBundle.swift" "$ROOT/src/MeloNX/MeloNX/Core/LANFileServer.swift"
