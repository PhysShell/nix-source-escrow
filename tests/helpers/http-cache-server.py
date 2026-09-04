#!/usr/bin/env python3
"""Serve a directory as an HTTP binary cache, announcing its port to a FILE.

t16 used to start `python3 -m http.server 0`, redirect its stdout to a log and
scrape the port out of the human-readable startup line. In CI that log was
empty and the test timed out after ten seconds -- not because the server had
failed, but because the sentence was still sitting in a stdio buffer. The
server was alive the whole time. Service discovery through a buffered printf
is not a protocol.

The port is written to a file, atomically (write to a sibling, then rename),
so a reader either sees nothing or sees the whole number. Nothing here parses
prose emitted by a standard library that is free to reword it.

usage: http-cache-server.py <directory> <port-file>
"""

import functools
import http.server
import os
import socketserver
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    directory, port_file = sys.argv[1], sys.argv[2]

    handler = functools.partial(http.server.SimpleHTTPRequestHandler,
                                directory=directory)

    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True

    with Server(("127.0.0.1", 0), handler) as httpd:
        port = httpd.server_address[1]
        tmp = port_file + ".tmp"
        with open(tmp, "w") as f:
            f.write("%d\n" % port)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, port_file)
        httpd.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
