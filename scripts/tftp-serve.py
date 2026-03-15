#!/usr/bin/env python3
"""Minimal multi-file TFTP server for firmware flashing."""
import os
import socket
import struct
import sys

BLOCK_SIZE = 512

def serve(directory, bind="0.0.0.0", port=69):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind((bind, port))
    except PermissionError:
        port = 6969
        sock.bind((bind, port))
    print(f"[tftp] Serving {directory} on :{port}")
    for f in os.listdir(directory):
        print(f"  {f} ({os.path.getsize(os.path.join(directory, f))} bytes)")

    while True:
        data, addr = sock.recvfrom(516)
        opcode = struct.unpack("!H", data[:2])[0]
        if opcode != 1:  # RRQ
            continue
        # Parse filename from RRQ
        parts = data[2:].split(b"\x00")
        filename = parts[0].decode()
        filepath = os.path.join(directory, os.path.basename(filename))
        print(f"[tftp] RRQ '{filename}' from {addr[0]}:{addr[1]}")

        xfer = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        xfer.settimeout(5.0)

        if not os.path.exists(filepath):
            err = struct.pack("!HH", 5, 1) + b"File not found\x00"
            xfer.sendto(err, addr)
            xfer.close()
            print(f"[tftp] File not found: {filepath}")
            continue

        with open(filepath, "rb") as f:
            file_data = f.read()
        total = len(file_data)
        block = 1
        offset = 0
        while True:
            chunk = file_data[offset:offset + BLOCK_SIZE]
            pkt = struct.pack("!HH", 3, block) + chunk
            for _ in range(5):
                xfer.sendto(pkt, addr)
                try:
                    ack, _ = xfer.recvfrom(4)
                    ack_op, ack_blk = struct.unpack("!HH", ack[:4])
                    if ack_op == 4 and ack_blk == block:
                        break
                except socket.timeout:
                    pass
            offset += BLOCK_SIZE
            block += 1
            pct = min(100, offset * 100 // total) if total else 100
            print(f"\r[tftp] {offset}/{total} ({pct}%)", end="", flush=True)
            if len(chunk) < BLOCK_SIZE:
                print(f"\n[tftp] Done: {filename} ({total} bytes)")
                break
        xfer.close()

if __name__ == "__main__":
    d = sys.argv[1] if len(sys.argv) > 1 else "."
    serve(d)
