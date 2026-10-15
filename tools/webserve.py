#!/usr/bin/env python3
"""Serve the web bundle.

    python3 tools/webserve.py [PORT] [DIRECTORY]

A plain static server. The page talks to the IRC server itself, over a
WebSocket, so there is nothing here to relay.
"""

import functools
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
    root = sys.argv[2] if len(sys.argv) > 2 else "build/web"
    handler = functools.partial(SimpleHTTPRequestHandler, directory=root)
    print(f"serving {root} on http://127.0.0.1:{port}/")
    ThreadingHTTPServer(("", port), handler).serve_forever()


if __name__ == "__main__":
    main()
