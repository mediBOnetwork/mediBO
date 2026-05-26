#!/usr/bin/env python3
"""Static server for the Flutter WASM build with cross-origin isolation.

Adds the COOP/COEP headers skwasm needs to run multi-threaded (SharedArrayBuffer).
COEP=credentialless lets the gstatic CanvasKit fallback still load.

Usage: python3 serve_coi.py [port] [directory]
  defaults: port 8080, directory ./build/web
"""
import sys
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
DIRECTORY = sys.argv[2] if len(sys.argv) > 2 else "build/web"


class COIHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "credentialless")
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()


if __name__ == "__main__":
    handler = partial(COIHandler, directory=DIRECTORY)
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), handler)
    print(f"Serving {DIRECTORY} on http://0.0.0.0:{PORT} (cross-origin isolated)")
    httpd.serve_forever()
