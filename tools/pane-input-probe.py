"""Bounded console-input probe for the native pane acceptance runner."""
import argparse
import ctypes
import msvcrt
from pathlib import Path
import sys
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("mouse", "paste", "selection", "ime"))
    parser.add_argument("output", type=Path)
    parser.add_argument("--seconds", type=float, default=5)
    args = parser.parse_args()
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.GetStdHandle.restype = ctypes.c_void_p
    kernel.GetConsoleMode.argtypes = (ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32))
    kernel.SetConsoleMode.argtypes = (ctypes.c_void_p, ctypes.c_uint32)
    handle = kernel.GetStdHandle(-10)
    original = ctypes.c_uint32()
    if not kernel.GetConsoleMode(handle, ctypes.byref(original)):
        raise ctypes.WinError(ctypes.get_last_error())
    if not kernel.SetConsoleMode(handle, (original.value & ~7) | 0x200):
        raise ctypes.WinError(ctypes.get_last_error())
    enable = "\x1b[?1000h\x1b[?1006h" if args.mode == "mouse" else ""
    if args.mode == "paste":
        enable = "\x1b[?2004h"
    received = []
    try:
        sys.stdout.write("\x1b[2J\x1b[HSELECTION_PANE\r\n" + enable)
        sys.stdout.flush()
        args.output.with_suffix(".ready").write_text("ready", encoding="utf-8")
        deadline = time.monotonic() + args.seconds
        while time.monotonic() < deadline:
            if msvcrt.kbhit():
                received.append(msvcrt.getwch())
            else:
                time.sleep(0.005)
    finally:
        sys.stdout.write("\x1b[?1000l\x1b[?1006l\x1b[?2004l")
        sys.stdout.flush()
        kernel.SetConsoleMode(handle, original.value)
        text = "".join(received).encode("utf-16", "surrogatepass").decode("utf-16")
        args.output.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
