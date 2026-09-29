#!/usr/bin/env python3
"""处理目录或单个 FLV 录播，跳过已完成的转写与弹幕转换步骤。"""

import argparse
import json
import subprocess
import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
ASR_SCRIPT = SCRIPT_DIR / "video-asr.py"
SRT_SCRIPT = SCRIPT_DIR / "diarized_json_to_srt.py"
ASS_SCRIPT = SCRIPT_DIR / "xml-to-ass.py"


def has_content(path):
    return path.is_file() and path.stat().st_size > 0


def has_diarized_json(path):
    if not has_content(path):
        return False
    try:
        with path.open("r", encoding="utf-8") as file:
            data = json.load(file)
    except (OSError, UnicodeError, ValueError):
        return False
    return isinstance(data, dict) and isinstance(data.get("segments"), list)


def run_step(script, source, *options):
    command = [sys.executable, str(script), *options, str(source)]
    print(f"运行：{script.name} {source.name}", flush=True)
    try:
        result = subprocess.run(command, check=False)
    except OSError as error:
        print(f"运行失败：{script.name}：{error}", file=sys.stderr)
        return False
    return result.returncode == 0


def process_video(source):
    json_path = source.with_suffix(".json")
    srt_path = source.with_suffix(".srt")
    failed = False
    json_updated = False

    if has_diarized_json(json_path):
        print(f"跳过 ASR：{json_path.name} 已存在")
    else:
        if json_path.exists():
            print(f"重做 ASR：{json_path.name} 无效或为空")
        if run_step(ASR_SCRIPT, source) and has_diarized_json(json_path):
            json_updated = True
        else:
            print(f"ASR 失败，跳过字幕：{source.name}", file=sys.stderr)
            return True

    if has_content(srt_path) and not json_updated:
        print(f"跳过字幕：{srt_path.name} 已存在")
    elif not run_step(SRT_SCRIPT, json_path) or not has_content(srt_path):
        print(f"字幕转换失败：{json_path.name}", file=sys.stderr)
        failed = True
    return failed


def process_xml(source):
    ass_path = source.with_suffix(".ass")
    if has_content(ass_path):
        print(f"跳过弹幕：{ass_path.name} 已存在")
        return False
    options = ("--force",) if ass_path.exists() else ()
    if not run_step(ASS_SCRIPT, source, *options) or not has_content(ass_path):
        print(f"弹幕转换失败：{source.name}", file=sys.stderr)
        return True
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "input", nargs="?", type=Path, default=SCRIPT_DIR,
        help="要处理的目录或单个 FLV；默认是脚本所在目录",
    )
    args = parser.parse_args()
    if args.input.is_dir():
        files = sorted((path for path in args.input.iterdir() if path.is_file()), key=lambda path: path.name)
        videos = [path for path in files if path.suffix.lower() == ".flv"]
        danmaku = [path for path in files if path.suffix.lower() == ".xml"]
    elif args.input.is_file() and args.input.suffix.lower() == ".flv":
        videos = [args.input]
        # 单文件模式只转换与所选录播同名的弹幕。
        danmaku = sorted(
            (path for path in args.input.parent.iterdir()
             if path.is_file() and path.stem == args.input.stem
             and path.suffix.lower() == ".xml"),
            key=lambda path: path.name,
        )
    else:
        parser.error(f"请输入存在的目录或 FLV 文件：{args.input}")

    print(f"发现 {len(videos)} 个 FLV、{len(danmaku)} 个 XML", flush=True)

    failed = False
    files = sorted(
        [*videos, *danmaku],
        key=lambda path: (path.stem, path.suffix.lower() != ".xml", path.name),
    )
    for source in files:
        if source.suffix.lower() == ".flv":
            print(f"\n处理视频：{source.name}", flush=True)
            failed = process_video(source) or failed
        else:
            print(f"\n处理弹幕：{source.name}", flush=True)
            failed = process_xml(source) or failed

    print("\n处理完成" if not failed else "\n处理结束，部分步骤失败", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
