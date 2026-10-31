"""Optional video inspection server for YaneCLIBB v10.

Runs FFmpeg through full timeline to find scene cuts and audible silence;
returns timecoded measurements and representative frames, NOT claimed story/retention.
Start: uvicorn worker:app --host 0.0.0.0 --port 8080
"""
import base64
import json
import math
import os
import re
import subprocess
import tempfile
from io import BytesIO
from pathlib import Path
from typing import Any
from fastapi import FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from PIL import Image, ImageChops, ImageStat

MAX_BYTES = int(os.getenv("VIDEO_MAX_MB", "150")) * 1024 * 1024
MAX_SECONDS = int(os.getenv("VIDEO_MAX_DURATION", "600"))
CODE = os.getenv("VIDEO_WORKER_CODE", "")
ORIGINS = [x.strip() for x in os.getenv("ALLOWED_ORIGINS", "").split(",") if x.strip()]
app = FastAPI(title="YaneCLIBB Video Worker", docs_url=None, redoc_url=None)
app.add_middleware(CORSMiddleware, allow_origins=ORIGINS, allow_methods=["POST", "GET"], allow_headers=["Authorization", "Content-Type"])


def run(args: list[str], timeout: float) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired as exc:
        raise HTTPException(504, "Время обработки FFmpeg истекло") from exc


def inspect_ffprobe(path: str) -> dict[str, Any]:
    r = run(["ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", path], timeout=16)
    if r.returncode:
        raise HTTPException(422, "Файл не декодируется FFprobe")
    try:
        raw = json.loads(r.stdout)
        video = next(s for s in raw["streams"] if s.get("codec_type") == "video")
    except (KeyError, StopIteration, ValueError) as exc:
        raise HTTPException(422, "В файле нет распознаваемого видеопотока") from exc
    audio = next((s for s in raw.get("streams", []) if s.get("codec_type") == "audio"), None)
    fps_raw = video.get("avg_frame_rate", "0/1")
    try:
        n, d = fps_raw.split("/")
        fps = round(int(n) / int(d), 3) if int(d) else None
    except (ValueError, ZeroDivisionError):
        fps = None
    duration = float(raw.get("format", {}).get("duration") or video.get("duration") or 0)
    if not (0 < duration <= MAX_SECONDS):
        raise HTTPException(413, f"Допустимая длительность: до {MAX_SECONDS} секунд")
    return {
        "width": video.get("width"),
        "height": video.get("height"),
        "fps": fps,
        "duration": round(duration, 3),
        "videoCodec": video.get("codec_name"),
        "hasAudio": bool(audio),
        "audioCodec": audio.get("codec_name") if audio else None,
        "sampleStep": max(1, duration / 120),
    }


def get_scenes(path: str) -> list[float]:
    # This filter decodes frames across the entire video; not three screenshots.
    r = run(["ffmpeg", "-nostdin", "-hide_banner", "-i", path, "-vf", "select=gt(scene\\,0.28),showinfo", "-an", "-f", "null", "-"], timeout=110)
    vals = [float(v) for v in re.findall(r"pts_time:([0-9]+(?:\.[0-9]+)?)", r.stderr)]
    return sorted({round(v, 2) for v in vals})[:200]


def get_audio(path: str, has_audio: bool) -> dict[str, Any]:
    if not has_audio:
        return {"available": False, "silences": [], "integratedLufs": None}
    r = run(["ffmpeg", "-nostdin", "-hide_banner", "-i", path, "-vn", "-af", "silencedetect=noise=-32dB:d=0.45,ebur128", "-f", "null", "-"], timeout=110)
    starts = [float(v) for v in re.findall(r"silence_start:\s*([0-9.]+)", r.stderr)]
    ends = [float(v) for v in re.findall(r"silence_end:\s*([0-9.]+)", r.stderr)]
    silences = [{"start": round(s, 2), "end": round(ends[i], 2)} for i, s in enumerate(starts) if i < len(ends) and ends[i] > s][:60]
    # FFmpeg ebur128 summary: avoid reporting arbitrary loudness as speech intelligibility.
    matches = re.findall(r"Integrated loudness:\s*I:\s*([-+]?\d+(?:\.\d+)?) LUFS", r.stderr)
    lufs = float(matches[-1]) if matches else None
    return {"available": True, "silences": silences, "integratedLufs": lufs,
            "note": "Уровни и тишина обнаружены технически; качество речи и музыка не распознаны."}


def analyze_frames(path: str, folder: str, duration: float, step: float) -> dict[str, Any]:
    pattern = str(Path(folder) / "s%04d.jpg")
    rate = f"fps=1/{step:.5f},scale=240:-1"
    r = run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-i", path,
             "-vf", rate, "-frames:v", "121", "-q:v", "6", pattern], timeout=110)
    if r.returncode:
        return {"samples": [], "events": [], "representativeFrames": []}
    files = sorted(Path(folder).glob('s*.jpg'))
    readings = []
    prev = None
    for i, file in enumerate(files):
        with Image.open(file) as image:
            image = image.convert('L').resize((32, 32))
            avg = float(ImageStat.Stat(image).mean[0])
            dif = float(ImageStat.Stat(ImageChops.difference(image, prev)).mean[0]) if prev else 0
            readings.append({"time": round(min(duration, i * step), 2), "brightness": round(avg, 1), "difference": round(dif, 1)})
            prev = image.copy()
    events = []
    for s in readings:
        if s['brightness'] < 26:
            events.append({"time": s['time'], "type": "dark", "note": "Очень тёмный кадр; проверь детали и субтитры."})
        elif s['brightness'] > 235:
            events.append({"time": s['time'], "type": "bright", "note": "Возможный пересвет; проверь видимость деталей."})
        if s['difference'] < 2 and s['time'] > 0 and step >= 1:
            events.append({"time": s['time'], "type": "static", "note": "Почти неизменная картинка между выборками; возможно, пауза."})
    frames = []
    limit = min(20, len(files))
    for i in range(limit):
        idx = round(i*(len(files)-1)/max(1,limit-1))
        data = files[idx].read_bytes()
        frames.append({"time": readings[idx]['time'], "image": "data:image/jpeg;base64,"+base64.b64encode(data).decode('ascii')})
    return {"samples": readings, "events": events[:90], "representativeFrames": frames}


@app.get('/health')
def health():
    return {'status': 'ready', 'fullTimeline': True, 'audioMetadata': True}


@app.post('/analyze')
async def analyze(file: UploadFile = File(...), authorization: str | None = Header(default=None)):
    if not CODE or authorization != 'Bearer '+CODE:
        raise HTTPException(401, 'Неверный код доступа к серверному анализу')
    if not (file.content_type or '').startswith('video/'):
        raise HTTPException(415, 'Нужен видеофайл')
    with tempfile.TemporaryDirectory(prefix='yane_worker_') as folder:
        path = str(Path(folder)/'upload.bin')
        size = 0
        with open(path,'wb') as output:
            while True:
                chunk = await file.read(1024*1024)
                if not chunk: break
                size += len(chunk)
                if size > MAX_BYTES: raise HTTPException(413, 'Файл слишком большой')
                output.write(chunk)
        if not size: raise HTTPException(400, 'Пустой файл')
        meta = inspect_ffprobe(path)
        scenes = get_scenes(path)
        audio = get_audio(path,meta['hasAudio'])
        frames = analyze_frames(path,folder,meta['duration'],meta['sampleStep'])
        return {'metadata':meta, 'sceneCuts':scenes, 'audio':audio, 'visual':frames,
                'limitations':'Алгоритмы FFmpeg измеряют сцены, яркость и тишину, но не понимают смысл сцен и речь. Действительное удержание нельзя определить по файлу.'}
