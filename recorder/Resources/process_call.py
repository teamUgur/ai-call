#!/usr/bin/env python3
"""Turns one call folder (me.wav + them.wav) into transcript.txt, transcript.srt and summary.md.

Usage: process_call.py <call folder>

Transcription runs locally with whisper.cpp. The summary goes through `claude -p` on Ugur's
Claude subscription (no API key). The script never sends the follow-up draft anywhere.
Prints "STAGE <name>" lines so the app can show progress. Runs on macOS's /usr/bin/python3 (3.9).
"""
import json
import os
import re
import subprocess
import sys
import tempfile

BIN = "/opt/homebrew/bin"
FFMPEG = BIN + "/ffmpeg"
WHISPER = BIN + "/whisper-cli"
CLAUDE = BIN + "/claude"
MODELS = os.path.expanduser("~/.cache/whisper.cpp")
MODEL = os.path.join(MODELS, "ggml-large-v3-turbo-q5_0.bin")
VAD_MODEL = os.path.join(MODELS, "ggml-silero-v5.1.2.bin")
TRACKS = [("me", "Я"), ("them", "Собеседник")]

# Phrases Whisper invents on silence and noise in Russian (it learned them from subtitle files).
HALLUCINATION = re.compile(
    r"субтитр|продолжение следует|спасибо за просмотр|подписывайтесь|dimatorzok|amara\.org",
    re.IGNORECASE,
)

SUMMARY_PROMPT = """Ниже расшифровка моего звонка. «Я» - это я (Угур), «Собеседник» - другая сторона (если в звонке несколько человек, они все записаны как «Собеседник»). Таймкоды в квадратных скобках.

Напиши итог звонка на русском языке в Markdown строго в таком виде:

# <короткое название звонка, 3-7 слов>

## Коротко
3-6 предложений: о чём был звонок и чем закончился.

## Решения и задачи
- Что решили.
- Задачи списком: кто делает, что именно, срок (если срок назвали). Если задач нет, так и напиши.

## Ключевые цитаты
3-6 дословных цитат из расшифровки с таймкодом и автором, например: > [00:12:05] Собеседник: «...»

## Черновик follow-up
Короткое сообщение от меня собеседнику после звонка: благодарность, договорённости, следующие шаги. Тон живой и вежливый, без канцелярита.

Правила: используй только то, что есть в расшифровке, ничего не придумывай. Если речь неразборчива или звонок пустой, напиши об этом коротко. Выведи только Markdown, без вступлений и пояснений.

Расшифровка:
"""


def stage(name):
    print("STAGE " + name, flush=True)


def duration(path):
    result = subprocess.run(
        [BIN + "/ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
        capture_output=True, text=True,
    )
    try:
        return float(result.stdout.strip())
    except ValueError:
        return 0.0


def transcribe(folder, track, speaker, workdir):
    wav = os.path.join(folder, track + ".wav")
    if not os.path.exists(wav) or duration(wav) < 1:
        return []
    pcm = os.path.join(workdir, track + ".wav")
    subprocess.run([FFMPEG, "-y", "-loglevel", "error", "-i", wav, "-ac", "1", "-ar", "16000", pcm], check=True)
    out = os.path.join(workdir, track)
    command = [WHISPER, "-m", MODEL, "-l", "ru", "-oj", "-of", out, "-np", "-mc", "0", "-sns"]
    if os.path.exists(VAD_MODEL):
        command += ["--vad", "-vm", VAD_MODEL]
    subprocess.run(command + ["-f", pcm], check=True, stdout=subprocess.DEVNULL)
    with open(out + ".json", encoding="utf-8") as file:
        data = json.load(file)
    segments = []
    for item in data.get("transcription", []):
        text = item["text"].strip()
        if not text or HALLUCINATION.search(text):
            continue
        segments.append({
            "start": item["offsets"]["from"] / 1000,
            "end": item["offsets"]["to"] / 1000,
            "speaker": speaker,
            "text": text,
        })
    return segments


def clock(seconds, srt=False):
    millis = int(round(seconds * 1000))
    hours, rest = divmod(millis, 3_600_000)
    minutes, rest = divmod(rest, 60_000)
    secs, millis = divmod(rest, 1000)
    if srt:
        return "%02d:%02d:%02d,%03d" % (hours, minutes, secs, millis)
    return "%02d:%02d:%02d" % (hours, minutes, secs)


def write_transcript(folder, segments):
    # One paragraph per turn: consecutive segments of the same speaker are joined.
    turns = []
    for segment in segments:
        if turns and turns[-1]["speaker"] == segment["speaker"] and segment["start"] - turns[-1]["end"] < 3:
            turns[-1]["text"] += " " + segment["text"]
            turns[-1]["end"] = segment["end"]
        else:
            turns.append(dict(segment))
    text = "\n\n".join("[%s] %s: %s" % (clock(t["start"]), t["speaker"], t["text"]) for t in turns)
    with open(os.path.join(folder, "transcript.txt"), "w", encoding="utf-8") as file:
        file.write(text + "\n")

    blocks = []
    for number, segment in enumerate(segments, 1):
        blocks.append("%d\n%s --> %s\n%s: %s\n" % (
            number, clock(segment["start"], True), clock(segment["end"], True), segment["speaker"], segment["text"],
        ))
    with open(os.path.join(folder, "transcript.srt"), "w", encoding="utf-8") as file:
        file.write("\n".join(blocks))
    return text


def write_summary(folder, transcript):
    path = os.path.join(folder, "summary.md")
    if not transcript.strip():
        with open(path, "w", encoding="utf-8") as file:
            file.write("# Пустой звонок\n\nВ записи не найдено речи.\n")
        return
    env = dict(os.environ, PATH=BIN + ":/usr/bin:/bin")
    result = subprocess.run(
        [CLAUDE, "-p", "--tools", "", "--strict-mcp-config", "--no-session-persistence"],
        input=SUMMARY_PROMPT + transcript, capture_output=True, text=True, cwd=folder, env=env, timeout=900,
    )
    if result.returncode != 0 or not result.stdout.strip():
        raise RuntimeError("claude -p failed: " + (result.stderr or result.stdout).strip()[:2000])
    with open(path, "w", encoding="utf-8") as file:
        file.write(result.stdout.strip() + "\n")


def update_call_json(folder):
    path = os.path.join(folder, "call.json")
    try:
        with open(path, encoding="utf-8") as file:
            info = json.load(file)
    except (OSError, ValueError):
        info = {}
    info["transcript"] = "transcript.txt"
    info["subtitles"] = "transcript.srt"
    info["summary"] = "summary.md"
    info["whisper_model"] = os.path.basename(MODEL)
    with open(path, "w", encoding="utf-8") as file:
        json.dump(info, file, ensure_ascii=False, indent=2, sort_keys=True)


def main():
    folder = os.path.abspath(sys.argv[1])
    error_path = os.path.join(folder, "error.txt")
    if os.path.exists(error_path):
        os.remove(error_path)
    try:
        stage("transcribing")
        with tempfile.TemporaryDirectory() as workdir:
            segments = []
            for track, speaker in TRACKS:
                segments += transcribe(folder, track, speaker, workdir)
        segments.sort(key=lambda s: s["start"])
        transcript = write_transcript(folder, segments)
        stage("summarizing")
        write_summary(folder, transcript)
        update_call_json(folder)
        stage("done")
    except Exception as error:  # the app shows error.txt next to the call
        with open(error_path, "w", encoding="utf-8") as file:
            file.write(str(error) + "\n")
        stage("failed")
        sys.exit(1)


if __name__ == "__main__":
    main()
