#!/usr/bin/env python3
"""安装本目录的桌面入口，并将相对 Exec 路径改为绝对路径。"""

import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
APPLICATIONS_DIR = Path.home() / ".local/share/applications"


def installed_content(source):
    lines = []
    for line in source.read_text(encoding="utf-8").splitlines(keepends=True):
        if line.startswith("Exec=./"):
            original = line[7:].rstrip("\r\n")
            newline = line[7 + len(original):]
            command, separator, arguments = original.partition(" ")
            executable = (SCRIPT_DIR / command).resolve()
            if not executable.is_file():
                raise FileNotFoundError(f"桌面入口引用的程序不存在：{executable}")
            line = f"Exec={executable}{separator}{arguments}{newline}"
        lines.append(line)
    return "".join(lines)


def main():
    entries = sorted(SCRIPT_DIR.glob("*.desktop"))
    if not entries:
        print(f"没有找到桌面入口：{SCRIPT_DIR}", file=sys.stderr)
        return 1

    try:
        prepared = [(entry.name, installed_content(entry)) for entry in entries]
        APPLICATIONS_DIR.mkdir(parents=True, exist_ok=True)
        for name, content in prepared:
            destination = APPLICATIONS_DIR / name
            destination.write_text(content, encoding="utf-8")
            print(f"已安装：{destination}")
    except OSError as error:
        print(f"安装失败：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
