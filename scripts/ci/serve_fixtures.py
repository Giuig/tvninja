#!/usr/bin/env python3
"""Serves the files of one folder over HTTP with Range support, for the emulator tests.

The emulator reaches the runner's loopback as 10.0.2.2. Python's own http.server ignores
Range requests, which ExoPlayer and mpv may send for a progressive MP4, so this answers
them (206) instead of always returning the whole file. Every request goes to the log.

Usage: serve_fixtures.py DIRECTORY PORT LOGFILE
"""
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.realpath(sys.argv[1])
PORT = int(sys.argv[2])
LOG = open(sys.argv[3], "a", buffering=1)
TYPES = {".mp4": "video/mp4", ".m3u8": "application/vnd.apple.mpegurl", ".ts": "video/mp2t"}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        LOG.write("%s %s\n" % (self.address_string(), fmt % args))

    def _file(self):
        name = os.path.basename(self.path.split("?", 1)[0])
        path = os.path.realpath(os.path.join(ROOT, name))
        if os.path.dirname(path) != ROOT or not os.path.isfile(path):
            return None
        return path

    def _serve(self, head):
        path = self._file()
        if path is None:
            self.send_error(404)
            return
        size = os.path.getsize(path)
        start, end, status = 0, size - 1, 200
        rng = self.headers.get("Range")
        if rng:
            m = re.match(r"bytes=(\d*)-(\d*)$", rng.strip())
            if m and (m.group(1) or m.group(2)):
                if m.group(1):
                    start = int(m.group(1))
                    if m.group(2):
                        end = min(int(m.group(2)), size - 1)
                else:
                    start = max(size - int(m.group(2)), 0)
                if start >= size:
                    self.send_response(416)
                    self.send_header("Content-Range", "bytes */%d" % size)
                    self.end_headers()
                    return
                status = 206
        self.send_response(status)
        self.send_header("Content-Type", TYPES.get(os.path.splitext(path)[1], "application/octet-stream"))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if status == 206:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.end_headers()
        if head:
            return
        with open(path, "rb") as f:
            f.seek(start)
            left = end - start + 1
            while left > 0:
                chunk = f.read(min(65536, left))
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    return
                left -= len(chunk)

    def do_GET(self):
        self._serve(False)

    def do_HEAD(self):
        self._serve(True)


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
