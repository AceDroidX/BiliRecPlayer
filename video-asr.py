#!/usr/bin/env python3
"""提取视频中的 AAC 音轨并请求本地 ASR 服务。"""

import argparse
import json
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path


API_URL = "http://localhost:8000/v1/audio/transcriptions"
MODEL = "OpenMOSS-Team/MOSS-Transcribe-Diarize"
LANGUAGE = "zh"
RESPONSE_FORMAT = "diarized_json"
PROMPT = (
    "请将音频转写为文本，每一段需以起始时间戳和说话人编号（[S01]、[S02]、[S03]…）开头，"
    "正文为对应的语音内容，并在段末标注结束时间戳，以清晰标明该段语音范围。"
    "热词提示：七海, 海子姐, 海海, 娜米, 脆鲨, 直播, 主播, 观时, 谢谢, Super Chat, SC"
)


def now():
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]


def format_duration(seconds):
    milliseconds = round(seconds * 1000)
    hours, remainder = divmod(milliseconds, 3_600_000)
    minutes, remainder = divmod(remainder, 60_000)
    whole_seconds, milliseconds = divmod(remainder, 1000)
    if hours:
        return f"{hours:02d}:{minutes:02d}:{whole_seconds:02d}.{milliseconds:03d}"
    if minutes:
        return f"{minutes:02d}:{whole_seconds:02d}.{milliseconds:03d}"
    return f"{whole_seconds}.{milliseconds:03d} 秒"


def notify(title, message):
    try:
        subprocess.run(
            ["notify-send", title, message],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except OSError:
        pass


def check_audio_codec(source):
    print(f"[{now()}] >>> 检查音轨开始", flush=True)
    started = time.monotonic()
    result = subprocess.run(
        [
            "ffprobe", "-v", "error", "-select_streams", "a:0",
            "-show_entries", "stream=codec_name",
            "-of", "default=noprint_wrappers=1:nokey=1", str(source),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    print(f"[{now()}] <<< 检查音轨结束", flush=True)
    print(f"[{now()}]     检查音轨耗时：{format_duration(time.monotonic() - started)}", flush=True)

    if result.returncode:
        detail = result.stderr.strip()
        raise RuntimeError(f"ffprobe 执行失败{f'：{detail}' if detail else ''}")
    codec = result.stdout.strip()
    if not codec:
        raise RuntimeError("没有找到音轨")
    print(f"[{now()}] 音频编码：{codec}", flush=True)
    if codec != "aac":
        raise RuntimeError(f"音轨为 {codec}，不是 AAC")


def transcribe(source, temporary_output):
    started = time.monotonic()
    print(f"[{now()}] >>> ASR 管道开始", flush=True)
    ffmpeg = subprocess.Popen(
        [
            "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
            "-i", str(source), "-map", "0:a:0", "-vn", "-c:a", "copy",
            "-f", "adts", "pipe:1",
        ],
        stdout=subprocess.PIPE,
    )
    ffmpeg_started = time.monotonic()
    print(f"[{now()}] >>> AAC 提取开始", flush=True)
    print(f"[{now()}] >>> ASR 请求开始", flush=True)
    curl_started = time.monotonic()
    try:
        with temporary_output.open("wb") as output_file:
            try:
                curl = subprocess.run(
                    [
                        "curl", "-N", "--fail-with-body", "-sS", API_URL,
                        "-F", "file=@-;filename=audio.aac;type=audio/aac",
                        "-F", f"model={MODEL}",
                        "-F", f"response_format={RESPONSE_FORMAT}",
                        "-F", f"language={LANGUAGE}",
                        "-F", "max_completion_tokens=16384",
                        "-F", f"prompt={PROMPT}",
                    ],
                    stdin=ffmpeg.stdout,
                    stdout=output_file,
                    check=False,
                )
            finally:
                if ffmpeg.stdout is not None:
                    ffmpeg.stdout.close()
        print(f"[{now()}] <<< ASR 请求结束", flush=True)
        print(f"[{now()}]     ASR 请求耗时：{format_duration(time.monotonic() - curl_started)}", flush=True)
    finally:
        ffmpeg_status = ffmpeg.wait()
        print(f"[{now()}] <<< AAC 提取结束", flush=True)
        print(f"[{now()}]     AAC 提取耗时：{format_duration(time.monotonic() - ffmpeg_started)}", flush=True)
        print(f"[{now()}] <<< ASR 管道结束", flush=True)
        print(f"[{now()}]     ASR 管道耗时：{format_duration(time.monotonic() - started)}", flush=True)

    if ffmpeg_status or curl.returncode:
        raise RuntimeError(f"音频提取或 ASR 请求失败（ffmpeg: {ffmpeg_status}，curl: {curl.returncode}）")

    # 避免把接口错误消息或不完整响应保存为转写结果。
    with temporary_output.open("r", encoding="utf-8") as file:
        response = json.load(file)
    if not isinstance(response, dict) or not isinstance(response.get("segments"), list):
        raise RuntimeError("ASR 响应不是 diarized_json（缺少 segments 数组）")


def process_file(source):
    if not source.is_file():
        raise RuntimeError(f"文件不存在：{source}")

    destination = source.with_suffix(".json")
    started = time.monotonic()
    started_at = now()
    print()
    print("=" * 60)
    print(f"文件：{source.name}")
    print(f"输入：{source}")
    print(f"输出：{destination}")
    print(f"任务开始时间：{started_at}")
    print("=" * 60, flush=True)

    check_audio_codec(source)
    notify("语音识别", f"正在识别：{source.name}")

    # 临时文件放在输出目录，以便成功后原子替换目标文件。
    with tempfile.NamedTemporaryFile(
        prefix=f".{destination.name}.", suffix=".tmp", dir=destination.parent, delete=False
    ) as file:
        temporary_output = Path(file.name)
    try:
        transcribe(source, temporary_output)
        temporary_output.replace(destination)
    finally:
        temporary_output.unlink(missing_ok=True)

    elapsed = format_duration(time.monotonic() - started)
    print()
    print("=" * 60)
    print("任务完成")
    print(f"文件：{source.name}")
    print(f"输出：{destination}")
    print(f"开始时间：{started_at}")
    print(f"结束时间：{now()}")
    print(f"总耗时：{elapsed}")
    print("=" * 60, flush=True)
    notify("语音识别完成", f"{source.name} → {destination.name}\n耗时：{elapsed}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", nargs="+", type=Path, help="要识别的视频文件")
    args = parser.parse_args()

    for source in args.inputs:
        try:
            process_file(source)
        except (OSError, UnicodeError, ValueError, RuntimeError) as error:
            print(f"识别失败：{source}：{error}", file=sys.stderr)
            notify("语音识别失败", f"{source.name}：{error}")
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
