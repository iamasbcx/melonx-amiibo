#!/usr/bin/env python3
"""校验 MeloNX 未签名 IPA：应用/扩展、arm64 真机 Mach-O、依赖闭合及本次 NativeAOT 核心。

校验器只读输入包，成功后输出 JSON。--expected-core 必须指向本次重编并移除
ad-hoc 签名的核心，拒绝仅有菜单而仍嵌入旧核心的产物；不代表已完成真机运行验证。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import struct
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from zipfile import ZipFile

ARM64 = 0x0100000C
DYLIB_COMMANDS = {0x0C, 0x80000018, 0x8000001F, 0x20, 0x80000023}
SYMBOLS = {"_mlx_amiibo_get_abi", "_mlx_amiibo_get_state", "_mlx_amiibo_scan"}
# Apple 平台由系统 ICU 与 Foundation 提供全球化和基础运行时能力。
SYSTEM_ICU_DEPENDENCIES = frozenset({
    "/usr/lib/libicucore.A.dylib",
    "/usr/lib/libicucore.dylib",
})
SYSTEM_FOUNDATION_DEPENDENCIES = frozenset({
    "/System/Library/Frameworks/Foundation.framework/Foundation",
})
APP_PREFIX = "Payload/MeloNX.app/"


@dataclass(frozen=True)
class MachO:
    """仅记录交付检查需要的信息，不执行包中的代码。"""

    architecture: int
    filetype: int
    signed: bool
    platforms: tuple[int, ...]
    dependencies: tuple[str, ...]
    exports: frozenset[str]


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_c_string(data: bytes, offset: int, limit: int) -> str:
    if not 0 <= offset < limit <= len(data):
        raise ValueError("Mach-O 字符串偏移越界")
    end = data.find(b"\0", offset, limit)
    if end < 0:
        raise ValueError("Mach-O 字符串缺少结束符")
    return data[offset:end].decode("utf-8", errors="strict")


def read_uleb(data: bytes, offset: int, limit: int) -> tuple[int, int]:
    """读取 Mach-O export trie 的无符号 LEB128，拒绝无界或溢出输入。"""

    value = 0
    shift = 0
    while offset < limit and shift <= 63:
        byte = data[offset]
        offset += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, offset
        shift += 7
    raise ValueError("Mach-O export trie 的 ULEB128 无效")


def read_export_trie(data: bytes, start: int, size: int) -> set[str]:
    """解析 LC_DYLD_EXPORTS_TRIE，返回导出的完整符号名。"""

    end = start + size
    if start < 0 or size < 0 or end > len(data):
        raise ValueError("Mach-O export trie 越界")
    exports: set[str] = set()
    seen: set[tuple[int, str]] = set()
    active: set[int] = set()

    def walk(node: int, prefix: str, root: bool = False, depth: int = 0) -> None:
        if node == 0 and not root:
            return
        absolute = start + node
        if node in active:
            raise ValueError("Mach-O export trie 存在循环")
        if absolute < start or absolute >= end or (node, prefix) in seen:
            if (node, prefix) in seen:
                return
            raise ValueError("Mach-O export trie 节点越界或循环")
        seen.add((node, prefix))
        active.add(node)
        if len(seen) > 100000 or len(prefix) > 4096 or depth > 256:
            raise ValueError("Mach-O export trie 超过检查容量")
        terminal_size, cursor = read_uleb(data, absolute, end)
        terminal_end = cursor + terminal_size
        if terminal_end > end:
            raise ValueError("Mach-O export trie terminal 越界")
        if terminal_size:
            # terminal flags/value 后续字段不影响符号名；只验证其 ULEB 边界。
            _, _ = read_uleb(data, cursor, terminal_end)
            if prefix:
                exports.add(prefix)
        child_count_offset = terminal_end
        if child_count_offset >= end:
            raise ValueError("Mach-O export trie 缺少子节点数量")
        child_count = data[child_count_offset]
        cursor = child_count_offset + 1
        for _ in range(child_count):
            child_end = data.find(b"\0", cursor, end)
            if child_end < 0:
                raise ValueError("Mach-O export trie 子边缺少结束符")
            edge = data[cursor:child_end].decode("utf-8", errors="strict")
            cursor = child_end + 1
            child_node, cursor = read_uleb(data, cursor, end)
            walk(child_node, prefix + edge, depth=depth + 1)
        active.remove(node)

    # 根节点位于 trie 起点偏移0；空 trie 允许没有导出。
    if size:
        walk(0, "", root=True)
    return exports


def arm64_slice(data: bytes) -> bytes:
    """接收 thin/fat Mach-O，只选择 arm64；拒绝损坏或相互覆盖的边界。"""

    if data[:4] == b"\xcf\xfa\xed\xfe":
        return data
    if data[:4] not in {b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"}:
        raise ValueError("预期 64 位 Mach-O 或 universal Mach-O")
    is_64 = data[:4] == b"\xca\xfe\xba\xbf"
    if len(data) < 8:
        raise ValueError("Mach-O fat 头截断")
    count = struct.unpack_from(">I", data, 4)[0]
    stride = 32 if is_64 else 20
    if not 1 <= count <= 32 or 8 + count * stride > len(data):
        raise ValueError("Mach-O fat 架构表无效")
    slices: list[tuple[int, int]] = []
    match: bytes | None = None
    for index in range(count):
        offset = 8 + index * stride
        cpu = struct.unpack_from(">I", data, offset)[0]
        if is_64:
            start, size = struct.unpack_from(">QQ", data, offset + 8)
        else:
            start, size = struct.unpack_from(">II", data, offset + 8)
        if start < 8 + count * stride or size < 32 or start + size > len(data):
            raise ValueError("Mach-O fat 切片越界")
        if any(start < old_start + old_size and old_start < start + size for old_start, old_size in slices):
            raise ValueError("Mach-O fat 切片重叠")
        slices.append((start, size))
        if cpu == ARM64:
            if match is not None:
                raise ValueError("Mach-O 出现多个 arm64 切片")
            match = data[start : start + size]
    if match is None:
        raise ValueError("Mach-O 缺少 arm64 切片")
    return match


def parse_macho(data: bytes) -> MachO:
    binary = arm64_slice(data)
    if len(binary) < 32 or binary[:4] != b"\xcf\xfa\xed\xfe":
        raise ValueError("arm64 切片不是 little-endian Mach-O 64")
    cpu, _, filetype, count, command_bytes = struct.unpack_from("<IIIII", binary, 4)
    if cpu != ARM64 or command_bytes > len(binary) - 32 or count > command_bytes // 8:
        raise ValueError("Mach-O 头或 load command 边界无效")
    offset, end = 32, 32 + command_bytes
    signed = False
    platforms: list[int] = []
    dependencies: list[str] = []
    symtab: tuple[int, int, int, int] | None = None
    export_trie: tuple[int, int] | None = None
    for _ in range(count):
        if offset + 8 > end:
            raise ValueError("Mach-O load command 截断")
        command, size = struct.unpack_from("<II", binary, offset)
        if size < 8 or size % 4 or offset + size > end:
            raise ValueError("Mach-O load command 长度无效")
        if command in DYLIB_COMMANDS:
            if size < 24:
                raise ValueError("Mach-O dylib command 截断")
            name_offset = struct.unpack_from("<I", binary, offset + 8)[0]
            if not 24 <= name_offset < size:
                raise ValueError("Mach-O 依赖名称越界")
            dependencies.append(read_c_string(binary, offset + name_offset, offset + size))
        elif command == 0x1D:
            signed = True
        elif command == 0x32:
            if size < 24:
                raise ValueError("LC_BUILD_VERSION 截断")
            platforms.append(struct.unpack_from("<I", binary, offset + 8)[0])
        elif command == 0x25:
            platforms.append(2)
        elif command == 0x80000033:
            if size < 16:
                raise ValueError("Mach-O export trie command 截断")
            export_trie = struct.unpack_from("<II", binary, offset + 8)
        elif command in (0x22, 0x80000022):
            if size < 48:
                raise ValueError("LC_DYLD_INFO 截断")
            export_trie = struct.unpack_from("<II", binary, offset + 40)
        elif command == 0x02:
            if size < 24:
                raise ValueError("LC_SYMTAB 截断")
            symtab = struct.unpack_from("<IIII", binary, offset + 8)
        offset += size
    if offset != end:
        raise ValueError("Mach-O load command 总长不匹配")
    exports: set[str] = set()
    if symtab is not None:
        symbols_offset, symbol_count, strings_offset, strings_size = symtab
        if symbols_offset + symbol_count * 16 > len(binary) or strings_offset + strings_size > len(binary):
            raise ValueError("Mach-O symbol/string table 越界")
        for index in range(symbol_count):
            entry = symbols_offset + index * 16
            string_index, symbol_type = struct.unpack_from("<IB", binary, entry)
            if string_index and not symbol_type & 0xE0 and symbol_type & 1 and symbol_type & 0x0E:
                if string_index >= strings_size:
                    raise ValueError("Mach-O symbol name 越界")
                exports.add(read_c_string(binary, strings_offset + string_index, strings_offset + strings_size))
    if export_trie is not None:
        exports.update(read_export_trie(binary, *export_trie))
    if not platforms or any(platform != 2 for platform in platforms):
        raise ValueError("Mach-O 不是 iOS 真机平台")
    return MachO(cpu, filetype, signed, tuple(platforms), tuple(dependencies), frozenset(exports))


def validate_system_icu(macho: MachO) -> str:
    """确认核心直接依赖 Apple 系统 ICU；数据文件不能替代该依赖。"""
    for dependency in macho.dependencies:
        if dependency in SYSTEM_ICU_DEPENDENCIES:
            return dependency
    raise ValueError("NativeAOT 核心缺少 Apple 系统 ICU 依赖（/usr/lib/libicucore*.dylib）")


def _validate_system_foundation(macho: MachO) -> str:
    """确认核心直接依赖 Foundation 系统框架。"""
    for dependency in macho.dependencies:
        if dependency in SYSTEM_FOUNDATION_DEPENDENCIES:
            return dependency
    raise ValueError("NativeAOT 核心缺少 Foundation 系统框架依赖")


def verify_core(data: bytes) -> MachO:
    """校验本次 NativeAOT 核心，并返回解析结果供 IPA 核心复核。"""
    macho = parse_macho(data)
    if macho.filetype != 6 or macho.signed or not SYMBOLS <= macho.exports:
        raise ValueError("本次核心应为未签名 iOS dylib，且必须导出 3 个 Amiibo ABI 函数")
    validate_system_icu(macho)
    _validate_system_foundation(macho)
    return macho


def verify(path: Path, expected_core: Path) -> dict:
    expected_core_bytes = expected_core.read_bytes()
    expected_info = verify_core(expected_core_bytes)
    globalization_dependency = validate_system_icu(expected_info)
    foundation_dependency = _validate_system_foundation(expected_info)
    with ZipFile(path) as archive:
        names = archive.namelist()
        if len(set(names)) != len(names):
            raise ValueError("IPA 含重复条目")
        files = {name for name in names if not name.endswith("/")}
        for name in names:
            normalized = PurePosixPath(name)
            if normalized.is_absolute() or ".." in normalized.parts or "\\" in name:
                raise ValueError(f"IPA 存在不安全路径：{name}")
            if name.rstrip("/") != "Payload" and not name.startswith(APP_PREFIX):
                raise ValueError(f"IPA 存在意外顶层内容：{name}")
            if "_CodeSignature" in normalized.parts or name.endswith("embedded.mobileprovision"):
                raise ValueError(f"未签名 IPA 包含签名材料：{name}")
        info = plistlib.loads(archive.read(APP_PREFIX + "Info.plist"))
        if info.get("CFBundleIdentifier") != "com.stossy11.MeloNX":
            raise ValueError("MeloNX Bundle ID 不符合契约")
        if info.get("CFBundleExecutable") != "MeloNX" or info.get("CFBundlePackageType") != "APPL":
            raise ValueError("MeloNX 应用可执行文件或包类型无效")
        extension_prefix = APP_PREFIX + "PlugIns/MeloNXRamDonor.appex/"
        extension_info = plistlib.loads(archive.read(extension_prefix + "Info.plist"))
        if extension_info.get("CFBundleIdentifier") != "com.stossy11.MeloNX.RamDonor":
            raise ValueError("MeloNXRamDonor Bundle ID 不符合契约")
        if extension_info.get("CFBundleExecutable") != "MeloNXRamDonor":
            raise ValueError("内存扩展可执行文件名无效")
        if not extension_info.get("NSExtension", {}).get("NSExtensionPointIdentifier"):
            raise ValueError("内存扩展缺少 NSExtension 契约")
        if extension_info.get("CFBundleVersion") != info.get("CFBundleVersion"):
            raise ValueError("应用与内存扩展构建号不一致")
        core_path = APP_PREFIX + "Frameworks/Ryujinx.Library.dylib"
        core = archive.read(core_path)
        if sha256(core) != sha256(expected_core_bytes):
            raise ValueError("IPA 核心与本次重编的 NativeAOT 核心不一致")
        embedded_core_info = verify_core(core)
        embedded_globalization_dependency = validate_system_icu(embedded_core_info)
        embedded_foundation_dependency = _validate_system_foundation(embedded_core_info)
        if embedded_globalization_dependency != globalization_dependency or embedded_foundation_dependency != foundation_dependency:
            raise ValueError("IPA 核心与本次 NativeAOT 核心的系统依赖不一致")
        required = {
            APP_PREFIX + "MeloNX",
            extension_prefix + "MeloNXRamDonor",
            core_path,
            APP_PREFIX + "Frameworks/SDL3.framework/SDL3",
            APP_PREFIX + "Frameworks/BreakpointJIT.framework/BreakpointJIT",
            APP_PREFIX + "Frameworks/libMoltenVK.dylib",
            APP_PREFIX + "Frameworks/libavcodec.dylib",
            APP_PREFIX + "Frameworks/libavutil.dylib",
        }
        missing = sorted(required - files)
        if missing:
            raise ValueError("IPA 缺少运行输入：" + ", ".join(missing))
        macho_files: dict[str, MachO] = {}
        for name in sorted(files):
            with archive.open(name) as source:
                magic = source.read(4)
            if magic in {b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"}:
                macho = parse_macho(archive.read(name))
                if macho.signed:
                    raise ValueError(f"未签名 IPA 中仍有 LC_CODE_SIGNATURE：{name}")
                macho_files[name] = macho
        for name in [APP_PREFIX + "MeloNX", extension_prefix + "MeloNXRamDonor"]:
            if macho_files[name].filetype != 2:
                raise ValueError(f"预期 MH_EXECUTE：{name}")
        for name, macho in macho_files.items():
            for dependency in macho.dependencies:
                if dependency.startswith(("/System/Library/", "/usr/lib/")):
                    continue
                if dependency.startswith("@rpath/"):
                    relative = dependency[len("@rpath/") :]
                    candidates = {APP_PREFIX + "Frameworks/" + relative}
                    if name.startswith(extension_prefix):
                        candidates.add(extension_prefix + "Frameworks/" + relative)
                    if not candidates & files:
                        raise ValueError(f"动态库依赖未嵌入：{name} -> {dependency}")
                elif dependency.startswith("@loader_path/"):
                    resolved = PurePosixPath(name).parent / dependency[len("@loader_path/") :]
                    if ".." in resolved.parts or resolved.as_posix() not in files:
                        raise ValueError(f"动态库 loader 路径无法闭合：{name} -> {dependency}")
                else:
                    raise ValueError(f"动态库依赖包含构建机路径或未支持加载方式：{name} -> {dependency}")
        app_dependencies = macho_files[APP_PREFIX + "MeloNX"].dependencies
        if "@rpath/Ryujinx.Library.dylib" not in app_dependencies:
            raise ValueError("应用未链接本次 NativeAOT 核心")
    return {
        "artifact": path.name,
        "sha256": sha256(path.read_bytes()),
        "bundle_identifier": info["CFBundleIdentifier"],
        "version": info["CFBundleShortVersionString"],
        "build": info["CFBundleVersion"],
        "minimum_ios": info.get("MinimumOSVersion"),
        "architecture": "arm64-ios-device",
        "signed": False,
        "core_sha256": sha256(core),
        "amiibo_symbols": sorted(SYMBOLS),
        "extension": extension_info["CFBundleIdentifier"],
        "macho_files_checked": len(macho_files),
        "globalization": {
            "mode": "apple-system-icu",
            "dependency": globalization_dependency,
            "foundation_dependency": foundation_dependency,
            "scope": "native dependency structure only",
        },
        "scope": "包结构、动态依赖闭合与本次核心一致性；未完成真机运行验证",
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--expected-core", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = verify(args.ipa, args.expected_core)
    output = args.output or args.ipa.parent / "ipa-verification.json"
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()


