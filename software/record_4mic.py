"""Record four INMP441 channels on a PYNQ-Z2 using the matching overlay.

Run this file ON the PYNQ board, not on the Windows Vivado computer.
The FPGA delivers one 128-bit beat per four-channel audio frame.
"""

import argparse
import json
import math
import time
import wave
from pathlib import Path

import numpy as np

SAMPLE_RATE = 48_000
FRAMES_PER_PACKET = 1_920
CHANNELS = 4
BYTES_PER_PACKET = FRAMES_PER_PACKET * CHANNELS * 4


def wait_packet(channel, mmio, timeout_seconds=2.0):
    deadline = time.monotonic() + timeout_seconds
    while not channel.idle:
        status = mmio.read(0x34)
        if status & 0x70:
            raise RuntimeError("DMA S2MM error, status=0x{:08x}".format(status))
        if time.monotonic() > deadline:
            raise TimeoutError("DMA packet timed out, status=0x{:08x}".format(status))
        time.sleep(0.001)
    channel.wait()  # Also invalidates the receive buffer's CPU cache.
    if channel.transferred != BYTES_PER_PACKET:
        raise RuntimeError(
            "Expected {} bytes per packet, got {}".format(
                BYTES_PER_PACKET, channel.transferred
            )
        )


def record(overlay_path, seconds):
    from pynq import Overlay, allocate

    overlay = Overlay(str(overlay_path))
    dma = overlay.axi_dma_0
    gpio = overlay.axi_gpio_capture.mmio
    channel = dma.recvchannel
    if not hasattr(channel, "transfer"):
        raise RuntimeError("AXI DMA receive channel is unavailable")

    packet_count = max(1, math.ceil(seconds * SAMPLE_RATE / FRAMES_PER_PACKET))
    total_frames = packet_count * FRAMES_PER_PACKET
    samples = np.empty((total_frames, CHANNELS), dtype=np.int32)

    # GPIO channel 2 controls capture; channel 1 reads the dropped-frame count.
    gpio.write(0x0C, 0)  # GPIO2 TRI: drive the output.
    gpio.write(0x08, 0)  # Keep the FIFO clear until DMA is armed.
    time.sleep(0.002)
    drops_before = gpio.read(0x00)

    buffers = [
        allocate(shape=(FRAMES_PER_PACKET, CHANNELS), dtype=np.int32, cacheable=False)
        for _ in range(2)
    ]
    try:
        channel.transfer(buffers[0])
        gpio.write(0x08, 1)
        start = time.monotonic()

        for packet in range(packet_count):
            current = packet & 1
            wait_packet(channel, dma.mmio)

            # Start receiving the next packet before copying this one.
            if packet + 1 < packet_count:
                channel.transfer(buffers[1 - current])
            else:
                drops_after = gpio.read(0x00)
                gpio.write(0x08, 0)

            begin = packet * FRAMES_PER_PACKET
            samples[begin:begin + FRAMES_PER_PACKET] = buffers[current]

        wall_seconds = time.monotonic() - start
    finally:
        gpio.write(0x08, 0)
        if channel.running:
            channel.stop()
        for buffer in buffers:
            buffer.close()

    drops = (drops_after - drops_before) & 0xFFFFFFFF
    return samples, drops, wall_seconds


def save_recording(prefix, samples, drops, wall_seconds):
    prefix.parent.mkdir(parents=True, exist_ok=True)
    np.save(str(prefix) + ".npy", samples)
    np.savetxt(
        str(prefix) + ".csv",
        samples,
        fmt="%d",
        delimiter=",",
        header="ch0,ch1,ch2,ch3",
        comments="",
    )

    # A convenient listening copy. The NPY/CSV keep the original 24-bit data.
    preview = (samples >> 8).astype("<i2")
    with wave.open(str(prefix) + ".wav", "wb") as output:
        output.setnchannels(CHANNELS)
        output.setsampwidth(2)
        output.setframerate(SAMPLE_RATE)
        output.writeframes(preview.tobytes())

    metadata = {
        "sample_rate_hz": SAMPLE_RATE,
        "channels": CHANNELS,
        "channel_order": ["SD0-left", "SD0-right", "SD1-left", "SD1-right"],
        "frames": int(samples.shape[0]),
        "duration_seconds": samples.shape[0] / SAMPLE_RATE,
        "capture_wall_seconds": wall_seconds,
        "dropped_frames": int(drops),
        "packet_frames": FRAMES_PER_PACKET,
    }
    with open(str(prefix) + ".json", "w", encoding="utf-8") as output:
        json.dump(metadata, output, indent=2)
    return metadata


def main():
    parser = argparse.ArgumentParser(description="Record four microphone channels")
    parser.add_argument("--overlay", type=Path, default=Path("4mic_realtime.bit"))
    parser.add_argument("--seconds", type=float, default=3.0)
    parser.add_argument("--output", type=Path, default=Path("recording_4mic"))
    args = parser.parse_args()
    if not math.isfinite(args.seconds) or args.seconds <= 0:
        parser.error("--seconds must be positive and finite")

    samples, drops, wall_seconds = record(args.overlay, args.seconds)
    info = save_recording(args.output, samples, drops, wall_seconds)
    print("Saved {:.3f} s ({} frames/channel) to {}.*".format(
        info["duration_seconds"], info["frames"], args.output
    ))
    print("Dropped frames while recording: {}".format(drops))
    if drops:
        print("WARNING: The recording has gaps; reduce board-side load or inspect DMA.")


if __name__ == "__main__":
    main()
