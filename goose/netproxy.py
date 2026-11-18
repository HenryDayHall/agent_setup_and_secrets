"""agentbox net proxy: lets the box make HTTPS connections to allowlisted hosts only.

usage: netproxy.py SOCKET ALLOW     e.g. ALLOW = pypi,github,example.org
Runs outside the box. Python 3.9+, standard library only.
"""
import ipaddress
import os
import re
import select
import socket
import socketserver
import sys
import threading
import time

GROUPS = {
    "pypi": ["pypi.org", "files.pythonhosted.org"],
    "github": ["github.com", "codeload.github.com", "raw.githubusercontent.com",
               "objects.githubusercontent.com", "release-assets.githubusercontent.com"],
}
# Never connected to, whatever a name resolves to: DESY's own networks (AS1754 and
# DESY-IPV6 in the RIPE database) and IPv6 prefixes that can carry an IPv4 address.
# Private, loopback, link-local and other non-public addresses are refused too.
BLOCKED = [ipaddress.ip_network(n) for n in (
    "131.169.0.0/16", "141.34.0.0/16", "192.76.172.0/24", "192.109.31.0/24",
    "2001:638:700::/48", "2002::/16", "64:ff9b::/96", "64:ff9b:1::/48")]
PORTS = {443}
MAX_TUNNELS = 32
HEADER_TIMEOUT, CONNECT_TIMEOUT, IDLE_TIMEOUT, TICK = 10, 10, 300, 5
HOSTNAME = re.compile(r"[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+")
ALLOW = set()
SLOTS = threading.BoundedSemaphore(MAX_TUNNELS)


def log(*msg):
    # Since the log will likely be inspected by the host, ensure there are no terminal-escape injections
    safe = (s.encode("unicode_escape").decode("ascii") if isinstance(s, str) else str(s) for s in msg)
    print(time.strftime("%Y-%m-%d %H:%M:%S"), *safe, file=sys.stderr, flush=True)


def blocked(ip):
    if ip.version == 6 and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    return (not ip.is_global or ip.is_private or ip.is_multicast or ip.is_reserved
            or ip.is_loopback or ip.is_link_local or ip.is_unspecified
            or any(ip in net for net in BLOCKED))


def public(addr):
    try:
        return not blocked(ipaddress.ip_address(addr))
    except ValueError:
        return False


def resolve(host, port):
    addrs = []
    for *_, sockaddr in socket.getaddrinfo(host, port, type=socket.SOCK_STREAM):
        if sockaddr[0] not in addrs:
            addrs.append(sockaddr[0])
    return addrs


def deny(conn, code, target, why):
    log("DENY ", target, "-", why)
    reason = why.encode("ascii", "replace").replace(b"\r", b" ").replace(b"\n", b" ")
    conn.sendall(b"HTTP/1.1 %d %s\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" % (code, reason))


def pipe(src, dst, tunnel, i):
    """Copy src to dst until EOF or error, or until neither direction has moved for IDLE_TIMEOUT."""
    while True:
        if not select.select([src], [], [], TICK)[0]:
            if time.monotonic() - tunnel["last"] < IDLE_TIMEOUT:
                continue
            break
        try:
            data = src.recv(65536)
            if not data:
                break
            tunnel["last"] = time.monotonic()
            dst.sendall(data)
        except OSError:
            break
        tunnel["bytes"][i] += len(data)
    try:
        dst.shutdown(socket.SHUT_WR)
    except OSError:
        pass


def handle(conn):
    conn.settimeout(HEADER_TIMEOUT)
    buf = b""
    try:
        while b"\r\n\r\n" not in buf and len(buf) <= 8192:
            data = conn.recv(4096)
            if not data:
                return
            buf += data
    except OSError:
        return
    head, sep, early = buf.partition(b"\r\n\r\n")
    parts = head.split(b"\r\n", 1)[0].decode("latin-1").split()
    if not sep or len(parts) != 3:
        return deny(conn, 400, "-", "malformed request")
    method, target = parts[0], parts[1]
    if method != "CONNECT":
        return deny(conn, 405, target, "only HTTPS through CONNECT is allowed")
    host, _, port = target.rpartition(":")
    host = host.strip("[]").lower().rstrip(".")
    if not port.isdigit() or int(port) not in PORTS:
        return deny(conn, 403, target, "port not allowed")
    if host not in ALLOW:              # checked before any DNS lookup
        return deny(conn, 403, target, "host not in the allowlist")
    if not SLOTS.acquire(blocking=False):
        return deny(conn, 503, target, "too many open connections")
    try:
        connect(conn, host, int(port), target, early)
    finally:
        SLOTS.release()


def connect(conn, host, port, target, early):
    try:
        addrs = resolve(host, port)
    except OSError as e:
        return deny(conn, 502, target, "DNS lookup failed: %s" % e)
    good = [a for a in addrs if public(a)]
    if not good:
        return deny(conn, 403, target, "resolves only to internal addresses " + " ".join(addrs))
    upstream, err = None, None
    for addr in good:                  # connect to the address that was checked, never re-resolve
        try:
            upstream = socket.create_connection((addr, port), timeout=CONNECT_TIMEOUT)
            break
        except OSError as e:
            err = e
    if upstream is None:
        return deny(conn, 502, target, "connect failed: %s" % err)
    with upstream:
        conn.settimeout(None)
        upstream.settimeout(None)
        log("OPEN ", target, "->", addr)
        conn.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        tunnel = {"last": time.monotonic(), "bytes": [len(early), 0]}
        if early:
            upstream.sendall(early)
        helper = threading.Thread(target=pipe, args=(conn, upstream, tunnel, 0), daemon=True)
        helper.start()
        pipe(upstream, conn, tunnel, 1)
        helper.join()
        log("CLOSE", target, "up=%d down=%d bytes" % tuple(tunnel["bytes"]))


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            handle(self.request)
        except OSError:
            pass


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True


def main(argv):
    if len(argv) != 2:
        sys.exit(__doc__)
    path, spec = argv
    for item in filter(None, (s.strip().lower() for s in spec.split(","))):
        for name in GROUPS.get(item, [item]):
            if not HOSTNAME.fullmatch(name):
                sys.exit("netproxy: not a host name: %r" % name)
            ALLOW.add(name)
    if not ALLOW:
        sys.exit("netproxy: nothing to allow")
    os.umask(0o077)
    log("allowing", " ".join(sorted(ALLOW)))
    with Server(path, Handler) as server:
        server.serve_forever()


if __name__ == "__main__":
    main(sys.argv[1:])
