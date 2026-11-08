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
  for old_file in MeloNXAmiibo.ipa SHA256SUMS ipa-verification.json build-inputs.json; do
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
xcrun swiftc -parse-as-library \
  src/MeloNX/MeloNX/Core/Amiibo/AmiiboCatalogParser.swift \
  tests/AmiiboCatalogParserTests.swift \
  -o "${BUILD_DIR}/AmiiboCatalogParserTests" \
  2>&1 | tee "${LOG_DIR}/amiibo-parser-build.log"
"${BUILD_DIR}/AmiiboCatalogParserTests" 2>&1 | tee "${LOG_DIR}/amiibo-parser-tests.log"
bash "${SCRIPT_DIR}/bootstrap-dotnet.sh" 2>&1 | tee "${LOG_DIR}/dotnet-bootstrap.log"
export DOTNET_ROOT
export PATH="${DOTNET_ROOT}:${PATH}"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
DOTNET="${DOTNET_ROOT}/dotnet"
"${DOTNET}" --info | tee "${LOG_DIR}/dotnet-info.log"
"${DOTNET}" workload list | tee "${LOG_DIR}/dotnet-workloads.log"
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

# 原发布目录整体归档，防止增量输出或 ICU 残留被当作本次发布结果。
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
for symbol in mlx_amiibo_get_abi mlx_amiibo_get_state mlx_amiibo_scan; do
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

# ICU 数据是当前 HybridGlobalization 核心的运行输入，必须从本次 publish 输出复制。
ICU_FOUND=0
while IFS= read -r -d '' icu_file; do
  ditto "${icu_file}" "${STAGED_APP}/$(basename "${icu_file}")"
  ICU_FOUND=1
done < <(find "${CORE_RUNTIME_DIR}" -type f -name 'icudt*.dat' -print0)
if [[ "${ICU_FOUND}" != 1 ]]; then
  echo "本次 NativeAOT 发布缺少 icudt*.dat，不能交付无法验证的全球化运行输入。" >&2
  exit 1
fi

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

