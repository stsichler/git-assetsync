#!/usr/bin/env python3
"""Plain HTTP server for the tests: serves DIR on 127.0.0.1 at a free port,
writes the port to PORTFILE, and stops by itself after a while (so a lost
background process can't keep a CI job alive).

    python3 http_server.py DIR PORTFILE [SECONDS]
"""

import functools
import os
import sys
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


class Quiet(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def main(directory, portfile, seconds="900"):
    server = ThreadingHTTPServer(("127.0.0.1", 0),
                                 functools.partial(Quiet, directory=directory))
    with open(portfile + ".tmp", "w") as f:
        f.write(str(server.server_address[1]))
    os.replace(portfile + ".tmp", portfile)
    threading.Timer(float(seconds), server.shutdown).start()
    server.serve_forever()


if __name__ == "__main__":
    main(*sys.argv[1:])
