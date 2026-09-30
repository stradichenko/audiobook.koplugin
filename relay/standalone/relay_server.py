#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Minimal cloud TTS relay for the KOReader audiobook.koplugin cloud backend.

This is a *reference* implementation you can self-host. It implements exactly
the HTTP API that ``cloud_tts_helper.sh`` (bundled in this plugin) expects:

    GET  /tts?voice=zh-CN-XiaoxiaoNeural&text=<sentence>&rate=+20%&volume=+30%
    POST /tts   (body = raw text, optional form field rate=/volume=)

The helper REQUIRES the response to be a WAV file (the e-ink device has no
ffmpeg to transcode MP3), so this server converts Edge-TTS's MP3 output to a
16kHz mono 16-bit PCM WAV with ffmpeg before returning it (16kHz is the rate
confirmed working on Kindle Oasis; see relay/README.md).

Dependencies: edge-tts + flask + ffmpeg (on PATH).

Run locally:
    pip install -r requirements.txt
    python relay_server.py --host 0.0.0.0 --port 5000

Then in the plugin's ``cloud_tts.cfg`` set:
    RELAY_BASE=http://<this-host-ip>:5000/tts

For a managed/cloud deployment, see the dedicated cloud-relay README
(added separately to this repository).
"""
import argparse
import asyncio
import subprocess

import edge_tts
from flask import Flask, request, Response

app = Flask(__name__)

DEFAULT_VOICE = "zh-CN-XiaoxiaoNeural"


def _norm_param(value):
    """Edge-TTS accepts rate/volume like '+20%' / '-10%' / 'default'.

    The helper already sends them in that format; pass through, but treat
    empty / 'default' / '+0%' / '0%' as "no override".
    """
    if not value:
        return None
    v = str(value).strip()
    if v in ("", "default", "+0%", "0%", "default,"):
        return None
    return v


async def _synth(voice, text, rate, volume):
    communicate = edge_tts.Communicate(
        text=text, voice=voice, rate=rate, volume=volume
    )
    chunks = []
    async for chunk in communicate.stream():
        if chunk.get("type") == "audio":
            chunks.append(chunk["data"])
    return b"".join(chunks)


@app.route("/", methods=["GET"])
def index():
    return (
        "cloud TTS relay OK. "
        "Use GET/POST /tts?voice=&text=&rate=&volume="
    )


@app.route("/tts", methods=["GET", "POST"])
def tts():
    if request.method == "POST":
        # Helper POST mode: text is the raw request body, rate/volume are form fields.
        text = request.get_data(as_text=True) or ""
        rate = _norm_param(request.values.get("rate"))
        volume = _norm_param(request.values.get("volume"))
    else:
        text = request.args.get("text", "")
        rate = _norm_param(request.args.get("rate"))
        volume = _norm_param(request.args.get("volume"))

    voice = request.values.get("voice") or DEFAULT_VOICE

    if not text or not text.strip():
        return Response("missing 'text'", status=400, mimetype="text/plain")

    try:
        mp3 = asyncio.run(_synth(voice, text, rate, volume))
    except Exception as exc:  # noqa: BLE001
        return Response(
            f"edge-tts error: {exc}", status=502, mimetype="text/plain"
        )

    if not mp3:
        return Response(
            "edge-tts returned empty audio", status=502, mimetype="text/plain"
        )

    # MP3 -> WAV (16kHz mono s16le). The Kindle Oasis playback pipeline is
    # confirmed to play 16kHz WAV directly (see relay/README.md).
    try:
        proc = subprocess.run(
            [
                "ffmpeg", "-y", "-i", "pipe:0",
                "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
                "pipe:1", "-loglevel", "error",
            ],
            input=mp3,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=60,
        )
    except FileNotFoundError:
        return Response(
            "ffmpeg not found on relay host (required to emit WAV)",
            status=500,
            mimetype="text/plain",
        )
    except Exception as exc:  # noqa: BLE001
        return Response(
            f"ffmpeg error: {exc}", status=502, mimetype="text/plain"
        )

    if proc.returncode != 0 or not proc.stdout:
        err = proc.stderr.decode("utf-8", errors="replace")
        return Response(
            f"ffmpeg failed: {err}", status=502, mimetype="text/plain"
        )

    return Response(
        proc.stdout,
        status=200,
        mimetype="audio/wav",
        headers={"Content-Type": "audio/wav"},
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Minimal cloud TTS relay")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=5000)
    args = parser.parse_args()
    # threaded=True so concurrent sentence requests don't block each other.
    app.run(host=args.host, port=args.port, threaded=True)
