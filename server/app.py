"""Локальный веб-интерфейс: BLE микрофон, снимок/мин, Whisper."""

from __future__ import annotations

import io
import threading
import time
from pathlib import Path

import numpy as np
import tomllib
from flask import Flask, Response, jsonify, render_template, request, send_file
from faster_whisper import WhisperModel

from audio_processor import AudioConfig, AudioProcessor
from ble_client import BleEspClient

BASE_DIR = Path(__file__).resolve().parent
CONFIG_PATH = BASE_DIR / "config.toml"

app = Flask(__name__, template_folder=str(BASE_DIR / "templates"), static_folder=str(BASE_DIR / "static"))

config = tomllib.loads(CONFIG_PATH.read_text(encoding="utf-8"))
whisper_model: WhisperModel | None = None
whisper_lock = threading.Lock()

latest_image = {"bytes": b"", "updated_at": 0.0}
image_lock = threading.Lock()


def get_whisper_model() -> WhisperModel:
    global whisper_model
    if whisper_model is None:
        wcfg = config["whisper"]
        whisper_model = WhisperModel(
            wcfg["model"],
            device=wcfg["device"],
            compute_type=wcfg["compute_type"],
        )
    return whisper_model


def transcribe_clip(samples: np.ndarray, peak_db: float) -> None:
    sample_rate = config["audio"]["sample_rate"]
    duration_ms = int(1000 * samples.size / sample_rate)

    audio = samples.astype(np.float32) / 32768.0
    wcfg = config["whisper"]

    with whisper_lock:
        model = get_whisper_model()
        segments, _info = model.transcribe(
            audio,
            language=wcfg["language"],
            vad_filter=True,
            beam_size=1,
        )
        text = " ".join(segment.text.strip() for segment in segments).strip()

    if text:
        audio_processor.add_transcript(text, duration_ms, peak_db)


def on_audio(pcm_bytes: bytes) -> None:
    audio_processor.ingest_pcm(pcm_bytes)


def on_image(jpeg_bytes: bytes) -> None:
    with image_lock:
        latest_image["bytes"] = jpeg_bytes
        latest_image["updated_at"] = time.time()


audio_cfg = AudioConfig(
    sample_rate=config["audio"]["sample_rate"],
    db_threshold=config["audio"]["db_threshold"],
    trigger_ms=config["audio"]["trigger_ms"],
    silence_ms=config["audio"]["silence_ms"],
    min_record_ms=config["audio"]["min_record_ms"],
    max_record_ms=config["audio"]["max_record_ms"],
)
audio_processor = AudioProcessor(audio_cfg, on_clip_ready=transcribe_clip)

ble_client = BleEspClient(
    device_name=config["ble"]["device_name"],
    on_audio=on_audio,
    on_image=on_image,
)


@app.route("/")
def index() -> str:
    return render_template("index.html")


@app.route("/api/status")
def api_status() -> Response:
    with image_lock:
        image_updated_at = latest_image["updated_at"]
        has_image = bool(latest_image["bytes"])

    snapshot = audio_processor.get_snapshot()
    return jsonify(
        {
            "transport": "ble",
            "esp_online": ble_client.connected,
            "audio_connected": snapshot["audio_connected"] and ble_client.connected,
            "db_threshold": audio_cfg.db_threshold,
            "image_updated_at": image_updated_at,
            "has_image": has_image,
            "snapshot_interval_sec": config["ble"]["snapshot_interval_sec"],
            **snapshot,
        }
    )


@app.route("/api/threshold", methods=["POST"])
def api_threshold() -> Response:
    data = request.get_json(silent=True) or {}
    value = float(data.get("db_threshold", audio_cfg.db_threshold))
    value = max(-60.0, min(-10.0, value))
    audio_processor.update_threshold(value)
    return jsonify({"db_threshold": value})


@app.route("/api/camera/latest")
def camera_latest() -> Response:
    with image_lock:
        if not latest_image["bytes"]:
            return Response(status=204)
        payload = latest_image["bytes"]

    return send_file(
        io.BytesIO(payload),
        mimetype="image/jpeg",
        max_age=0,
    )


if __name__ == "__main__":
    print("Загрузка Whisper (первый запуск может занять время)...")
    get_whisper_model()
    ble_client.start()

    host = config["server"]["host"]
    port = config["server"]["port"]
    print(f"Интерфейс: http://127.0.0.1:{port}")
    print(f"Ищем BLE-устройство: {config['ble']['device_name']}")
    app.run(host=host, port=port, debug=False, threaded=True)
