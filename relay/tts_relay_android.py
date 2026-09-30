#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
TTS 中继（配合 Kindle 3 的 KOReader tts_cn 插件）
==============================================
作用：把 edge-tts（微软真人中文音色，免费）合成结果转成 WAV，
      通过 HTTP 服务发给 Kindle 播放。设备端零依赖。

支持两种部署（代码完全一致，二选一）：
  A. 本地 / 手机（Termux、电脑、树莓派、NAS）：
        pip install -r requirements.txt
        python tts_relay_android.py
     脚本会打印本机地址，直接填进 Kindle 即可。
  B. 云端（推荐，彻底不用手机）：
       部署到 Railway / Render 等免费平台，Kindle 填公网地址。
       详见同目录 DEPLOY.md —— 部署后控制台即在公网地址 / 路径，手机完全不用参与。
       云端所需依赖：Python 3.8+、edge-tts、flask、ffmpeg（由平台在构建期安装）。

网页控制台：
    打开 <服务地址>/ 即可看到控制台：
      - 显示服务地址（直接复制填进 Kindle）
      - 显示 Kindle 累计请求数（实时反映是否在朗读）
      - 在线试听文本框（确认音色/语速，无需 Kindle）

Kindle 插件设置（阅读器菜单 → 中文朗读 → 设置）：
    在线接口地址： <服务地址>/tts?voice={voice}&text={text}
    后端： 在线
    （注：云端为 https 地址，插件已支持 https）
"""

import asyncio
import os
import socket
import tempfile
import subprocess
import flask
import edge_tts
import time

app = flask.Flask(__name__)

# 默认音色（可在 Kindle 设置里改；这里只是兜底）
DEFAULT_VOICE = "zh-CN-XiaoxiaoNeural"

# 输出 WAV 参数：单声道 16bit PCM @16000。
# v1.40 关键回退（凭 v1.31 实测能连着放好几句、人声干净）：
# 本机 Kindle 3 的【8000Hz 直出路径是坏的】——无论中继发 8000 还是 Kindle 端 Lua 重采样到 8000，
# 放出来全程"吱吱吱"。而把 16000Hz 数据喂给设备、由 ALSA "default" 的 plug 层做
# 16000→设备内时钟(约 8000) 的硬件下采样，那条路是干净的（代价：语速慢一倍、音调低八度，
# 但人声完全可懂）。故中继发 16000Hz，Kindle 端原样直出、交给系统重采样，不办事先 Lua 重采样。
# 若日后想提速：把这个率调到设备能干净直出的更高率（如 22050）再测，不要回到 8000。
# 可用环境变量覆盖：
#   TTS_WAV_RATE=8000   → 会触发 Kindle 的吱吱坏路，勿用
#   TTS_WAV_RATE=16000  → 默认（干净路）
WAV_RATE = int(os.environ.get("TTS_WAV_RATE", "16000"))

# 语速（edge-tts 格式，如 +20% / -10%）。Kindle 端可在接口地址里加 &rate=+20% 覆盖，
# 也可以用环境变量 TTS_RATE 设默认值。
DEFAULT_RATE = os.environ.get("TTS_RATE", "+0%")

# 端口：本地默认 5000；云端平台（Railway/Render）通过 PORT 环境变量注入。
PORT = int(os.environ.get("PORT", "5000"))

# 请求计数 + 日志：单窗口也能看清 Kindle 是否在持续请求（不用另开会话）
import threading
_req_no = 0
_lock = threading.Lock()


def _log(msg):
    print(f"[{time.strftime('%m-%d %H:%M:%S')}] {msg}", flush=True)


def get_lan_ip() -> str:
    """尽量拿到本机在局域网下的 IP（本地部署用；云端无意义）。"""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except Exception:
        return "127.0.0.1"
    finally:
        s.close()


# 网页控制台模板（{{BASE}} {{RATE}} {{REQ}} {{VOICE}} {{WRATE}} 为占位符，启动时替换）
# {{BASE}} 在云端自动为公网域名（含 https），本地自动为 http://IP:端口。
INDEX_HTML = """<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>TTS 中继控制台</title>
<style>
 body{font-family:-apple-system,system-ui,"PingFang SC","Microsoft YaHei",sans-serif;max-width:680px;margin:0 auto;padding:16px;background:#fafafa;color:#222}
 h1{font-size:20px;margin:0 0 8px}
 .card{background:#fff;border:1px solid #e3e3e3;border-radius:10px;padding:14px;margin:12px 0}
 code{background:#f0f0f0;padding:2px 6px;border-radius:4px;word-break:break-all;display:inline-block}
 label{display:block;margin:8px 0 4px;font-weight:600}
 textarea,select{width:100%;box-sizing:border-box;font-size:15px;padding:8px;border:1px solid #ccc;border-radius:8px}
 button{margin-top:10px;background:#2d7cff;color:#fff;border:0;border-radius:8px;padding:10px 16px;font-size:15px}
 .muted{color:#888;font-size:13px;margin-top:6px}
 audio{width:100%;margin-top:10px}
</style>
</head>
<body>
<h1>📢 TTS 中继控制台</h1>
<div class="card">
 <div>服务地址：<br><code>{{BASE}}/tts?voice={{VOICE}}&text={text}</code></div>
 <div class="muted">把上面整行地址填进 Kindle「中文朗读 → 设置 → 在线接口」（保留 {text} 占位符）</div>
</div>
<div class="card">
 <div>Kindle 累计请求：<b>{{REQ}}</b> 次 &nbsp;|&nbsp; 当前语速：<b>{{RATE}}</b> &nbsp;|&nbsp; 采样率：<b>{{WRATE}}Hz</b></div>
 <div class="muted">刷新本页可更新计数 —— 每次 Kindle 读一句 +1，可确认连接是否活着</div>
</div>
<div class="card">
 <label for="t">测试朗读（直接在这里试听，确认音色/语速，无需 Kindle）</label>
 <textarea id="t" rows="4" placeholder="输入要朗读的中文...">你好，这是语音合成测试。</textarea>
 <label for="r">语速</label>
 <select id="r">
   <option value="+0%">原速</option>
   <option value="+20%">快 +20%</option>
   <option value="-10%">慢 -10%</option>
   <option value="+50%">更快 +50%</option>
 </select>
 <button onclick="play()">▶ 试听</button>
 <audio id="a" controls></audio>
 <div id="msg" class="muted"></div>
</div>
<script>
function play(){
 var t=document.getElementById('t').value;
 var r=document.getElementById('r').value;
 var a=document.getElementById('a');
 var u='/tts?text='+encodeURIComponent(t)+'&rate='+encodeURIComponent(r);
 document.getElementById('msg').textContent='请求中...';
 a.src=u;
 a.play().catch(function(e){document.getElementById('msg').textContent='播放失败：'+e;});
 a.onended=function(){document.getElementById('msg').textContent='播放完成';};
 a.onerror=function(){document.getElementById('msg').textContent='加载失败，检查 edge-tts / ffmpeg 是否可用';};
}
</script>
</body>
</html>
"""


@app.route("/")
def index():
    # 关键：用请求里的 Host 自动生成地址，云端为公网域名、本地为 IP:端口，零配置。
    base = flask.request.host_url.rstrip("/")
    html = (INDEX_HTML
            .replace("{{BASE}}", base)
            .replace("{{RATE}}", DEFAULT_RATE)
            .replace("{{WRATE}}", str(WAV_RATE))
            .replace("{{REQ}}", str(_req_no))
            .replace("{{VOICE}}", DEFAULT_VOICE))
    return flask.Response(html, mimetype="text/html")


@app.route("/healthz")
def healthz():
    """云平台健康检查（Render 等用此路径判断服务存活）。"""
    return ("ok", 200)


@app.route("/tts")
def tts():
    global _req_no
    with _lock:
        _req_no += 1
        cur_no = _req_no
    _t0 = time.time()
    text = flask.request.args.get("text", "")
    voice = flask.request.args.get("voice", DEFAULT_VOICE)
    rate = flask.request.args.get("rate", DEFAULT_RATE) or DEFAULT_RATE
    # 每次请求都打一行日志（落到平台日志/relay.log），无需另开窗口就能看到 Kindle 是否还在请求
    _log(f"#{cur_no} 收到请求 字数={len(text)} 音色={voice} 语速={rate} 输出率={WAV_RATE}Hz")

    if not text:
        _log(f"#{cur_no} 空文本，忽略")
        return ("missing text", 400)

    mp3_path = tempfile.mktemp(suffix=".mp3")
    wav_path = tempfile.mktemp(suffix=".wav")
    last_err = ""
    _out = 0
    try:
        # 1) edge-tts 合成 mp3（偶发网络抖动，重试 3 次提升稳定性）
        for attempt in range(3):
            try:
                asyncio.run(edge_tts.Communicate(text, voice, rate=rate).save(mp3_path))
                break
            except Exception as e:
                last_err = str(e)
                if attempt < 2:
                    time.sleep(0.5)
        else:
            return (f"edge-tts failed: {last_err}", 500)
        # 2) 转成 WAV（16bit PCM 单声道），Kindle 端用 ALSA 直写
        subprocess.run(
            [
                "ffmpeg", "-y", "-i", mp3_path,
                "-acodec", "pcm_s16le", "-ac", "1", "-ar", str(WAV_RATE),
                wav_path,
            ],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        with open(wav_path, "rb") as f:
            data = f.read()
        _out = len(data)
        if not data:
            return ("empty wav", 500)
        _log(f"#{cur_no} 合成完成 用时={time.time() - _t0:.1f}s 返回={_out}B 率={WAV_RATE}Hz "
             f"预览={text[:12]}")
        # Connection: close，避免 Kindle 端复用 keep-alive 连接导致截断
        return flask.Response(data, mimetype="audio/wav",
                             headers={"Connection": "close"})
    except Exception as e:
        return (f"tts error: {e}", 500)
    finally:
        for p in (mp3_path, wav_path):
            try:
                os.remove(p)
            except OSError:
                pass


if __name__ == "__main__":
    # 本地启动信息：优先用 PUPLIC_URL 环境变量（云端可手动指定），否则用本机 IP。
    base = os.environ.get("PUBLIC_URL")
    if not base:
        ip = get_lan_ip()
        base = f"http://{ip}:{PORT}"
    base = base.rstrip("/")
    print("=" * 50)
    print("TTS 中继已启动")
    print(f"  Kindle 插件填：{base}/tts?voice={DEFAULT_VOICE}&text={{text}}")
    print(f"  浏览器控制台：  {base}/   （可测试朗读 / 看 Kindle 请求数）")
    print(f"  语速：&rate=+20%   采样率 {WAV_RATE}Hz")
    print("=" * 50)
    # 0.0.0.0 让外部可访问；threaded=True 避免连续请求被单线程 dev server 阻塞。
    # 云端平台通过 PORT 环境变量注入端口；本地默认 5000。
    app.run(host="0.0.0.0", port=PORT, threaded=True)
