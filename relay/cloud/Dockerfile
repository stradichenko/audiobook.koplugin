# TTS 中继云端镜像（Railway / Render / 任意支持 Docker 的平台通用）
FROM python:3.11-slim

# 安装 ffmpeg（edge-tts 产 mp3，需 ffmpeg 转 WAV 给 Kindle）
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# 端口由平台通过 PORT 环境变量注入（脚本里已读 os.environ.get("PORT")）
EXPOSE 5000
CMD ["python", "tts_relay_android.py"]
