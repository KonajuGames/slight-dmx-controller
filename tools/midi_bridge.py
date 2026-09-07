#!/usr/bin/env python3
"""
sLight MIDI feedback bridge.

Godot has no MIDI output, so sLight sends its MIDI feedback (LED updates
for a controller's pads/buttons) as raw 3-byte MIDI messages over UDP.
This script forwards them to a real MIDI output port.

    pip install mido python-rtmidi
    python midi_bridge.py --list
    python midi_bridge.py --port "Launchpad" --udp 9010

In sLight: Triggers... dialog -> Feedback (LEDs), set "MIDI -> bridge :"
to the same UDP port (default 9010), tick a binding's "light the pad
when active".
"""
import argparse
import socket
import sys

try:
    import mido
except ImportError:
    sys.exit("mido not found.  pip install mido python-rtmidi")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--udp", type=int, default=9010, help="UDP port to listen on (default 9010)")
    ap.add_argument("--host", default="127.0.0.1", help="UDP bind address (default 127.0.0.1)")
    ap.add_argument("--port", default=None, help="MIDI output port name (substring match)")
    ap.add_argument("--list", action="store_true", help="list MIDI output ports and exit")
    args = ap.parse_args()

    outs = mido.get_output_names()
    if args.list or not outs:
        print("MIDI output ports:")
        for o in outs:
            print("  ", o)
        if not outs:
            print("  (none)")
        return

    name = outs[0]
    if args.port:
        matches = [o for o in outs if args.port.lower() in o.lower()]
        if not matches:
            sys.exit(f"No MIDI output matches {args.port!r}. Have: {outs}")
        name = matches[0]

    out = mido.open_output(name)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((args.host, args.udp))
    print(f"Forwarding UDP {args.host}:{args.udp}  ->  MIDI '{name}'   (Ctrl+C to stop)")

    try:
        while True:
            data, _ = sock.recvfrom(256)
            for i in range(0, len(data) - 2, 3):
                try:
                    out.send(mido.Message.from_bytes(bytes(data[i:i + 3])))
                except (ValueError, IndexError):
                    pass
    except KeyboardInterrupt:
        pass
    finally:
        out.close()
        sock.close()


if __name__ == "__main__":
    main()
