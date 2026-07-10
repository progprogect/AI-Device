"""Приём BLE-пакетов с ESP-Sense: аудио и JPEG-снимки."""

from __future__ import annotations

import asyncio
import struct
import threading
import time
from typing import Callable, Optional

from bleak import BleakClient, BleakScanner

SERVICE_UUID = "a1b2c300-1111-2222-3333-444455556666"
DATA_CHAR_UUID = "a1b2c300-1111-2222-3333-444455556667"

PACKET_AUDIO = 0x01
PACKET_IMG_BEGIN = 0x02
PACKET_IMG_CHUNK = 0x03
PACKET_IMG_END = 0x04


class BleEspClient:
    def __init__(
        self,
        device_name: str,
        on_audio: Callable[[bytes], None],
        on_image: Callable[[bytes], None],
    ) -> None:
        self.device_name = device_name
        self.on_audio = on_audio
        self.on_image = on_image
        self.connected = False
        self.last_packet_at = 0.0
        self.last_image_at = 0.0

        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._image_size = 0
        self._image_chunks: dict[int, bytes] = {}
        self._expected_chunks = 0

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._run_loop, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def _run_loop(self) -> None:
        asyncio.run(self._main())

    async def _main(self) -> None:
        while not self._stop.is_set():
            try:
                device = await BleakScanner.find_device_by_name(self.device_name, timeout=20.0)
                if device is None:
                    self.connected = False
                    await asyncio.sleep(3)
                    continue

                async with BleakClient(device, timeout=20.0) as client:
                    self.connected = client.is_connected
                    await client.start_notify(DATA_CHAR_UUID, self._handle_notify)

                    while client.is_connected and not self._stop.is_set():
                        await asyncio.sleep(0.5)

            except Exception:
                self.connected = False
                await asyncio.sleep(3)
            finally:
                self.connected = False

    def _handle_notify(self, _handle: int, data: bytearray) -> None:
        if not data:
            return

        self.last_packet_at = time.time()
        packet_type = data[0]

        if packet_type == PACKET_AUDIO and len(data) >= 7:
            sample_count = struct.unpack_from("<H", data, 5)[0]
            byte_count = sample_count * 2
            if len(data) >= 7 + byte_count:
                self.on_audio(bytes(data[7 : 7 + byte_count]))
            return

        if packet_type == PACKET_IMG_BEGIN and len(data) >= 7:
            self._image_size = struct.unpack_from("<I", data, 1)[0]
            self._expected_chunks = struct.unpack_from("<H", data, 5)[0]
            self._image_chunks = {}
            return

        if packet_type == PACKET_IMG_CHUNK and len(data) >= 3:
            index = struct.unpack_from("<H", data, 1)[0]
            self._image_chunks[index] = bytes(data[3:])
            return

        if packet_type == PACKET_IMG_END:
            if self._expected_chunks and len(self._image_chunks) >= self._expected_chunks:
                ordered = b"".join(
                    self._image_chunks.get(i, b"")
                    for i in range(self._expected_chunks)
                )
                if ordered and (not self._image_size or len(ordered) >= self._image_size * 0.9):
                    self.last_image_at = time.time()
                    self.on_image(ordered[: self._image_size] if self._image_size else ordered)
            self._image_chunks = {}
            self._expected_chunks = 0
            self._image_size = 0
