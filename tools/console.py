"""Talk to the logger's serial console from the command line.

Opening the port resets the board (its USB serial does that), so the script waits
for the boot banner's "Ready." before sending anything. Without --port it finds the
logger by its Espressif USB ID, so it keeps working when Windows renumbers the port.

Examples (PowerShell, from the project folder):
  C:\\pio\\venv\\Scripts\\python.exe tools\\console.py status
  C:\\pio\\venv\\Scripts\\python.exe tools\\console.py "ls" "tail trip.txt 5"
  C:\\pio\\venv\\Scripts\\python.exe tools\\console.py --watch 120 --every 30
  C:\\pio\\venv\\Scripts\\python.exe tools\\console.py --watch 15            (boot log only)

Commands that ask first (rm *, erase-logs) aren't answered for you: send the answer
as the next command if you mean it, for example: console.py erase-logs yes
"""
import argparse
import sys
import time

try:
    import serial  # pyserial, installed with PlatformIO
except ImportError:
    sys.exit("pyserial is missing. Run this with PlatformIO's Python: C:\\pio\\venv\\Scripts\\python.exe")


ESPRESSIF_VID = 0x303A  # the ESP32-C6's built-in USB serial


def find_logger():
    """The logger's port, if exactly one ESP32 is plugged in."""
    from serial.tools import list_ports
    esp = [p.device for p in list_ports.comports() if p.vid == ESPRESSIF_VID]
    return esp[0] if len(esp) == 1 else None


def describe_ports():
    """Says which ports exist and which one looks like the logger."""
    from serial.tools import list_ports
    ports = list(list_ports.comports())
    esp = [p.device for p in ports if p.vid == ESPRESSIF_VID]
    if esp:
        return f"ESP32 ports: {', '.join(esp)}. Pick one with --port."
    names = ", ".join(p.device for p in ports) or "none"
    return f"No ESP32 found (ports present: {names}). Is the logger plugged in, or is a monitor or upload using it?"


def main():
    ap = argparse.ArgumentParser(description="Send commands to the logger's serial console and print the replies.")
    ap.add_argument("commands", nargs="*", help="console commands to send, one argument each (quote ones with spaces)")
    ap.add_argument("--port", help="serial port (default: the plugged-in ESP32)")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--wait", type=float, default=2.0, help="seconds to collect each command's reply (default 2)")
    ap.add_argument("--ready-timeout", type=float, default=10.0,
                    help="seconds to wait for the boot banner's 'Ready.' (default 10)")
    ap.add_argument("--watch", type=float, metavar="SECONDS", help="after the commands, keep printing output this long")
    ap.add_argument("--every", type=float, metavar="SECONDS", help="while watching, send --repeat this often")
    ap.add_argument("--repeat", default="status", help="the command --every sends (default status)")
    args = ap.parse_args()

    if not args.port:
        args.port = find_logger()
        if not args.port:
            sys.exit("Can't find the logger. " + describe_ports())
    try:
        port = serial.Serial(args.port, args.baud, timeout=0.2)
    except serial.SerialException as e:
        sys.exit(f"Can't open {args.port}: {e}\n{describe_ports()}")
    port.dtr = False
    port.rts = False

    seen = bytearray()

    def pump(seconds, stop_on=None):
        end = time.time() + seconds
        while time.time() < end:
            data = port.read(4096)
            if data:
                sys.stdout.write(data.decode("utf-8", "replace"))
                sys.stdout.flush()
                if stop_on is not None:
                    seen.extend(data)
                    if stop_on in seen:
                        return True
        return False

    def send(cmd):
        port.write((cmd + "\n").encode("utf-8"))

    try:
        if not pump(args.ready_timeout, stop_on=b"Ready."):
            print(f"\n[console.py] no 'Ready.' within {args.ready_timeout:g} s; sending anyway", file=sys.stderr)
        pump(0.3)  # the rest of the banner line

        for cmd in args.commands:
            send(cmd)
            pump(args.wait)

        if args.watch:
            end = time.time() + args.watch
            next_send = time.time() + args.every if args.every else None
            while time.time() < end:
                step = min(end, next_send) - time.time() if next_send else end - time.time()
                pump(max(step, 0))
                if next_send and time.time() >= next_send:
                    send(args.repeat)
                    next_send += args.every
    except serial.SerialException as e:
        sys.exit(f"\n[console.py] lost {args.port}: {e}")
    except KeyboardInterrupt:
        pass
    finally:
        port.close()
    print()


if __name__ == "__main__":
    main()
