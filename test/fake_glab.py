#!/usr/bin/env python3
"""Stand-in for the GitLab CLI in the tests: answers `glab api ...` like the
GitLab REST API would, from the same fixture directory as fake_gh.py,
without network.

    FAKE_GH_DIR=<dir> python3 fake_glab.py api --hostname H PATH

Fixture layout (written by the 'release' helper in regress.sh):

    <dir>/<host>/<project path>/<n>/release.json   one directory per release
    <dir>/<host>/<project path>/<n>/assets/<name>  its assets
    <dir>/<host>/<project path>/<n>/notes.md       optional: its description

release.json: {"tag_name", "name", "published_at" (released_at here),
"prerelease" (an upcoming release here), "links" (how the asset links
point to the files: "api" (default; generic packages), "job" (job
artifacts), "upload" (project uploads), "http" (a server elsewhere:
$FAKE_HTTP, see http_server.py), "broken" (a missing file there))}. Drafts don't exist on GitLab and are
left out.

Every call is appended to <dir>/calls.log. Like glab, a missing resource
gives a JSON message on stdout, 'glab: 404 Not Found (HTTP 404)' on stderr
and exit code 1.
"""

import json
import os
import sys
from pathlib import Path
from urllib.parse import parse_qs, quote, unquote, urlsplit

ROOT = Path(os.environ["FAKE_GH_DIR"])
SECRET = "0123456789abcdef0123456789abcdef"


def fail(status, message):
    sys.stdout.write(json.dumps({"message": f"{status} {message}"}))
    sys.stderr.write(f"glab: {status} {message} (HTTP {status})\n")
    sys.exit(1)


def releases(host, project):
    base = ROOT / host / project
    if not (base.is_dir() and all(p.name.isdigit() for p in base.iterdir())):
        fail(404, "Project Not Found")
    result = []
    for d in sorted(base.iterdir(), key=lambda p: int(p.name)):
        meta = json.loads((d / "release.json").read_text(encoding="utf-8"))
        if meta.get("draft"):
            continue
        notes = d / "notes.md"
        if notes.is_file():
            meta["body"] = notes.read_bytes().decode("utf-8")
        adir = d / "assets"
        files = sorted(adir.iterdir()) if adir.is_dir() else []
        result.append((meta, d, files))
    return result


def link_url(host, project, meta, d, f):
    kind = meta.get("links", "api")
    if kind == "http":
        return f"{os.environ['FAKE_HTTP']}/{host}/{project}/{d.name}/assets/{quote(f.name)}"
    if kind == "broken":
        return f"{os.environ['FAKE_HTTP']}/nothing/{quote(f.name)}"
    if kind == "job":
        return f"https://{host}/{project}/-/jobs/{d.name}/artifacts/raw/dist/{quote(f.name)}"
    if kind == "upload":
        return f"https://{host}/{project}/uploads/{SECRET}/{quote(f.name)}"
    return (f"https://{host}/api/v4/projects/{quote(project, safe='')}/packages/generic/"
            f"pkg/{quote(meta['tag_name'], safe='')}/{quote(f.name, safe='')}")


def answer(host, project, meta, d, files):
    tag = meta["tag_name"]
    return {"tag_name": tag, "name": meta.get("name", tag),
            "description": meta.get("body", ""),
            "released_at": meta["published_at"], "created_at": meta["published_at"],
            "upcoming_release": bool(meta.get("prerelease")),
            "_links": {"self": f"https://{host}/{project}/-/releases/{quote(tag)}"},
            "assets": {"count": len(files) + 2,
                       "sources": [{"format": fmt, "url": f"https://{host}/{project}/-/archive/"
                                                         f"{tag}/x-{tag}.{fmt}"}
                                   for fmt in ("zip", "tar.gz")],
                       "links": [{"id": int(d.name) * 1000 + i, "name": f.name,
                                  "url": link_url(host, project, meta, d, f),
                                  "link_type": "other"}
                                 for i, f in enumerate(files)]}}


def main(argv):
    with open(ROOT / "calls.log", "a", encoding="utf-8") as log:
        log.write(" ".join(["glab"] + argv) + "\n")
    if not argv or argv[0] != "api":
        sys.stderr.write(f"fake glab: unsupported command {argv[:1]}\n")
        sys.exit(2)
    host, path, i = "gitlab.com", None, 1
    while i < len(argv):
        a = argv[i]
        if a == "--hostname":
            host, i = argv[i + 1], i + 2
        elif a.startswith("-"):
            sys.stderr.write(f"fake glab: unsupported option {a}\n")
            sys.exit(2)
        else:
            path, i = a, i + 1
    url = urlsplit(path)
    query = parse_qs(url.query)
    parts = url.path.strip("/").split("/")
    if len(parts) < 2 or parts[0] != "projects":
        fail(404, "Not Found")
    project, rest = unquote(parts[1]), parts[2:]

    def out(obj):
        sys.stdout.write(json.dumps(obj))

    def send(f):
        sys.stdout.buffer.write(f.read_bytes())

    if not rest:
        if not (ROOT / host / project).is_dir():
            fail(404, "Project Not Found")
        out({"path_with_namespace": project})
        return
    rels = releases(host, project)
    if rest == ["releases"]:
        per_page = int(query.get("per_page", ["20"])[0])
        page = int(query.get("page", ["1"])[0])
        items = sorted(rels, key=lambda r: r[0]["published_at"], reverse=True)
        out([answer(host, project, *r) for r in items[(page - 1) * per_page:page * per_page]])
    elif rest == ["releases", "permalink", "latest"]:
        cands = [r for r in rels if not r[0].get("prerelease")]
        if not cands:
            fail(404, "Not Found")
        out(answer(host, project, *max(cands, key=lambda r: r[0]["published_at"])))
    elif len(rest) == 2 and rest[0] == "releases":
        tag = unquote(rest[1])
        for r in rels:
            if r[0]["tag_name"] == tag:
                out(answer(host, project, *r))
                return
        fail(404, "Not Found")
    elif len(rest) == 5 and rest[:2] == ["packages", "generic"]:
        tag, name = unquote(rest[3]), unquote(rest[4])
        for meta, _, files in rels:
            for f in files:
                if meta["tag_name"] == tag and f.name == name:
                    return send(f)
        fail(404, "Not Found")
    elif len(rest) >= 4 and rest[0] == "jobs" and rest[2] == "artifacts":
        name = unquote(rest[-1])
        for meta, d, files in rels:
            for f in files:
                if d.name == rest[1] and f.name == name:
                    return send(f)
        fail(404, "Not Found")
    elif len(rest) == 3 and rest[0] == "uploads" and rest[1] == SECRET:
        name = unquote(rest[2])
        for meta, d, files in rels:
            for f in files:
                if f.name == name:
                    return send(f)
        fail(404, "Not Found")
    else:
        fail(404, "Not Found")


if __name__ == "__main__":
    main(sys.argv[1:])
