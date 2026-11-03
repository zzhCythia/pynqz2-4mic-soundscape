"""Load the 4mic_hdmi overlay and start the 720p HDMI test pattern.

Run this ON the PYNQ board, in the same directory as 4mic_hdmi.bit and
4mic_hdmi.hwh.  The overlay has to be loaded first: without the bitstream
there is no v_tc_0 / v_tpg_0 behind 0x43C0_0000 / 0x43C1_0000 and any access
to those addresses faults.

Register offsets are taken from the AMD product guides:
  PG016 (Video Timing Controller v6.2), CONTROL register at 0x00
  PG103 (Video Test Pattern Generator v8.2)
"""

import argparse
import time
from pathlib import Path

from pynq import Overlay

# --- v_tc CONTROL register (PG016, offset 0x0000) ---------------------------
VTC_CONTROL = 0x00
VTC_STATUS = 0x04
VTC_CTL_SW_ENABLE = 1 << 0     # enable generator (and detector)
VTC_CTL_REG_UPDATE = 1 << 1    # latch the generator registers next frame
VTC_CTL_GEN_ENABLE = 1 << 2    # generator only (when SW_ENABLE is 0)

# --- v_tpg registers (PG103) ------------------------------------------------
TPG_CONTROL = 0x00
TPG_ACTIVE_HEIGHT = 0x10
TPG_ACTIVE_WIDTH = 0x18
TPG_BACKGROUND_PATTERN = 0x20
TPG_COLOR_FORMAT = 0x40
TPG_AP_START = 1 << 0
TPG_AUTO_RESTART = 1 << 7
TPG_FMT_RGB = 0x0
TPG_FMT_YUV444 = 0x1
TPG_FMT_YUV422 = 0x2

PATTERNS = {
    1: "horizontal ramp",
    2: "vertical ramp",
    3: "temporal ramp",
    4: "solid red",
    5: "solid green",
    6: "solid blue",
    7: "solid black",
    8: "solid white",
    9: "colour bars",
    10: "zone plate",
    11: "tartan colour bars",
    12: "cross hatch",
}

# Fallback map, matching 4mic_hdmi.hwh.
FALLBACK = {"v_tc_0": 0x43C00000, "v_tpg_0": 0x43C10000}


def block(overlay, name):
    """Return the AXI-Lite register window of an IP, from the HWH if possible."""
    ip = getattr(overlay, name, None)
    if ip is not None and hasattr(ip, "mmio"):
        return ip.mmio
    from pynq import MMIO

    print("  {} not found in the overlay, using the hardcoded address".format(name))
    return MMIO(FALLBACK[name], 0x10000)


def start_colour_bars(overlay, width, height, pattern):
    vtc = block(overlay, "v_tc_0")
    tpg = block(overlay, "v_tpg_0")

    # Stop the generator while the timing/pattern registers are being written.
    vtc.write(VTC_CONTROL, 0)

    # Configure the pattern generator before it is started.
    tpg.write(TPG_ACTIVE_HEIGHT, height)
    tpg.write(TPG_ACTIVE_WIDTH, width)
    tpg.write(TPG_COLOR_FORMAT, TPG_FMT_RGB)
    tpg.write(TPG_BACKGROUND_PATTERN, pattern)
    tpg.write(TPG_CONTROL, TPG_AP_START | TPG_AUTO_RESTART)

    # SW_ENABLE turns on both the generator and the detector; the timing values
    # themselves are the ones preset in the v_tc IP (1280x720p60).
    vtc.write(VTC_CONTROL, VTC_CTL_SW_ENABLE)

    # Give v_axi4s_vid_out its four-frame lock time, then read the state back.
    time.sleep(0.2)
    vtc_ctl = vtc.read(VTC_CONTROL)
    vtc_status = vtc.read(VTC_STATUS)
    tpg_ctl = tpg.read(TPG_CONTROL)
    print("v_tc_0  CONTROL = 0x{:08X}  STATUS = 0x{:08X}".format(vtc_ctl, vtc_status))
    print("v_tpg_0 CONTROL = 0x{:08X}".format(tpg_ctl))

    if not vtc_ctl & VTC_CTL_SW_ENABLE:
        print("WARNING: the VTC reports that the generator is disabled")
    if vtc_status == 0:
        print("WARNING: VTC status is 0, the timing generator looks inactive")
    if not tpg_ctl & TPG_AP_START:
        print("WARNING: the TPG reports ap_start = 0")
    print(
        "Requested {}x{} pattern '{}'. If the monitor stays black, check that "
        "the .bit file matches the .hwh file name and that the cable is on "
        "HDMI OUT.".format(width, height, PATTERNS.get(pattern, pattern))
    )


def main():
    parser = argparse.ArgumentParser(description="720p HDMI test pattern")
    parser.add_argument("--overlay", type=Path, default=Path("4mic_hdmi.bit"))
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=720)
    parser.add_argument("--pattern", type=int, default=9,
                        help="TPG background pattern id, 9 = colour bars")
    args = parser.parse_args()

    if args.width <= 0 or args.height <= 0:
        parser.error("--width and --height must be positive")
    if not 1 <= args.pattern <= 19:
        parser.error("--pattern must be between 1 and 19")
    if not args.overlay.is_file():
        parser.error("overlay not found: {} (copy the .bit and the .hwh here)".format(
            args.overlay))
    hwh = args.overlay.with_suffix(".hwh")
    if not hwh.is_file():
        parser.error("missing {} - PYNQ needs the HWH next to the bitstream".format(
            hwh))

    overlay = Overlay(str(args.overlay))
    start_colour_bars(overlay, args.width, args.height, args.pattern)


if __name__ == "__main__":
    main()
