"""Save the logger's screen as a PNG, using the console's "screenshot" command.

Opening the port resets the board, so the script waits for the boot banner's
"Ready." and then --delay seconds (default 6) for the screen to settle before
asking for the picture. The image is the real frame LVGL draws, pixel for pixel
(172 x 320), scaled up by --scale for sharing.

Example (PowerShell, from the project folder):
  C:\\pio\\venv\\Scripts\\python.exe tools\\screenshot.py screen.png
  C:\\pio\\venv\\Scripts\\python.exe tools\\screenshot.py screen.png --scale 1
"""
import argparse
import struct
import sys
import time
import zlib

from console import find_logger, describe_ports

try:
    import serial
except ImportError:
    sys.exit("pyserial is missing. Run this with PlatformIO's Python: C:\\pio\\venv\\Scripts\\python.exe")


def write_png(path, width, height, rows):
    """rows: list of bytes objects, RGB, width*3 long each."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + r for r in rows)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        f.write(chunk(b"IEND", b""))


def rgb565(c):
    r, g, b = (c >> 11) & 31, (c >> 5) & 63, c & 31
    return (r * 255 + 15) // 31, (g * 255 + 31) // 63, (b * 255 + 15) // 31


def main():
    ap = argparse.ArgumentParser(description="Save the logger's screen as a PNG.")
    ap.add_argument("out", nargs="?", default="screenshot.png")
    ap.add_argument("--port", help="serial port (default: the plugged-in ESP32)")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--delay", type=float, default=6.0, help="seconds after boot before the picture (default 6)")
    ap.add_argument("--scale", type=int, default=3, help="enlarge each pixel this many times (default 3)")
    args = ap.parse_args()

    if not args.port:
        args.port = find_logger()
        if not args.port:
            sys.exit("Can't find the logger. " + describe_ports())
    try:
        port = serial.Serial(args.port, args.baud, timeout=0.5)
    except serial.SerialException as e:
        sys.exit(f"Can't open {args.port}: {e}\n{describe_ports()}")
    port.dtr = False
    port.rts = False

    # Read in big chunks and split lines here: pyserial's readline() reads a byte at a
    # time, which can't keep up with the ~220 KB burst, and rows arrive short.
    pending = bytearray()

    def readline(timeout):
        end = time.time() + timeout
        while time.time() < end:
            i = pending.find(b"\n")
            if i >= 0:
                line = bytes(pending[:i])
                del pending[:i + 1]
                return line.decode("ascii", "replace").strip()
            pending.extend(port.read(port.in_waiting or 1))
        return None

    try:
        end = time.time() + 15
        while time.time() < end:
            line = readline(1)
            if line and "Ready." in line:
                break
        else:
            print("[screenshot.py] no 'Ready.' seen; asking anyway", file=sys.stderr)
        time.sleep(args.delay)
        port.reset_input_buffer()
        pending.clear()
        port.write(b"screenshot\n")

        width = height = None
        frame = None
        end = time.time() + 30
        while time.time() < end:
            line = readline(5)
            if line is None:
                continue
            if line.startswith("SCREENSHOT "):
                width, height = map(int, line.split()[1:3])
                frame = [[(0, 0, 0)] * width for _ in range(height)]
            elif line.startswith("AREA ") and frame is not None:
                x1, y1, x2, y2 = map(int, line.split()[1:5])
                for y in range(y1, y2 + 1):
                    row = readline(5) or ""
                    if len(row) < (x2 - x1 + 1) * 4:
                        sys.exit(f"[screenshot.py] row {y} arrived short ({len(row)} characters); try again")
                    for i, x in enumerate(range(x1, x2 + 1)):
                        frame[y][x] = rgb565(int(row[i * 4:i * 4 + 4], 16))
            elif line == "END SCREENSHOT":
                break
        else:
            sys.exit("[screenshot.py] the picture didn't arrive. Is the firmware new enough to have 'screenshot'?")
    except serial.SerialException as e:
        sys.exit(f"[screenshot.py] lost {args.port}: {e}")
    finally:
        port.close()

    s = max(1, args.scale)
    rows = []
    for y in range(height):
        r = b"".join(bytes(px) * s for px in frame[y])
        rows.extend([r] * s)
    write_png(args.out, width * s, height * s, rows)
    print(f"Saved {args.out} ({width * s} x {height * s})")


if __name__ == "__main__":
    main()
