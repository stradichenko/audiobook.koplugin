#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
TTS 中继 · 云端版（PythonAnywhere / 任意 WSGI 平台）
=================================================
作用：把 edge-tts（微软真人中文音色，免费）合成结果转成 WAV，
      通过【纯 HTTP】发给 Kindle 3 播放。设备端零依赖、不需要 TLS。

为什么要有云端版？
  · 手机/本地版(tts_relay_android.py) 用 ffmpeg 做 mp3→WAV；
    PythonAnywhere 等共享托管【装不了系统 ffmpeg】，所以本版换用 PyAV
    （av 是自带 ffmpeg 二进制的 wheel，pip 就能装，不需要 root）。
  · 对外是【纯 HTTP】(http://xxx.pythonanywhere.com)，Kindle 3 那台
    TLS/DNS 栈坏掉的设备才能访问 —— 这正是本版存在的唯一理由。

★ 已实测（2026-09）：edge-tts 7.x 已移除 output_format，只能拿 MP3；
  本脚本用 av 把 MP3 解码并重采样到 16000Hz 单声道 16bit，再包成 WAV。
  16000Hz 是本地版验证过的「干净路」（8000Hz 直出会全程吱吱，勿用）。

部署后 Kindle「在线接口地址」填：
  http://<用户名>.pythonanywhere.com/tts?voice=zh-CN-XiaoxiaoNeural&text={text}

路由：
  /          → 控制台（要填的地址 / 请求计数 / 在线试听）
  /tts       → 合成并回 WAV（核心）
  /healthz   → 健康检查
  /selftest  → ⚠关键自检：真合成一次，报告 edge-tts 与外网是否可用
"""

import asyncio
import io
import os
import shutil
import subprocess
import tempfile
import threading
import time
import wave

import flask
import edge_tts

app = flask.Flask(__name__)
# PythonAnywhere 的 WSGI 配置默认找名为 application 的对象
application = app

DEFAULT_VOICE = "zh-CN-XiaoxiaoNeural"
DEFAULT_RATE = os.environ.get("TTS_RATE", "+0%")
# 16000Hz：本地版实测的干净路（由 ALSA 降到设备时钟），别改成 8000
WAV_RATE = int(os.environ.get("TTS_WAV_RATE", "16000"))

_req_no = 0
_lock = threading.Lock()


def _log(msg):
    print(f"[{time.strftime('%m-%d %H:%M:%S')}] {msg}", flush=True)


# ---------- MP3 → WAV ----------
def _to_wav_via_av(mp3: bytes) -> bytes:
    """用 PyAV(自带 ffmpeg) 解码 mp3 并重采样；不需要系统 ffmpeg。"""
    import av  # 延迟导入：没装也能让服务先起来，错误更清楚
    buf = io.BytesIO(mp3)
    container = av.open(buf)
    resampler = av.AudioResampler(format="s16", layout="mono", rate=WAV_RATE)
    pcm = bytearray()
    for frame in container.decode(audio=0):
        for f in resampler.resample(frame):
            pcm += f.to_ndarray().tobytes()
    for f in resampler.resample(None):   # flush
        pcm += f.to_ndarray().tobytes()
    container.close()
    return _wrap_wav(bytes(pcm))


def _to_wav_via_ffmpeg(mp3: bytes) -> bytes:
    """退回：系统里有 ffmpeg 时的老路子（本地/有 root 的机器）。"""
    if not shutil.which("ffmpeg"):
        raise RuntimeError("ffmpeg 不可用")
    mp3_path = tempfile.mktemp(suffix=".mp3")
    wav_path = tempfile.mktemp(suffix=".wav")
    try:
        with open(mp3_path, "wb") as f:
            f.write(mp3)
        subprocess.run(
            ["ffmpeg", "-y", "-i", mp3_path, "-acodec", "pcm_s16le",
             "-ac", "1", "-ar", str(WAV_RATE), wav_path],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with open(wav_path, "rb") as f:
            return f.read()
    finally:
        for p in (mp3_path, wav_path):
            try:
                os.remove(p)
            except OSError:
                pass


def _wrap_wav(pcm: bytes) -> bytes:
    """给裸 PCM 加 44 字节 RIFF/WAVE 头。"""
    b = io.BytesIO()
    w = wave.open(b, "wb")
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(WAV_RATE)
    w.writeframes(pcm)
    w.close()
    return b.getvalue()


def _mp3_to_wav(mp3: bytes):
    """优先 PyAV，其次系统 ffmpeg。返回 (wav_bytes, err)。"""
    try:
        return _to_wav_via_av(mp3), None
    except Exception as e1:
        try:
            return _to_wav_via_ffmpeg(mp3), None
        except Exception as e2:
            return None, f"av失败({type(e1).__name__}: {e1}) / ffmpeg失败({e2})"


# ---------- 合成 ----------
async def _synth_mp3(text, voice, rate) -> bytes:
    chunks = []
    comm = edge_tts.Communicate(text, voice, rate=rate)
    async for ch in comm.stream():
        if ch.get("type") == "audio":
            chunks.append(ch["data"])
    return b"".join(chunks)


def _synth(text, voice, rate, tries=3):
    """合成→转WAV，带重试。返回 (wav, err)。"""
    err = ""
    for i in range(tries):
        try:
            mp3 = asyncio.run(_synth_mp3(text, voice, rate))
            if not mp3:
                raise RuntimeError("edge-tts 返回空")
            wav, e = _mp3_to_wav(mp3)
            if e:
                raise RuntimeError(e)
            return wav, None
        except Exception as e:
            err = f"{type(e).__name__}: {e}"
            if i < tries - 1:
                time.sleep(0.6)
    return None, err


INDEX_HTML = """<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>TTS 中继 · 云端</title>
<style>
 body{font-family:-apple-system,system-ui,"PingFang SC","Microsoft YaHei",sans-serif;
      max-width:680px;margin:0 auto;padding:16px;background:#fafafa;color:#222}
 h1{font-size:20px;margin:0 0 8px}
 .card{background:#fff;border:1px solid #e3e3e3;border-radius:10px;padding:14px;margin:12px 0}
 code{background:#f0f0f0;padding:2px 6px;border-radius:4px;word-break:break-all;display:inline-block}
 .muted{color:#888;font-size:13px;margin-top:6px}
 textarea{width:100%;box-sizing:border-box;font-size:15px;padding:8px;
          border:1px solid #ccc;border-radius:8px}
 button{margin-top:10px;background:#2d7cff;color:#fff;border:0;border-radius:8px;
        padding:10px 16px;font-size:15px}
 audio{width:100%;margin-top:10px}
</style></head><body>
<h1>📢 TTS 中继 · 云端（纯 HTTP）</h1>
<div class="card"><div>Kindle 插件填这行：<br>
<code>{{BASE}}/tts?voice={{VOICE}}&text={text}</code></div>
<div class="muted">保留 {text}；注意是 http 不是 https</div></div>
<div class="card"><div>累计请求：<b>{{REQ}}</b> 次 ｜ 输出：<b>{{RATE}}Hz</b></div>
<div class="muted">每读一句 +1 —— 数字在涨就说明 Kindle 连上了</div></div>
<div class="card"><label>在线试听（确认音色，无需 Kindle）</label>
<textarea id="t" rows="3">你好，这是云端语音合成测试。</textarea>
<button onclick="play()">▶ 试听</button>
<audio id="a" controls></audio><div id="m" class="muted"></div></div>
<div class="card"><a href="/selftest">⚠ 点这里做一次完整自检</a>
<div class="muted">真合成一句，报告 edge-tts / 外网是否可用（排查白名单）</div></div>
<script>
function play(){var u='/tts?text='+encodeURIComponent(document.getElementById('t').value);
var a=document.getElementById('a');document.getElementById('m').textContent='请求中...';
a.src=u;a.play().catch(function(e){document.getElementById('m').textContent='播放失败：'+e;});}
</script></body></html>
"""


@app.route("/")
def index():
    html = (INDEX_HTML
            .replace("{{BASE}}", flask.request.host_url.rstrip("/"))
            .replace("{{VOICE}}", DEFAULT_VOICE)
            .replace("{{RATE}}", str(WAV_RATE))
            .replace("{{REQ}}", str(_req_no)))
    return flask.Response(html, mimetype="text/html")


@app.route("/healthz")
def healthz():
    return ("ok", 200)


@app.route("/selftest")
def selftest():
    """真合成一次。确认托管平台能否连微软 TTS（PythonAnywhere 免费版有外网白名单）。"""
    t0 = time.time()
    wav, err = _synth("自检", DEFAULT_VOICE, DEFAULT_RATE, tries=2)
    if err:
        _log(f"selftest 失败: {err}")
        hint = ""
        if any(k in err for k in ("Timeout", "Connection", "ClientConnector", "Forbidden", "403")):
            hint = ("\n\n👉 这是【外网被限制】：本平台不允许访问微软语音服务"
                    "（PythonAnywhere 免费版有白名单）。\n"
                    "   办法：换成 alwaysdata.com 免费版，或升级为付费版。")
        elif "av失败" in err:
            hint = "\n\n👉 转码失败：请确认已 pip install --user av numpy"
        return flask.Response(
            f"❌ 自检失败（{time.time()-t0:.1f}s）\n错误: {err}{hint}",
            mimetype="text/plain; charset=utf-8")
    ok = b"RIFF" in wav[:4]
    return flask.Response(
        f"{'✅ 自检通过' if ok else '⚠ 非RIFF'}"
        f"（{time.time()-t0:.1f}s，{len(wav)}字节，{WAV_RATE}Hz）\n"
        f"Kindle 填：{flask.request.host_url.rstrip('/')}/tts"
        f"?voice={DEFAULT_VOICE}&text={{text}}",
        mimetype="text/plain; charset=utf-8")


@app.route("/tts")
def tts():
    global _req_no
    with _lock:
        _req_no += 1
        cur = _req_no
    t0 = time.time()
    text = flask.request.args.get("text", "")
    voice = flask.request.args.get("voice", DEFAULT_VOICE)
    rate = flask.request.args.get("rate", DEFAULT_RATE) or DEFAULT_RATE
    _log(f"#{cur} 收到请求 字数={len(text)} 音色={voice} 语速={rate}")

    if not text:
        return ("missing text", 400)

    wav, err = _synth(text, voice, rate)
    if err:
        _log(f"#{cur} 失败: {err}")
        return (f"tts failed: {err}", 500)
    if not wav or len(wav) < 100:
        return ("empty audio", 500)

    _log(f"#{cur} 完成 用时={time.time()-t0:.1f}s 返回={len(wav)}B 预览={text[:12]}")
    # Connection: close —— 避免 Kindle 复用 keep-alive 导致音频被截断
    return flask.Response(wav, mimetype="audio/wav",
                          headers={"Connection": "close"})


if __name__ == "__main__":
    app.run(host="0.0.0.0",
            port=int(os.environ.get("PORT", "5000")), threaded=True)
