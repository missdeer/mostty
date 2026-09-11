"""Real PTY probe: periodic output, live terminal dimensions, and raw input log."""
import base64
import os
import select
import signal
import sys
import tty

name, directory = sys.argv[1:3]
tty.setraw(0)


def title(*_):
    size = os.get_terminal_size()
    print(f"\033]2;{name}:{os.getpid()}:{size.lines}:{size.columns}\007", end="", flush=True)


signal.signal(signal.SIGWINCH, title)
title()
with open(os.path.join(directory, name + ".pid"), "w") as file:
    file.write(str(os.getpid()))
with open(os.path.join(directory, name + ".input"), "wb", buffering=0) as log:
    tick = 0
    paused = False
    while True:
        if select.select([0], [], [], 0.1)[0]:
            data = os.read(0, 4096)
            if not data or b"\x04" in data:
                break
            log.write(data)
            if data == b"M":
                print("\033[?1003h\033[?1006h", end="", flush=True)
            elif data == b"B":
                print("\033[?2004h", end="", flush=True)
            elif data == b"G":
                paused = True
                pixels = base64.b64encode(bytes([255, 0, 0, 255]) * 4).decode()
                print(f"\033[2J\033[H\033_Ga=T,f=32,s=2,v=2,i=1,c=200,r=100,q=2;{pixels}\033\\", end="", flush=True)
            elif data == b"C":
                paused = True
                print("\033[2J\033[H", end="", flush=True)
            elif data == b"R":
                paused = False
        if paused:
            continue
        tick += 1
        print(f"{name} output {tick}\r\n", end="", flush=True)
