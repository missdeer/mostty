"""Deterministic output probes for pane visibility and URL targeting."""
import argparse
import os
from pathlib import Path
import sys
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("url", "hidden", "stream", "glyphs"))
    parser.add_argument("pane", type=int, choices=range(4))
    parser.add_argument("output", type=Path)
    parser.add_argument("--phase", type=int, choices=(0, 1), default=0)
    args = parser.parse_args()
    if args.mode in ("hidden", "stream"):
        args.output.with_suffix(".ready").write_text("ready", encoding="utf-8")
        deadline = time.monotonic() + 20
        while not args.output.with_suffix(".go").exists():
            if time.monotonic() >= deadline:
                raise TimeoutError("runner did not release hidden output")
            time.sleep(0.02)
        if args.mode == "stream":
            for index in range(300):
                sys.stdout.write(f"sustained-output-{index}\r\n")
                sys.stdout.flush()
                if index == 0:
                    args.output.with_suffix(".started").write_text("started", encoding="utf-8")
                time.sleep(0.01)
            args.output.write_text(f"{os.getppid()},{args.output.stem}", encoding="utf-8")
            return
        colors = ((255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0))
        red, green, blue = colors[(args.pane + args.phase) % 4]
        text = f"\x1b[2J\x1b[H\x1b[48;2;{red};{green};{blue}m        \x1b[0m\r\nHIDDEN_PANE_{args.pane}\r\n"
    elif args.mode == "glyphs":
        background = "0;0;128" if args.phase == 0 else "128;0;0"
        text = f"\x1b[2J\x1b[H\x1b[48;2;{background}m\x1b[38;2;255;255;255mDPI{args.pane}_ABC123xyz\x1b[0m\r\n"
    else:
        text = "\x1b[2J\x1b[H" + "\r\n" * (args.pane * 2) + f"https://p{args.pane}.example.test/\r\n"
    sys.stdout.write(text)
    sys.stdout.flush()
    args.output.write_text(f"{os.getppid()},{args.output.stem}", encoding="utf-8")


if __name__ == "__main__":
    main()
