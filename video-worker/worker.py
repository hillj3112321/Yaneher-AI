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
import asyncio
import httpx
from io import BytesIO
from pathlib import Path
from typing import Any
from fastapi import FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from PIL import Image, ImageChops, ImageStat

MAX_BYTES = int(os.getenv("VIDEO_MAX_MB", "150")) * 1024 * 1024
MAX_SECONDS = int(os.getenv("VIDEO_MAX_DURATION", "600"))
SUPABASE_URL = os.getenv("SUPABASE_URL", "").rstrip("/")
SUPABASE_ANON_KEY = os.getenv("SUPABASE_ANON_KEY", "")
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY", "")
GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-2.5-flash")
SEGMENT_SECONDS = max(30, min(int(os.getenv("VIDEO_SEGMENT_SECONDS", "120")), 240))
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



async def authorize_and_claim(authorization: str | None) -> str:
    """Validate Supabase JWT, ban state and 60-second cooldown, entirely server-side."""
    if not SUPABASE_URL or not SUPABASE_ANON_KEY or not GEMINI_API_KEY:
        raise HTTPException(503, 'Сервер анализа видео не настроен: нужны ключи Supabase и Gemini')
    if not authorization or not authorization.startswith('Bearer ') or len(authorization) > 5000:
        raise HTTPException(401, 'Сначала войди в аккаунт')
    headers={'apikey':SUPABASE_ANON_KEY,'Authorization':authorization}
    async with httpx.AsyncClient(timeout=15.0) as client:
        try:
            res=await client.get(SUPABASE_URL+'/auth/v1/user',headers=headers)
            if res.status_code != 200 or not res.json().get('id'):
                raise HTTPException(401, 'Сессия Supabase не подтверждена')
            claim=await client.post(SUPABASE_URL+'/rest/v1/rpc/v11_claim_ai',headers=headers,json={})
            if claim.status_code != 200:
                raise HTTPException(403, 'Доступ к ЯнеИИ ограничен. Проверь роль или блокировку.')
            remaining=int(claim.json())
            if remaining>0:
                raise HTTPException(429, f'Подожди {remaining} секунд перед следующим запросом ЯнеИИ')
            return res.json()['id']
        except httpx.HTTPError as ex:
            raise HTTPException(503, 'Не удалось связаться с Supabase для проверки аккаунта') from ex

async def analyze_with_gemini(path: str, mime: str, metadata: dict, cuts: list[float], audio: dict, language: str = 'ru', question: str = '') -> dict[str, Any]:
    """Upload the entire file (including sound) to Google Files API, analyze every segment.

    Gemini chooses its own internal frame sampling; scanning each actual video frame
    is separately performed by FFmpeg get_scenes(). Claims must reflect this.
    """
    size=os.path.getsize(path)
    host='https://generativelanguage.googleapis.com'
    key_headers={'x-goog-api-key':GEMINI_API_KEY}
    filename=None
    async with httpx.AsyncClient(timeout=httpx.Timeout(connect=20,read=120,write=240,pool=15),follow_redirects=False) as client:
        try:
            initial=await client.post(host+'/upload/v1beta/files',headers={
                **key_headers,
                'X-Goog-Upload-Protocol':'resumable',
                'X-Goog-Upload-Command':'start',
                'X-Goog-Upload-Header-Content-Length':str(size),
                'X-Goog-Upload-Header-Content-Type':mime,
                'Content-Type':'application/json',
            },json={'file':{'display_name':'YaneCLIBB video analysis'}})
            if initial.status_code not in (200,201):
                raise HTTPException(502,'Gemini Files API: '+str(initial.status_code)+' '+initial.text[:200])
            upload_url=initial.headers.get('X-Goog-Upload-URL','')
            if not upload_url.startswith('https://') or not (httpx.URL(upload_url).host or '').endswith('.googleapis.com'):
                raise HTTPException(502,'Gemini не предоставил безопасный URL для загрузки')
            async def data_chunks():
                with open(path,'rb') as handle:
                    while True:
                        block=handle.read(1024*1024)
                        if not block: break
                        yield block
            uploaded=await client.post(upload_url,headers={'Content-Length':str(size),
                'X-Goog-Upload-Offset':'0','X-Goog-Upload-Command':'upload, finalize'},content=data_chunks())
            if uploaded.status_code not in (200,201):
                raise HTTPException(502,'Gemini не принял видео: '+str(uploaded.status_code)+' '+uploaded.text[:200])
            info=uploaded.json().get('file') or {}
            filename=info.get('name')
            uri=info.get('uri')
            if not filename or not uri:
                raise HTTPException(502,'Gemini не вернул имя загруженного видео')
            for _ in range(45):
                if str(info.get('state') or '').upper()=='ACTIVE': break
                if str(info.get('state') or '').upper()=='FAILED':
                    raise HTTPException(502,'Gemini не смог обработать видеофайл')
                await asyncio.sleep(3)
                check=await client.get(host+'/v1beta/'+filename,headers=key_headers)
                if check.status_code!=200:
                    raise HTTPException(502,'Gemini Files API status: '+str(check.status_code))
                info=check.json()
                if 'file' in info: info=info['file']
            else:
                raise HTTPException(504,'Gemini слишком долго обрабатывает видео')
            duration=float(metadata['duration']);segments=[]
            current=0.0
            while current<duration:
                end=min(duration,current+SEGMENT_SECONDS)
                if end-current<0.1:break
                relevant_cuts=[x for x in cuts if current<=x<=end][:80]
                silences=[x for x in audio.get('silences',[]) if current<=x['start']<=end][:30]
                lang_label={'ru':'русском','uk':'украинском','en':'английском'}.get(language,'русском')
                prompt=(
                 'Отвечай на '+lang_label+' языке, если пользователь явно не попросил другой. ' +
                 'Запрос пользователя: '+question[:2000]+'\n'+
                 'Ты эксперт по нарезкам стримов и профессиональному видеомонтажу. Получено НАСТОЯЩЕЕ '
                 'видео со всей аудиодорожкой. Анализируй ТОЛЬКО данный временной диапазон, '
                 f'от {current:.2f} до {end:.2f} сек (таймкоды в отчёте АБСОЛЮТНЫЕ). '
                 'Рассмотри речь, музыкальные акценты, голос, посторонние шумы, эффекты, '
                 'интенсивность склеек, субтитры, композицию, первый и последний кадры сегмента. '
                 'Используй подтверждённые факты: не выдумывай речь, музыку, смысл сцен или '
                 'ошибки, если их нельзя определить. Технические склейки FFmpeg (вероятные): '
                 f'{relevant_cuts}. Технические интервалы тишины: {silences}. '
                 f'Интегральная громкость: {audio.get("integratedLufs")} LUFS. '
                 'Ответь по-русски, структурированным JSON: '
                 '{"summary":"...","speech":"...","music":"...",'
                 '"findings":[{"time":"00:03–00:05","category":"Звук/Монтаж/...",'
                 '"observation":"...","recommendation":"..."}],'
                 '"scores":{"editing":{"score":0,"reason":"..."},'
                 '"pacing":{"score":0,"reason":"..."},'
                 '"sound":{"score":0,"reason":"..."},'
                 '"effects":{"score":0,"reason":"..."},'
                 '"picture":{"score":0,"reason":"..."}}}. '
                 'Оценка 0–10 только если есть основания; иначе score:null. '
                 'Не утверждай, что рассмотрел каждый кадр — возможна выборка моделью.'
                )
                content={'contents':[{'role':'user','parts':[
                  {'fileData':{'mimeType':mime,'fileUri':uri},
                   'videoMetadata':{'startOffset':f'{current:.2f}s','endOffset':f'{end:.2f}s'}},
                  {'text':prompt}]}],
                  'generationConfig':{'maxOutputTokens':8192,'responseMimeType':'application/json'}}
                r=await client.post(host+'/v1beta/models/'+GEMINI_MODEL+':generateContent',headers={**key_headers,'content-type':'application/json'},json=content)
                if r.status_code!=200:
                    raise HTTPException(502,'Gemini video segment HTTP '+str(r.status_code)+': '+r.text[:260])
                raw='\n'.join(part.get('text','') for c in r.json().get('candidates',[])
                              for part in c.get('content',{}).get('parts',[]) if 'text' in part)
                try:parsed=json.loads(raw)
                except (ValueError,TypeError):parsed={'summary':raw[:12000]}
                segments.append({'start':round(current,2),'end':round(end,2),'analysis':parsed})
                current=end
            return {'segments':segments,'fullFileUploaded':True,'audioProvided':bool(metadata['hasAudio']),
                    'segmentSeconds':SEGMENT_SECONDS}
        except httpx.HTTPError as ex:
            raise HTTPException(503,'Ошибка соединения с Gemini Files API: '+str(ex)[:150]) from ex
        finally:
            if filename and filename.startswith('files/'):
                try:
                    await client.delete(host+'/v1beta/'+filename,headers=key_headers,timeout=15)
                except Exception: pass

@app.get('/health')
def health():
    return {'status':'ready','fullTimeline':True,'audioMetadata':True,'videoAndAudioAI':bool(GEMINI_API_KEY),'authRequired':True}


@app.post('/analyze')
async def analyze(file: UploadFile = File(...), authorization: str | None = Header(default=None),
                  question: str = Form(default=''), language: str = Form(default='ru')):
    await authorize_and_claim(authorization)
    if file.content_type not in ('video/mp4', 'video/webm', 'video/quicktime'):
        raise HTTPException(415, 'Поддерживаются MP4, WebM и MOV')
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
        tech={'metadata':meta,'sceneCuts':scenes,'audio':audio,'visual':frames}
        semantic = await analyze_with_gemini(path,file.content_type,meta,scenes,audio,language,question)
        return {**tech,'semantic':semantic,'model':GEMINI_MODEL,
                'limitations':'Весь файл со звуком отправлен Gemini; технический анализ FFmpeg проходит полный таймлайн. Модель может выбирать кадры внутри видео и ошибаться. Оценки не являются гарантией просмотров.'}
