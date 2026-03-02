"""TAP network interface + built-in DHCP server for integration tests.

Provides a TapNetwork context manager that:
  - Creates a TAP interface (requires sudo)
  - Runs a minimal DHCP server thread on the TAP interface
  - Assigns a fixed IP to the guest (10.0.2.15/24)
  - Tears down cleanly on exit

Uses AF_PACKET raw sockets because Linux drops DHCP broadcasts
(src IP 0.0.0.0) before they reach regular UDP sockets.

Usage:
    with TapNetwork("fornax0") as tap:
        # tap.iface = "fornax0"
        # tap.host_ip = "10.0.2.2"
        # Guest will get 10.0.2.15 via DHCP
        qemu = QemuDriver(..., tap_iface="fornax0")
"""
import os
import socket
import struct
import subprocess
import threading
import time


# DHCP constants
DHCP_SERVER_PORT = 67
DHCP_CLIENT_PORT = 68
DHCP_MAGIC = b'\x63\x82\x53\x63'

# Ethernet
ETH_P_IP = 0x0800
ETH_HEADER_LEN = 14
IP_HEADER_LEN = 20
UDP_HEADER_LEN = 8

# Message types
DHCPDISCOVER = 1
DHCPOFFER = 2
DHCPREQUEST = 3
DHCPACK = 5


def _ip_bytes(ip_str):
    """Convert dotted-quad string to 4 bytes."""
    return socket.inet_aton(ip_str)


def _checksum(data):
    """Compute IP/UDP checksum."""
    if len(data) % 2:
        data += b'\x00'
    s = 0
    for i in range(0, len(data), 2):
        s += (data[i] << 8) + data[i + 1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return ~s & 0xFFFF


class _DhcpServer(threading.Thread):
    """Minimal DHCP server for a single client on a TAP interface.

    Uses AF_PACKET raw sockets to handle DHCP broadcasts with src=0.0.0.0
    which Linux's IP stack would otherwise drop before delivery to UDP sockets.

    Handles: DISCOVER -> OFFER, REQUEST -> ACK.
    Assigns a single fixed IP; no lease management.
    """

    def __init__(self, iface, host_ip, client_ip, netmask, dns_ip):
        super().__init__(daemon=True)
        self.iface = iface
        self.host_ip = host_ip
        self.client_ip = client_ip
        self.netmask = netmask
        self.dns_ip = dns_ip
        self._stop_event = threading.Event()
        self._ready = threading.Event()
        self._error = None
        self.sock = None
        # Get our MAC from the interface
        self._server_mac = b'\x00' * 6

    def stop(self):
        self._stop_event.set()
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass

    def wait_ready(self, timeout=5):
        """Wait for DHCP server to be listening. Raises on failure."""
        self._ready.wait(timeout)
        if self._error:
            raise self._error

    def run(self):
        try:
            self._serve()
        except Exception as e:
            self._error = e
            self._ready.set()  # unblock waiter
            if not self._stop_event.is_set():
                import sys
                print(f"\nDHCP server error: {e}", file=sys.stderr, flush=True)

    def _get_mac(self):
        """Get the MAC address of our interface."""
        import fcntl
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            info = fcntl.ioctl(
                s.fileno(), 0x8927,  # SIOCGIFHWADDR
                struct.pack('256s', self.iface.encode()[:15])
            )
            return info[18:24]
        finally:
            s.close()

    def _serve(self):
        self._server_mac = self._get_mac()

        # Raw socket: receive all IPv4 frames on this interface.
        # Requires CAP_NET_RAW (run test with sudo).
        try:
            self.sock = socket.socket(
                socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_IP)
            )
        except PermissionError:
            raise PermissionError(
                "AF_PACKET socket requires root. Run: sudo python tests/run_iperf.py"
            )
        self.sock.bind((self.iface, 0))
        self.sock.settimeout(1.0)
        self._ready.set()

        self._logf = open("/tmp/fornax-dhcp.log", "w")
        _log = lambda msg: (self._logf.write(f"{msg}\n"), self._logf.flush())
        _log(f"listening on {self.iface} (mac={self._server_mac.hex(':')})")

        pkt_count = 0
        while not self._stop_event.is_set():
            try:
                data = self.sock.recv(4096)
            except socket.timeout:
                continue
            except OSError:
                break

            pkt_count += 1
            frame = self._parse_dhcp_frame(data)
            if frame is None:
                continue

            dhcp_data, client_mac = frame
            mac_str = client_mac.hex(':')
            _log(f"DHCP packet from {mac_str} (frame #{pkt_count}, {len(data)} bytes)")
            reply_dhcp = self._handle_dhcp(dhcp_data)
            if reply_dhcp:
                msg_type = reply_dhcp[240 + 2]  # option 53 value
                type_name = {2: "OFFER", 5: "ACK"}.get(msg_type, f"type={msg_type}")
                _log(f"sending {type_name} → {self.client_ip}")
                reply_frame = self._build_reply_frame(reply_dhcp, client_mac)
                try:
                    self.sock.send(reply_frame)
                    _log(f"sent {len(reply_frame)} bytes")
                except OSError as e:
                    _log(f"send failed: {e}")

    def _parse_dhcp_frame(self, data):
        """Parse Ethernet+IP+UDP frame, return (dhcp_payload, client_mac) or None."""
        if len(data) < ETH_HEADER_LEN + IP_HEADER_LEN + UDP_HEADER_LEN:
            return None

        # Ethernet header
        eth_type = struct.unpack('!H', data[12:14])[0]
        if eth_type != ETH_P_IP:
            return None
        src_mac = data[6:12]

        # IP header
        ip_start = ETH_HEADER_LEN
        ip_ver_ihl = data[ip_start]
        ip_ihl = (ip_ver_ihl & 0x0F) * 4
        if ip_ihl < 20:
            return None
        ip_proto = data[ip_start + 9]
        if ip_proto != 17:  # UDP
            return None

        # UDP header
        udp_start = ip_start + ip_ihl
        if len(data) < udp_start + UDP_HEADER_LEN:
            return None
        src_port, dst_port = struct.unpack('!HH', data[udp_start:udp_start + 4])

        # DHCP: client port 68 → server port 67
        if src_port != DHCP_CLIENT_PORT or dst_port != DHCP_SERVER_PORT:
            return None

        dhcp_start = udp_start + UDP_HEADER_LEN
        return data[dhcp_start:], src_mac

    def _handle_dhcp(self, data):
        """Parse DHCP request, return DHCP reply payload or None."""
        if len(data) < 240:
            return None

        op = data[0]
        if op != 1:  # Not BOOTREQUEST
            return None

        xid = data[4:8]
        client_mac = data[28:34]

        # Check magic cookie
        if data[236:240] != DHCP_MAGIC:
            return None

        # Parse options to find message type
        msg_type = None
        i = 240
        while i < len(data):
            opt = data[i]
            if opt == 255:  # END
                break
            if opt == 0:  # PAD
                i += 1
                continue
            if i + 1 >= len(data):
                break
            opt_len = data[i + 1]
            if i + 2 + opt_len > len(data):
                break
            opt_data = data[i + 2:i + 2 + opt_len]

            if opt == 53 and opt_len >= 1:  # DHCP Message Type
                msg_type = opt_data[0]

            i += 2 + opt_len

        if msg_type == DHCPDISCOVER:
            return self._build_dhcp_reply(DHCPOFFER, xid, client_mac)
        elif msg_type == DHCPREQUEST:
            return self._build_dhcp_reply(DHCPACK, xid, client_mac)

        return None

    def _build_dhcp_reply(self, msg_type, xid, client_mac):
        """Build a DHCP OFFER or ACK reply (DHCP payload only)."""
        reply = bytearray(300)

        reply[0] = 2  # BOOTREPLY
        reply[1] = 1  # Ethernet
        reply[2] = 6  # MAC length
        reply[3] = 0  # Hops
        reply[4:8] = xid
        # flags: broadcast
        reply[10] = 0x80
        reply[11] = 0x00
        # yiaddr (your IP)
        reply[16:20] = _ip_bytes(self.client_ip)
        # siaddr (server IP)
        reply[20:24] = _ip_bytes(self.host_ip)
        # chaddr (client MAC)
        reply[28:34] = client_mac

        # Magic cookie
        reply[236:240] = DHCP_MAGIC

        # Options
        pos = 240

        # Option 53: DHCP Message Type
        reply[pos:pos + 3] = bytes([53, 1, msg_type])
        pos += 3

        # Option 54: Server Identifier
        reply[pos:pos + 2] = bytes([54, 4])
        reply[pos + 2:pos + 6] = _ip_bytes(self.host_ip)
        pos += 6

        # Option 51: Lease Time (1 hour)
        reply[pos:pos + 2] = bytes([51, 4])
        struct.pack_into('>I', reply, pos + 2, 3600)
        pos += 6

        # Option 1: Subnet Mask
        reply[pos:pos + 2] = bytes([1, 4])
        reply[pos + 2:pos + 6] = _ip_bytes(self.netmask)
        pos += 6

        # Option 3: Router
        reply[pos:pos + 2] = bytes([3, 4])
        reply[pos + 2:pos + 6] = _ip_bytes(self.host_ip)
        pos += 6

        # Option 6: DNS Server
        reply[pos:pos + 2] = bytes([6, 4])
        reply[pos + 2:pos + 6] = _ip_bytes(self.dns_ip)
        pos += 6

        # End
        reply[pos] = 255

        return bytes(reply)

    def _build_reply_frame(self, dhcp_payload, dst_mac):
        """Wrap DHCP reply in UDP+IP+Ethernet frame for raw socket send."""
        src_ip = _ip_bytes(self.host_ip)
        dst_ip = b'\xff\xff\xff\xff'  # broadcast

        # UDP header
        udp_len = UDP_HEADER_LEN + len(dhcp_payload)
        udp_hdr = struct.pack('!HHH', DHCP_SERVER_PORT, DHCP_CLIENT_PORT, udp_len)
        udp_hdr += b'\x00\x00'  # checksum (optional for IPv4 UDP)
        udp_pkt = udp_hdr + dhcp_payload

        # IP header
        ip_total = IP_HEADER_LEN + len(udp_pkt)
        ip_hdr = struct.pack('!BBHHHBBH4s4s',
            0x45,           # version + IHL
            0,              # TOS
            ip_total,       # total length
            0,              # identification
            0x4000,         # flags (DF)
            64,             # TTL
            17,             # protocol (UDP)
            0,              # checksum (filled below)
            src_ip,
            dst_ip,
        )
        # Compute IP checksum
        cksum = _checksum(ip_hdr)
        ip_hdr = ip_hdr[:10] + struct.pack('!H', cksum) + ip_hdr[12:]

        ip_pkt = ip_hdr + udp_pkt

        # Ethernet header: broadcast reply
        bcast_mac = b'\xff\xff\xff\xff\xff\xff'
        eth_hdr = bcast_mac + self._server_mac + struct.pack('!H', ETH_P_IP)

        return eth_hdr + ip_pkt


class TapNetwork:
    """Context manager: TAP with NAT routing for guest network access.

    Creates a TAP interface on a private subnet (192.168.30.0/24 by default)
    with IP forwarding and iptables MASQUERADE.  The host NIC is NEVER touched.
    A built-in DHCP server assigns the guest a fixed IP.

    Requires root (sudo).
    """

    # Private subnet for the TAP link — must NOT overlap host's real network
    SUBNET = "10.55.0.0/24"
    HOST_TAP_IP = "10.55.0.1"
    GUEST_IP = "10.55.0.15"
    NETMASK = "255.255.255.0"

    def __init__(self, iface="fornax0", host_nic=None):
        self.iface = iface
        self.host_ip = self.HOST_TAP_IP
        self._host_nic = host_nic  # auto-detected for MASQUERADE
        self._reused = False
        self._dhcp = None
        self._fwd_was_on = False

    def __enter__(self):
        self._detect_host_nic()
        self._setup_tap()
        self._start_dhcp()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self._stop_dhcp()
        if not self._reused:
            self._teardown_tap()
        return False

    # ── detection ──────────────────────────────────────────────────

    def _detect_host_nic(self):
        """Find the default-route interface (for MASQUERADE out-iface)."""
        if self._host_nic:
            return
        out = subprocess.run(
            ["ip", "-4", "route", "show", "default"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        if not out:
            raise RuntimeError("No default IPv4 route — can't detect host NIC")
        parts = out.split()
        self._host_nic = parts[parts.index("dev") + 1]

    # ── helpers ────────────────────────────────────────────────────

    def _run(self, *args, check=True):
        r = subprocess.run(list(args), capture_output=True)
        if check and r.returncode != 0:
            cmd = " ".join(args)
            err = r.stderr.decode().strip()
            raise RuntimeError(f"command failed: {cmd}\n  {err}")
        return r

    def _iface_exists(self, name):
        return os.path.isdir(f"/sys/class/net/{name}")

    def _iface_has_ip(self, name, ip):
        r = subprocess.run(
            ["ip", "-4", "-o", "addr", "show", "dev", name],
            capture_output=True, text=True,
        )
        return ip in r.stdout

    # ── setup / teardown ───────────────────────────────────────────

    def _setup_tap(self):
        """Create TAP interface with host IP, enable forwarding + NAT.

        Idempotent: if the TAP already exists and is configured, skip.
        """
        if (self._iface_exists(self.iface)
                and self._iface_has_ip(self.iface, self.HOST_TAP_IP)):
            self._reused = True
            return

        self._reused = False
        user = os.environ.get("SUDO_USER", os.environ.get("USER", "root"))

        # Clean up stale TAP
        self._run("ip", "tuntap", "del", "dev", self.iface, "mode", "tap",
                  check=False)

        # Create TAP
        self._run("ip", "tuntap", "add", "dev", self.iface,
                  "mode", "tap", "user", user)
        self._run("ip", "addr", "add",
                  f"{self.HOST_TAP_IP}/24", "dev", self.iface)
        self._run("ip", "link", "set", self.iface, "up")

        # Enable IP forwarding (save old state)
        try:
            with open("/proc/sys/net/ipv4/ip_forward") as f:
                self._fwd_was_on = f.read().strip() == "1"
        except OSError:
            self._fwd_was_on = False
        if not self._fwd_was_on:
            with open("/proc/sys/net/ipv4/ip_forward", "w") as f:
                f.write("1\n")

        # Add MASQUERADE rule (idempotent via -C check)
        r = self._run("iptables", "-t", "nat", "-C", "POSTROUTING",
                       "-s", self.SUBNET, "-o", self._host_nic,
                       "-j", "MASQUERADE", check=False)
        if r.returncode != 0:
            self._run("iptables", "-t", "nat", "-A", "POSTROUTING",
                       "-s", self.SUBNET, "-o", self._host_nic,
                       "-j", "MASQUERADE")

        # Allow forwarding for TAP traffic
        r = self._run("iptables", "-C", "FORWARD",
                       "-i", self.iface, "-j", "ACCEPT", check=False)
        if r.returncode != 0:
            self._run("iptables", "-A", "FORWARD",
                       "-i", self.iface, "-j", "ACCEPT")
        r = self._run("iptables", "-C", "FORWARD",
                       "-o", self.iface, "-m", "state",
                       "--state", "RELATED,ESTABLISHED",
                       "-j", "ACCEPT", check=False)
        if r.returncode != 0:
            self._run("iptables", "-A", "FORWARD",
                       "-o", self.iface, "-m", "state",
                       "--state", "RELATED,ESTABLISHED",
                       "-j", "ACCEPT")

        time.sleep(0.3)

    def _teardown_tap(self):
        """Remove TAP, NAT rules, and optionally restore forwarding."""
        # Remove iptables rules
        self._run("iptables", "-t", "nat", "-D", "POSTROUTING",
                   "-s", self.SUBNET, "-o", self._host_nic,
                   "-j", "MASQUERADE", check=False)
        self._run("iptables", "-D", "FORWARD",
                   "-i", self.iface, "-j", "ACCEPT", check=False)
        self._run("iptables", "-D", "FORWARD",
                   "-o", self.iface, "-m", "state",
                   "--state", "RELATED,ESTABLISHED",
                   "-j", "ACCEPT", check=False)

        # Restore forwarding if we enabled it
        if not self._fwd_was_on:
            try:
                with open("/proc/sys/net/ipv4/ip_forward", "w") as f:
                    f.write("0\n")
            except OSError:
                pass

        # Delete TAP
        self._run("ip", "tuntap", "del", "dev", self.iface, "mode", "tap",
                  check=False)

    def _start_dhcp(self):
        """Start the built-in DHCP server on the TAP interface."""
        self._dhcp = _DhcpServer(
            self.iface, self.HOST_TAP_IP, self.GUEST_IP,
            self.NETMASK, "1.1.1.1",
        )
        self._dhcp.start()
        self._dhcp.wait_ready()

    def _stop_dhcp(self):
        if self._dhcp:
            self._dhcp.stop()
