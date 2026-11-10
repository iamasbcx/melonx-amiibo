#!/usr/bin/env python3
"""验证 IPA 交付门禁，使用合成 Mach-O 数据覆盖关键错误，不运行二进制。"""

from __future__ import annotations

import plistlib
import struct
import tempfile
import unittest
from pathlib import Path
from zipfile import ZipFile

from verify_ipa import AMIIBO_SYMBOLS, APP_PREFIX, ARM64, CORE_SYMBOLS, MOTION_SYMBOLS, parse_macho, read_export_trie, verify


def make_macho(filetype: int = 6, dependencies: tuple[str, ...] = (), symbols: tuple[str, ...] = (),
               platform: int = 2, signed: bool = False) -> bytes:
    """生成仅用于结构校验的最小 Mach-O；不是可执行交付产物。"""

    commands = [struct.pack("<IIIIII", 0x32, 24, platform, 0, 0, 0)]
    for dependency in dependencies:
        encoded = dependency.encode() + b"\0"
        size = (24 + len(encoded) + 7) // 8 * 8
        commands.append(struct.pack("<IIIIII", 0x0C, size, 24, 0, 0, 0) + encoded
                        + b"\0" * (size - 24 - len(encoded)))
    if signed:
        commands.append(struct.pack("<IIII", 0x1D, 16, 0, 0))
    strings = b"\0"
    entries = b""
    for symbol in symbols:
        entries += struct.pack("<IBBHQ", len(strings), 0x0F, 1, 0, 1)
        strings += symbol.encode() + b"\0"
    table_offset = 32 + sum(map(len, commands)) + 24
    commands.append(struct.pack("<IIIIII", 2, 24, table_offset, len(symbols),
                                table_offset + len(entries), len(strings)))
    return (struct.pack("<IIIIIIII", 0xFEEDFACF, ARM64, 0, filetype, len(commands),
                        sum(map(len, commands)), 0, 0) + b"".join(commands) + entries + strings)


class IpaVerificationTests(unittest.TestCase):
    """保证打包门禁会拒绝旧核心、错平台、缺依赖与损坏输入。"""

    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory(prefix="melonx-ipa-verifier-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.core = make_macho(dependencies=("/usr/lib/libicucore.A.dylib", "/System/Library/Frameworks/Foundation.framework/Foundation"), symbols=tuple(sorted(CORE_SYMBOLS)))
        self.core_path = self.root / "core.dylib"
        self.core_path.write_bytes(self.core)
        app_info = {
            "CFBundleIdentifier": "com.stossy11.MeloNX", "CFBundleExecutable": "MeloNX",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "2.7",
            "CFBundleVersion": "1", "MinimumOSVersion": "15.0",
        }
        extension_info = {
            "CFBundleIdentifier": "com.stossy11.MeloNX.RamDonor",
            "CFBundleExecutable": "MeloNXRamDonor", "CFBundleVersion": "1",
            "NSExtension": {"NSExtensionPointIdentifier": "com.apple.ar.viewer"},
        }
        self.entries = {
            APP_PREFIX + "Info.plist": plistlib.dumps(app_info),
            APP_PREFIX + "MeloNX": make_macho(2, ("@rpath/Ryujinx.Library.dylib",)),
            APP_PREFIX + "PlugIns/MeloNXRamDonor.appex/Info.plist": plistlib.dumps(extension_info),
            APP_PREFIX + "PlugIns/MeloNXRamDonor.appex/MeloNXRamDonor": make_macho(2),
            APP_PREFIX + "Frameworks/Ryujinx.Library.dylib": self.core,
        }
        for name in ("SDL3.framework/SDL3", "BreakpointJIT.framework/BreakpointJIT",
                     "libMoltenVK.dylib", "libavcodec.dylib", "libavutil.dylib"):
            self.entries[APP_PREFIX + "Frameworks/" + name] = make_macho()

    def check(self, entries: dict[str, bytes]) -> dict:
        path = self.root / "test.ipa"
        with ZipFile(path, "w") as archive:
            for name, content in entries.items():
                archive.writestr(name, content)
        return verify(path, self.core_path)

    def test_valid_package(self) -> None:
        report = self.check(self.entries)
        self.assertEqual(report["macho_files_checked"], 8)
        self.assertEqual(report["amiibo_symbols"], sorted(AMIIBO_SYMBOLS))
        self.assertEqual(report["motion_symbols"], sorted(MOTION_SYMBOLS))

    def test_missing_motion_export_even_when_core_matches(self) -> None:
        # 两份核心摘要一致也不能放过旧 ABI，必须拒绝缺少完整采样接口的交付。
        self.core = make_macho(
            dependencies=("/usr/lib/libicucore.A.dylib", "/System/Library/Frameworks/Foundation.framework/Foundation"),
            symbols=tuple(sorted(AMIIBO_SYMBOLS)),
        )
        self.core_path.write_bytes(self.core)
        self.entries[APP_PREFIX + "Frameworks/Ryujinx.Library.dylib"] = self.core
        with self.assertRaisesRegex(ValueError, "缺少必需导出.*_set_gamepad_motion_sample_with_controls"):
            self.check(self.entries)

    def test_missing_amiibo_export_with_motion_export_present(self) -> None:
        # 增加运动接口不能弱化原有 Amiibo 导出门禁。
        self.core = make_macho(
            dependencies=("/usr/lib/libicucore.A.dylib", "/System/Library/Frameworks/Foundation.framework/Foundation"),
            symbols=tuple(sorted(CORE_SYMBOLS - {"_mlx_amiibo_scan"})),
        )
        self.core_path.write_bytes(self.core)
        self.entries[APP_PREFIX + "Frameworks/Ryujinx.Library.dylib"] = self.core
        with self.assertRaisesRegex(ValueError, "缺少必需导出.*_mlx_amiibo_scan"):
            self.check(self.entries)

    def test_missing_motion_suspend_export(self) -> None:
        # 完整采样接口存在也不足以支持游戏内编辑，必须同时具备保留姿态的挂起接口。
        self.core = make_macho(
            dependencies=("/usr/lib/libicucore.A.dylib", "/System/Library/Frameworks/Foundation.framework/Foundation"),
            symbols=tuple(sorted(CORE_SYMBOLS - {"_suspend_gamepad_motion"})),
        )
        self.core_path.write_bytes(self.core)
        self.entries[APP_PREFIX + "Frameworks/Ryujinx.Library.dylib"] = self.core
        with self.assertRaisesRegex(ValueError, "缺少必需导出.*_suspend_gamepad_motion"):
            self.check(self.entries)

    def test_valid_package_without_icu_dat(self) -> None:
        report = self.check(self.entries)
        self.assertEqual(report["globalization"]["mode"], "apple-system-icu")
        self.assertEqual(report["globalization"]["dependency"], "/usr/lib/libicucore.A.dylib")

    def test_missing_system_icu(self) -> None:
        self.core = make_macho(dependencies=("/System/Library/Frameworks/Foundation.framework/Foundation",), symbols=tuple(sorted(CORE_SYMBOLS)))
        self.core_path.write_bytes(self.core)
        self.entries[APP_PREFIX + "Frameworks/Ryujinx.Library.dylib"] = self.core
        with self.assertRaisesRegex(ValueError, "系统 ICU"):
            self.check(self.entries)

    def test_rpath_icu_does_not_satisfy_system_dependency(self) -> None:
        self.core = make_macho(dependencies=("@rpath/libicucore.A.dylib", "/System/Library/Frameworks/Foundation.framework/Foundation"), symbols=tuple(sorted(CORE_SYMBOLS)))
        self.core_path.write_bytes(self.core)
        self.entries[APP_PREFIX + "Frameworks/Ryujinx.Library.dylib"] = self.core
        with self.assertRaisesRegex(ValueError, "系统 ICU"):
            self.check(self.entries)

    def test_icu_dat_does_not_satisfy_dependency(self) -> None:
        self.core = make_macho(dependencies=("/System/Library/Frameworks/Foundation.framework/Foundation",), symbols=tuple(sorted(CORE_SYMBOLS)))
        self.core_path.write_bytes(self.core)
        self.entries[APP_PREFIX + "Frameworks/Ryujinx.Library.dylib"] = self.core
        self.entries[APP_PREFIX + "icudt_hybrid.dat"] = b"test-only"
        with self.assertRaisesRegex(ValueError, "系统 ICU"):
            self.check(self.entries)

    def test_missing_foundation(self) -> None:
        self.core = make_macho(dependencies=("/usr/lib/libicucore.A.dylib",), symbols=tuple(sorted(CORE_SYMBOLS)))
        self.core_path.write_bytes(self.core)
        self.entries[APP_PREFIX + "Frameworks/Ryujinx.Library.dylib"] = self.core
        with self.assertRaisesRegex(ValueError, "Foundation"):
            self.check(self.entries)

    def test_stale_core(self) -> None:
        self.entries[APP_PREFIX + "Frameworks/Ryujinx.Library.dylib"] = make_macho()
        with self.assertRaisesRegex(ValueError, "核心不一致"):
            self.check(self.entries)

    def test_missing_extension(self) -> None:
        del self.entries[APP_PREFIX + "PlugIns/MeloNXRamDonor.appex/MeloNXRamDonor"]
        with self.assertRaises(ValueError):
            self.check(self.entries)

    def test_missing_dependency(self) -> None:
        self.entries[APP_PREFIX + "MeloNX"] = make_macho(2, ("@rpath/missing.dylib",))
        with self.assertRaisesRegex(ValueError, "动态库依赖未嵌入"):
            self.check(self.entries)

    def test_simulator(self) -> None:
        self.entries[APP_PREFIX + "MeloNX"] = make_macho(2, platform=7)
        with self.assertRaisesRegex(ValueError, "iOS 真机"):
            self.check(self.entries)

    def test_remaining_code_signature(self) -> None:
        self.entries[APP_PREFIX + "MeloNX"] = make_macho(2, signed=True)
        with self.assertRaisesRegex(ValueError, "LC_CODE_SIGNATURE"):
            self.check(self.entries)

    def test_zip_path_traversal(self) -> None:
        self.entries["../escape"] = b"invalid"
        with self.assertRaisesRegex(ValueError, "不安全路径"):
            self.check(self.entries)

    def test_malformed_macho(self) -> None:
        for data in (b"", b"\xcf\xfa\xed\xfe" + b"\0" * 28, make_macho()[:-8]):
            with self.subTest(size=len(data)), self.assertRaises(ValueError):
                parse_macho(data)

    def test_valid_export_trie(self) -> None:
        trie = bytes((0, 1)) + b"_mlx\0" + bytes((8, 1, 0, 0))
        self.assertEqual(read_export_trie(trie, 0, len(trie)), {"_mlx"})

    def test_export_trie_out_of_bounds(self) -> None:
        trie = bytes((0, 1)) + b"_mlx\0" + bytes((80,))
        with self.assertRaises(ValueError):
            read_export_trie(trie, 0, len(trie))


if __name__ == "__main__":
    unittest.main()

