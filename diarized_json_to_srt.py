#!/usr/bin/env python3
"""将 diarized_json 的 segments 转换为 SRT 字幕。"""

import argparse
import json
import math
import sys
from pathlib import Path


def format_timestamp(seconds):
    if isinstance(seconds, bool) or not isinstance(seconds, (int, float)):
        raise ValueError(f"时间戳不是数字：{seconds!r}")
    if not math.isfinite(seconds) or seconds < 0:
        raise ValueError(f"时间戳无效：{seconds!r}")

    milliseconds = round(seconds * 1000)
    hours, remainder = divmod(milliseconds, 3_600_000)
    minutes, remainder = divmod(remainder, 60_000)
    whole_seconds, milliseconds = divmod(remainder, 1000)
    return f"{hours:02d}:{minutes:02d}:{whole_seconds:02d},{milliseconds:03d}"


def convert(source, destination, show_speaker):
    with source.open("r", encoding="utf-8") as file:
        data = json.load(file)

    if not isinstance(data, dict) or not isinstance(data.get("segments"), list):
        raise ValueError("JSON 缺少 segments 数组")

    subtitles = []
    for position, segment in enumerate(data["segments"], start=1):
        if not isinstance(segment, dict):
            raise ValueError(f"第 {position} 段不是对象")

        start = segment.get("start")
        end = segment.get("end")
        text = segment.get("text")
        if start is None or end is None:
            raise ValueError(f"第 {position} 段缺少开始或结束时间")
        if not isinstance(text, str):
            raise ValueError(f"第 {position} 段缺少文本")
        text = text.strip()
        if not text:
            continue

        start_time = format_timestamp(start)
        end_time = format_timestamp(end)
        if end <= start or end_time == start_time:
            raise ValueError(f"第 {position} 段的结束时间不晚于开始时间")

        speaker = segment.get("speaker")
        if show_speaker and speaker:
            text = f"[{speaker}] {text}"
        subtitles.append(f"{len(subtitles) + 1}\n{start_time} --> {end_time}\n{text}")

    destination.write_text("\n\n".join(subtitles) + ("\n" if subtitles else ""), encoding="utf-8")
    return len(subtitles)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", nargs="+", type=Path, help="输入的 diarized_json 文件")
    parser.add_argument("-o", "--output", type=Path, help="输出 SRT 路径；仅支持单个输入文件")
    parser.add_argument("--no-speaker", action="store_true", help="字幕中不显示说话人编号")
    args = parser.parse_args()

    if args.output and len(args.inputs) != 1:
        parser.error("--output 只能与一个输入文件一起使用")

    failed = False
    for source in args.inputs:
        destination = args.output or source.with_suffix(".srt")
        try:
            count = convert(source, destination, not args.no_speaker)
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
            print(f"转换失败：{source}：{error}", file=sys.stderr)
            failed = True
            continue
        print(f"{source} -> {destination}（{count} 条）")

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
