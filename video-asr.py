#!/usr/bin/env python3
"""提取视频中的 AAC 音轨并请求本地 ASR 服务。"""

import argparse
import json
import math
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
    "热词提示：七海, 海子姐, 海海, 娜米, 脆鲨, 直播, 主播, 观时, 谢谢, 钢镚, Super Chat, SC"
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


def get_audio_duration(source):
    result = subprocess.run(
        [
            "ffprobe", "-v", "error", "-select_streams", "a:0",
            "-show_entries", "stream=duration:format=duration", "-of", "json", str(source),
        ],
        capture_output=True, text=True, check=False,
    )
    if result.returncode:
        raise RuntimeError(f"读取音频时长失败：{result.stderr.strip()}")
    data = json.loads(result.stdout)
    # 优先使用音轨时长，部分容器仅提供文件总时长。
    candidates = [stream.get("duration") for stream in data.get("streams", [])]
    candidates.append(data.get("format", {}).get("duration"))
    for value in candidates:
        try:
            duration = float(value)
        except (TypeError, ValueError):
            continue
        if math.isfinite(duration) and duration > 0:
            return duration
    raise RuntimeError("无法取得有效的音频时长")


def transcribe(source, temporary_output, start=None, duration=None):
    started = time.monotonic()
    print(f"[{now()}] >>> ASR 管道开始", flush=True)
    command = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error"]
    if start is not None:
        command.extend(["-ss", str(start)])
    command.extend(["-i", str(source), "-map", "0:a:0", "-vn"])
    if duration is not None:
        # 分段时重新编码，确保准确裁切并使每段从零开始计时。
        command.extend(["-t", str(duration), "-c:a", "aac"])
    else:
        command.extend(["-c:a", "copy"])
    command.extend(["-f", "adts", "pipe:1"])
    ffmpeg = subprocess.Popen(command, stdout=subprocess.PIPE)
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
    return response


def transcribe_in_segments(source, temporary_output, segment_seconds):
    duration = get_audio_duration(source)
    count = math.ceil(duration / segment_seconds)
    merged = None
    segments = []
    speaker_count = 0
    with tempfile.TemporaryDirectory(prefix="video-asr-") as directory:
        chunk_output = Path(directory) / "response.json"
        for index in range(count):
            offset = index * segment_seconds
            print(f"[{now()}] 分段识别：{index + 1}/{count}，起点 {format_duration(offset)}", flush=True)
            response = transcribe(source, chunk_output, offset, min(segment_seconds, duration - offset))
            if merged is None:
                merged = dict(response)
            speakers = {}
            for segment in response["segments"]:
                if not isinstance(segment, dict) or not isinstance(segment.get("text"), str):
                    raise RuntimeError("ASR 分段响应包含无效的文本段")
                item = dict(segment)
                # 将分段相对时间转换为原文件时间，同时检查接口返回值。
                for key in ("start", "end"):
                    value = item.get(key)
                    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
                        raise RuntimeError(f"ASR 分段响应包含无效的 {key} 时间戳：{value!r}")
                    item[key] = round(value + offset, 6)
                if item["end"] <= item["start"]:
                    raise RuntimeError("ASR 分段响应的结束时间不晚于开始时间")
                speaker = item.get("speaker")
                if speaker:
                    if not isinstance(speaker, str):
                        raise RuntimeError("ASR 分段响应包含无效的说话人编号")
                    # 不同请求中的同名说话人不一定是同一个人。
                    if speaker not in speakers:
                        speaker_count += 1
                        speakers[speaker] = f"S{speaker_count:02d}"
                    item["speaker"] = speakers[speaker]
                if "id" in item:
                    item["id"] = len(segments)
                segments.append(item)
    if merged is None:
        raise RuntimeError("没有取得任何 ASR 分段响应")
    merged["segments"] = segments
    merged["text"] = "".join(item["text"] for item in segments)
    if "duration" in merged:
        merged["duration"] = duration
    temporary_output.write_text(json.dumps(merged, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def process_file(source, segment_minutes=None):
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
        if segment_minutes is None:
            transcribe(source, temporary_output)
        else:
            transcribe_in_segments(source, temporary_output, segment_minutes * 60)
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
    parser.add_argument(
        "--segment-minutes", type=float, metavar="分钟",
        help="按指定分钟数分段提交（支持小数）；默认不分段",
    )
    args = parser.parse_args()
    if args.segment_minutes is not None and (
        not math.isfinite(args.segment_minutes) or args.segment_minutes <= 0
        or not math.isfinite(args.segment_minutes * 60)
    ):
        parser.error("--segment-minutes 必须是大于 0 的有限分钟数")

    for source in args.inputs:
        try:
            process_file(source, args.segment_minutes)
        except (OSError, UnicodeError, ValueError, RuntimeError) as error:
            print(f"识别失败：{source}：{error}", file=sys.stderr)
            notify("语音识别失败", f"{source.name}：{error}")
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
