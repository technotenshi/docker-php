#!/usr/bin/env python3
"""Send bounded FastCGI GET requests to a local PHP-FPM container."""

import socket
import struct
import sys
import time


VERSION = 1
FCGI_BEGIN_REQUEST = 1
FCGI_PARAMS = 4
FCGI_STDIN = 5
FCGI_STDOUT = 6
FCGI_STDERR = 7
FCGI_END_REQUEST = 3
FCGI_RESPONDER = 1


def record(kind, request_id, content=b""):
    pad = (-len(content)) % 8
    return struct.pack("!BBHHBB", VERSION, kind, request_id, len(content), pad, 0) + content + b"\0" * pad


def name_value(name, value):
    name = name.encode()
    value = value.encode()

    def length(size):
        return bytes([size]) if size < 128 else struct.pack("!I", size | 0x80000000)

    return length(len(name)) + length(len(value)) + name + value


MAX_RESPONSE = 1024 * 1024
TIMEOUT_SECONDS = 10
REQUIRED_MODULES = {
    "curl", "mbstring", "Zend OPcache", "readline", "xdebug", "dom",
    "SimpleXML", "xml", "xmlreader", "xmlwriter", "xsl", "zip",
}


def request(host, port, token, request_id, expected_version):
    params = {
        "GATEWAY_INTERFACE": "CGI/1.1",
        "REQUEST_METHOD": "GET",
        "SCRIPT_FILENAME": "/var/www/html/index.php",
        "SCRIPT_NAME": "/index.php",
        "REQUEST_URI": "/index.php",
        "QUERY_STRING": "probe=" + str(request_id),
        "SERVER_PROTOCOL": "HTTP/1.1",
        "SERVER_NAME": "localhost",
        "SERVER_PORT": str(port),
        "REMOTE_ADDR": "127.0.0.1",
        "REMOTE_PORT": "12345",
        "CONTENT_LENGTH": "0",
        "CONTENT_TYPE": "",
    }
    payload = record(FCGI_BEGIN_REQUEST, request_id, struct.pack("!HB5s", FCGI_RESPONDER, 0, b""))
    payload += record(FCGI_PARAMS, request_id, b"".join(name_value(k, v) for k, v in params.items()))
    payload += record(FCGI_PARAMS, request_id)
    payload += record(FCGI_STDIN, request_id)
    output = bytearray()
    errors = bytearray()
    deadline = time.monotonic() + TIMEOUT_SECONDS
    with socket.create_connection((host, port), timeout=5) as conn:
        conn.settimeout(5)
        conn.sendall(payload)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError("FastCGI response exceeded time limit")
            conn.settimeout(min(5, remaining))
            header = read_exact(conn, 8, deadline)
            version, kind, rid, length, padding, _ = struct.unpack("!BBHHBB", header)
            if version != VERSION or rid != request_id:
                raise RuntimeError("invalid FastCGI response header")
            content = read_exact(conn, length, deadline)
            if padding:
                read_exact(conn, padding, deadline)
            if kind == FCGI_STDOUT:
                output.extend(content)
            elif kind == FCGI_STDERR:
                errors.extend(content)
            elif kind == FCGI_END_REQUEST:
                app_status, protocol_status, _ = struct.unpack("!IB3s", content)
                if app_status != 0 or protocol_status != 0:
                    raise RuntimeError(
                        "FastCGI end status was app=%d protocol=%d" % (app_status, protocol_status)
                    )
                break
            if len(output) + len(errors) > MAX_RESPONSE:
                raise RuntimeError("FastCGI response exceeded size limit")
    response = bytes(output)
    if b"\r\n\r\n" not in response:
        raise RuntimeError("FastCGI response has no HTTP header separator: " + bytes(errors).decode(errors="replace"))
    body = response.split(b"\r\n\r\n", 1)[1].decode(errors="replace")
    values = dict(line.split("=", 1) for line in body.splitlines() if "=" in line)
    version = values.get("PHP_VERSION", "")
    try:
        major, minor, patch = (int(part) for part in version.split(".")[:3])
        version_id = major * 10000 + minor * 100 + patch
    except (ValueError, TypeError):
        version_id = 0
    modules = set(values.get("MODULES", "").split(","))
    missing = REQUIRED_MODULES - modules
    if (version != expected_version or not 80427 <= version_id < 80500
            or values.get("PHP_SAPI") != "fpm-fcgi"
            or values.get("TOKEN") != token or missing):
        raise RuntimeError(
            "FastCGI response failed checks: version=%r sapi=%r token_match=%r missing_modules=%r body=%r stderr=%r"
            % (version, values.get("PHP_SAPI"), values.get("TOKEN") == token,
               sorted(missing), body[:4000], bytes(errors).decode(errors="replace")[:2000])
        )
    print("request", request_id, "OK:", body.strip())


def read_exact(conn, length, deadline):
    result = bytearray()
    while len(result) < length:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("FastCGI response exceeded time limit")
        conn.settimeout(min(5, remaining))
        part = conn.recv(length - len(result))
        if not part:
            raise RuntimeError("truncated FastCGI response")
        result.extend(part)
    return bytes(result)


def main():
    if len(sys.argv) != 5:
        raise SystemExit("usage: fpm-probe.py HOST PORT TOKEN EXPECTED_PHP_VERSION")
    host, port, token, expected_version = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
    request(host, port, token, 1, expected_version)
    request(host, port, token, 2, expected_version)


if __name__ == "__main__":
    main()
