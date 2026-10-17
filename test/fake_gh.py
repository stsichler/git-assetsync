#!/usr/bin/env python3
"""Stand-in for the GitHub CLI in the tests: answers `gh api ...` like the
GitHub REST API would, from a fixture directory, without network.

    FAKE_GH_DIR=<dir> python3 fake_gh.py api [--hostname H] [-H HEADER] PATH

Fixture layout (written by the 'release' helper in regress.sh):

    <dir>/<host>/<owner>/<repo>/<n>/release.json   one directory per release
    <dir>/<host>/<owner>/<repo>/<n>/assets/<name>  its assets
    <dir>/<host>/<owner>/<repo>/<n>/notes.md       optional: its description

release.json: {"tag_name", "name", "published_at", "prerelease", "draft",
"latest" (marked as latest), "nodigest" (no digest in the answer),
"baddigest" (a wrong one)}.

Every call is appended to <dir>/calls.log (one line, arguments joined by
blanks). Like gh, a missing resource gives a JSON message on stdout, 'gh: Not Found (HTTP 404)'
on stderr and exit code 1.
"""

import hashlib
import json
import os
import sys
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit

ROOT = Path(os.environ["FAKE_GH_DIR"])


def fail(status, message):
    sys.stdout.write(json.dumps({"message": message, "status": str(status)}))
    sys.stderr.write(f"gh: {message} (HTTP {status})\n")
    sys.exit(1)


def asset_id(path):
    return int(hashlib.sha1(path.as_posix().encode()).hexdigest()[:8], 16)


def releases(host, repo):
    base = ROOT / host / repo
    if not base.is_dir():
        fail(404, "Not Found")
    result = []
    for d in sorted(base.iterdir(), key=lambda p: int(p.name)):
        meta = json.loads((d / "release.json").read_text(encoding="utf-8"))
        assets = []
        adir = d / "assets"
        for f in sorted(adir.iterdir()) if adir.is_dir() else []:
            data = f.read_bytes()
            a = {"id": asset_id(f.relative_to(ROOT)), "name": f.name, "size": len(data),
                 "browser_download_url":
                     f"https://{host}/{repo}/releases/download/{meta['tag_name']}/{f.name}"}
            if meta.get("baddigest"):
                a["digest"] = "sha256:" + "0" * 64
            elif not meta.get("nodigest"):
                a["digest"] = "sha256:" + hashlib.sha256(data).hexdigest()
            assets.append((a, f))
        notes = d / "notes.md"
        if notes.is_file():
            meta["body"] = notes.read_bytes().decode("utf-8")
        result.append((meta, assets))
    return result


def answer(host, repo, meta, assets):
    draft = bool(meta.get("draft"))
    return {"tag_name": meta["tag_name"], "name": meta.get("name", meta["tag_name"]),
            "draft": draft, "prerelease": bool(meta.get("prerelease")),
            "created_at": meta["published_at"],
            "published_at": None if draft else meta["published_at"],
            "html_url": f"https://{host}/{repo}/releases/tag/{meta['tag_name']}",
            "body": meta.get("body"),
            "assets": [a for a, _ in assets]}


def main(argv):
    with open(ROOT / "calls.log", "a", encoding="utf-8") as log:
        log.write(" ".join(argv) + "\n")
    if not argv or argv[0] != "api":
        sys.stderr.write(f"fake gh: unsupported command {argv[:1]}\n")
        sys.exit(2)
    host, accept, path, i = "github.com", None, None, 1
    while i < len(argv):
        a = argv[i]
        if a == "--hostname":
            host, i = argv[i + 1], i + 2
        elif a == "-H":
            name, _, value = argv[i + 1].partition(":")
            if name.strip().lower() == "accept":
                accept = value.strip()
            i += 2
        elif a.startswith("-"):
            sys.stderr.write(f"fake gh: unsupported option {a}\n")
            sys.exit(2)
        else:
            path, i = a, i + 1
    url = urlsplit(path)
    query = parse_qs(url.query)
    parts = url.path.strip("/").split("/")
    if len(parts) == 3 and parts[0] == "repos":
        if not (ROOT / host / parts[1] / parts[2]).is_dir():
            fail(404, "Not Found")
        sys.stdout.write(json.dumps({"full_name": f"{parts[1]}/{parts[2]}"}))
        return
    if len(parts) < 4 or parts[0] != "repos" or parts[3] != "releases":
        fail(404, "Not Found")
    repo = f"{parts[1]}/{parts[2]}"
    rels = releases(host, repo)
    rest = parts[4:]
    visible = [r for r in rels if not r[0].get("draft")]

    def out(obj):
        sys.stdout.write(json.dumps(obj))

    if rest == ["latest"]:
        cands = [r for r in visible if not r[0].get("prerelease")]
        marked = [r for r in cands if r[0].get("latest")]
        if not cands:
            fail(404, "Not Found")
        meta, assets = marked[-1] if marked else max(cands, key=lambda r: r[0]["published_at"])
        out(answer(host, repo, meta, assets))
    elif len(rest) == 2 and rest[0] == "tags":
        tag = unquote(rest[1])
        for meta, assets in visible:
            if meta["tag_name"] == tag:
                out(answer(host, repo, meta, assets))
                return
        fail(404, "Not Found")
    elif len(rest) == 2 and rest[0] == "assets":
        for meta, assets in rels:
            for a, f in assets:
                if str(a["id"]) == rest[1]:
                    if accept == "application/octet-stream":
                        sys.stdout.buffer.write(f.read_bytes())
                    else:
                        out(a)
                    return
        fail(404, "Not Found")
    elif not rest:
        # newest first, like GitHub (by creation date); drafts included
        per_page = int(query.get("per_page", ["30"])[0])
        page = int(query.get("page", ["1"])[0])
        items = sorted(rels, key=lambda r: r[0]["published_at"], reverse=True)
        items = items[(page - 1) * per_page:page * per_page]
        out([answer(host, repo, m, a) for m, a in items])
    else:
        fail(404, "Not Found")


if __name__ == "__main__":
    main(sys.argv[1:])
