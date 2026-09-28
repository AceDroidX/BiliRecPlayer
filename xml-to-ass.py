#!/usr/bin/env python3
"""使用 DanmakuFactory 将录播弹幕 XML 转换为 ASS。"""

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_FACTORY = SCRIPT_DIR / "DanmakuFactory"
DEFAULT_CONFIG = SCRIPT_DIR / "DanmakuFactoryGUIConfig-1080横屏.txt"

SIMPLE_OPTIONS = {
    "displayarea": "--displayarea",
    "scrollarea": "--scrollarea",
    "scrolltime": "--scrolltime",
    "fixtime": "--fixtime",
    "density": "--density",
    "fontname": "--fontname",
    "fontsize": "--fontsize",
    "opacity": "--opacity",
    "outline": "--outline",
    "shadow": "--shadow",
    "bold": "--bold",
    "showUsernames": "--showusernames",
    "showMsgbox": "--showmsgbox",
    "msgboxFontsize": "--msgboxfontsize",
    "giftMinPrice": "--giftminprice",
}
BLOCK_OPTIONS = {
    "blockR2L": "R2L",
    "blockL2R": "L2R",
    "blockTop": "TOP",
    "blockBtm": "BOTTOM",
    "blockSpecial": "SPECIAL",
    "blockColor": "COLOR",
    "blockRepeat": "REPEAT",
}
STAT_OPTIONS = {"statTable": "TABLE", "statHistogram": "HISTOGRAM"}
PAIR_OPTIONS = {
    "resX": "resY",
    "msgboxPosX": "msgboxPosY",
    "msgboxSizeWidth": "msgboxSizeHeight",
}
KNOWN_KEYS = (
    set(SIMPLE_OPTIONS) | set(BLOCK_OPTIONS) | set(STAT_OPTIONS)
    | set(PAIR_OPTIONS) | set(PAIR_OPTIONS.values()) | {"DanmakuFactoryConfigVer"}
)


def read_gui_config(path):
    values = {}
    for entry in path.read_text(encoding="utf-8-sig").split(";"):
        entry = entry.strip()
        if not entry:
            continue
        key, separator, value = entry.partition(":")
        if not separator or not key.strip() or not value.strip():
            raise ValueError(f"配置项格式错误：{entry}")
        key = key.strip()
        if key not in KNOWN_KEYS:
            raise ValueError(f"不支持的配置项：{key}")
        if key in values:
            raise ValueError(f"配置项重复：{key}")
        values[key] = value.strip()

    if values.get("DanmakuFactoryConfigVer") != "1.0":
        raise ValueError("配置文件版本不是 1.0")
    return values


def enabled(value, key):
    if value.lower() not in {"true", "false"}:
        raise ValueError(f"{key} 必须为 True 或 False")
    return value.lower() == "true"


def config_arguments(values):
    arguments = []
    for first, second, option in (
        ("resX", "resY", "--resolution"),
        ("msgboxPosX", "msgboxPosY", "--msgboxpos"),
        ("msgboxSizeWidth", "msgboxSizeHeight", "--msgboxsize"),
    ):
        if (first in values) != (second in values):
            raise ValueError(f"{first} 和 {second} 必须一起设置")
        if first in values:
            arguments.extend([option, f"{values[first]}x{values[second]}"])

    for key, option in SIMPLE_OPTIONS.items():
        if key in values:
            value = values[key]
            if key in {"bold", "showUsernames", "showMsgbox"}:
                value = str(enabled(value, key)).lower()
            arguments.extend([option, value])

    blocked = [name for key, name in BLOCK_OPTIONS.items() if key in values and enabled(values[key], key)]
    if blocked:
        arguments.extend(["--blockmode", "-".join(blocked)])
    statistics = [name for key, name in STAT_OPTIONS.items() if key in values and enabled(values[key], key)]
    if statistics:
        arguments.extend(["--statmode", "-".join(statistics)])
    return arguments


def convert(source, destination, factory, settings, force):
    if not source.is_file():
        raise ValueError(f"输入文件不存在：{source}")
    if source.suffix.lower() != ".xml":
        raise ValueError(f"输入文件不是 XML：{source}")
    if destination.exists() and not force:
        raise ValueError(f"输出文件已存在：{destination}；需要覆盖时使用 --force")

    # 先在输出目录生成结果，转换成功后再替换目标文件。
    with tempfile.TemporaryDirectory(prefix=".danmaku-", dir=destination.parent) as directory:
        temporary_output = Path(directory) / destination.name
        command = [
            str(factory), "-o", "ass", str(temporary_output),
            "-i", "xml", str(source), *settings,
        ]
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        if result.returncode or not temporary_output.is_file():
            detail = (result.stderr + "\n" + result.stdout).strip()
            raise RuntimeError(f"DanmakuFactory 转换失败{f'：{detail}' if detail else ''}")
        temporary_output.replace(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", nargs="+", type=Path, help="输入的 XML 弹幕文件")
    parser.add_argument("-o", "--output", type=Path, help="输出 ASS 路径；只支持单个输入")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG, help="DanmakuFactory GUI 配置文件")
    parser.add_argument("--factory", type=Path, default=DEFAULT_FACTORY, help="DanmakuFactory 可执行文件")
    parser.add_argument("--force", action="store_true", help="覆盖已有 ASS 文件")
    args = parser.parse_args()
    if args.output and len(args.inputs) != 1:
        parser.error("--output 只能与一个输入文件一起使用")

    try:
        settings = config_arguments(read_gui_config(args.config))
        if not args.factory.is_file():
            raise ValueError(f"找不到 DanmakuFactory：{args.factory}")
    except (OSError, UnicodeError, ValueError) as error:
        parser.exit(1, f"配置错误：{error}\n")

    failed = False
    for source in args.inputs:
        destination = args.output or source.with_suffix(".ass")
        try:
            convert(source, destination, args.factory, settings, args.force)
        except (OSError, UnicodeError, ValueError, RuntimeError) as error:
            print(f"转换失败：{source}：{error}", file=sys.stderr)
            failed = True
            continue
        print(f"{source} -> {destination}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
