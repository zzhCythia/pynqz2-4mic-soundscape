"""Run four-microphone localization, the LED ring, and FPGA HDMI animation.

Run this file on the PYNQ-Z2 beside the matching .bit/.hwh files and
record_4mic.py. The screen and ring share the accepted angle, color and level.
The array is assumed to be a square viewed from above::

                    front (+Y, 0 deg)

              ch0 ---------------- ch1
               |                    |
     left      |                    |      right
   (negative)  |                    |     (positive)
              ch3 ---------------- ch2

The default side length is 8 cm.  Angles are reported as 0 degrees in front,
positive to the right, and negative to the left.
"""

import argparse
import math
import queue
import threading
import time
from collections import deque
from pathlib import Path

import numpy as np

from record_4mic import (
    CHANNELS,
    FRAMES_PER_PACKET,
    SAMPLE_RATE,
    wait_packet,
)

SPEED_OF_SOUND = 343.0
PAIRS = ((0, 1), (0, 2), (0, 3), (1, 2), (1, 3), (2, 3))


def parse_calibration(text):
    values = [float(value.strip()) for value in text.split(",")]
    if len(values) != CHANNELS or not all(math.isfinite(value) for value in values):
        raise argparse.ArgumentTypeError(
            "calibration must contain four finite values, for example 0,0,0,0"
        )
    return np.asarray(values, dtype=np.float64)


def square_positions(side_m):
    """Return ch0..ch3 XY positions for a square microphone array."""
    half = side_m / 2.0
    return np.asarray(
        [
            [-half, +half],
            [+half, +half],
            [+half, -half],
            [-half, -half],
        ],
        dtype=np.float64,
    )


def _next_power_of_two(value):
    return 1 << (int(value) - 1).bit_length()


def gcc_phat_from_spectra(spectrum_i, spectrum_j, fft_length, max_lag):
    """Return fractional lag i-j in samples and a simple peak confidence."""
    cross = spectrum_i * np.conj(spectrum_j)
    cross /= np.maximum(np.abs(cross), 1e-15)
    correlation = np.fft.irfft(cross, n=fft_length)

    max_lag = int(max_lag)
    local = np.concatenate((correlation[-max_lag:], correlation[: max_lag + 1]))
    magnitude = np.abs(local)
    peak_index = int(np.argmax(magnitude))
    lag = float(peak_index - max_lag)

    # Three-point parabolic interpolation gives sub-sample TDOA without SciPy.
    if 0 < peak_index < magnitude.size - 1:
        left, centre, right = magnitude[peak_index - 1 : peak_index + 2]
        denominator = left - 2.0 * centre + right
        if abs(denominator) > 1e-15:
            offset = 0.5 * (left - right) / denominator
            lag += float(np.clip(offset, -0.5, 0.5))

    floor = float(np.median(magnitude))
    peak = float(magnitude[peak_index])
    confidence = max(0.0, min(1.0, (peak - floor) / (peak + 1e-15)))
    return lag, confidence


def estimate_direction(samples, positions, calibration=None):
    """Estimate angle, six pair delays and confidence from one audio window."""
    if samples.ndim != 2 or samples.shape[1] != CHANNELS:
        raise ValueError("samples must have shape (frames, 4)")
    if samples.shape[0] < 64:
        raise ValueError("at least 64 frames are required")

    calibration = (
        np.zeros(CHANNELS, dtype=np.float64)
        if calibration is None
        else np.asarray(calibration, dtype=np.float64)
    )

    signal = samples.astype(np.float64, copy=False)
    signal = signal - np.mean(signal, axis=0, keepdims=True)
    signal *= np.hanning(signal.shape[0])[:, None]
    fft_length = _next_power_of_two(signal.shape[0] * 2)
    spectra = np.fft.rfft(signal, n=fft_length, axis=0)

    delays = []
    confidences = []
    equations = []
    for mic_i, mic_j in PAIRS:
        distance = float(np.linalg.norm(positions[mic_i] - positions[mic_j]))
        physical_limit = distance * SAMPLE_RATE / SPEED_OF_SOUND
        max_lag = int(math.ceil(physical_limit)) + 2
        lag, confidence = gcc_phat_from_spectra(
            spectra[:, mic_i], spectra[:, mic_j], fft_length, max_lag
        )
        lag -= calibration[mic_i] - calibration[mic_j]
        delays.append(lag)
        confidences.append(confidence)
        equations.append(positions[mic_i] - positions[mic_j])

    equations = np.asarray(equations, dtype=np.float64)
    delays = np.asarray(delays, dtype=np.float64)
    confidences = np.asarray(confidences, dtype=np.float64)
    distances = -SPEED_OF_SOUND * delays / SAMPLE_RATE

    # Weak pairs still contribute slightly; strong pairs receive more weight.
    weights = 0.05 + confidences * confidences
    weighted_a = equations * np.sqrt(weights)[:, None]
    weighted_b = distances * np.sqrt(weights)
    direction, _, _, _ = np.linalg.lstsq(weighted_a, weighted_b, rcond=None)
    norm = float(np.linalg.norm(direction))
    if norm < 1e-12:
        raise RuntimeError("direction solution is degenerate")
    direction /= norm

    angle = math.degrees(math.atan2(direction[0], direction[1]))
    confidence = float(np.average(confidences, weights=weights))
    return angle, delays, confidence


def circular_mean_degrees(angles):
    radians = np.radians(np.asarray(angles, dtype=np.float64))
    return math.degrees(
        math.atan2(float(np.mean(np.sin(radians))), float(np.mean(np.cos(radians))))
    )


def angular_distance_degrees(first, second):
    """Return the shortest unsigned distance between two angles."""
    return abs((float(first) - float(second) + 180.0) % 360.0 - 180.0)


def circular_median_degrees(angles):
    """Choose the measured angle with the smallest total circular distance."""
    values = [float(angle) for angle in angles]
    if not values:
        raise ValueError("at least one angle is required")
    return min(
        values,
        key=lambda candidate: sum(
            angular_distance_degrees(candidate, value) for value in values
        ),
    )


class AngleTracker:
    """Suppress isolated reflections while retaining real source movement."""

    def __init__(
        self,
        history_size=5,
        min_confidence=0.75,
        jump_degrees=25.0,
        confirm_windows=3,
        candidate_radius=15.0,
    ):
        self.history = deque(maxlen=history_size)
        self.candidate = deque(maxlen=confirm_windows)
        self.min_confidence = min_confidence
        self.jump_degrees = jump_degrees
        self.confirm_windows = confirm_windows
        self.candidate_radius = candidate_radius
        self.angle = None

    def _candidate_accepts(self, angle):
        if not self.candidate:
            return True
        centre = circular_median_degrees(self.candidate)
        return angular_distance_degrees(angle, centre) <= self.candidate_radius

    def update(self, raw_angle, confidence):
        if confidence < self.min_confidence:
            self.candidate.clear()
            return self.angle, "low-confidence"

        if self.angle is None:
            if not self._candidate_accepts(raw_angle):
                self.candidate.clear()
            self.candidate.append(raw_angle)
            if len(self.candidate) < self.confirm_windows:
                return None, "acquiring"
            self.history.extend(self.candidate)
            self.candidate.clear()
            self.angle = circular_median_degrees(self.history)
            return self.angle, "locked"

        if angular_distance_degrees(raw_angle, self.angle) <= self.jump_degrees:
            self.candidate.clear()
            self.history.append(raw_angle)
            self.angle = circular_median_degrees(self.history)
            return self.angle, "tracking"

        # A large jump must persist for several consecutive windows before the
        # tracker changes direction.  Isolated room reflections are held out.
        if not self._candidate_accepts(raw_angle):
            self.candidate.clear()
        self.candidate.append(raw_angle)
        if len(self.candidate) < self.confirm_windows:
            return self.angle, "holding"

        new_angle = circular_median_degrees(self.candidate)
        self.history.clear()
        self.history.extend(self.candidate)
        self.candidate.clear()
        self.angle = new_angle
        return self.angle, "switched"


def put_latest(packet_queue, item, stats):
    """Never block capture: discard the oldest analysis packet if necessary."""
    while True:
        try:
            packet_queue.put_nowait(item)
            return
        except queue.Full:
            try:
                packet_queue.get_nowait()
                stats["software_dropped_packets"] += 1
            except queue.Empty:
                pass


def capture_worker(dma, gpio, channel, buffers, packet_queue, stop_event, stats):
    """Continuously re-arm simple DMA and feed complete packets to the CPU."""
    sequence = 0
    current = 0
    try:
        gpio.write(0x0C, 0)
        gpio.write(0x08, 0)
        time.sleep(0.002)
        stats["hardware_drops_before"] = gpio.read(0x00)

        channel.transfer(buffers[current])
        gpio.write(0x08, 1)
        while not stop_event.is_set():
            wait_packet(channel, dma.mmio)
            next_buffer = 1 - current
            channel.transfer(buffers[next_buffer])

            # Re-arm first, then copy, so the 4096-frame hardware FIFO covers
            # the short CPU copy interval rather than the FFT calculation.
            packet = np.array(buffers[current], dtype=np.int32, copy=True)
            put_latest(packet_queue, (sequence, packet), stats)
            stats["captured_packets"] = sequence + 1
            sequence += 1
            current = next_buffer
    except BaseException as error:
        stats["error"] = error
        stop_event.set()
    finally:
        gpio.write(0x08, 0)
        stats["hardware_drops_after"] = gpio.read(0x00)
        if channel.running:
            channel.stop()


LED_COUNT = 24


def loudness_to_brightness(samples, min_db=-55.0, max_db=-12.0,
                            min_brightness=4, max_brightness=255):
    """Map the four-channel RMS level to an 8-bit LED brightness value."""
    signal = samples.astype(np.float64, copy=False) / float(1 << 23)
    rms = float(np.sqrt(np.mean(np.square(signal))))
    db = 20.0 * math.log10(max(rms, 1e-12))
    normalized = (db - min_db) / max(max_db - min_db, 1e-9)
    normalized = float(np.clip(normalized, 0.0, 1.0))
    brightness = min_brightness + normalized * (max_brightness - min_brightness)
    return int(round(np.clip(brightness, 0, 255))), db


def spectral_centroid_hz(samples):
    """Return the energy-weighted spectral centroid of the four-channel audio."""
    signal = samples.astype(np.float64, copy=False)
    signal -= np.mean(signal, axis=0, keepdims=True)
    window = np.hanning(signal.shape[0])[:, None]
    spectrum = np.abs(np.fft.rfft(signal * window, axis=0))
    magnitude = np.mean(spectrum, axis=1)
    frequencies = np.fft.rfftfreq(signal.shape[0], 1.0 / SAMPLE_RATE)
    total = float(np.sum(magnitude))
    if total < 1e-12:
        return 0.0
    return float(np.sum(frequencies * magnitude) / total)


def pitch_to_rgb(centroid_hz, min_hz=250.0, max_hz=5000.0):
    """Map low/cool spectral content to blue and high content to red."""
    value = (float(centroid_hz) - min_hz) / max(max_hz - min_hz, 1e-9)
    value = float(np.clip(value, 0.0, 1.0))
    # Hue: 240 degrees (blue) at low frequencies -> 0 degrees (red) at high.
    hue = (1.0 - value) * 240.0
    sector = hue / 60.0
    index = int(math.floor(sector)) % 6
    fraction = sector - math.floor(sector)
    colours = (
        (1.0, fraction, 0.0),
        (1.0 - fraction, 1.0, 0.0),
        (0.0, 1.0, fraction),
        (0.0, 1.0 - fraction, 1.0),
        (fraction, 0.0, 1.0),
        (1.0, 0.0, 1.0 - fraction),
    )
    red, green, blue = colours[index]
    return int(round(red * 255)), int(round(green * 255)), int(round(blue * 255))


def led_control_for_angle(angle, offset=0, red=32, green=0, blue=0):
    """Pack one selected WS2812 LED and its RGB color into the AXI GPIO word."""
    index = int(round(float(angle) * LED_COUNT / 360.0)) % LED_COUNT
    index = (index + int(offset)) % LED_COUNT
    return (
        index
        | (1 << 5)
        | ((int(red) & 0xFF) << 8)
        | ((int(green) & 0xFF) << 16)
        | ((int(blue) & 0xFF) << 24)
    )


def start_hdmi_visual(overlay):
    """Enable the 720p VTC; the FPGA graphics source needs no TPG register."""
    try:
        vtc = overlay.v_tc_0.mmio
        visual_gpio = overlay.axi_gpio_visual.mmio
    except AttributeError as error:
        raise RuntimeError(
            "The overlay has no v_tc_0/axi_gpio_visual. Build the soundscape "
            "Vivado design and use its matching .bit/.hwh files."
        ) from error

    visual_gpio.write(0x04, 0)  # GPIO channel 1: all outputs
    visual_gpio.write(0x0C, 0)  # GPIO channel 2: all outputs
    visual_gpio.write(0x00, 0)
    visual_gpio.write(0x08, (1 << 27) | (1 << 31))  # quiet until first packet
    vtc.write(0x00, 0x01FFFF07)
    print("HDMI soundscape 1280x720: VTC=0x{:08X}".format(vtc.read(0x00)),
          flush=True)
    return visual_gpio


def pack_visual_words(angle, brightness, rgb, confidence, centroid_hz,
                      silence, pulse, commit):
    """Pack two 32-bit GPIO words for the PL animation source."""
    if angle is None:
        x_offset, y_offset = 0, -205
    else:
        radians = math.radians(angle)
        x_offset = int(round(205 * math.sin(radians)))
        y_offset = int(round(-205 * math.cos(radians)))
    x_offset = max(-511, min(511, x_offset))
    y_offset = max(-511, min(511, y_offset))
    level = max(0, min(255, int(brightness)))
    quality = max(0, min(15, int(round(confidence * 15))))
    word0 = ((x_offset & 0x3FF) | ((y_offset & 0x3FF) << 10) |
             (level << 20) | (quality << 28))
    red, green, blue = [max(0, min(255, int(c))) for c in rgb]
    band = 0 if centroid_hz < 650 else 1 if centroid_hz < 2300 else 2
    word1 = (red | (green << 8) | (blue << 16) | (band << 24) |
             (int(angle is not None) << 26) | (int(silence) << 27) |
             (int(pulse) << 28) | (int(commit) << 31))
    return word0, word1


def run(args):
    # PYNQ's device discovery uses the main thread's asyncio event loop on this
    # board image, so create the Overlay and DMA buffers before starting capture.
    from pynq import Overlay, allocate

    overlay = Overlay(str(args.overlay))
    visual_gpio = start_hdmi_visual(overlay)
    dma = overlay.axi_dma_0
    gpio = overlay.axi_gpio_capture.mmio
    led_gpio = getattr(overlay, "axi_gpio_led", None)
    if led_gpio is not None:
        led_gpio = led_gpio.mmio
        led_gpio.write(0x00, 0)
    else:
        print("WS2812 output is unavailable in this overlay", flush=True)
    channel = dma.recvchannel
    if not hasattr(channel, "transfer"):
        raise RuntimeError("AXI DMA receive channel is unavailable")
    buffers = [
        allocate(shape=(FRAMES_PER_PACKET, CHANNELS), dtype=np.int32, cacheable=False)
        for _ in range(2)
    ]

    positions = square_positions(args.side_cm / 100.0)
    packet_queue = queue.Queue(maxsize=args.queue_packets)
    stop_event = threading.Event()
    stats = {
        "captured_packets": 0,
        "software_dropped_packets": 0,
        "hardware_drops_before": 0,
        "hardware_drops_after": 0,
        "error": None,
    }
    worker = threading.Thread(
        target=capture_worker,
        args=(dma, gpio, channel, buffers, packet_queue, stop_event, stats),
        name="microphone-capture",
        daemon=True,
    )
    worker.start()

    windows = []
    smoothed_brightness = float(args.min_brightness)
    smoothed_rgb = np.asarray([255.0, 0.0, 0.0])
    visual_commit = 1
    visual_pulse = 0
    previous_level_db = None
    last_pulse_time = 0.0
    accepted_angle = None
    accepted_confidence = 0.0
    accepted_brightness = args.min_brightness
    accepted_rgb = (0, 0, 255)
    accepted_centroid = 0.0
    expected_sequence = None
    tracker = AngleTracker(
        history_size=args.smoothing,
        min_confidence=args.min_confidence,
        jump_degrees=args.jump_degrees,
        confirm_windows=args.confirm_windows,
    )
    print(
        "Real-time localization started: {:.0f} ms/window, Ctrl+C to stop".format(
            1000.0 * args.packets_per_estimate * FRAMES_PER_PACKET / SAMPLE_RATE
        ),
        flush=True,
    )
    print("Angle convention: front=0 deg, right=positive, left=negative", flush=True)

    try:
        while not stop_event.is_set():
            try:
                sequence, packet = packet_queue.get(timeout=0.25)
            except queue.Empty:
                if stats["error"] is not None:
                    raise stats["error"]
                continue

            if expected_sequence is not None and sequence != expected_sequence:
                windows.clear()
            expected_sequence = sequence + 1
            windows.append(packet)
            if len(windows) < args.packets_per_estimate:
                continue

            samples = np.concatenate(windows, axis=0)
            windows.clear()
            brightness, level_db = loudness_to_brightness(
                samples,
                args.loudness_min_db,
                args.loudness_max_db,
                args.min_brightness,
                args.max_brightness,
            )
            smoothed_brightness += args.brightness_alpha * (
                brightness - smoothed_brightness
            )
            brightness = int(round(smoothed_brightness))
            if level_db < args.silence_db:
                # Below the noise floor, the spectral centroid is dominated by
                # microphone/electrical noise and must not drive the colour.
                centroid_hz = 0.0
                target_rgb = np.asarray((0.0, 0.0, 255.0), dtype=np.float64)
                smoothed_brightness += args.brightness_alpha * (
                    args.min_brightness - smoothed_brightness
                )
                brightness = int(round(smoothed_brightness))
            else:
                centroid_hz = spectral_centroid_hz(samples)
                target_rgb = np.asarray(
                    pitch_to_rgb(centroid_hz, args.pitch_min_hz, args.pitch_max_hz),
                    dtype=np.float64,
                )
            smoothed_rgb += args.color_alpha * (target_rgb - smoothed_rgb)
            red, green, blue = [int(round(np.clip(value, 0, 255))) for value in smoothed_rgb]
            angle, delays, confidence = estimate_direction(
                samples, positions, args.calibration
            )
            smooth, state = tracker.update(angle, confidence)
            if smooth is not None and state in ("locked", "tracking", "switched"):
                accepted_angle = smooth
                accepted_confidence = confidence
                accepted_brightness = brightness
                accepted_rgb = (red, green, blue)
                accepted_centroid = centroid_hz
            if (
                led_gpio is not None
                and smooth is not None
                and state in ("locked", "tracking", "switched")
            ):
                led_gpio.write(
                    0x00,
                    led_control_for_angle(
                        smooth, args.led_offset,
                        red=round(red * brightness / 255.0),
                        green=round(green * brightness / 255.0),
                        blue=round(blue * brightness / 255.0),
                    ),
                )
            now = time.monotonic()
            if (previous_level_db is not None and
                level_db >= args.silence_db and
                level_db - previous_level_db >= 8.0 and
                now - last_pulse_time >= 0.35):
                visual_pulse ^= 1
                last_pulse_time = now
            previous_level_db = level_db
            visual_commit ^= 1
            visual0, visual1 = pack_visual_words(
                accepted_angle, accepted_brightness, accepted_rgb,
                accepted_confidence, accepted_centroid,
                level_db < args.silence_db, visual_pulse, visual_commit,
            )
            visual_gpio.write(0x00, visual0)
            visual_gpio.write(0x08, visual1)  # commit bit is written last
            delay_text = ",".join("{:+.1f}".format(value) for value in delays)
            angle_text = "  ----" if smooth is None else "{:+6.1f}".format(smooth)
            print(
                "Angle={} deg  raw={:+6.1f}  confidence={:.2f}  level={:+.1f} dB  "
                "centroid={:.0f} Hz  "
                "state={:<14} delays=[{}]".format(
                    angle_text, angle, confidence, level_db, centroid_hz, state, delay_text
                ),
                flush=True,
            )
    except KeyboardInterrupt:
        print("\nStopping...", flush=True)
    finally:
        stop_event.set()
        worker.join(timeout=3.0)
        gpio.write(0x08, 0)
        if led_gpio is not None:
            led_gpio.write(0x00, 0)
        if channel.running:
            channel.stop()
        for buffer in buffers:
            buffer.close()

    if stats["error"] is not None:
        raise stats["error"]
    hardware_drops = (
        stats["hardware_drops_after"] - stats["hardware_drops_before"]
    ) & 0xFFFFFFFF
    print(
        "Stopped. captured packets={}, hardware dropped frames={}, "
        "software dropped packets={}".format(
            stats["captured_packets"],
            hardware_drops,
            stats["software_dropped_packets"],
        )
    )


def main():
    parser = argparse.ArgumentParser(description="Real-time four-microphone DOA")
    parser.add_argument("--overlay", type=Path, default=Path("4mic_soundscape.bit"))
    parser.add_argument("--side-cm", type=float, default=8.0)
    parser.add_argument("--packets-per-estimate", type=int, default=4)
    parser.add_argument("--smoothing", type=int, default=5)
    parser.add_argument("--min-confidence", type=float, default=0.75)
    parser.add_argument("--jump-degrees", type=float, default=25.0)
    parser.add_argument("--confirm-windows", type=int, default=3)
    parser.add_argument("--queue-packets", type=int, default=32)
    parser.add_argument(
        "--led-offset",
        type=int,
        default=0,
        help="clockwise LED index offset used to align LED 0 with the array front",
    )
    parser.add_argument("--loudness-min-db", type=float, default=-55.0)
    parser.add_argument("--loudness-max-db", type=float, default=-12.0)
    parser.add_argument("--min-brightness", type=int, default=4)
    parser.add_argument("--max-brightness", type=int, default=255)
    parser.add_argument("--brightness-alpha", type=float, default=0.30)
    parser.add_argument("--pitch-min-hz", type=float, default=250.0)
    parser.add_argument("--pitch-max-hz", type=float, default=5000.0)
    parser.add_argument("--color-alpha", type=float, default=0.25)
    parser.add_argument(
        "--silence-db",
        type=float,
        default=-55.0,
        help="音量低于此值时忽略噪声频谱，默认 -55 dB",
    )
    parser.add_argument(
        "--calibration",
        type=parse_calibration,
        default=np.zeros(CHANNELS, dtype=np.float64),
        help="per-channel timing offsets in samples, e.g. 0,0,2,0",
    )
    args = parser.parse_args()
    if not args.overlay.is_file():
        parser.error("bitstream not found: {}".format(args.overlay))
    if not args.overlay.with_suffix(".hwh").is_file():
        parser.error("matching HWH file not found: {}".format(
            args.overlay.with_suffix(".hwh")
        ))
    if not math.isfinite(args.side_cm) or args.side_cm <= 0:
        parser.error("--side-cm must be positive")
    if args.packets_per_estimate <= 0:
        parser.error("--packets-per-estimate must be positive")
    if args.smoothing <= 0 or args.queue_packets <= 0:
        parser.error("--smoothing and --queue-packets must be positive")
    if not 0.0 <= args.min_confidence <= 1.0:
        parser.error("--min-confidence must be between 0 and 1")
    if args.jump_degrees <= 0 or args.confirm_windows <= 0:
        parser.error("--jump-degrees and --confirm-windows must be positive")
    if not 0 <= args.led_offset < LED_COUNT:
        parser.error("--led-offset must be between 0 and 23")
    run(args)


if __name__ == "__main__":
    main()

