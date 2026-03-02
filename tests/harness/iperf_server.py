#!/usr/bin/env python3
"""Simple TCP sink for iperf testing.

Listens on port 5201 (or specified port), accepts one connection,
reads all data until EOF, and reports bytes/elapsed/throughput.
No iperf3 protocol — just raw TCP.

Usage:
    python tests/harness/iperf_server.py [PORT]
"""
import socket
import sys
import time


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 5201

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as srv:
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("0.0.0.0", port))
        srv.listen(1)
        print(f"iperf_server: listening on :{port}")

        conn, addr = srv.accept()
        print(f"iperf_server: connection from {addr}")

        total = 0
        start = time.monotonic()

        with conn:
            while True:
                data = conn.recv(65536)
                if not data:
                    break
                total += len(data)

        elapsed = time.monotonic() - start
        elapsed = max(elapsed, 0.001)

        kb = total / 1024
        kbps = kb / elapsed

        print(f"\n--- iperf_server results ---")
        print(f"Received: {total} bytes in {elapsed:.3f}s")
        print(f"Throughput: {kbps:.1f} KB/s ({kbps * 8 / 1024:.2f} Mbps)")


if __name__ == "__main__":
    main()
