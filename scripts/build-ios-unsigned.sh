#!/usr/bin/env bash
# 固定 SDK 重编 NativeAOT 核心，再构建应用、内存扩展并验证未签名 IPA。
# 不请求证书，不采用现成核心；失败保留日志，全部校验通过才报告完成。
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/build"
ARTIFACT_DIR="${BUILD_DIR}/artifacts"
LOG_DIR="${BUILD_DIR}/logs"
DERIVED_DATA="${BUILD_DIR}/DerivedData"
DOTNET_ROOT="${BUILD_DIR}/tools/dotnet-10.0.100"
CORE_DIR="${PROJECT_ROOT}/src/Ryujinx.Library/bin/Release/net10.0/ios-arm64/native"
CORE_DYLIB="${CORE_DIR}/Ryujinx.Library.dylib"
CORE_PUBLISH_STAMP="${BUILD_DIR}/nativeaot-publish-start"
XCODE_PROJECT="${PROJECT_ROOT}/src/MeloNX/MeloNX.xcodeproj"
SPM_LOCK="${XCODE_PROJECT}/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
APP_PATH="${DERIVED_DATA}/Build/Products/Release-iphoneos/MeloNX.app"
BUILD_NUMBER="${PROJECT_BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"

cd "${PROJECT_ROOT}"
mkdir -p "${LOG_DIR}" "${ARTIFACT_DIR}"
exec > >(tee "${LOG_DIR}/build.log") 2>&1
# 一进入新构建就归档旧交付；工具链或测试失败也不会留下可误认的新产物。
if [[ -f "${ARTIFACT_DIR}/MeloNXAmiibo.ipa" ]]; then
  OLD_ARTIFACT_DIR="${BUILD_DIR}/backups/artifacts-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "${OLD_ARTIFACT_DIR}"
  for old_file in MeloNXAmiibo.ipa SHA256SUMS ipa-verification.json core-verification.json build-inputs.json; do
    if [[ -e "${ARTIFACT_DIR}/${old_file}" ]]; then
      mv "${ARTIFACT_DIR}/${old_file}" "${OLD_ARTIFACT_DIR}/${old_file}"
    fi
  done
fi
PYTHONDONTWRITEBYTECODE=1 python3 "${SCRIPT_DIR}/check_localization.py" 2>&1 | tee "${LOG_DIR}/localization-check.log"
PYTHONDONTWRITEBYTECODE=1 python3 "${SCRIPT_DIR}/test_verify_ipa.py" 2>&1 | tee "${LOG_DIR}/ipa-verifier-tests.log"
if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "iOS NativeAOT 构建需要 Apple Silicon macOS 和 Xcode。" >&2
  exit 1
fi
if [[ ! "${BUILD_NUMBER}" =~ ^[0-9]+$ ]]; then
  echo "构建号必须是非负整数。" >&2
  exit 1
fi
XCODE_VERSION="$(xcodebuild -version | awk '/^Xcode / { print $2; exit }')"
if [[ "${XCODE_VERSION}" != "26.2" ]]; then
  echo "需要 Xcode 26.2，实际为 ${XCODE_VERSION}。" >&2
  exit 1
fi
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version
# 运动桥接头使用标准 C 标量 ABI；先以严格告警检查，再交由 Swift 导入。
xcrun clang -x c -std=c11 -Wall -Wextra -Werror -fsyntax-only \
  src/MeloNX/MeloNX/Core/Models/MotionBridge.h \
  2>&1 | tee "${LOG_DIR}/motion-bridge-header.log"
xcrun swiftc -parse-as-library \
  src/MeloNX/MeloNX/Core/Amiibo/AmiiboCatalogParser.swift \
  tests/AmiiboCatalogParserTests.swift \
  -o "${BUILD_DIR}/AmiiboCatalogParserTests" \
  2>&1 | tee "${LOG_DIR}/amiibo-parser-build.log"
"${BUILD_DIR}/AmiiboCatalogParserTests" 2>&1 | tee "${LOG_DIR}/amiibo-parser-tests.log"
# 使用应用的同一份 Swift 数学模块生成运动回放，再交给生产 C# 滤波器验证停止后的姿态。
xcrun swiftc -parse-as-library -default-isolation MainActor \
  src/MeloNX/MeloNX/Core/Controllers/InGameInputSession.swift \
  src/MeloNX/MeloNX/Core/Controllers/Motion/PhoneMotionControls.swift \
  src/MeloNX/MeloNX/Core/Controllers/Motion/PhoneMotionTransform.swift \
  src/MeloNX/MeloNX/UI/Main/Settings/TouchLookSensitivityConfiguration.swift \
  tests/ControllerInputTests.swift \
  -o "${BUILD_DIR}/ControllerInputTests" \
  2>&1 | tee "${LOG_DIR}/controller-input-build.log"
"${BUILD_DIR}/ControllerInputTests" "${BUILD_DIR}/controller-motion-traces.json" \
  2>&1 | tee "${LOG_DIR}/controller-input-tests.log"
# 使用隔离的 UserDefaults suite 检查真实作用域存储，不读写构建机的应用配置。
xcrun swiftc -parse-as-library -default-isolation MainActor -target arm64-apple-macosx14.0 \
  src/MeloNX/MeloNX/Core/Controllers/ControllerInputProfile.swift \
  tests/InputProfileTests.swift \
  -o "${BUILD_DIR}/InputProfileTests" \
  2>&1 | tee "${LOG_DIR}/input-profile-build.log"
"${BUILD_DIR}/InputProfileTests" 2>&1 | tee "${LOG_DIR}/input-profile-tests.log"
# 生命周期测试直接使用生产屏障，检查旧游戏、旧绑定和已停止传感器的回调不会重新写入。
xcrun swiftc -parse-as-library -default-isolation MainActor \
  src/MeloNX/MeloNX/Core/Controllers/InGameInputSession.swift \
  src/MeloNX/MeloNX/UI/Main/Settings/NativeSettingsOverrideMarker.swift \
  tests/InputLifecycleTests.swift \
  -o "${BUILD_DIR}/InputLifecycleTests" \
  2>&1 | tee "${LOG_DIR}/input-lifecycle-build.log"
"${BUILD_DIR}/InputLifecycleTests" 2>&1 | tee "${LOG_DIR}/input-lifecycle-tests.log"
# 本地手柄包使用自身隔离规则；测试直接链接生产仲裁和布局数学，避免复制实现。
xcrun swiftc -parse-as-library \
  src/MeloNX/Dependencies/Melo-Controller/Sources/Melo-Controller/ControllerInteractionState.swift \
  src/MeloNX/Dependencies/Melo-Controller/Sources/Melo-Controller/Models/Layout.swift \
  tests/VirtualControllerInteractionTests.swift \
  -o "${BUILD_DIR}/VirtualControllerInteractionTests" \
  2>&1 | tee "${LOG_DIR}/virtual-controller-interaction-build.log"
"${BUILD_DIR}/VirtualControllerInteractionTests" 2>&1 | tee "${LOG_DIR}/virtual-controller-interaction-tests.log"
bash "${SCRIPT_DIR}/bootstrap-dotnet.sh" 2>&1 | tee "${LOG_DIR}/dotnet-bootstrap.log"
export DOTNET_ROOT
export PATH="${DOTNET_ROOT}:${PATH}"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
DOTNET="${DOTNET_ROOT}/dotnet"
"${DOTNET}" --info | tee "${LOG_DIR}/dotnet-info.log"
"${DOTNET}" workload list | tee "${LOG_DIR}/dotnet-workloads.log"
"${DOTNET}" run --project tests/MotionInput.Tests/MotionInput.Tests.csproj \
  -c Release -- "${BUILD_DIR}/controller-motion-traces.json" \
  2>&1 | tee "${LOG_DIR}/controller-motion-tests.log"
"${DOTNET}" run --project tests/NativeMotion.Tests/NativeMotion.Tests.csproj \
  -c Release 2>&1 | tee "${LOG_DIR}/native-motion-tests.log"
"${DOTNET}" run --project tests/AmiiboContract.Tests/AmiiboContract.Tests.csproj \
  -c Release 2>&1 | tee "${LOG_DIR}/amiibo-contract-tests.log"
"${DOTNET}" run --project tests/HleAmiibo.Tests/HleAmiibo.Tests.csproj \
  -c Release 2>&1 | tee "${LOG_DIR}/amiibo-hle-tests.log"

# 所有可复用的输入先记录摘要；SPM 只接受现有锁文件，禁止构建时自动升级。
python3 - "${PROJECT_ROOT}" "${ARTIFACT_DIR}" <<'PY'
import hashlib, json, pathlib, subprocess, sys
root, output = map(pathlib.Path, sys.argv[1:])
paths = [
    root / "global.json", root / "Directory.Packages.props",
    root / "nuget.config",
    root / "src/MeloNX/MeloNX.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
]
paths.extend(p for p in (root / "src/MeloNX/MeloNX/Dependencies").rglob("*") if p.is_file())
manifest = {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths)}
sdk = json.loads((root / "global.json").read_text(encoding="utf-8-sig"))["sdk"]
if sdk.get("version") != "10.0.100" or sdk.get("rollForward") != "disable" or sdk.get("allowPrerelease", False):
    raise SystemExit("global.json 必须精确锁定 .NET SDK 10.0.100，且 rollForward=disable")
try:
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
except subprocess.CalledProcessError:
    revision = "unavailable"
(output / "build-inputs.json").write_text(json.dumps({"git_revision": revision, "sha256": manifest}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
SPM_HASH="$(shasum -a 256 "${SPM_LOCK}" | awk '{print $1}')"
xcodebuild -resolvePackageDependencies \
  -project "${XCODE_PROJECT}" -scheme MeloNX \
  -clonedSourcePackagesDirPath "${BUILD_DIR}/SourcePackages" \
  -onlyUsePackageVersionsFromResolvedFile \
  -disableAutomaticPackageResolution \
  2>&1 | tee "${LOG_DIR}/spm-resolve.log"
test "${SPM_HASH}" = "$(shasum -a 256 "${SPM_LOCK}" | awk '{print $1}')"

# 原发布目录整体归档，防止增量输出被当作本次发布结果。
CORE_RUNTIME_DIR="${PROJECT_ROOT}/src/Ryujinx.Library/bin/Release/net10.0/ios-arm64"
if [[ -d "${CORE_RUNTIME_DIR}" ]]; then
  CORE_BACKUP="${BUILD_DIR}/backups/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "${CORE_BACKUP}"
  mv "${CORE_RUNTIME_DIR}" "${CORE_BACKUP}/ios-arm64"
fi
touch "${CORE_PUBLISH_STAMP}"
"${DOTNET}" publish src/Ryujinx.Library/Ryujinx.Library.csproj \
  -c Release -r ios-arm64 --self-contained true --disable-build-servers \
  -p:ExtraDefineConstants=DISABLE_UPDATER \
  -p:ContinuousIntegrationBuild=true \
  -p:Codesign=false -p:EnableCodeSigning=false \
  2>&1 | tee "${LOG_DIR}/nativeaot-publish.log"
test -s "${CORE_DYLIB}"
test "${CORE_DYLIB}" -nt "${CORE_PUBLISH_STAMP}"
nm -gU "${CORE_DYLIB}" > "${LOG_DIR}/core-symbols.log"
for symbol in mlx_amiibo_get_abi mlx_amiibo_get_state mlx_amiibo_scan set_gamepad_phone_motion_sample suspend_gamepad_motion; do
  if ! awk '{print $NF}' "${LOG_DIR}/core-symbols.log" | grep -qx "_${symbol}"; then
    echo "新核心缺少导出：${symbol}" >&2
    exit 1
  fi
done
# NativeAOT/Apple 链接器可能写入 ad-hoc 签名；以去签名的同一核心验证实际打包副本。
CORE_NORMALIZED="${BUILD_DIR}/Ryujinx.Library.unsigned.dylib"
cp "${CORE_DYLIB}" "${CORE_NORMALIZED}"
if codesign --display "${CORE_NORMALIZED}" >/dev/null 2>&1; then
  codesign --remove-signature "${CORE_NORMALIZED}"
fi
# .NET 10 iOS 使用系统 ICU 与 Foundation；在 Xcode 前检查本次核心的实际加载依赖。
# 与最终 IPA 共用同一验证函数，缺依赖、ABI 或目标平台错误均立即失败。
xcrun otool -L "${CORE_NORMALIZED}" | tee "${LOG_DIR}/core-dependencies.log"
python3 - "${SCRIPT_DIR}" "${CORE_NORMALIZED}" "${ARTIFACT_DIR}/core-verification.json" <<'PY'
import json, pathlib, sys
sys.path.insert(0, sys.argv[1])
from verify_ipa import AMIIBO_SYMBOLS, MOTION_SYMBOLS, sha256, validate_system_icu, verify_core
data = pathlib.Path(sys.argv[2]).read_bytes()
core = verify_core(data)
report = {
    "core_sha256": sha256(data),
    "amiibo_symbols": sorted(AMIIBO_SYMBOLS),
    "motion_symbols": sorted(MOTION_SYMBOLS),
    "dependencies": list(core.dependencies),
    "globalization": {"mode": "apple-system-icu", "dependency": validate_system_icu(core)},
    "scope": "NativeAOT 核心的平台、导出与依赖结构；未完成真机运行验证",
}
pathlib.Path(sys.argv[3]).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps(report, ensure_ascii=False, indent=2))
PY
# Xcode 仍会执行上游 Legacy 依赖；它只能复核同一核心，不能再次发布使摘要漂移。
export MLX_FIXED_DOTNET="${DOTNET}"
export MLX_PREBUILT_CORE_SHA256="$(shasum -a 256 "${CORE_DYLIB}" | awk '{print $1}')"

xcodebuild \
  -project "${XCODE_PROJECT}" -scheme MeloNX \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "${DERIVED_DATA}" \
  -clonedSourcePackagesDirPath "${BUILD_DIR}/SourcePackages" \
  -onlyUsePackageVersionsFromResolvedFile -disableAutomaticPackageResolution \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  MLX_FIXED_DOTNET="${MLX_FIXED_DOTNET}" MLX_PREBUILT_CORE_SHA256="${MLX_PREBUILT_CORE_SHA256}" \
  COPY_PHASE_STRIP=NO STRIP_INSTALLED_PRODUCT=NO build \
  2>&1 | tee "${LOG_DIR}/xcodebuild.log"
test "${MLX_PREBUILT_CORE_SHA256}" = "$(shasum -a 256 "${CORE_DYLIB}" | awk '{print $1}')"
if ! grep -Fq "Xcode 核心依赖已匹配本次发布摘要：${MLX_PREBUILT_CORE_SHA256}" "${LOG_DIR}/xcodebuild.log"; then
  echo "Xcode 未记录 Legacy 目标对本次核心摘要的确认。" >&2
  exit 1
fi
test -s "${APP_PATH}/MeloNX"
test -s "${APP_PATH}/PlugIns/MeloNXRamDonor.appex/MeloNXRamDonor"

PACKAGE_DIR="$(mktemp -d "${BUILD_DIR}/package.XXXXXX")"
trap 'rm -rf "${PACKAGE_DIR}"' EXIT
mkdir -p "${PACKAGE_DIR}/Payload"
ditto "${APP_PATH}" "${PACKAGE_DIR}/Payload/MeloNX.app"
STAGED_APP="${PACKAGE_DIR}/Payload/MeloNX.app"

# 嵌入依赖可携带上游签名；只在打包副本中移除，不改第三方原始文件。
while IFS= read -r -d '' item; do
  if file -b "${item}" | grep -q 'Mach-O'; then
    if codesign --display "${item}" >/dev/null 2>&1; then
      codesign --remove-signature "${item}"
    fi
  fi
done < <(find "${STAGED_APP}" -type f -print0)
while IFS= read -r -d '' signature; do
  rm -rf "${signature}"
done < <(find "${STAGED_APP}" -type d -name _CodeSignature -print0)
if find "${STAGED_APP}" -name embedded.mobileprovision | grep -q .; then
  echo "打包副本中出现未预期的 provisioning profile。" >&2
  exit 1
fi
cmp "${CORE_NORMALIZED}" "${STAGED_APP}/Frameworks/Ryujinx.Library.dylib"
nm -gU "${STAGED_APP}/Frameworks/Ryujinx.Library.dylib" > "${LOG_DIR}/embedded-core-symbols.log"
ditto -c -k --norsrc --keepParent "${PACKAGE_DIR}/Payload" "${PACKAGE_DIR}/MeloNXAmiibo.ipa"
python3 "${SCRIPT_DIR}/verify_ipa.py" "${PACKAGE_DIR}/MeloNXAmiibo.ipa" \
  --expected-core "${CORE_NORMALIZED}" --output "${ARTIFACT_DIR}/ipa-verification.json" \
  2>&1 | tee "${LOG_DIR}/ipa-verification.log"
mv "${PACKAGE_DIR}/MeloNXAmiibo.ipa" "${ARTIFACT_DIR}/MeloNXAmiibo.ipa"
(cd "${ARTIFACT_DIR}" && shasum -a 256 MeloNXAmiibo.ipa > SHA256SUMS)
echo "已生成经过结构、依赖和新核心一致性校验的未签名 IPA：${ARTIFACT_DIR}/MeloNXAmiibo.ipa"

