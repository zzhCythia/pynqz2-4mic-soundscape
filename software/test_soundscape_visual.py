#!/usr/bin/env python3
"""Standalone HDMI animation check, without microphones or the LED ring."""

import argparse
import math
import time

from pynq import Overlay


def packet(angle, color, level, band, pulse, commit):
    angle = math.radians(angle)
    x = round(205 * math.sin(angle)) & 0x3ff
    y = round(-205 * math.cos(angle)) & 0x3ff
    word0 = x | (y << 10) | (level << 20) | (15 << 28)
    red, green, blue = color
    word1 = (red | (green << 8) | (blue << 16) |
             (band << 24) | (1 << 26) | (pulse << 28) |
             (commit << 31))
    return word0, word1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--overlay', default='4mic_soundscape.bit')
    args = parser.parse_args()

    overlay = Overlay(args.overlay)
    gpio = overlay.axi_gpio_visual.mmio
    vtc = overlay.v_tc_0.mmio
    gpio.write(0x04, 0)
    gpio.write(0x0c, 0)
    vtc.write(0x00, 0x01ffff07)
    print('VTC:', hex(vtc.read(0x00)), flush=True)

    commit = 0
    pulse = 0
    colors = ((0, 90, 255), (40, 255, 130), (255, 55, 0))
    try:
        for step in range(120):
            commit ^= 1
            if step % 5 == 0:
                pulse ^= 1
            angle = -90 + (step * 6) % 180
            band = (step // 15) % 3
            word0, word1 = packet(angle, colors[band], 150,
                                  band, pulse, commit)
            gpio.write(0x00, word0)
            gpio.write(0x08, word1)
            print('angle={:+4d} band={}'.format(angle, band), flush=True)
            time.sleep(0.16)
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
