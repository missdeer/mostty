"""Emit identical Kitty image IDs with distinct pane colors for isolation checks."""
import argparse
import base64
from pathlib import Path
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("draw", "delete"))
    parser.add_argument("pane", type=int, choices=range(4))
    parser.add_argument("ready", type=Path)
    args = parser.parse_args()
    if args.mode == "draw":
        colors = ((255, 0, 0, 255), (0, 255, 0, 255), (0, 0, 255, 255), (255, 255, 0, 255))
        pixels = bytes(colors[args.pane]) * (16 * 16)
        payload = base64.b64encode(pixels).decode("ascii")
        sys.stdout.write(f"\x1b[2J\x1b[HPANE_IMAGE_{args.pane}\r\n")
        sys.stdout.write(f"\x1b_Ga=T,f=32,s=16,v=16,i=77,q=2,c=4,r=2,z=1;{payload}\x1b\\")
    else:
        sys.stdout.write("\x1b_Ga=d,d=i,i=77,q=2\x1b\\")
    sys.stdout.flush()
    args.ready.write_text("ready", encoding="utf-8")


if __name__ == "__main__":
    main()
