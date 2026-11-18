#!/usr/bin/env python3
"""Plain HTTP server for the tests: serves DIR on 127.0.0.1 at a free port,
writes the port to PORTFILE, and stops by itself after a while (so a lost
background process can't keep a CI job alive).

    python3 http_server.py DIR PORTFILE [SECONDS]

Below /api/ it plays the REST APIs for git-assetsync without the CLIs
(ASSETSYNC_TEST_API=http://127.0.0.1:PORT/api): /api/<API URL without
https://> is answered by fake_gh.py (api.github.com, api.<x>.ghe.com,
<host>/api/v3) or fake_glab.py (<host>/api/v4), with FAKE_GH_DIR as
fixture directory, like the platforms do it:

- GitHub asset downloads are redirected to localhost/storage/... (another
  host: the token must not go along), GitLab's releases/permalink/latest to the
  release (the same host: the token goes along).
- Each request is appended to <FAKE_GH_DIR>/http.log: "PATH auth=TOKEN"
  (the token sent, '-' without).
- Tokens: 'bad' gives HTTP 401; a file <FAKE_GH_DIR>/ratelimit HTTP 403
  with X-RateLimit-Remaining: 0, as GitHub's rate limit.
"""

import functools
import json
import os
import re
import subprocess
import sys
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote

HERE = Path(__file__).resolve().parent


class Handler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        for prefix in ("/api/", "/storage/"):
            if self.path.startswith(prefix):
                return self.api(self.path[len(prefix):], prefix == "/storage/")
        super().do_GET()

    def reply(self, status, body=b"", headers=()):
        self.send_response(status)
        for h in headers:
            self.send_header(*h)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def api(self, rest, storage):
        fixtures = Path(os.environ["FAKE_GH_DIR"])
        auth = self.headers.get("Authorization") or self.headers.get("Private-Token") or "-"
        token = auth.split()[-1]
        with open(fixtures / "http.log", "a", encoding="utf-8") as log:
            log.write(f"{'/storage/' if storage else '/api/'}{rest} auth={token}\n")
        if token == "bad":
            return self.reply(401, b'{"message": "Bad credentials"}')
        if (fixtures / "ratelimit").exists():
            return self.reply(403, b'{"message": "API rate limit exceeded"}',
                              [("X-RateLimit-Remaining", "0")])
        apihost, _, path = rest.partition("/")
        m = re.fullmatch(r"api\.(.+)", apihost)
        if m and not path.startswith("api/"):
            fake, host = "fake_gh.py", m.group(1)
        elif path.startswith("api/v3/"):
            fake, host, path = "fake_gh.py", apihost, path[len("api/v3/"):]
        elif path.startswith("api/v4/"):
            fake, host, path = "fake_glab.py", apihost, path[len("api/v4/"):]
        else:
            return self.reply(404)
        accept = self.headers.get("Accept", "")
        if fake == "fake_gh.py" and not storage and accept == "application/octet-stream" \
                and re.search(r"/releases/assets/\d+$", path):
            port = self.server.server_address[1]
            return self.reply(302, headers=[
                ("Location", f"http://localhost:{port}/storage/{rest}")])
        args = [sys.executable, str(HERE / fake), "api", "--hostname", host]
        if accept and accept != "*/*":
            args += ["-H", f"Accept: {accept}"]
        p = subprocess.run(args + [path], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if p.returncode:
            m = re.search(rb"\(HTTP (\d+)\)", p.stderr)
            return self.reply(int(m.group(1)) if m else 500, p.stdout)
        if fake == "fake_glab.py" and path.endswith("/releases/permalink/latest"):
            tag = json.loads(p.stdout)["tag_name"]
            base = path[:-len("permalink/latest")]
            return self.reply(302, headers=[
                ("Location", f"/api/{apihost}/api/v4/{base}{quote(tag, safe='')}")])
        self.reply(200, p.stdout)


def main(directory, portfile, seconds="900"):
    server = ThreadingHTTPServer(("127.0.0.1", 0),
                                 functools.partial(Handler, directory=directory))
    with open(portfile + ".tmp", "w") as f:
        f.write(str(server.server_address[1]))
    os.replace(portfile + ".tmp", portfile)
    threading.Timer(float(seconds), server.shutdown).start()
    server.serve_forever()


if __name__ == "__main__":
    main(*sys.argv[1:])
