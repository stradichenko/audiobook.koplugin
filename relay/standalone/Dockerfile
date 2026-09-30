FROM python:3.11-slim

# ffmpeg is required to convert Edge-TTS MP3 output into the WAV the device needs.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY relay_server.py .

EXPOSE 5000
CMD ["python", "relay_server.py", "--host", "0.0.0.0", "--port", "5000"]
