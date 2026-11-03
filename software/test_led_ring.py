"""Light one WS2812 LED at a time to verify wiring and LED order on the board."""

import argparse
import time
from pathlib import Path


def control_word(index, red=16, green=16, blue=16):
    return (
        (index & 0x1F)
        | (1 << 5)
        | ((red & 0xFF) << 8)
        | ((green & 0xFF) << 16)
        | ((blue & 0xFF) << 24)
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--overlay", type=Path, default=Path("4mic_realtime.bit"))
    parser.add_argument("--seconds", type=float, default=0.25)
    parser.add_argument("--red", type=int, default=16)
    parser.add_argument("--green", type=int, default=16)
    parser.add_argument("--blue", type=int, default=16)
    args = parser.parse_args()
    if args.seconds <= 0 or any(not 0 <= value <= 255 for value in
                                (args.red, args.green, args.blue)):
        parser.error("--seconds must be positive and RGB values must be 0..255")

    from pynq import Overlay

    overlay = Overlay(str(args.overlay))
    gpio = overlay.axi_gpio_led.mmio
    try:
        for index in range(24):
            print("LED", index, flush=True)
            gpio.write(0x00, control_word(index, args.red, args.green, args.blue))
            time.sleep(args.seconds)
    finally:
        gpio.write(0x00, 0)


if __name__ == "__main__":
    main()
