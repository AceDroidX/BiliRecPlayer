#!/usr/bin/env python3
"""批量处理目录中的 FLV 录播和 XML 弹幕，跳过已完成的步骤。"""

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
        "directory", nargs="?", type=Path, default=SCRIPT_DIR,
        help="要处理的目录；默认是脚本所在目录",
    )
    args = parser.parse_args()
    if not args.directory.is_dir():
        parser.error(f"目录不存在：{args.directory}")

    files = sorted((path for path in args.directory.iterdir() if path.is_file()), key=lambda path: path.name)
    videos = [path for path in files if path.suffix.lower() == ".flv"]
    danmaku = [path for path in files if path.suffix.lower() == ".xml"]
    print(f"发现 {len(videos)} 个 FLV、{len(danmaku)} 个 XML", flush=True)

    failed = False
    for video in videos:
        print(f"\n处理视频：{video.name}", flush=True)
        failed = process_video(video) or failed
    for xml in danmaku:
        print(f"\n处理弹幕：{xml.name}", flush=True)
        failed = process_xml(xml) or failed

    print("\n处理完成" if not failed else "\n处理结束，部分步骤失败", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
