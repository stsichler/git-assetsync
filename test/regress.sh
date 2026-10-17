#!/bin/bash
# =============================================================================
# Regression test for git-assetsync (Linux, macOS, Git Bash on Windows)
# =============================================================================
#
# Usage:  test/regress.sh [path/to/git-assetsync.py] </dev/null
#         (PYTHON=python test/regress.sh … to use another interpreter, e.g.
#         in Git Bash on Windows)
#
# The script builds throwaway repositories in a temp directory ($T, removed
# on exit) and runs git-assetsync against them. GitHub is played by
# test/fake_gh.py (via ASSETSYNC_GH), GitLab by test/fake_glab.py (via
# ASSETSYNC_GLAB): they answer 'gh api' / 'glab api' calls from a fixture
# directory ($GH) that the 'release' helper fills; asset links to other
# servers are served by test/http_server.py on 127.0.0.1 - no network
# needed. Each check prints "ok   <name>" or "FAIL <name>: got [...]
# expected [...]"; the exit code is 1 if any check failed. The Git LFS
# section is skipped when git-lfs is not installed.
#
# With the oldest supported Python and Git (see test/minver.Containerfile):
#   podman build -t assetsync-minver -f test/minver.Containerfile test
#   podman run --rm -v "$PWD":/src:ro,Z -w /src assetsync-minver test/regress.sh </dev/null
#
# Sections:
#    1. Basic workflow: add, status, pull
#    2. Release selection: latest, patterns, pinned tags, prereleases, drafts
#    3. Asset selection and integrity
#    4. Local modifications: refused by pull, discarded with --force
#    5. .git-assetsync registry: sources, unlink, mv, commit consistency
#    6. Commit proposals: --no-commit, SQUASH_MSG
#    7. Offline: --no-fetch, one API request per source
#    8. Line endings
#    9. Git LFS
#   10. Robustness: unsafe registry paths, incomplete entries, missing gh
#   11. Hosts: GitHub Enterprise, unsupported platforms
#   12. Dry runs
#   13. Hooks and colors
#   14. GitLab
#   15. source: list, rename and change sources
#   16. set: change entries
#   17. releases: list releases and assets
#   18. Directories and filters
#   19. Archives: formats, executables, unsafe members
#   20. Download cache
#   21. 7z archives (an external 7-Zip)
#
# Adding a test: put it into the section it belongs to, or add a new
# section at the end that starts with 'section' and 'cd "$T"'.

# --- setup -------------------------------------------------------------------

# The script under test (absolute path): the argument, or the one in the
# directory above this test; the fake gh next to this test.
S=${1:-$(dirname "$0")/../git-assetsync.py}
S=$(cd "$(dirname "$S")" && pwd)/$(basename "$S")
TD=$(cd "$(dirname "$0")" && pwd)
if command -v cygpath >/dev/null; then    # Git Bash: C:/... for Python
  S=$(cygpath -m "$S"); TD=$(cygpath -m "$TD")
fi

# Scratch directory for all repositories; removed on exit. In Git Bash on
# Windows as a Windows path (C:/...), which native git and Python understand.
T=$(cd "$(mktemp -d)" && pwd -P)       # physical path (macOS: /var -> /private/var)
HTTP_PID=
trap '[ -n "$HTTP_PID" ] && kill $HTTP_PID 2>/dev/null; rm -rf "$T"' EXIT
command -v cygpath >/dev/null && T=$(cygpath -m "$T")
cd "$T" || exit 2

PYTHON=${PYTHON:-python3}

# Isolate from the user's setup: own HOME (global git config) and download
# cache; the fake GitHub instead of gh, with its fixture directory $GH;
# asset files to publish are made in $F.
export HOME=$T/home GH=$T/gh F=$T/files ASSETSYNC_CACHE=$T/cache
mkdir -p "$HOME" "$GH" "$F"
export FAKE_GH_DIR=$GH
export ASSETSYNC_GH="\"$PYTHON\" \"$TD/fake_gh.py\""
export ASSETSYNC_GLAB="\"$PYTHON\" \"$TD/fake_glab.py\""
# the "other server" for GitLab asset links: serves the fixture directory
"$PYTHON" "$TD/http_server.py" "$GH" "$T/http.port" &
HTTP_PID=$!
i=0
while [ ! -f "$T/http.port" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
export FAKE_HTTP=http://127.0.0.1:$(cat "$T/http.port")
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
export GIT_EDITOR=true                 # accept commit messages unchanged
export GIT_PAGER=cat                   # never start a pager
export LC_ALL=C                        # messages and sort order like in the checks
git config --global init.defaultBranch main
git config --global core.autocrlf false    # Git for Windows: true by default
git config --global alias.assetsync "!$PYTHON $S"

# --- helpers -----------------------------------------------------------------

TAB=$(printf '\t')     # for grep -E patterns (portable, unlike Perl regexes)

PASSED=0 FAILED=0

# check NAME ACTUAL EXPECTED - compare two strings and report the result
check() {
  if [ "$2" = "$3" ]; then
    echo "ok   $1"; PASSED=$((PASSED + 1))
  else
    echo "FAIL $1: got [$2] expected [$3]"; FAILED=$((FAILED + 1))
  fi
}

# section TITLE - print a heading between the check results
section() { printf '\n=== %s\n' "$1"; }

# st [ARGS...] - 'status -s' code of the first file listed ("" = nothing to
# report). Three columns: upstream (P pending, N new, E error), committed
# (A modified), worktree (M modified, D deleted ...); trailing blanks removed.
st() { git assetsync status -s "$@" 2>/dev/null | head -1 | cut -c1-3 | sed 's/ *$//'; }

# quiet CMD... - run a command with all output discarded
quiet() { "$@" >/dev/null 2>&1; }

# rc CMD... - run a command quietly and print its exit code
rc() { "$@" >/dev/null 2>&1; echo $?; }

# addc ARGS... - 'git assetsync add' (which only stages, like git add), then
# commit with the proposed message, as 'git commit --no-edit' offers it
addc() { git assetsync add "$@" >/dev/null 2>&1 && git commit -q --no-edit >/dev/null 2>&1; }

# pullc PATH... - pull and commit without the editor, quietly
pullc() { git assetsync pull --no-edit "$@" >/dev/null 2>&1; }

# asd ARGS... - git-assetsync run directly, not through the git alias (Git
# for Windows runs aliases through its MSYS shell, which expands wildcard
# characters in arguments if a file matches). No effect elsewhere.
asd() { MSYS_NO_PATHCONV=1 "$PYTHON" "$S" "$@"; }

# sedi SCRIPT FILE... - edit each FILE in place with sed; works with GNU and
# BSD sed and keeps CRLF (GNU sed in Git Bash only does with -b)
SED_B=; sed --version >/dev/null 2>&1 && SED_B=-b
sedi() {
  local script=$1 f; shift
  for f; do sed $SED_B "$script" "$f" > "$f.sedi" && cat "$f.sedi" > "$f" && rm -f "$f.sedi" || return; done
}

# lines - number of lines on stdin, without the blanks BSD wc puts in front
lines() { wc -l | tr -d ' '; }

# oneline - join the lines of stdin with blanks ("a\nb\n" -> "a b ")
oneline() { tr '\n' ' '; }

# sha FILE - SHA-256 of a file (sha256sum is missing on macOS)
sha() { "$PYTHON" -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

# reg KEY - value in .git-assetsync ("" if not set)
reg() { git config -f .git-assetsync "$1"; }

# msg - message of the last commit, one line, empty lines dropped
msg() { git log -1 --format=%B | sed '/^$/d' | oneline; }

# new_repo DIR - create a repository with an empty initial commit, cd into it
new_repo() { cd "$T" && git init -q "$1" && cd "$1" && git commit -q --allow-empty -m init; }

# asset NAME CONTENT - make the file $F/NAME with CONTENT (and a newline)
asset() { printf '%s\n' "$2" > "$F/$1"; }

# release [OPTIONS] OWNER/REPO TAG DAY FILE... - publish a release with these
# files as assets in the fake GitHub. DAY: the day in October 2026 it is
# published (at noon; or DAYThh:mm:ssZ). Options: --pre (prerelease),
# --draft, --latest (marked as latest), --nodigest (no digest in the API),
# --baddigest (a wrong one), --title TITLE, --notes FILE (its description),
# --host HOST (default github.com), --links KIND (GitLab: how asset links
# point to the files - api, job, upload or http, see fake_glab.py)
release() {
  local pre=false draft=false latest=false nodigest=false baddigest=false title= notes= host=github.com links=api
  while :; do
    case $1 in
      --pre) pre=true; shift ;;
      --draft) draft=true; shift ;;
      --latest) latest=true; shift ;;
      --nodigest) nodigest=true; shift ;;
      --baddigest) baddigest=true; shift ;;
      --title) title=$2; shift 2 ;;
      --notes) notes=$2; shift 2 ;;
      --host) host=$2; shift 2 ;;
      --links) links=$2; shift 2 ;;
      *) break ;;
    esac
  done
  local repo=$1 tag=$2 date=2026-10-$3 base n
  shift 3
  case $date in *T*) ;; *) date=${date}T12:00:00Z ;; esac
  base=$GH/$host/$repo
  mkdir -p "$base"
  n=$(($(ls "$base" | lines) + 1))
  mkdir -p "$base/$n/assets"
  printf '{"tag_name": "%s", "name": "%s", "published_at": "%s", "prerelease": %s, "draft": %s, "latest": %s, "nodigest": %s, "baddigest": %s, "links": "%s"}\n' \
    "$tag" "${title:-$tag}" "$date" $pre $draft $latest $nodigest $baddigest $links > "$base/$n/release.json"
  [ -n "$notes" ] && cp "$notes" "$base/$n/notes.md"
  local f
  for f; do cp "$f" "$base/$n/assets/"; done
}

# reupload OWNER/REPO TAG FILE - replace an asset of a published release
reupload() {
  local d
  for d in "$GH/github.com/$1"/*; do
    grep -q "\"tag_name\": \"$2\"" "$d/release.json" && cp "$3" "$d/assets/"
  done
}

# mkarchive OUT DIR - archive of the files below DIR (paths relative to
# it): .zip, .tar, .tar.gz/.tgz, .tar.bz2, .tar.xz; files named *.sh are
# marked executable (independent of the file system)
mkarchive() {
  "$PYTHON" - "$1" "$2" <<'EOF'
import io, os, sys, tarfile, zipfile
out, src = sys.argv[1], sys.argv[2]
files = sorted(os.path.relpath(os.path.join(d, f), src).replace(os.sep, "/")
               for d, _, fs in os.walk(src) for f in fs)
def mode(f): return 0o755 if f.endswith(".sh") else 0o644
if out.endswith(".zip"):
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for f in files:
            info = zipfile.ZipInfo(f)
            info.create_system, info.external_attr = 3, (0o100000 | mode(f)) << 16
            z.writestr(info, open(os.path.join(src, f), "rb").read())
else:
    kind = next((k for e, k in ((".gz", "gz"), (".tgz", "gz"), (".bz2", "bz2"), (".xz", "xz"))
                 if out.endswith(e)), "")
    with tarfile.open(out, "w:" + kind) as t:
        for f in files:
            data = open(os.path.join(src, f), "rb").read()
            info = tarfile.TarInfo(f)
            info.size, info.mode = len(data), mode(f)
            t.addfile(info, io.BytesIO(data))
EOF
}

# mkevil OUT KIND - an archive with one bad member: slip (../x), abs
# (/x), symlink, hardlink (tar), git (.git/config), case (A.txt and
# a.txt), winname (con.txt), dup (x.txt twice)
mkevil() {
  "$PYTHON" - "$1" "$2" <<'EOF'
import io, sys, tarfile, zipfile, warnings
out, kind = sys.argv[1], sys.argv[2]
warnings.simplefilter("ignore")
members = {"slip": [("../evil.txt", "f")], "abs": [("/tmp/evil.txt", "f")],
           "symlink": [("link", "l")], "hardlink": [("ok.txt", "f"), ("hard", "h")],
           "git": [(".git/config", "f")], "case": [("A.txt", "f"), ("a.txt", "f")],
           "winname": [("con.txt", "f")], "dup": [("x.txt", "f"), ("x.txt", "f")]}[kind]
if out.endswith(".zip"):
    with zipfile.ZipFile(out, "w") as z:
        for name, t in members:
            info = zipfile.ZipInfo(name)
            info.create_system = 3
            info.external_attr = (0o120777 if t == "l" else 0o100644) << 16
            z.writestr(info, "/etc/passwd" if t == "l" else "evil\n")
else:
    with tarfile.open(out, "w") as t:
        for name, k in members:
            info = tarfile.TarInfo(name)
            if k == "l":
                info.type, info.linkname = tarfile.SYMTYPE, "/etc/passwd"
                t.addfile(info)
            elif k == "h":
                info.type, info.linkname = tarfile.LNKTYPE, "ok.txt"
                t.addfile(info)
            else:
                info.size = 5
                t.addfile(info, io.BytesIO(b"evil\n"))
EOF
}

# mkfake7z OUT JSON - an "archive" for test/fake_7z.py: the 7z signature
# followed by the JSON list of its members (see there)
mkfake7z() { printf '7z\274\257\047\034' > "$1" && printf '%s' "$2" >> "$1"; }

# downloads - number of asset downloads since the last reset_calls
downloads() { if [ -f "$GH/calls.log" ]; then grep -c -E 'releases/assets/|packages/generic/' "$GH/calls.log"; else echo 0; fi; }

# calls - number of 'gh api' calls since the last reset_calls
calls() { if [ -f "$GH/calls.log" ]; then lines < "$GH/calls.log"; else echo 0; fi; }
reset_calls() { rm -f "$GH/calls.log"; }


# =============================================================================
section "1. Basic workflow: add, status, pull"
# =============================================================================

asset tool-1.0.bin "tool 1.0"
release --title "Tool 1.0" acme/tool v1.0 10 "$F/tool-1.0.bin"

new_repo r1
OUT=$(asd add bin/tool.bin acme/tool --asset 'tool-*.bin' 2>&1)
check "add stages, like git add" "$(git status --porcelain | oneline)" "A  .git-assetsync A  bin/tool.bin "
check "add: says how to commit" "$(echo "$OUT" | grep -cxE '    git commit|\(it offers the proposed commit message\)')" "2"
check "add: file is the asset" "$(cat bin/tool.bin)" "tool 1.0"
check "add: source" "$(reg source.acme/tool.url)" "https://github.com/acme/tool"
check "add: no release key (latest)" "$(reg source.acme/tool.release)" ""
check "add: entry" "$(reg file.bin/tool.bin.source) $(reg file.bin/tool.bin.asset) $(reg file.bin/tool.bin.synced)" \
  "acme/tool tool-*.bin v1.0"
check "add: digest" "$(reg file.bin/tool.bin.digest)" "sha256:$(sha "$F/tool-1.0.bin")"
check "add: blob as git add stores it" "$(reg file.bin/tool.bin.blob)" "$(git rev-parse :bin/tool.bin)"
git commit -q --no-edit
check "add: proposed commit message" "$(msg)" \
  "Add bin/tool.bin from acme/tool v1.0 Release: https://github.com/acme/tool/releases/tag/v1.0 Title:   Tool 1.0 Asset:   tool-1.0.bin "
check "add + commit: file and entry" "$(git show --name-only --format= HEAD | sort | oneline)" ".git-assetsync bin/tool.bin "
check "status: clean" "$(st)" ""
check "status: nothing to pull" "$(git assetsync status | tail -1)" "nothing to pull, 1 file unmodified"
check "no command = status" "$(git assetsync | tail -1)" "nothing to pull, 1 file unmodified"
check "status -v" "$(git assetsync status -v | grep -cE "^${TAB}unmodified: bin/tool\.bin  \(tool-\*\.bin from acme/tool, latest release; synced v1\.0\)")" "1"

asset tool-1.1.bin "tool 1.1"
release acme/tool v1.1 11 "$F/tool-1.1.bin"
check "new release: pending" "$(st)" "P"
check "status: pending row" \
  "$(git assetsync status | grep -cE "^${TAB}pending:[[:space:]]+bin/tool\.bin  \(v1\.0 -> v1\.1\)")" "1"
check "status: hint" "$(git assetsync status | grep -c 'use "git assetsync pull <file>..." to update')" "1"
check "status: relative path from subdirectory" "$(cd bin && git assetsync status -s)" "P   tool.bin"
check "status: exit code 0" "$(rc git assetsync status)" "0"
check "status --exit-code: 1" "$(rc git assetsync status --exit-code)" "1"
check "pull without paths refused" "$(rc git assetsync pull)" "2"
check "pull without paths: message" "$(git assetsync pull 2>&1)" "error: specify file(s) or --all"
pullc bin/tool.bin
check "pull: content" "$(cat bin/tool.bin)" "tool 1.1"
check "pull: commit message" "$(msg)" \
  "Update bin/tool.bin to acme/tool v1.1 (was v1.0) Release: https://github.com/acme/tool/releases/tag/v1.1 Asset:   tool-1.1.bin "
check "pull: commit has file and entry" "$(git show --name-only --format= HEAD | sort | oneline)" ".git-assetsync bin/tool.bin "
check "pull: entry updated" "$(reg file.bin/tool.bin.synced) $(reg file.bin/tool.bin.blob)" "v1.1 $(git rev-parse HEAD:bin/tool.bin)"
check "pull: nothing left" "$(git status --porcelain)" ""
check "after pull: clean" "$(st)" ""
check "pull: up to date" "$(git assetsync pull bin/tool.bin 2>&1)" "bin/tool.bin: up to date"
check "pull --all: everything up to date" "$(git assetsync pull --all 2>&1)" "everything up to date"
check "status --exit-code when clean: 0" "$(rc git assetsync status --exit-code)" "0"

# a directory as PATH selects the entries below it
asset tool-1.2.bin "tool 1.2"
release acme/tool v1.2 12 "$F/tool-1.2.bin"
cd bin
pullc .
cd ..
check "pull DIR (from the subdirectory)" "$(cat bin/tool.bin)" "tool 1.2"
check "pull: not an entry" "$(git assetsync pull nothing.txt 2>&1)" \
  "error: 'nothing.txt' is not synced (use 'git assetsync add' to add it)"

# pull --all: only entries with something to do, one commit each
asd add other.bin acme/tool --asset 'tool-*.bin' >/dev/null 2>&1 && git commit -q --no-edit
asset tool-1.3.bin "tool 1.3"
release acme/tool v1.3 13 "$F/tool-1.3.bin"
N=$(git rev-list --count HEAD)
quiet git assetsync pull --all --no-edit
check "pull --all: both updated" "$(cat bin/tool.bin other.bin | oneline)" "tool 1.3 tool 1.3 "
check "pull --all: a commit per file" "$(($(git rev-list --count HEAD) - N))" "2"

# release notes, shortened, in the message of an update
cd "$T"
asset rn.txt "rn 1"
printf 'First release\n' > "$F/notes1.md"
release --notes "$F/notes1.md" acme/rn v1 10 "$F/rn.txt"
new_repo r1b
addc rn.txt acme/rn
check "add: no release notes" "$(git log -1 --format=%B | grep -c 'First release')" "0"
asset rn.txt "rn 2"
printf '<!-- template\r\ncomment -->\r\n## What'"'"'s Changed\r\n\r\n\r\n* Fix A by @x\r\n* Fix B\r\n\r\n' > "$F/notes2.md"
release --notes "$F/notes2.md" acme/rn v2 11 "$F/rn.txt"
git assetsync pull rn.txt >/dev/null 2>&1        # with the editor: comment lines stripped
check "pull: release notes, indented, comments and blank lines dropped" \
  "$(git log -1 --format=%B | sed -n '/^Release notes:$/,$p')" \
  "$(printf 'Release notes:\n  ## What'"'"'s Changed\n\n  * Fix A by @x\n  * Fix B')"
asset rn.txt "rn 3"
i=1; : > "$F/notes3.md"
while [ $i -le 25 ]; do echo "- change $i" >> "$F/notes3.md"; i=$((i + 1)); done
"$PYTHON" -c 'print("x" * 300)' >> "$F/notes3.md"
release --notes "$F/notes3.md" acme/rn v3 12 "$F/rn.txt"
pullc rn.txt
check "long notes: 20 lines and a hint" "$(git log -1 --format=%B | grep -v '^$' | tail -2 | oneline)" \
  "  - change 20   [... see the release page for more] "
check "long notes: 20 lines" "$(git log -1 --format=%B | grep -c '^  - change')" "20"
asset rn.txt "rn 4"
"$PYTHON" -c 'print("y" * 300)' > "$F/notes4.md"
release --notes "$F/notes4.md" acme/rn v4 13 "$F/rn.txt"
pullc rn.txt
check "long line: cut" "$(git log -1 --format=%B | grep -v '^$' | tail -1 | wc -c | tr -d ' ')" "203"
check "long line: marked" "$(git log -1 --format=%B | grep -v '^$' | tail -1 | grep -c '^  y*\[\.\.\.\]$')" "1"
asset rn.txt "rn 5"
release acme/rn v5 14 "$F/rn.txt"
pullc rn.txt
check "no notes: no section" "$(git log -1 --format=%B | grep -c 'Release notes')" "0"


# =============================================================================
section "2. Release selection: latest, patterns, pinned tags, prereleases, drafts"
# =============================================================================
cd "$T"

# several tools in one repository; tags are opaque: the newest by date counts
for t in toolA-20261016:16 toolB-20261017:17 toolA-20261015:18 toolA-20261019:19:--pre toolA-20261020:20:--draft; do
  IFS=: read -r tag day opt <<EOF
$t
EOF
  asset "$tag.zip" "$tag"
  release $opt acme/multi "$tag" "$day" "$F/$tag.zip"
done

new_repo r2
quiet asd add a.zip acme/multi --asset '*.zip' --release 'toolA-*'
check "pattern: newest by date, not by name" "$(cat a.zip)" "toolA-20261015"
check "pattern: release key" "$(reg source.acme/multi.release)" "toolA-*"
quiet asd add a2.zip acme/multi --asset '*.zip'
check "source name without options: that source" "$(cat a2.zip) $(reg file.a2.zip.source)" "toolA-20261015 acme/multi"
quiet asd add latest.zip https://github.com/acme/multi --asset '*.zip'
check "latest: no prerelease, no draft" "$(cat latest.zip)" "toolA-20261015"
check "URL without options: another source" "$(reg file.latest.zip.source) $(reg source.acme/multi-2.release)" "acme/multi-2 "
quiet asd add b.zip acme/multi --asset '*.zip' --release toolB-20261017
check "exact tag: pinned" "$(cat b.zip)" "toolB-20261017"
check "source name with other --release: its URL, another source" "$(reg file.b.zip.source) $(reg source.acme/multi-3.release)" \
  "acme/multi-3 toolB-20261017"
quiet asd add pre.zip acme/multi --asset '*.zip' --release 'toolA-*' --prerelease
check "pattern with --prerelease" "$(cat pre.zip)" "toolA-20261019"
check "prerelease key" "$(git config -f .git-assetsync --get-regexp 'source\..*\.prerelease' | cut -d' ' -f2)" "true"
quiet asd add prelatest.zip acme/multi --asset '*.zip' --prerelease
check "--prerelease without pattern: newest incl. prereleases" "$(cat prelatest.zip)" "toolA-20261019"
quiet asd add pinpre.zip acme/multi --asset '*.zip' --release toolA-20261019
check "exact tag of a prerelease" "$(cat pinpre.zip)" "toolA-20261019"
check "exact tag of a draft: not found" "$(asd add d.zip acme/multi --asset '*.zip' --release toolA-20261020 2>&1)" \
  "error: no release with tag 'toolA-20261020' in acme/multi"
check "pattern without match" "$(asd add x.zip acme/multi --asset '*.zip' --release 'toolC-*' 2>&1)" \
  "error: no release with a tag matching 'toolC-*' in acme/multi (prereleases not counted)"
git commit -q --no-edit
check "all clean" "$(git assetsync status -s)" ""

# a new toolB release doesn't concern the toolA pattern, nor the pinned one
asset toolB-20261021.zip toolB-20261021
release acme/multi toolB-20261021 21 "$F/toolB-20261021.zip"
check "pattern: other tool's release ignored" "$(st a.zip)" ""
check "pinned: newer release ignored" "$(st b.zip)" ""
check "latest: follows" "$(st latest.zip)" "P"

# the release GitHub marks as latest counts, even if not the newest
asset toolA-20261001.zip toolA-20261001
release --latest acme/multi toolA-20261001 01 "$F/toolA-20261001.zip"
check "latest: as marked by the platform" "$(git assetsync status latest.zip | grep -c 'toolA-20261015 -> toolA-20261001')" "1"

# tags may contain '/'
asset slash.bin slash
release acme/slash tools/v2 10 "$F/slash.bin"
quiet asd add slash.bin acme/slash --asset slash.bin --release tools/v2
check "tag with '/'" "$(cat slash.bin)" "slash"

# more than one page of releases (100 per page): the match is on page 2
i=1
while [ $i -le 100 ]; do
  mkdir -p "$GH/github.com/acme/many/$i"
  printf '{"tag_name": "r%s", "published_at": "2026-10-20T12:00:%02dZ"}\n' $i $((i % 60)) > "$GH/github.com/acme/many/$i/release.json"
  i=$((i + 1))
done
asset old.bin old
release acme/many special-1 01 "$F/old.bin"
reset_calls
quiet asd add old.bin acme/many --asset old.bin --release 'special-*'
check "paging: match on page 2" "$(cat old.bin 2>/dev/null)" "old"
check "paging: 2 pages + download" "$(calls)" "3"

check "no releases at all" "$(mkdir -p "$GH/github.com/acme/empty"; asd add x.bin acme/empty --asset x 2>&1)" \
  "error: no release in acme/empty"
check "unknown repository" "$(asd add x.bin acme/nothing --asset x --release 'v*' 2>&1)" \
  "error: repository acme/nothing not found (or no access)"
check "unknown repository (latest)" "$(asd add x.bin acme/nothing --asset x 2>&1)" \
  "error: repository acme/nothing not found (or no access)"


# =============================================================================
section "3. Asset selection and integrity"
# =============================================================================
cd "$T"
asset app-linux.tar.gz linux
asset app-windows.zip windows
asset app-macos.tar.gz macos
release acme/app v3 10 "$F/app-linux.tar.gz" "$F/app-windows.zip" "$F/app-macos.tar.gz"

new_repo r3
check "asset glob with no match" "$(asd add x.deb acme/app --asset 'app-*.deb' 2>&1)" \
  "error: release v3 of acme/app has no asset matching 'app-*.deb' (assets: app-linux.tar.gz, app-macos.tar.gz, app-windows.zip)"
check "asset glob with 2 matches" "$(asd add x.tgz acme/app --asset 'app-*.tar.gz' 2>&1)" \
  "error: 'app-*.tar.gz' matches 2 assets of release v3 of acme/app: app-linux.tar.gz, app-macos.tar.gz - use a more specific pattern"
check "nothing written on error" "$(git status --porcelain)" ""
quiet asd add app.tgz acme/app --asset 'app-linux.*' && git commit -q --no-edit
check "asset glob with 1 match" "$(cat app.tgz)" "linux"
check "no --asset, several assets" "$(asd add y.tgz acme/app 2>&1)" \
  "error: release v3 of acme/app has 3 assets: app-linux.tar.gz, app-macos.tar.gz, app-windows.zip - choose one with --asset PATTERN"

# the newest release lacks the asset: an error, no fallback to older ones
asset other.txt other
release acme/app v4 11 "$F/other.txt"
check "new release without the asset: error" "$(st)" "E"
check "... message" "$(git assetsync status 2>&1 | head -1)" \
  "error: app.tgz: release v4 of acme/app has no asset matching 'app-linux.*' (assets: other.txt)"
check "... exit code 2" "$(rc git assetsync status)" "2"
check "... pull fails" "$(rc git assetsync pull --no-edit app.tgz)" "2"
cd "$T"

# without --asset: the release's only asset; no asset key recorded
asset single.bin "single 1"
release acme/single v1 10 "$F/single.bin"
new_repo r3a
addc single.bin acme/single
check "no --asset, one asset: taken" "$(cat single.bin)" "single 1"
check "no --asset: no asset key" "$(reg file.single.bin.asset)" ""
check "no --asset: status -v" "$(git assetsync status -v | grep -c '(only asset from acme/single, latest release; synced v1)')" "1"
asset single.bin "single 2"
release acme/single v2 11 "$F/single.bin"
pullc single.bin
check "no --asset: pulled" "$(cat single.bin)" "single 2"
asset single.bin "single 3"
asset extra.txt extra
release acme/single v3 12 "$F/single.bin" "$F/extra.txt"
check "no --asset, more assets later: error" "$(git assetsync status 2>&1 | head -1)" \
  "error: single.bin: release v3 of acme/single has 2 assets: extra.txt, single.bin - choose one with 'git assetsync set single.bin --asset PATTERN'"
cd "$T"

# a re-uploaded asset (same tag, other content) is an upstream change
asset re.bin "first upload"
release acme/re v1 10 "$F/re.bin"
new_repo r3b
addc re.bin acme/re --asset re.bin
asset re.bin "second upload"
reupload acme/re v1 "$F/re.bin"
check "asset replaced: pending" "$(st)" "P"
check "asset replaced: note" "$(git assetsync status | grep -c 'asset replaced in release v1')" "1"
pullc re.bin
check "asset replaced: pulled" "$(cat re.bin)" "second upload"
check "asset replaced: message" "$(git log -1 --format=%s)" "Update re.bin from acme/re v1 (asset replaced)"

# a wrong digest in the release: nothing is changed
asset bad.bin bad
release --baddigest acme/bad v1 10 "$F/bad.bin"
new_repo r3c
OUT=$(asd add bad.bin acme/bad --asset bad.bin 2>&1)
check "digest mismatch: error" "$(echo "$OUT" | grep -c 'downloaded file has sha256:.*, but the release lists sha256:0000')" "1"
check "digest mismatch: nothing written" "$(ls; git status --porcelain)" ""

# releases from before GitHub reported digests: computed on download
asset nod.bin nodigest
release --nodigest acme/nod v1 10 "$F/nod.bin"
quiet asd add nod.bin acme/nod --asset nod.bin
check "no digest in the API: computed" "$(reg file.nod.bin.digest)" "sha256:$(sha "$F/nod.bin")"


# =============================================================================
section "4. Local modifications: refused by pull, discarded with --force"
# =============================================================================
cd "$T"
asset lm.txt "lm 1"
release acme/lm v1 10 "$F/lm.txt"
new_repo r4
addc lm.txt acme/lm --asset lm.txt

# committed modification
echo changed > lm.txt && git commit -qam "local change"
check "committed modification: A" "$(st)" " A"
check "status: section" "$(git assetsync status | grep -cE "^${TAB}modified:[[:space:]]+lm\.txt  \(NOT ALLOWED\)")" "1"
check "status --exit-code: 1" "$(rc git assetsync status --exit-code)" "1"
check "pull refused" "$(rc git assetsync pull --no-edit lm.txt)" "2"
check "pull refused: message" "$(git assetsync pull lm.txt 2>&1 | grep -c 'committed modifications NOT ALLOWED')" "1"
check "... file unchanged" "$(cat lm.txt)" "changed"
pullc --force lm.txt
check "pull --force restores" "$(cat lm.txt)" "lm 1"
check "pull --force: message" "$(msg)" \
  "Restore lm.txt from acme/lm v1 Release: https://github.com/acme/lm/releases/tag/v1 Asset:   lm.txt Local modifications of this repository were discarded. "
check "after restore: clean" "$(st)" ""

# uncommitted modification, with a new release
echo dirty > lm.txt
check "uncommitted modification: M" "$(st)" "  M"
check "status: NOT ALLOWED" "$(git assetsync status | grep -cE "^${TAB}modified:[[:space:]]+lm\.txt  \(NOT ALLOWED\)")" "1"
asset lm.txt "lm 2"
release acme/lm v2 11 "$F/lm.txt"
check "pending + uncommitted" "$(st)" "P M"
check "pull refused" "$(git assetsync pull lm.txt 2>&1 | grep -c "uncommitted changes NOT ALLOWED.*git restore lm.txt")" "1"
check "... file unchanged" "$(cat lm.txt)" "dirty"
check "pull --all --force: discards and updates" \
  "$(git assetsync pull --all --force --no-edit 2>&1 | grep -c 'warning: lm.txt: discarding local modifications')" "1"
check "... content" "$(cat lm.txt)" "lm 2"
check "... message" "$(git log -1 --format=%s)" "Update lm.txt to acme/lm v2 (was v1)"

# uncommitted deletion
rm lm.txt
check "deleted: D" "$(st)" "  D"
check "deleted: pull refused" "$(rc git assetsync pull lm.txt)" "2"
pullc --force lm.txt
check "deleted: pull --force restores" "$(cat lm.txt)" "lm 2"

# a change back to the asset version is no modification
echo changed > lm.txt && git commit -qam "local change"
git show HEAD~1:lm.txt > lm.txt
check "worktree back to the asset: only the committed one counts" "$(st)" " AM"
check "... not in 'Uncommitted changes' as NOT ALLOWED" \
  "$(git assetsync status | grep -cE "^${TAB}modified:[[:space:]]+lm\.txt\$")" "1"
git commit -qam "back"
check "committed back: clean" "$(st)" ""

# an entry written by hand (no base yet): pull fetches it
cd "$T"
asset hand.txt hand
release acme/hand v1 10 "$F/hand.txt"
new_repo r4b
printf '[source "h"]\n\turl = https://github.com/acme/hand\n[file "hand.txt"]\n\tsource = h\n\tasset = hand.txt\n' > .git-assetsync
git add .git-assetsync && git commit -qm "hand-written entry"
check "hand-written entry: new" "$(st)" "N"
check "hand-written entry: -v" "$(git assetsync status -v | grep -cE "^${TAB}not synced: hand\.txt  \(hand\.txt from h, latest release; not synced yet\)")" "1"
check "hand-written entry: note" "$(git assetsync status | grep -cE "^${TAB}new:[[:space:]]+hand\.txt  \(release v1\)")" "1"
echo mine > hand.txt
check "existing other file: refused" "$(git assetsync pull hand.txt 2>&1 | tail -1)" \
  "error: 'hand.txt' exists and differs from hand.txt - use --force to overwrite it"
rm hand.txt
pullc hand.txt
check "hand-written entry: pulled" "$(cat hand.txt) $(git log -1 --format=%s)" "hand Add hand.txt from h v1"
check "hand-written entry: base recorded" "$(reg file.hand.txt.synced)" "v1"


# =============================================================================
section "5. .git-assetsync registry: sources, unlink, mv, commit consistency"
# =============================================================================
cd "$T"
asset one.bin one
asset two.bin two
release acme/pair v1 10 "$F/one.bin" "$F/two.bin"
new_repo r5
addc one.bin acme/pair --asset one.bin
addc two.bin https://github.com/acme/pair.git --asset two.bin
check "same URL and selection: one source" "$(git config -f .git-assetsync --get-regexp 'source\..*\.url' | lines)" "1"
check "source by name" "$(rc asd add three.bin acme/pair --asset one.bin)" "0"
git reset -q --hard
quiet asd add x.bin acme/pair --asset one.bin --release v1
check "source name with another --release: a new source" "$(reg file.x.bin.source) $(reg source.acme/pair-2.release)" "acme/pair-2 v1"
git reset -q --hard; rm -f x.bin
check "already synced: refused" "$(asd add one.bin acme/pair --asset two.bin 2>&1)" \
  "error: 'one.bin' is already synced (use --force to replace its entry)"
quiet asd add --force one.bin acme/pair --asset two.bin
check "add --force: replaced" "$(cat one.bin) $(reg file.one.bin.asset)" "two two.bin"
git reset -q --hard
echo mine > mine.bin
check "existing different file: refused" "$(asd add mine.bin acme/pair --asset one.bin 2>&1 | tail -1)" \
  "error: 'mine.bin' exists and differs from one.bin - use --force to overwrite it"
check "... file kept" "$(cat mine.bin)" "mine"
cp "$F/one.bin" same.bin
check "existing identical file: fine" "$(rc asd add same.bin acme/pair --asset one.bin)" "0"
git reset -q --hard; rm -f mine.bin same.bin
check "an existing directory: a directory entry" "$(mkdir -p dir && asd add dir acme/pair --asset one.bin 2>/dev/null | head -1)" \
  "added dir/ <- acme/pair v1 (one.bin)"
git reset -q --hard; rm -rf dir

# unlink: entry (and unused source) removed, file kept, staged
OUT=$(git assetsync unlink one.bin)
check "unlink: output" "$OUT" "unlinked one.bin (file kept)"
check "unlink: staged" "$(git status --porcelain | oneline)" "M  .git-assetsync "
check "unlink: source kept while used" "$(reg source.acme/pair.url)" "https://github.com/acme/pair"
quiet git assetsync unlink two.bin
check "unlink last: registry removed" "$(git status --porcelain | oneline)" "D  .git-assetsync "
check "unlink: files kept" "$(cat one.bin two.bin | oneline)" "one two "
git reset -q --hard

# mv: git mv, entry follows
mkdir sub
quiet git assetsync mv one.bin sub
check "mv into directory" "$(git status --porcelain | oneline)" "M  .git-assetsync R  one.bin -> sub/one.bin "
check "mv: entry renamed" "$(reg file.sub/one.bin.asset)" "one.bin"
check "mv: clean" "$(git commit -qm mv && st)" ""
check "mv to existing: refused" "$(git assetsync mv sub/one.bin two.bin 2>&1)" "error: 'two.bin' already exists"

# pull commits only its own file and entry: others' uncommitted entries refuse
asset one.bin "one v2"
asset two.bin "two v2"
release acme/pair v2 11 "$F/one.bin" "$F/two.bin"
git config -f .git-assetsync file.two.bin.asset 'two*' && git add .git-assetsync
check "uncommitted other entry: pull refused" "$(git assetsync pull --no-edit sub/one.bin 2>&1 | tail -1)" \
  "error: .git-assetsync has uncommitted changes for two.bin - commit them first, or use --no-commit to stage everything and commit together"
quiet git assetsync pull --no-commit sub/one.bin
check "--no-commit: staged together" "$(git status --porcelain | oneline)" "M  .git-assetsync M  sub/one.bin "
git commit -q --no-edit
check "uncommitted [source] changes go along" "$(git config -f .git-assetsync source.acme/pair.release v2 && git add .git-assetsync && pullc two.bin; git status --porcelain)" ""
check "... in the commit" "$(git show --format= --name-only HEAD | sort | oneline)" ".git-assetsync two.bin "


# =============================================================================
section "6. Commit proposals: --no-commit, SQUASH_MSG"
# =============================================================================
cd "$T"
asset p.txt "p 1"
release acme/p v1 10 "$F/p.txt"
new_repo r6
quiet asd add p1.txt acme/p --asset p.txt
quiet asd add p2.txt acme/p --asset p.txt
check "two adds: proposals collected" "$(grep -c '^Add ' .git/SQUASH_MSG)" "2"
git commit -q --no-edit
check "commit takes both" "$(git log -1 --format=%B | grep -c '^Add ')" "2"
check "SQUASH_MSG removed by git" "$(ls .git/SQUASH_MSG 2>/dev/null)" ""
asset p.txt "p 2"
release acme/p v2 11 "$F/p.txt"
OUT=$(git assetsync pull --no-commit p1.txt 2>&1)
check "pull --no-commit: staged" "$(git status --porcelain | oneline)" "M  .git-assetsync M  p1.txt "
check "pull --no-commit: hint" "$(echo "$OUT" | grep -c '^p1.txt: updated and staged. Commit with:')" "1"
git commit -q --no-edit
check "pull --no-commit: message" "$(git log -1 --format=%s)" "Update p1.txt to acme/p v2 (was v1)"
# a SQUASH_MSG of git's own is left alone
echo "squash of someone else" > .git/SQUASH_MSG
OUT=$(git assetsync pull --no-commit p2.txt 2>&1)
check "foreign SQUASH_MSG kept" "$(cat .git/SQUASH_MSG)" "squash of someone else"
check "... message file instead" "$(echo "$OUT" | grep -c 'git commit -e -F ".*ASSETSYNC_MSG_p2.txt" -- p2.txt .git-assetsync')" "1"
rm .git/SQUASH_MSG; git commit -q -F .git/ASSETSYNC_MSG_p2.txt
# a commit that fails (here: a rejecting hook) leaves the change staged
asset p.txt "p 3"
release acme/p v3 12 "$F/p.txt"
printf '#!/bin/sh\nexit 1\n' > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
check "failed commit: exit code 1" "$(rc git assetsync pull --no-edit p1.txt)" "1"
check "failed commit: staged" "$(git status --porcelain | oneline)" "M  .git-assetsync M  p1.txt "
rm .git/hooks/pre-commit; git commit -q --no-edit
check "failed commit: proposal kept" "$(git log -1 --format=%s)" "Update p1.txt to acme/p v3 (was v2)"


# =============================================================================
section "7. Offline: --no-fetch, one API request per source"
# =============================================================================
cd "$T/r6"
reset_calls
OUT=$(git assetsync status --no-fetch)
check "--no-fetch: no API request" "$(calls)" "0"
check "--no-fetch: said so" "$(echo "$OUT" | tail -1)" "new releases not checked (--no-fetch)"
asset p.txt "p 4"
release acme/p v4 13 "$F/p.txt"
check "--no-fetch: upstream not shown" "$(st --no-fetch)" ""
echo local > p2.txt
check "--no-fetch: worktree still checked" "$(st --no-fetch p2.txt)" "  M"
git checkout -q p2.txt
reset_calls
quiet git assetsync status
check "status: one request for both entries of the source" "$(calls)" "1"


# =============================================================================
section "8. Line endings"
# =============================================================================
cd "$T"
printf 'line 1\r\nline 2\r\n' > "$F/crlf.txt"
printf 'line 1\nline 2\n' > "$F/lf.txt"
release acme/eol v1 10 "$F/crlf.txt" "$F/lf.txt"

new_repo r8
printf '* text=auto\n' > .gitattributes && git add .gitattributes && git commit -qm attrs
addc crlf.txt acme/eol --asset crlf.txt
check "text=auto: stored normalized" "$(git cat-file -p HEAD:crlf.txt | od -c | grep -c '\\r')" "0"
check "text=auto: blob as git add stores it" "$(reg file.crlf.txt.blob)" "$(git hash-object --path=crlf.txt "$F/crlf.txt")"
check "text=auto: clean" "$(st) $(git status --porcelain)" " "
cd "$T"

new_repo r8b
git config core.autocrlf true
addc lf.txt acme/eol --asset lf.txt
check "autocrlf: checked out with CRLF" "$(od -c lf.txt | grep -c '\\r')" "1"
check "autocrlf: clean" "$(st) $(git status --porcelain)" " "
check "autocrlf: registry has no warning-causing LF" "$(git status --porcelain .git-assetsync)" ""
cd "$T"

# .gitattributes changed afterwards (normalization on): content still the asset
new_repo r8c
addc crlf.txt acme/eol --asset crlf.txt
printf '* text=auto\n' > .gitattributes && git add .gitattributes && git add --renormalize . && git commit -qm "normalize"
check "renormalized after add: unmodified" "$(st)" ""


# =============================================================================
section "9. Git LFS"
# =============================================================================
cd "$T"
if ! git lfs version >/dev/null 2>&1; then
  echo "skipped: git-lfs not installed"
else
  git lfs install --skip-repo >/dev/null 2>&1
  printf 'bin\000ary 1\n' > "$F/fw.bin"
  release acme/fw v1 10 "$F/fw.bin"
  new_repo r9
  printf '*.bin filter=lfs diff=lfs merge=lfs -text\n' > .gitattributes && git add .gitattributes && git commit -qm lfs
  addc fw.bin acme/fw --asset fw.bin
  check "LFS: committed as pointer" "$(git cat-file -p HEAD:fw.bin | head -1)" "version https://git-lfs.github.com/spec/v1"
  check "LFS: content in the working tree" "$(sha fw.bin)" "$(sha "$F/fw.bin")"
  check "LFS: clean" "$(st) $(git status --porcelain)" " "
  printf 'bin\000ary 2\n' > "$F/fw.bin"
  release acme/fw v2 11 "$F/fw.bin"
  pullc fw.bin
  check "LFS: pulled" "$(sha fw.bin)" "$(sha "$F/fw.bin")"
  check "LFS: pull clean" "$(st) $(git status --porcelain)" " "
  cd "$T"

  # moved to LFS afterwards: still the asset (pointer hash = digest)
  new_repo r9b
  addc fw.bin acme/fw --asset fw.bin
  printf '*.bin filter=lfs diff=lfs merge=lfs -text\n' > .gitattributes && git add .gitattributes
  git add --renormalize . && git commit -qm "to LFS"
  check "moved to LFS afterwards: committed as pointer" "$(git cat-file -p HEAD:fw.bin | head -1)" "version https://git-lfs.github.com/spec/v1"
  check "moved to LFS afterwards: unmodified" "$(st)" ""
  cd "$T"

  # big binaries not in LFS: a hint
  head -c 1048576 /dev/zero > "$F/big.bin"
  release acme/big v1 10 "$F/big.bin"
  new_repo r9c
  check "big binary, no LFS: hint" "$(asd add big.bin acme/big --asset big.bin 2>&1 | grep -c "git lfs track big.bin")" "1"
  git reset -q --hard
  printf '*.bin filter=lfs diff=lfs merge=lfs -text\n' > .gitattributes && git add .gitattributes && git commit -qm lfs
  check "big binary in LFS: no hint" "$(asd add --force big.bin acme/big --asset big.bin 2>&1 | grep -c 'git lfs track')" "0"
fi


# =============================================================================
section "10. Robustness: unsafe registry paths, incomplete entries, missing gh"
# =============================================================================
cd "$T"
asset r.txt r
release acme/rb v1 10 "$F/r.txt"
new_repo r10
for p in ../evil.txt /tmp/evil.txt .git/hooks/post-merge sub/.GIT/x a//b; do
  git config -f .git-assetsync "file.$p.source" s
  git config -f .git-assetsync "file.$p.asset" r.txt
done
git config -f .git-assetsync source.s.url https://github.com/acme/rb
check "unsafe paths: all errors" "$(git assetsync status -s 2>/dev/null | cut -c1 | sort -u | oneline)" "E "
check "unsafe paths: error count" "$(git assetsync status 2>&1 | grep -c '^error: ')" "5"
check "unsafe paths: pull --all writes nothing" "$(git assetsync pull --all --no-edit >/dev/null 2>&1; ls -a .git/hooks | grep -c '^post-merge$'; ls ../evil.txt 2>/dev/null)" "0"
check "unsafe paths: hint" "$(git assetsync status 2>&1 | grep -c "remove it with 'git assetsync unlink /tmp/evil.txt'")" "1"
quiet asd unlink ../evil.txt /tmp/evil.txt .git/hooks/post-merge sub/.GIT/x a//b    # asd: '/tmp' unconverted on Windows
check "unsafe paths: unlink by name" "$(git config -f .git-assetsync --get-regexp '^file\.' | lines)" "0"
rm .git-assetsync
git config -f .git-assetsync file.x.txt.source nothing
check "incomplete entry" "$(git assetsync status 2>&1 | head -1)" \
  "error: x.txt: incomplete entry in .git-assetsync (needs a source with url)"
printf '[file "x\n' > .git-assetsync
check "unparsable registry" "$(git assetsync status 2>&1 | grep -c '^error: .git-assetsync: cannot parse')" "1"
rm .git-assetsync
check "not a repository" "$(cd "$T" && git assetsync status 2>&1)" "error: not inside a Git working tree"
check "gh missing" "$(ASSETSYNC_GH=/nonexistent/gh asd add r.txt acme/rb --asset r.txt 2>&1 | sed 's/ (.*) / /')" \
  "error: cannot run the GitHub CLI '/nonexistent/gh' - install it from https://cli.github.com and log in with 'gh auth login'"
check "gh fails" "$(ASSETSYNC_GH="\"$PYTHON\" -c 'import sys; sys.stderr.write(\"gh: Bad credentials (HTTP 401)\\n\"); sys.exit(1)'" asd add r.txt acme/rb --asset r.txt 2>&1)" \
  "error: acme/rb: 'gh api repos/acme/rb/releases/latest' failed: gh: Bad credentials (HTTP 401)"
check "add: path outside the repository" "$(asd add ../r.txt acme/rb --asset r.txt 2>&1)" \
  "error: cannot add '../r.txt': not a path inside the working tree"
check "add: the registry itself" "$(asd add .git-assetsync acme/rb --asset r.txt 2>&1)" \
  "error: cannot add '.git-assetsync': .git-assetsync itself"
check "add: bad URL" "$(asd add r.txt ftp://x/y --asset r.txt 2>&1)" \
  "error: 'ftp://x/y' is not a URL like https://github.com/owner/repo"
# wildcard characters in a file name are taken literally: 'we[i]rd f.txt'
# must not stage 'weird f.txt' (no '*' or '?': not allowed on Windows)
echo other > 'weird f.txt'
quiet asd add 'we[i]rd f.txt' acme/rb --asset r.txt
# (names via -z: git's quoting of blanks in porcelain output differs by version)
check "wildcard characters in a file name" "$(cat 'we[i]rd f.txt') $(git diff --cached --name-only -z | tr '\0' '|')" \
  "r .git-assetsync|we[i]rd f.txt|"
git commit -q --no-edit
check "... clean" "$(asd status -s)" ""


# =============================================================================
section "11. Hosts: GitHub Enterprise, unsupported platforms"
# =============================================================================
cd "$T"
asset e.txt enterprise
release --host ghe.example.com acme/ent v1 10 "$F/e.txt"
new_repo r11
check "unknown host without type" "$(asd add e.txt https://ghe.example.com/acme/ent --asset e.txt 2>&1)" \
  "error: https://ghe.example.com/acme/ent: platform of ghe.example.com unknown - give its type (add --type github|gitlab, or 'git assetsync source set-type <source> github|gitlab')"
reset_calls
addc e.txt https://ghe.example.com/acme/ent --asset e.txt --type github
check "GitHub Enterprise: fetched" "$(cat e.txt)" "enterprise"
check "GitHub Enterprise: --hostname" "$(grep -c '^api --hostname ghe.example.com ' "$GH/calls.log")" "2"
check "GitHub Enterprise: type recorded" "$(reg source.acme/ent.type)" "github"
check "GitHub Enterprise: status" "$(st)" ""
check "unknown type" "$(git config -f .git-assetsync source.acme/ent.type bitbucket; git assetsync status 2>&1 | head -1)" \
  "error: e.txt: https://ghe.example.com/acme/ent: unknown type 'bitbucket' (supported: github, gitlab)"
git checkout -q .git-assetsync
# GH_HOST must not redirect requests for github.com (gh would follow it)
reset_calls
GH_HOST=ghe.example.com quiet asd add -n x.txt acme/tool
check "github.com: --hostname always given" "$(grep -c '^api --hostname github.com ' "$GH/calls.log")" "1"


# =============================================================================
section "12. Dry runs"
# =============================================================================
cd "$T"
asset dr.txt "dr 1"
release acme/dr v1 10 "$F/dr.txt"
new_repo r12
reset_calls
check "add -n: output" "$(asd add -n dr.txt acme/dr --asset dr.txt 2>&1)" \
  "would add dr.txt from acme/dr v1 (dr.txt, latest release)"
check "add -n: nothing changed, no download" "$(git status --porcelain; ls; calls)" "1"
addc dr.txt acme/dr --asset dr.txt
asset dr.txt "dr 2"
release acme/dr v2 11 "$F/dr.txt"
check "pull -n: output" "$(git assetsync pull -n dr.txt 2>&1)" \
  "would: Update dr.txt to acme/dr v2 (was v1)"
check "pull -n: nothing changed" "$(git status --porcelain; cat dr.txt)" "dr 1"
check "unlink -n" "$(git assetsync unlink -n dr.txt; git status --porcelain)" "would unlink dr.txt"
git config -f .git-assetsync source.acme/dr.note x
check "unlink -n: nothing staged" "$(git assetsync unlink -n dr.txt >/dev/null; git status --porcelain)" " M .git-assetsync"
git checkout -q .git-assetsync
check "mv -n" "$(git assetsync mv -n dr.txt x.txt; git status --porcelain)" "would move dr.txt -> x.txt"


# =============================================================================
section "13. Hooks and colors"
# =============================================================================
cd "$T/r12"
check "install-hooks" "$(git assetsync install-hooks | oneline)" "pre-push: installed post-merge: installed "
check "hook runs status --hook" "$(sh .git/hooks/post-merge 2>&1 | head -1)" ""
echo changed > dr.txt
check "hook output" "$(sh .git/hooks/post-merge 2>&1 | head -1)" \
  "assetsync: dr.txt: local modifications NOT ALLOWED"
git checkout -q dr.txt
check "pre-push hook sees new releases" "$(sh .git/hooks/pre-push 2>&1 | head -1)" \
  "assetsync: dr.txt: upstream pending (v1 -> v2)"
check "uninstall-hooks" "$(git assetsync uninstall-hooks | oneline)" "pre-push: removed post-merge: removed "
printf '#!/bin/sh\necho mine\n' > .git/hooks/post-merge
check "existing hook: not touched" "$(git assetsync install-hooks | grep -c 'post-merge: hook exists')" "1"
check "colors: --color=always" "$(git assetsync status -s --color=always | grep -c "$(printf '\033')")" "1"
check "colors: none in pipes" "$(git assetsync status -s | grep -c "$(printf '\033')")" "0"


# =============================================================================
section "14. GitLab"
# =============================================================================
cd "$T"
asset gl.bin "gl 1"
asset gl.txt "gl text 1"
release --host gitlab.com --title "GL 1" grp/proj v1 10 "$F/gl.bin" "$F/gl.txt"

new_repo r14
reset_calls
OUT=$(asd add gl.bin https://gitlab.com/grp/proj --asset 'gl.b*' 2>&1)
check "GitLab: add" "$(cat gl.bin)" "gl 1"
check "GitLab: source without type" "$(reg source.grp/proj.url) $(reg source.grp/proj.type)" "https://gitlab.com/grp/proj "
check "GitLab: digest computed" "$(reg file.gl.bin.digest)" "sha256:$(sha "$F/gl.bin")"
check "GitLab: glab with --hostname" "$(grep -c '^glab api --hostname gitlab.com ' "$GH/calls.log")" "2"
check "GitLab: generic package downloaded via the API" \
  "$(grep -c '^glab api --hostname gitlab.com projects/grp%2Fproj/packages/generic/pkg/v1/gl.bin$' "$GH/calls.log")" "1"
git commit -q --no-edit
check "GitLab: message" "$(msg)" \
  "Add gl.bin from grp/proj v1 Release: https://gitlab.com/grp/proj/-/releases/v1 Title:   GL 1 Asset:   gl.bin "
check "GitLab: clean" "$(st)" ""
check "GitLab: URL of a page of the project" "$(rc asd add gl2.txt https://gitlab.com/grp/proj/-/releases --asset gl.txt)" "0"
check "... same source" "$(reg file.gl2.txt.source)" "grp/proj"
git reset -q --hard; rm -f gl2.txt
check "GitLab: several assets need --asset" "$(asd add x.bin https://gitlab.com/grp/proj 2>&1)" \
  "error: release v1 of grp/proj has 2 assets: gl.bin, gl.txt - choose one with --asset PATTERN"

# a new release: pending, pull with release notes
asset gl.bin "gl 2"
printf '## Changes\n* faster\n' > "$F/gl-notes.md"
release --host gitlab.com --notes "$F/gl-notes.md" grp/proj v2 11 "$F/gl.bin"
check "GitLab: pending" "$(st)" "P"
pullc gl.bin
check "GitLab: pulled" "$(cat gl.bin)" "gl 2"
check "GitLab: message with notes" "$(msg)" \
  "Update gl.bin to grp/proj v2 (was v1) Release: https://gitlab.com/grp/proj/-/releases/v2 Asset:   gl.bin Release notes:   ## Changes   * faster "

# upcoming releases (released_at in the future) count as prereleases
asset gl.bin "gl 3 upcoming"
release --host gitlab.com --pre grp/proj v3 30 "$F/gl.bin"
check "GitLab: upcoming release not latest" "$(st)" ""
quiet asd add pre.bin https://gitlab.com/grp/proj --asset gl.bin --release 'v*' --prerelease
check "GitLab: upcoming with --prerelease" "$(cat pre.bin)" "gl 3 upcoming"
check "GitLab: pattern by date, without upcoming" \
  "$(asd add -n x.bin https://gitlab.com/grp/proj --asset gl.bin --release 'v*' 2>&1)" \
  "would add x.bin from grp/proj-3 v2 (gl.bin, newest release matching v*)"
check "GitLab: exact tag" "$(asd add -n x.bin https://gitlab.com/grp/proj --asset gl.txt --release v1 2>&1)" \
  "would add x.bin from grp/proj-3 v1 (gl.txt, release v1)"
git reset -q --hard; rm -f pre.bin

# subgroups; tags with '/'
asset sub.txt sub
release --host gitlab.com grp/sub/deep tools/v1 10 "$F/sub.txt"
quiet asd add sub.txt https://gitlab.com/grp/sub/deep --release tools/v1
check "GitLab: subgroup and tag with '/'" "$(cat sub.txt)" "sub"

# asset links: job artifacts and uploads via the API, other servers plainly
for kind in job upload http; do
  asset "$kind.txt" "via $kind"
  release --host gitlab.com --links $kind grp/$kind v1 10 "$F/$kind.txt"
  reset_calls
  OUT=$(asd add $kind.txt https://gitlab.com/grp/$kind 2>&1)
  check "GitLab: $kind link" "$(cat $kind.txt 2>/dev/null)" "via $kind"
  case $kind in
    job) check "GitLab: job artifact via the API" \
           "$(grep -c "^glab api --hostname gitlab.com projects/grp%2Fjob/jobs/1/artifacts/dist/job.txt$" "$GH/calls.log")" "1" ;;
    upload) check "GitLab: upload via the API" \
           "$(grep -c "^glab api --hostname gitlab.com projects/grp%2Fupload/uploads/0123456789abcdef0123456789abcdef/upload.txt$" "$GH/calls.log")" "1" ;;
  esac
done
check "GitLab: http link: a warning" "$(echo "$OUT" | grep -c 'warning: http.txt of grp/http: downloading over unencrypted http')" "1"
git commit -q --no-edit
asset http.txt "via http 2"
release --host gitlab.com --links broken grp/http v2 11 "$F/http.txt"
check "GitLab: failed download" "$(git assetsync pull --no-edit http.txt 2>&1 | grep -c 'download of .*/nothing/http.txt failed: HTTP 404')" "1"
check "... nothing changed" "$(cat http.txt; git status --porcelain)" "via http"

# self-managed GitLab: by name, or with type
asset sm.txt selfmanaged
release --host gitlab.example.org grp/sm v1 10 "$F/sm.txt"
release --host code.example.org grp/sm v1 10 "$F/sm.txt"
quiet asd add sm1.txt https://gitlab.example.org/grp/sm
check "self-managed GitLab, 'gitlab' in the host name" "$(cat sm1.txt)" "selfmanaged"
check "self-managed GitLab, other name: needs type" "$(asd add sm2.txt https://code.example.org/grp/sm 2>&1)" \
  "error: https://code.example.org/grp/sm: platform of code.example.org unknown - give its type (add --type github|gitlab, or 'git assetsync source set-type <source> github|gitlab')"
quiet asd add sm2.txt https://code.example.org/grp/sm --type gitlab
check "... with --type gitlab" "$(cat sm2.txt) $(reg source.grp/sm-2.type)" "selfmanaged gitlab"

# more than one page of releases
i=1
while [ $i -le 100 ]; do
  mkdir -p "$GH/gitlab.com/grp/many/$i"
  printf '{"tag_name": "r%s", "published_at": "2026-10-20T12:00:%02dZ"}\n' $i $((i % 60)) > "$GH/gitlab.com/grp/many/$i/release.json"
  i=$((i + 1))
done
asset old.bin old
release --host gitlab.com grp/many special-1 01 "$F/old.bin"
reset_calls
quiet asd add old.bin https://gitlab.com/grp/many --release 'special-*'
check "GitLab: paging, match on page 2" "$(cat old.bin 2>/dev/null) $(calls)" "old 3"

check "GitLab: unknown project" "$(asd add x.bin https://gitlab.com/grp/nothing 2>&1)" \
  "error: project grp/nothing not found (or no access)"
check "GitLab: no releases" "$(mkdir -p "$GH/gitlab.com/grp/empty"; asd add x.bin https://gitlab.com/grp/empty 2>&1)" \
  "error: no release in grp/empty"
check "GitLab: not a project URL" "$(asd add x.bin https://gitlab.com/grp 2>&1)" \
  "error: 'https://gitlab.com/grp' is not a GitLab project URL (https://gitlab.com/group/project)"
check "glab missing" "$(ASSETSYNC_GLAB=/nonexistent/glab asd add x.bin https://gitlab.com/grp/proj 2>&1 | sed 's/ (.*) / /')" \
  "error: cannot run the GitLab CLI '/nonexistent/glab' - install it from https://gitlab.com/gitlab-org/cli and log in with 'glab auth login'"


# =============================================================================
section "15. source: list, rename and change sources"
# =============================================================================
cd "$T"
asset s1.txt "s1 v1"
release acme/src v1 10 "$F/s1.txt"
asset s1.txt "s1 v2"
release --pre acme/src v2-rc 11 "$F/s1.txt"
asset s1.txt "s1 v0"
release acme/src v0 09 "$F/s1.txt"
new_repo r15
addc a.txt acme/src
addc b.txt acme/src --release v0
check "source: list" "$(git assetsync source | oneline)" "acme/src acme/src-2 "
check "source -v" "$(git assetsync source -v | oneline)" \
  "acme/src${TAB}https://github.com/acme/src (latest release, 1 file) - now v1 acme/src-2${TAB}https://github.com/acme/src (release v0, 1 file) - now v0 "
reset_calls
check "source -v --no-fetch: not asked" "$(git assetsync source -v --no-fetch | head -1) $(calls)" \
  "acme/src${TAB}https://github.com/acme/src (latest release, 1 file) 0"

# set-release: staged only; pull updates the file and commits both
OUT=$(git assetsync source set-release acme/src 'v*' --prerelease)
check "set-release: output" "$(echo "$OUT" | head -1)" \
  "acme/src: newest release matching v* (prereleases too) (was: latest release); .git-assetsync staged"
check "set-release: keys" "$(reg source.acme/src.release) $(reg source.acme/src.prerelease)" "v* true"
check "set-release: staged" "$(git status --porcelain | oneline)" "M  .git-assetsync "
check "set-release: pending" "$(st a.txt)" "P"
pullc a.txt
check "set-release + pull: one commit" "$(cat a.txt) $(git show --name-only --format= HEAD | sort | oneline)" "s1 v2 .git-assetsync a.txt "
check "set-release --no-prerelease only" "$(git assetsync source set-release acme/src --no-prerelease >/dev/null; reg source.acme/src.release) $(reg source.acme/src.prerelease)" "v* "
check "set-release --unset: latest again" "$(git assetsync source set-release acme/src --unset >/dev/null; reg source.acme/src.release)" ""
pullc a.txt
check "... pulled back to the latest" "$(cat a.txt)" "s1 v1"
check "set-release: same selection as another source" "$(git assetsync source set-release acme/src-2 --unset 2>&1)" \
  "error: source 'acme/src' already has this URL and selection - move the files to it with 'git assetsync set <file>... --source acme/src'"
check "set-release: nothing given" "$(git assetsync source set-release acme/src 2>&1)" \
  "error: give either TAG|PATTERN or --unset (or only --prerelease / --no-prerelease)"
check "unknown source" "$(git assetsync source set-release nope v1 2>&1)" \
  "error: no source 'nope' in .git-assetsync (known: acme/src, acme/src-2)"

# rename, set-url, set-type
quiet git assetsync source rename acme/src-2 pinned
check "rename: section and references" "$(reg source.pinned.release) $(reg file.b.txt.source)" "v0 pinned"
check "rename: to an existing name" "$(git assetsync source rename pinned acme/src 2>&1)" "error: source 'acme/src' already exists"
git commit -q -m "rename source"
check "rename: still clean" "$(git assetsync status -s)" ""
asset s1.txt "moved v1"
release acme/moved v0 10 "$F/s1.txt"
quiet git assetsync source set-url pinned https://github.com/acme/moved.git
check "set-url" "$(reg source.pinned.url)" "https://github.com/acme/moved"
check "set-url: pending (other asset)" "$(st b.txt)" "P"
git reset -q --hard
check "set-type" "$(git assetsync source set-type pinned gitlab >/dev/null; reg source.pinned.type)" "gitlab"
check "set-type --unset" "$(git assetsync source set-type pinned --unset >/dev/null; reg source.pinned.type)" ""
check "set-type: unknown" "$(git assetsync source set-type pinned svn 2>&1)" "error: unknown type 'svn' (supported: github, gitlab)"
git reset -q --hard

# the asset of a file: changed with add --force
asset other.txt other
release acme/src v3 12 "$F/s1.txt" "$F/other.txt"
check "two assets now: hint at set" "$(git assetsync status a.txt 2>&1 | head -1)" \
  "error: a.txt: release v3 of acme/src has 2 assets: other.txt, s1.txt - choose one with 'git assetsync set a.txt --asset PATTERN'"
quiet asd add --force a.txt acme/src --asset 's1*'
git commit -q --no-edit
check "add --force: asset chosen" "$(reg file.a.txt.asset) $(st a.txt)" "s1* "


# =============================================================================
section "16. set: change entries"
# =============================================================================
cd "$T"
asset x.bin "x v1"
asset y.bin "y v1"
release acme/set v1 10 "$F/x.bin" "$F/y.bin"
asset x.bin "x v2"
asset y.bin "y v2"
release acme/set v2 11 "$F/x.bin" "$F/y.bin"
asset x.bin "fork x v2"
asset y.bin "fork y v2"
release me/set-fork v2 12 "$F/x.bin" "$F/y.bin"
new_repo r16
addc x.bin acme/set --asset x.bin --release v1
addc y.bin acme/set --asset y.bin --release v1
check "nothing to change" "$(git assetsync set x.bin 2>&1)" \
  "error: nothing to change: give --source, --release/--latest/--prerelease/--type, --asset/--no-asset or filter options"
check "same selection: nothing to change" "$(git assetsync set x.bin --release v1)" "nothing to change"

# another release selection for one file of two: the source is split
OUT=$(git assetsync set x.bin --latest)
check "set --latest: split" "$(echo "$OUT" | head -1)" \
  "x.bin: acme/set -> acme/set-2 (latest release); acme/set keeps 1 other file"
check "set: staged only" "$(git status --porcelain | oneline)" "M  .git-assetsync "
check "set: base kept" "$(reg file.x.bin.synced)" "v1"
check "set: pending" "$(st x.bin)" "P"
check "set: other file unchanged" "$(st y.bin)" ""
pullc x.bin
check "set + pull" "$(cat x.bin) $(git log -1 --format=%s)" "x v2 Update x.bin to acme/set-2 v2 (was v1)"
# all files of a source: the source itself changes
check "set: whole source" "$(git assetsync set y.bin --latest | head -1)" \
  "y.bin: acme/set -> acme/set-2 (latest release)"
check "... moved to the matching source, old one removed" "$(reg file.y.bin.source) $(reg source.acme/set.url)" "acme/set-2 "
git reset -q --hard
check "set -n: nothing changed" "$(git assetsync set -n y.bin --latest | head -1; git status --porcelain)" \
  "would: y.bin: acme/set -> acme/set-2 (latest release)"

# another project (a fork): base kept, the asset counts as unknown
OUT=$(git assetsync set x.bin --source me/set-fork)
# (x.bin is the only file of its source: the source itself changes)
check "set --source: output" "$(echo "$OUT" | head -1)" \
  "acme/set-2: https://github.com/acme/set (latest release) -> https://github.com/me/set-fork (latest release)"
check "set --source: synced removed, base kept" "$(reg file.x.bin.synced)|$(reg file.x.bin.blob)" "|$(git rev-parse HEAD:x.bin)"
check "set --source: still unmodified" "$(git assetsync status x.bin | grep -c 'pending:    x.bin  (entry changed, release v2)')" "1"
pullc x.bin
check "set --source + pull" "$(cat x.bin) $(git log -1 --format=%s)" "fork x v2 Update x.bin to acme/set-2 v2"
# local modifications stay modifications
echo mine > x.bin && git commit -qam mine
quiet git assetsync set x.bin --source https://github.com/acme/set
check "set: modified stays modified" "$(st x.bin)" "PA"
git reset -q --hard HEAD~1

# another asset of the same release; the same content: only the entry
quiet git assetsync set y.bin --asset 'y*'
pullc y.bin
check "set --asset, same file: recorded" "$(git log -1 --format=%s) $(reg file.y.bin.asset)" \
  "Record y.bin as acme/set v1 (file unchanged) y*"
quiet git assetsync set y.bin --asset x.bin
check "set --asset: pending" "$(st y.bin)" "P"
pullc y.bin
check "set --asset + pull" "$(cat y.bin) $(git log -1 --format=%s)" "x v1 Update y.bin to acme/set v1"
check "set --no-asset" "$(git assetsync set y.bin --no-asset >/dev/null; reg file.y.bin.asset)" ""
git reset -q --hard
check "set --release and --latest" "$(git assetsync set y.bin --release v1 --latest 2>&1)" \
  "error: --release and --latest exclude each other"
check "set --source: unknown host" "$(git assetsync set y.bin --source https://code.example.org/a/b 2>&1 | grep -c '^error: .*platform of code.example.org unknown')" "1"


# =============================================================================
section "17. releases: list releases and assets"
# =============================================================================
cd "$T"
printf 'abc' > "$F/small.bin"
head -c 3000 /dev/zero > "$F/kib.bin"
release acme/rl v0 09
release --title "Rel 1" acme/rl v1 10 "$F/small.bin" "$F/kib.bin"
release acme/rl v1.1 11 "$F/small.bin"
release --title "Rel 2 RC" --pre acme/rl v2-rc1 12 "$F/small.bin"
release --draft acme/rl v3 13 "$F/small.bin"
check "releases outside a repository" "$(asd releases acme/rl | oneline)" \
  "v3      2026-10-13  (draft) v2-rc1  2026-10-12  Rel 2 RC  (prerelease) v1.1    2026-10-11  (latest) v1      2026-10-10  Rel 1 v0      2026-10-09 "
check "releases -n" "$(asd releases acme/rl -n 2 | lines)" "2"
check "releases --assets" "$(asd releases acme/rl --assets | tail -5 | oneline)" \
  "v1      2026-10-10  Rel 1     kib.bin    2.9 KiB     small.bin  3 bytes v0      2026-10-09     (no assets) "
new_repo r17
addc a.bin acme/rl --asset small.bin
addc b.bin acme/rl --asset small.bin --release 'v*' --prerelease
check "releases: selected by sources" "$(git assetsync releases acme/rl | grep '^v2-rc1 ' | oneline)" \
  "v2-rc1  2026-10-12  Rel 2 RC  (prerelease, selected by acme/rl-2) "
check "releases: latest selected" "$(git assetsync releases acme/rl | grep '^v1.1 ')" \
  "v1.1    2026-10-11  (latest, selected by acme/rl)"
check "releases of a source by name" "$(git assetsync releases acme/rl-2 -n 1)" \
  "v3  2026-10-13  (draft)"
check "releases: GitLab, upcoming" "$(asd releases https://gitlab.com/grp/proj -n 2 | oneline)" \
  "v3  2026-10-30  (upcoming) v2  2026-10-11  (latest) "
check "releases: none" "$(asd releases https://gitlab.com/grp/empty)" "no releases in grp/empty"
check "releases: unknown project" "$(asd releases acme/nothing 2>&1)" "error: repository acme/nothing not found (or no access)"


# =============================================================================
section "18. Directories and filters"
# =============================================================================
cd "$T"
# zlib-1.3/: the layout of a typical archive
mkdir -p z/zlib-1.3/include z/zlib-1.3/lib/x64
echo "zlib 1.3" > z/zlib-1.3/include/zlib.h
echo "zconf 1.3" > z/zlib-1.3/include/zconf.h
echo "lib 1.3" > z/zlib-1.3/lib/x64/zlib.lib
echo "pdb" > z/zlib-1.3/lib/x64/zlib.pdb
echo "readme" > z/zlib-1.3/README
mkarchive "$F/zlib-1.3-win64.zip" z
echo sums > "$F/checksums.txt"
release madler/zlib v1.3 10 "$F/zlib-1.3-win64.zip" "$F/checksums.txt"

new_repo r18
printf '*.lib\n*.log\n' > .gitignore && git add .gitignore && git commit -qm ignore
OUT=$(asd add lib/zlib/ madler/zlib --asset 'zlib-*-win64.zip' --extract --strip 1 \
  --include 'include/*.h' --include 'lib/x64/*.lib' --exclude '*.pdb' 2>&1)
check "dir: added" "$(echo "$OUT" | grep '^added')" "added lib/zlib/ <- madler/zlib v1.3 (zlib-1.3-win64.zip)"
check "dir: files (ignored *.lib included)" "$(git ls-files lib | oneline)" \
  "lib/zlib/include/zconf.h lib/zlib/include/zlib.h lib/zlib/lib/x64/zlib.lib "
check "dir: [dir] entry" "$(git config -f .git-assetsync --get-all dir.lib/zlib.step | oneline)" \
  "extract strip 1 keep 'include/*.h' 'lib/x64/*.lib' drop '*.pdb' "
check "dir: tree as staged" "$(reg dir.lib/zlib.tree)" "$(git write-tree --prefix=lib/zlib/)"
check "dir: filterhash" "$(reg dir.lib/zlib.filterhash | wc -c | tr -d ' ')" "17"
git commit -q --no-edit
check "dir: message" "$(git log -1 --format=%B | grep -E '^(Add|Filter|Files)' | oneline)" \
  "Add lib/zlib/ from madler/zlib v1.3 Filter:  extract, strip 1, keep 'include/*.h' 'lib/x64/*.lib', drop '*.pdb' Files:   3 added, 0 removed, 0 changed (3 in total) "
check "dir: clean" "$(st) $(git status --porcelain)" " "
check "dir: nothing to pull" "$(git assetsync status | tail -1)" "nothing to pull, 1 directory unmodified"
check "dir: status -v" "$(git assetsync status -v | grep -c "unmodified: lib/zlib/  (zlib-\*-win64.zip from madler/zlib, latest release, filter: extract")" "1"
check "dir: shown with /" "$(cd lib && git assetsync status -v | grep -c 'unmodified: zlib/ ')" "1"

# a new release: files changed, removed, added
echo "zlib 1.3.1" > "$T/z/zlib-1.3/include/zlib.h"
rm "$T/z/zlib-1.3/include/zconf.h"
echo "new" > "$T/z/zlib-1.3/include/new.h"
mkarchive "$F/zlib-1.3.1-win64.zip" "$T/z"
release madler/zlib v1.3.1 11 "$F/zlib-1.3.1-win64.zip" "$F/checksums.txt"
check "dir: pending" "$(st)" "P"
pullc lib/zlib
check "dir: pulled" "$(git ls-files lib | oneline)$(cat lib/zlib/include/zlib.h)" \
  "lib/zlib/include/new.h lib/zlib/include/zlib.h lib/zlib/lib/x64/zlib.lib zlib 1.3.1"
check "dir: removed file gone" "$(ls lib/zlib/include | oneline)" "new.h zlib.h "
check "dir: message" "$(git log -1 --format=%B | grep -E '^(Update|Files)' | oneline)" \
  "Update lib/zlib/ to madler/zlib v1.3.1 (was v1.3) Files:   1 added, 1 removed, 1 changed (3 in total) "
check "dir: clean after pull" "$(st) $(git status --porcelain)" " "

# local modifications: changed, untracked; ignored files don't count
echo build > lib/zlib/build.log
check "dir: ignored file: no modification" "$(st)" ""
echo mine > lib/zlib/mine.h
check "dir: untracked file: modified" "$(st)" "  M"
check "dir: NOT ALLOWED" "$(git assetsync status | grep -cE "^${TAB}modified:[[:space:]]+lib/zlib/  \(NOT ALLOWED\)")" "1"
rm lib/zlib/mine.h
echo changed >> lib/zlib/include/zlib.h
check "dir: changed file: modified" "$(st)" "  M"
check "dir: pull refused" "$(rc git assetsync pull --no-edit lib/zlib)" "2"
git commit -qam "local change"
check "dir: committed modification" "$(st)" " A"
echo mine > lib/zlib/mine.h
pullc --force lib/zlib
check "dir: --force restores" "$(cat lib/zlib/include/zlib.h) $(git log -1 --format=%s)" "zlib 1.3.1 Restore lib/zlib/ from madler/zlib v1.3.1"
check "dir: --force: untracked deleted, ignored kept" "$(ls lib/zlib | oneline)" "build.log include lib "
check "dir: clean after restore" "$(st) $(git status --porcelain)" " "

# another filter (set): pending, pulled from the cache
quiet git assetsync set lib/zlib --extract --strip 1 --include 'include/*.h'
check "set filter: staged" "$(git config -f .git-assetsync --get-all dir.lib/zlib.step | oneline)" \
  "extract strip 1 keep 'include/*.h' "
check "set filter: pending" "$(git assetsync status | grep -c 'pending:    lib/zlib/  (filter changed)')" "1"
reset_calls
pullc lib/zlib
check "filter changed: pulled" "$(git ls-files lib | oneline)" "lib/zlib/include/new.h lib/zlib/include/zlib.h "
check "filter changed: message" "$(git log -1 --format=%s)" "Update lib/zlib/ from madler/zlib v1.3.1 (filter changed)"
check "filter changed: no download (cache)" "$(downloads)" "0"
check "set --no-filter" "$(git assetsync set lib/zlib --no-filter; git config -f .git-assetsync --get-all dir.lib/zlib.step)" \
  "lib/zlib/: filter extract, strip 1, keep 'include/*.h' -> (none)
.git-assetsync staged (use \"git assetsync status\" to see what changes, \"git assetsync pull <file>...\" to update)"
git reset -q --hard

# entries must not overlap
check "overlap: file in a dir" "$(asd add lib/zlib/x.txt madler/zlib --asset checksums.txt 2>&1)" \
  "error: cannot add 'lib/zlib/x.txt': overlaps with the entry for lib/zlib - entries must not overlap"
check "overlap: dir around a dir" "$(asd add lib/ madler/zlib --asset checksums.txt 2>&1)" \
  "error: cannot add 'lib/': overlaps with the entry for lib/zlib - entries must not overlap"
git config -f .git-assetsync file.lib/zlib/y.txt.source madler/zlib
check "overlap in the registry: error" "$(git assetsync status 2>&1 | grep -c 'overlaps with the entry for')" "2"
git checkout -q .git-assetsync

# a file from an archive; a filter giving several files for a file
mkdir -p "$T/b/firmware" && echo fw > "$T/b/firmware/fw.bin" && echo doc > "$T/b/firmware/doc.txt"
mkarchive "$F/bundle.zip" "$T/b"
release acme/bundle v1 10 "$F/bundle.zip"
quiet asd add fw.bin acme/bundle --extract --include fw.bin
check "file from an archive" "$(cat fw.bin) $(git config -f .git-assetsync --get-all file.fw.bin.step | oneline)" "fw extract keep fw.bin "
check "file: several files" "$(asd add two.bin acme/bundle --extract 2>&1)" \
  "error: two.bin: the filter gives 2 files, a file needs exactly one - narrow it with --include, or add 'two.bin/' as a directory"
check "dir from the same archive" "$(asd add -n fwdir/ acme/bundle --extract --subdir firmware)" \
  "would add fwdir/ from acme/bundle v1 (bundle.zip, latest release, filter: extract, subdir firmware)"
git reset -q --hard; rm -f fw.bin

# a directory of all assets (no --asset); a guard against many or big ones
asset a1.txt a1; asset a2.txt a2
release acme/many-assets v1 10 "$F/a1.txt" "$F/a2.txt"
OUT=$(asd add all/ acme/many-assets 2>/dev/null)
check "all assets: listed" "$(echo "$OUT" | head -1)" "all/: all 2 assets of acme/many-assets v1: a1.txt (3 bytes), a2.txt (3 bytes)"
check "all assets: taken" "$(git ls-files all | oneline)" "all/a1.txt all/a2.txt "
check "all assets: message" "$(sed -n 1,5p .git/SQUASH_MSG | grep Assets)" "Assets:  a1.txt, a2.txt"
git reset -q --hard; rm -rf all
i=1; set --
while [ $i -le 11 ]; do asset "m$i.txt" "m$i"; set -- "$@" "$F/m$i.txt"; i=$((i + 1)); done
release acme/eleven v1 10 "$@"
check "more than 10 assets: refused" "$(asd add many/ acme/eleven 2>&1 >/dev/null)" \
  "error: that is more than 10 assets or 100 MiB - choose some with --asset PATTERN, or take all with --force"
check "more than 10 assets: --force" "$(asd add --force many/ acme/eleven >/dev/null 2>&1; git ls-files many | lines)" "11"
check "dir --asset with several matches" "$(asd add -n m1/ acme/eleven --asset 'm1*' | sed 's/(.*,/(...,/')" \
  "would add m1/ from acme/eleven v1 (..., latest release)"
git reset -q --hard; rm -rf many

# an existing directory with files becomes the entry's only with --force
mkdir -p own && echo mine > own/mine.txt && echo old > own/a1.txt
check "non-empty dir: refused" "$(asd add own/ acme/many-assets 2>&1 >/dev/null)" \
  "error: 'own/' is not empty - with --force it becomes the entry's (files there the release doesn't give are deleted; ignored ones stay)"
quiet asd add --force own/ acme/many-assets
check "non-empty dir with --force" "$(ls own | oneline)$(cat own/a1.txt)" "a1.txt a2.txt a1"
git reset -q --hard; rm -rf own

# a hand-written [dir] entry: pull fetches it
printf '[source "h"]\n\turl = https://github.com/acme/many-assets\n[dir "hand"]\n\tsource = h\n' > .git-assetsync
git add .git-assetsync && git commit -qm "hand-written dir"
check "hand-written dir: new" "$(st hand)" "N"
pullc hand
check "hand-written dir: pulled" "$(git ls-files hand | oneline) $(git log -1 --format=%s)" "hand/a1.txt hand/a2.txt  Add hand/ from h v1"

# mv and unlink of a directory entry
quiet git assetsync mv hand moved
check "mv dir" "$(git status --porcelain | sed 's/ -> .*//' | oneline) $(reg dir.moved.source)" "M  .git-assetsync R  hand/a1.txt R  hand/a2.txt  h"
git commit -qm mv
check "mv dir: clean" "$(st moved)" ""
check "unlink dir" "$(git assetsync unlink moved)" "unlinked moved/ (files kept)"
git reset -q --hard

# line endings and LFS in a directory
printf 'a\r\nb\r\n' > z2.txt; mkdir -p eol && mv z2.txt eol/crlf.txt
printf 'bin\000ary\n' > eol/data.bin
mkarchive "$F/eol.tar.gz" eol
release acme/eol-dir v1 10 "$F/eol.tar.gz"
new_repo r18b
printf '* text=auto\n' > .gitattributes
if git lfs version >/dev/null 2>&1; then printf '*.bin filter=lfs diff=lfs merge=lfs -text\n' >> .gitattributes; fi
git add .gitattributes && git commit -qm attrs
addc d/ acme/eol-dir --extract
check "dir: text=auto: normalized" "$(git cat-file -p HEAD:d/crlf.txt | od -c | grep -c '\\r')" "0"
if git lfs version >/dev/null 2>&1; then
  check "dir: LFS: pointer" "$(git cat-file -p HEAD:d/data.bin | head -1)" "version https://git-lfs.github.com/spec/v1"
fi
check "dir: eol/LFS: clean" "$(st) $(git status --porcelain)" " "

# GitLab: a directory of several assets (no digests)
asset g1.txt g1; asset g2.txt g2
release --host gitlab.com grp/dir v1 10 "$F/g1.txt" "$F/g2.txt"
addc gl/ https://gitlab.com/grp/dir
check "GitLab dir" "$(git ls-files gl | oneline) $(st gl)" "gl/g1.txt gl/g2.txt  "
asset g1.txt "g1 v2"
release --host gitlab.com grp/dir v2 11 "$F/g1.txt" "$F/g2.txt"
pullc gl
check "GitLab dir: pulled" "$(cat gl/g1.txt) $(git log -1 --format=%B | grep Files)" "g1 v2 Files:   0 added, 0 removed, 1 changed (2 in total)"
addc t.bin acme/tool --asset 'tool-*.bin'
check "files and directories unmodified" "$(git assetsync status | tail -1)" "nothing to pull, all 1 file and 2 directories unmodified"


# =============================================================================
section "19. Archives: formats, executables, unsafe members"
# =============================================================================
cd "$T"
mkdir -p fmt/sub && echo one > fmt/one.txt && echo two > fmt/sub/two.txt && printf '#!/bin/sh\n' > fmt/run.sh
new_repo r19
for ext in zip tar tar.gz tgz tar.bz2 tar.xz; do
  mkarchive "$F/fmt.$ext" "$T/fmt"
  release acme/fmt-$ext v1 10 "$F/fmt.$ext"
  quiet asd add "x-$ext/" acme/fmt-$ext --extract
  check "extract $ext" "$(git ls-files -s "x-$ext" | awk '{print $1, $4}' | oneline)" \
    "100644 x-$ext/one.txt 100755 x-$ext/run.sh 100644 x-$ext/sub/two.txt "
done
printf 'plain\n' | gzip > "$F/plain.txt.gz"
release acme/gz v1 10 "$F/plain.txt.gz"
quiet asd add plain.txt acme/gz --extract
check "extract a .gz file" "$(cat plain.txt)" "plain"
check "extract without an archive" "$(asd add x/ acme/many-assets --extract 2>&1 >/dev/null)" \
  "error: x/: 'extract': no archive among a1.txt, a2.txt"
check "strip too deep" "$(asd add x/ acme/fmt-zip --extract --strip 1 2>&1)" \
  "error: x/: 'strip 1': 'one.txt' has fewer than 1 directory to strip"
check "subdir missing" "$(asd add x/ acme/fmt-zip --extract --subdir nope 2>&1)" \
  "error: x/: 'subdir nope': no files there"
check "nothing left" "$(asd add x/ acme/fmt-zip --extract --include '*.c' 2>&1)" \
  "error: x/: the filter leaves no files"
git reset -q --hard; git clean -qfd

for kind in slip abs symlink git case winname dup; do
  for ext in zip tar; do
    mkevil "$F/evil-$kind.$ext" $kind
    release acme/evil-$kind-$ext v1 10 "$F/evil-$kind.$ext"
    OUT=$(asd add "e/" acme/evil-$kind-$ext --extract 2>&1)
    check "unsafe $kind ($ext): refused" "$(echo "$OUT" | grep -c '^error: e/: ')" "1"
    check "unsafe $kind ($ext): nothing written" "$(ls -A e 2>/dev/null; git status --porcelain; ls ../evil.txt 2>/dev/null)" ""
  done
done
mkevil "$F/evil-hardlink.tar" hardlink
release acme/evil-hardlink v1 10 "$F/evil-hardlink.tar"
check "unsafe hardlink (tar): refused" "$(asd add e/ acme/evil-hardlink --extract 2>&1 | grep '^error')" \
  "error: e/: evil-hardlink.tar: 'hard' is a hard link"
printf 'PK\003\004broken' > "$F/broken.zip"
release acme/broken v1 10 "$F/broken.zip"
check "broken archive" "$(asd add e/ acme/broken --extract 2>&1 | grep -c '^error: e/: broken.zip: cannot unpack')" "1"


# =============================================================================
section "20. Download cache"
# =============================================================================
cd "$T"
asset c.txt cached
release acme/cache v1 10 "$F/c.txt"
release --host gitlab.com grp/cache v1 10 "$F/c.txt"
new_repo r20
reset_calls
quiet asd add a.txt acme/cache
quiet asd add b.txt acme/cache
check "cache: downloaded once (GitHub, by digest)" "$(downloads)" "1"
check "cache: stored by SHA-256" "$(ls "$ASSETSYNC_CACHE/sha256" | grep -c "^$(sha "$F/c.txt")\$")" "1"
N=$(ls "$ASSETSYNC_CACHE/sha256" | lines)
reset_calls
quiet asd add c.txt https://gitlab.com/grp/cache
quiet asd add d.txt https://gitlab.com/grp/cache
check "cache: downloaded once (GitLab, by the index)" "$(downloads)" "1"
check "cache: same content once" "$(ls "$ASSETSYNC_CACHE/sha256" | lines)" "$N"
reset_calls
check "cache: pull --force from the cache" "$(echo x > a.txt; git commit -qam x; git assetsync pull --force --no-edit a.txt >/dev/null 2>&1; cat a.txt) $(downloads)" "cached 0"
rm -rf "$ASSETSYNC_CACHE"
check "cache: deleted cache is filled again" "$(asd add e.txt acme/cache >/dev/null 2>&1; ls "$ASSETSYNC_CACHE/sha256" | lines)" "1"
check "cache: unusable" "$(ASSETSYNC_CACHE=$T/r20/a.txt/x asd add f.txt acme/cache 2>&1 | sed 's/ (.*) / /' | tr '\\' /)" \
  "error: cannot create the download cache $T/r20/a.txt/x - set ASSETSYNC_CACHE to another directory"


# =============================================================================
section "21. 7z archives (an external 7-Zip)"
# =============================================================================
cd "$T"
FAKE7Z="\"$PYTHON\" \"$TD/fake_7z.py\""
new_repo r21
# x7 NAME JSON - release acme/7z-NAME with the fake archive NAME.7z
x7() { mkfake7z "$F/$1.7z" "$2" && release acme/7z-$1 v1 10 "$F/$1.7z"; }
x7 ok '[{"path": "a.txt", "content": "a"}, {"path": "sub", "attrs": "D drwxr-xr-x"},
        {"path": "sub/run.sh", "content": "run", "attrs": "A -rwxr-xr-x"},
        {"path": "win.txt", "content": "w", "attrs": "A"}]'
ASSETSYNC_7Z=$FAKE7Z quiet asd add ok/ acme/7z-ok --extract
check "7z: unpacked" "$(git ls-files -s ok | awk '{print $1, $4}' | oneline)" \
  "100644 ok/a.txt 100755 ok/sub/run.sh 100644 ok/win.txt "
check "7z: listing checked first" "$(head -1 "$GH/7z.log" | cut -d' ' -f1-3)" "l -sccUTF-8 -slt"
rm -f "$GH/7z.log"
check "7z: older 7-Zip without -scc" "$(git reset -q --hard; FAKE_7Z_OLD=1 ASSETSYNC_7Z=$FAKE7Z asd add ok2/ acme/7z-ok --extract >/dev/null 2>&1; git ls-files ok2 | lines) $(grep -c -- '-scc' "$GH/7z.log") $(lines < "$GH/7z.log")" "3 2 4"
git reset -q --hard; rm -rf ok2
for bad in 'unsafe|[{"path": "../evil.txt", "content": "e"}]|unsafe path' \
           'abs|[{"path": "/tmp/evil.txt", "content": "e"}]|unsafe path' \
           'enc|[{"path": "a.txt", "encrypted": true}]|is encrypted' \
           'link|[{"path": "link", "attrs": "A lrwxrwxrwx"}]|is a symbolic link' \
           'fifo|[{"path": "pipe", "attrs": "A prw-r--r--"}]|is no regular file' \
           'win|[{"path": "con.txt", "content": "c"}]|not a valid file name' \
           'fail|[{"path": "a.txt", "fail": true}]|7-Zip failed: ERROR: Data Error'; do
  name=${bad%%|*}; rest=${bad#*|}; json=${rest%|*}; msg=${rest##*|}
  x7 "$name" "$json"
  OUT=$(ASSETSYNC_7Z=$FAKE7Z asd add e/ acme/7z-$name --extract 2>&1)
  check "7z: $name refused" "$(echo "$OUT" | grep -c "^error: e/: $name.7z.*$msg")" "1"
  check "7z: $name: nothing written" "$(ls -A e 2>/dev/null; git status --porcelain; ls ../evil.txt 2>/dev/null)" ""
done
if ! command -v cygpath >/dev/null; then    # symbolic links: not on Windows
  x7 sneaky '[{"path": "a.txt", "content": "a"}, {"path": "x", "sneaky_link": "/etc"}]'
  check "7z: link unpacked although listed as a file: refused" \
    "$(ASSETSYNC_7Z=$FAKE7Z asd add e/ acme/7z-sneaky --extract 2>&1 | grep '^error')" \
    "error: e/: sneaky.7z: 'x' is no regular file"
fi
check "7z: 7-Zip not runnable" "$(ASSETSYNC_7Z=/nonexistent/7z asd add e/ acme/7z-ok --extract 2>&1 | grep '^error' | sed 's/ (.*) / /')" \
  "error: cannot run 7-Zip '/nonexistent/7z' - install it or set ASSETSYNC_7Z"
check "7z without --extract: kept as it is" "$(ASSETSYNC_7Z=/nonexistent/7z asd add -n raw/ acme/7z-ok)" \
  "would add raw/ from acme/7z-ok v1 (ok.7z, latest release)"
if ! command -v cygpath >/dev/null; then
  # no 7-Zip at all: a PATH with only git and Python
  mkdir -p "$T/only" && ln -sf "$(command -v git)" "$T/only/git" && ln -sf "$(command -v "$PYTHON")" "$T/only/$PYTHON"
  check "7z: no 7-Zip" "$(PATH=$T/only "$PYTHON" "$S" add e/ acme/7z-ok --extract 2>&1 | grep '^error')" \
    "error: e/: ok.7z is a 7z archive: unpacking it needs 7-Zip - install it (https://www.7-zip.org; 7zz or 7z) or set ASSETSYNC_7Z"
fi

# with the real 7-Zip, if there is one (the CI installs it)
SZ=$(command -v 7zz || command -v 7z || command -v 7za || true)
[ -z "$SZ" ] && [ -f "/c/Program Files/7-Zip/7z.exe" ] && SZ="/c/Program Files/7-Zip/7z.exe"
if [ -z "$SZ" ]; then
  echo "skipped: no 7-Zip installed"
else
  echo "(7-Zip: $SZ)"
  mkdir -p "$T/s7/inc" && echo h > "$T/s7/inc/x.h" && echo t > "$T/s7/doc.txt" && printf '#!/bin/sh\n' > "$T/s7/run.sh"
  chmod +x "$T/s7/run.sh"
  (cd "$T/s7" && "$SZ" a -bd "$F/real.7z" inc doc.txt run.sh >/dev/null)
  release acme/real7z v1 10 "$F/real.7z"
  quiet asd add real/ acme/real7z --extract --exclude doc.txt
  check "real 7-Zip: unpacked" "$(git ls-files real | oneline)" "real/inc/x.h real/run.sh "
  if ! command -v cygpath >/dev/null; then   # no executable bit in archives made on Windows
    check "real 7-Zip: executable" "$(git ls-files -s real/run.sh | cut -c1-6)" "100755"
    ln -s doc.txt "$T/s7/link"
    (cd "$T/s7" && "$SZ" a -bd -snl "$F/reallink.7z" doc.txt link >/dev/null)
    release acme/real7zlink v1 10 "$F/reallink.7z"
    # only if this 7-Zip stored the link as one (p7zip on macOS follows it)
    if "$SZ" l -slt "$F/reallink.7z" | grep -q '^Attributes = .* l'; then
      check "real 7-Zip: symbolic link refused" "$(asd add rl/ acme/real7zlink --extract 2>&1 | grep '^error')" \
        "error: rl/: reallink.7z: 'link' is a symbolic link"
    else
      check "real 7-Zip: link stored as a file: a file" "$(asd add rl/ acme/real7zlink --extract >/dev/null 2>&1; git ls-files rl | oneline)" "rl/doc.txt rl/link "
    fi
  fi
fi


# =============================================================================
echo
echo "passed: $PASSED, failed: $FAILED"
[ "$FAILED" -eq 0 ]
