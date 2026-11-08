#!/usr/bin/env python3
"""检查中文资源的参数、Markdown 和变量占位符，避免显示翻译改变格式契约。"""

from __future__ import annotations

from collections import Counter
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "src/MeloNX/MeloNX/Assets/Localizable.xcstrings"
FORMAT = re.compile(r"%(?:\d+\$)?[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|ll|[hljztL])?([@diuoxXfFeEgGaAcCsSp%])")
VARIABLE = re.compile(r"\$\{[^}]+\}")


def parameters(value: str) -> Counter:
    return Counter((match.group(1) or "", match.group(2)) for match in FORMAT.finditer(value))


def main() -> None:
    document = json.loads(CATALOG.read_text(encoding="utf-8"))
    if document["sourceLanguage"] != "en":
        raise ValueError("源语言契约必须保持 en")
    count = 0
    translated = 0
    for key, entry in document["strings"].items():
        if not key:
            continue
        unit = entry.get("localizations", {}).get("zh-Hans", {}).get("stringUnit", {})
        value = unit.get("value")
        if not isinstance(value, str) or not value:
            raise ValueError(f"缺少简体中文资源：{key!r}")
        if parameters(key) != parameters(value):
            raise ValueError(f"格式参数发生变化：{key!r}")
        if Counter(VARIABLE.findall(key)) != Counter(VARIABLE.findall(value)):
            raise ValueError(f"变量占位符发生变化：{key!r}")
        if key.count("**") != value.count("**"):
            raise ValueError(f"Markdown 加粗标记发生变化：{key!r}")
        count += 1
        translated += value != key
    project = (ROOT / "src/MeloNX/MeloNX.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
    if '"zh-Hans",' not in project:
        raise ValueError("Xcode 工程缺少 zh-Hans 语言声明")
    print(f"Localization checked: {count} keys, {translated} translated; placeholders preserved.")


if __name__ == "__main__":
    main()
