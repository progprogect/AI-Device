"""Проверка прошивки v2 (esp_sense_ctrl): команды start/stop audio и capture photo.

Запуск: source .venv/bin/activate && python test_ctrl.py
"""

import asyncio
import struct
import time
from pathlib import Path

from bleak import BleakClient, BleakScanner

DEVICE_NAME = "ESP-Sense"
DATA_CHAR = "a1b2c300-1111-2222-3333-444455556667"
CMD_CHAR = "a1b2c300-1111-2222-3333-444455556668"
INFO_CHAR = "a1b2c300-1111-2222-3333-444455556669"

PKT_AUDIO = 0x01
PKT_IMG_BEGIN = 0x02
PKT_IMG_CHUNK = 0x03
PKT_IMG_END = 0x04
PKT_STATUS = 0x06

CMD_START_AUDIO = bytes([0x10])
CMD_STOP_AUDIO = bytes([0x11])
CMD_CAPTURE_PHOTO = bytes([0x20])


class State:
    def __init__(self):
        self.audio_packets = 0
        self.audio_bytes = 0
        self.image_size = 0
        self.image_chunks = {}
        self.image_expected_chunks = 0
        self.image_done = asyncio.Event()
        self.status_events = []


state = State()


def on_notify(_, data: bytearray):
    if not data:
        return
    pkt = data[0]
    if pkt == PKT_AUDIO:
        state.audio_packets += 1
        state.audio_bytes += len(data) - 7
    elif pkt == PKT_IMG_BEGIN:
        state.image_size, state.image_expected_chunks = struct.unpack_from("<IH", data, 1)
        state.image_chunks = {}
        print(f"  IMG_BEGIN: size={state.image_size} chunks={state.image_expected_chunks}")
    elif pkt == PKT_IMG_CHUNK:
        (index,) = struct.unpack_from("<H", data, 1)
        state.image_chunks[index] = bytes(data[3:])
    elif pkt == PKT_IMG_END:
        print(f"  IMG_END: received {len(state.image_chunks)}/{state.image_expected_chunks} chunks")
        state.image_done.set()
    elif pkt == PKT_STATUS:
        audio_on = data[1] if len(data) > 1 else -1
        state.status_events.append(audio_on)
        print(f"  STATUS: audio_on={audio_on}")


async def main():
    print(f"Scanning for {DEVICE_NAME}...")
    device = await BleakScanner.find_device_by_name(DEVICE_NAME, timeout=15)
    if device is None:
        raise SystemExit("Device not found. Is the board powered and advertising?")

    print(f"Connecting to {device.address}...")
    async with BleakClient(device) as client:
        info = await client.read_gatt_char(INFO_CHAR)
        print(f"device_info: {info.decode()}")

        await client.start_notify(DATA_CHAR, on_notify)

        print("\n[1] CMD_START_AUDIO — collect 5 seconds of audio")
        await client.write_gatt_char(CMD_CHAR, CMD_START_AUDIO, response=False)
        t0 = time.monotonic()
        await asyncio.sleep(5)
        elapsed = time.monotonic() - t0
        samples = state.audio_bytes // 2
        print(
            f"  audio: {state.audio_packets} packets, {samples} samples "
            f"({samples / elapsed:.0f} samples/s effective)"
        )
        assert state.audio_packets > 0, "No audio packets received"

        print("\n[2] CMD_STOP_AUDIO — verify stream stops")
        await client.write_gatt_char(CMD_CHAR, CMD_STOP_AUDIO, response=False)
        await asyncio.sleep(1)
        packets_after_stop = state.audio_packets
        await asyncio.sleep(2)
        stopped = state.audio_packets == packets_after_stop
        print(f"  stream stopped: {stopped}")
        assert stopped, "Audio packets kept arriving after CMD_STOP_AUDIO"

        print("\n[3] CMD_CAPTURE_PHOTO — receive JPEG")
        await client.write_gatt_char(CMD_CHAR, CMD_CAPTURE_PHOTO, response=False)
        try:
            await asyncio.wait_for(state.image_done.wait(), timeout=60)
        except asyncio.TimeoutError:
            raise SystemExit("Photo transfer timed out")

        ordered = b"".join(
            state.image_chunks[i] for i in sorted(state.image_chunks)
        )[: state.image_size]
        out = Path("test_photo.jpg")
        out.write_bytes(ordered)
        valid = ordered[:2] == b"\xff\xd8"
        print(f"  saved {out} ({len(ordered)} bytes, JPEG header valid: {valid})")

        await client.stop_notify(DATA_CHAR)

    print("\nAll checks passed." if valid else "\nDone, but JPEG header invalid!")


if __name__ == "__main__":
    asyncio.run(main())
