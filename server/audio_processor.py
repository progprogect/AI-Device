"""Обработка аудио: уровень dB, запись по порогу, Whisper."""

from __future__ import annotations

import threading
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Callable, Deque, List, Optional

import numpy as np


@dataclass
class AudioConfig:
    sample_rate: int = 16000
    db_threshold: float = -35.0
    trigger_ms: int = 200
    silence_ms: int = 900
    min_record_ms: int = 500
    max_record_ms: int = 15000


@dataclass
class TranscriptEvent:
    timestamp: float
    text: str
    duration_ms: int
    peak_db: float


@dataclass
class AudioState:
    current_db: float = -100.0
    is_recording: bool = False
    last_packet_at: float = 0.0
    transcripts: Deque[TranscriptEvent] = field(default_factory=lambda: deque(maxlen=50))
    level_history: Deque[float] = field(default_factory=lambda: deque(maxlen=120))


def samples_to_dbfs(samples: np.ndarray) -> float:
    if samples.size == 0:
        return -100.0
    rms = float(np.sqrt(np.mean(samples.astype(np.float32) ** 2)))
    if rms < 1.0:
        return -100.0
    return 20.0 * np.log10(rms / 32768.0)


class AudioProcessor:
    def __init__(
        self,
        config: AudioConfig,
        on_clip_ready: Callable[[np.ndarray, float], None],
    ) -> None:
        self.config = config
        self.on_clip_ready = on_clip_ready
        self.state = AudioState()
        self._lock = threading.Lock()

        self._record_buffer: List[int] = []
        self._recording = False
        self._loud_ms = 0
        self._silence_ms = 0
        self._record_started_at = 0.0
        self._clip_peak_db = -100.0

    def ingest_pcm(self, pcm_bytes: bytes) -> None:
        if not pcm_bytes:
            return
        samples = np.frombuffer(pcm_bytes, dtype=np.int16)
        self._handle_samples(samples)

    def get_snapshot(self) -> dict:
        with self._lock:
            return {
                "current_db": round(self.state.current_db, 1),
                "is_recording": self.state.is_recording,
                "audio_connected": (time.time() - self.state.last_packet_at) < 2.0,
                "transcripts": [
                    {
                        "time": event.timestamp,
                        "text": event.text,
                        "duration_ms": event.duration_ms,
                        "peak_db": round(event.peak_db, 1),
                    }
                    for event in reversed(self.state.transcripts)
                ],
                "levels": list(self.state.level_history),
            }

    def update_threshold(self, db_threshold: float) -> None:
        with self._lock:
            self.config.db_threshold = db_threshold

    def add_transcript(self, text: str, duration_ms: int, peak_db: float) -> None:
        with self._lock:
            self.state.transcripts.appendleft(
                TranscriptEvent(time.time(), text.strip(), duration_ms, peak_db)
            )

    def _handle_samples(self, samples: np.ndarray) -> None:
        db = samples_to_dbfs(samples)
        now = time.time()

        with self._lock:
            self.state.current_db = db
            self.state.last_packet_at = now
            self.state.level_history.append(db)

            threshold = self.config.db_threshold
            chunk_ms = int(1000 * samples.size / self.config.sample_rate)

            if db >= threshold:
                self._loud_ms += chunk_ms
                self._silence_ms = 0
                if not self._recording and self._loud_ms >= self.config.trigger_ms:
                    self._start_recording(now, db)
            else:
                self._loud_ms = max(0, self._loud_ms - chunk_ms)
                if self._recording:
                    self._silence_ms += chunk_ms

            if self._recording:
                self._record_buffer.extend(samples.tolist())
                self._clip_peak_db = max(self._clip_peak_db, db)

                elapsed_ms = int((now - self._record_started_at) * 1000)
                if elapsed_ms >= self.config.max_record_ms:
                    self._finish_recording()
                elif self._silence_ms >= self.config.silence_ms:
                    self._finish_recording()

            self.state.is_recording = self._recording

    def _start_recording(self, now: float, db: float) -> None:
        self._recording = True
        self._record_buffer = []
        self._record_started_at = now
        self._clip_peak_db = db
        self._silence_ms = 0

    def _finish_recording(self) -> None:
        samples = np.array(self._record_buffer, dtype=np.int16)
        duration_ms = int(1000 * samples.size / self.config.sample_rate)
        peak_db = self._clip_peak_db

        self._recording = False
        self._record_buffer = []
        self._loud_ms = 0
        self._silence_ms = 0

        if duration_ms < self.config.min_record_ms:
            return

        threading.Thread(
            target=self.on_clip_ready,
            args=(samples, peak_db),
            daemon=True,
        ).start()
