#!/usr/bin/env python3
"""用 mpv 播放视频，同时加载同名 ASS 弹幕和 SRT 字幕栏。"""

import argparse
import shlex
import shutil
import subprocess
import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
LUA_SCRIPT = SCRIPT_DIR / "subtitle-sidebar.lua"
HEATMAP_SCRIPT = SCRIPT_DIR / "danmaku-heatmap.lua"
VIDEO_SUFFIXES = {".flv", ".mp4", ".mkv", ".mov", ".webm"}


def choose_video():
    videos = sorted(
        path for path in SCRIPT_DIR.iterdir()
        if path.is_file() and path.suffix.lower() in VIDEO_SUFFIXES
    )
    if not videos:
        raise ValueError(f"目录中没有视频文件：{SCRIPT_DIR}")
    if not sys.stdin.isatty():
        raise ValueError("没有指定视频文件；请把视频拖到快捷方式上，或在终端运行本脚本")

    print("请选择视频：")
    for index, video in enumerate(videos, start=1):
        print(f"{index}. {video.name}")
    try:
        choice = input("编号（回车取消）：").strip()
    except EOFError:
        return None
    if not choice:
        return None
    if not choice.isdecimal() or not 1 <= int(choice) <= len(videos):
        raise ValueError(f"无效编号：{choice}")
    return videos[int(choice) - 1]


def collect_videos(inputs):
    videos = []
    for source in inputs:
        source = source.expanduser().resolve()
        if source.is_dir():
            entries = sorted(
                path for path in source.iterdir()
                if path.is_file() and path.suffix.lower() == ".flv"
            )
            if not entries:
                raise ValueError(f"目录中没有 FLV 文件：{source}")
            videos.extend(entries)
        else:
            videos.append(source)
    return videos


def video_options(video):
    video = video.expanduser().resolve()
    if not video.is_file() or video.suffix.lower() not in VIDEO_SUFFIXES:
        raise ValueError(f"不是支持的视频文件：{video}")
    ass = video.with_suffix(".ass")
    srt = video.with_suffix(".srt")
    missing = [str(path) for path in (ass, srt) if not path.is_file()]
    if missing:
        raise ValueError("缺少同名字幕文件：" + "、".join(missing))

    return [f"--sub-file={ass}", f"--sub-file={srt}", str(video)]


def command_for(videos):
    command = [
        "mpv",
        "--no-sub-auto",
        "--sid=no",
        "--secondary-sid=no",
        "--secondary-sub-pos=95",
        "--sub-use-margins=no",
        f"--script={LUA_SCRIPT}",
        f"--script={HEATMAP_SCRIPT}",
    ]
    for video in videos:
        # 每个播放列表条目单独绑定字幕，切换视频时不会混用字幕。
        command.extend(["--{", *video_options(video), "--}"])
    return command


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "videos", nargs="*", type=Path,
        help="视频文件或文件夹（添加当前层所有 FLV）；不指定则显示选择菜单",
    )
    parser.add_argument("--dry-run", action="store_true", help="只检查文件并打印 mpv 命令")
    args = parser.parse_args()

    for script in (LUA_SCRIPT, HEATMAP_SCRIPT):
        if not script.is_file():
            parser.exit(1, f"找不到 mpv 脚本：{script}\n")
    if not args.dry_run and not shutil.which("mpv"):
        parser.exit(1, "找不到 mpv 可执行程序\n")

    try:
        inputs = args.videos or [choose_video()]
        if inputs == [None]:
            return 0
        videos = collect_videos(inputs)
        command = command_for(videos)
        if args.dry_run:
            print(shlex.join(command))
        else:
            print(f"播放列表共 {len(videos)} 个视频，正在播放：{videos[0]}", flush=True)
            if subprocess.run(command, check=False).returncode:
                return 1
    except (OSError, ValueError) as error:
        print(f"启动失败：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
