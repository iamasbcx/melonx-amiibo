#!/usr/bin/env python3
"""验证 IPA 交付门禁，使用合成 Mach-O 数据覆盖关键错误，不运行二进制。"""

from __future__ import annotations

import plistlib
import struct
import tempfile
import unittest
from pathlib import Path
from zipfile import ZipFile

from verify_ipa import APP_PREFIX, ARM64, SYMBOLS, parse_macho, read_export_trie, verify


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
        self.core = make_macho(symbols=tuple(sorted(SYMBOLS)))
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
            APP_PREFIX + "icudt_hybrid.dat": b"test-only",
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
        self.assertEqual(report["amiibo_symbols"], sorted(SYMBOLS))

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

