#!/usr/bin/env python3
"""Stand-in for 7-Zip in the tests (via ASSETSYNC_7Z), for archives real
7-Zip doesn't create: members with unsafe paths, links, or a listing that
differs from what is unpacked.

    python3 fake_7z.py l -slt [-scc...] -- ARCHIVE
    python3 fake_7z.py x -y -oDIR [-scc...] [-bd] [-bso0] [-bsp0] -- ARCHIVE

An archive is the 7z signature followed by JSON: a list of members
{"path", "content" (default ""), "attrs" (default "A -rw-r--r--"),
"encrypted", "sneaky_link" (unpacked as a symbolic link to this target
although listed as a file), "fail" (7-Zip fails on it)}. Like 7-Zip, a
command line error exits with 7: with FAKE_7Z_OLD=1, -scc... is one (an
older 7-Zip). Every call is appended to $FAKE_GH_DIR/7z.log.
"""

import json
import os
import sys
from pathlib import Path

MAGIC = b"7z\xbc\xaf\x27\x1c"


def main(argv):
    with open(Path(os.environ["FAKE_GH_DIR"]) / "7z.log", "a", encoding="utf-8") as log:
        log.write(" ".join(argv) + "\n")
    cmd, opts = argv[0], argv[1:argv.index("--")]
    archive = argv[argv.index("--") + 1]
    if os.environ.get("FAKE_7Z_OLD") and any(o.startswith("-scc") for o in opts):
        print("Command Line Error:\nUnsupported switch:\n" + opts[0])
        sys.exit(7)
    data = Path(archive).read_bytes()
    if not data.startswith(MAGIC):
        sys.stderr.write("ERROR: Cannot open the file as archive\n")
        sys.exit(2)
    members = json.loads(data[len(MAGIC):].decode("utf-8"))
    if any(m.get("fail") for m in members):
        sys.stderr.write("ERROR: Data Error : " + members[0]["path"] + "\n")
        sys.exit(2)
    if cmd == "l":
        print("\n7-Zip (fake)\n\nListing archive: " + archive + "\n\n--\nPath = " + archive
              + "\nType = 7z\n\n----------")
        for m in members:
            print(f"Path = {m['path']}\nSize = {len(m.get('content', ''))}\n"
                  f"Attributes = {m.get('attrs', 'A -rw-r--r--')}\n"
                  f"Encrypted = {'+' if m.get('encrypted') else '-'}\nMethod = LZMA2:12\n")
    elif cmd == "x":
        target = Path(next(o[2:] for o in opts if o.startswith("-o")))
        for m in members:
            if ".." in m["path"].split("/") or m["path"].startswith("/"):
                continue           # never outside, even if asked to
            dest = target / m["path"]
            dest.parent.mkdir(parents=True, exist_ok=True)
            if m.get("sneaky_link"):
                os.symlink(m["sneaky_link"], dest)
            elif not m.get("attrs", "").startswith("D"):
                dest.write_text(m.get("content", ""), encoding="utf-8")
    else:
        sys.exit(7)


if __name__ == "__main__":
    main(sys.argv[1:])
