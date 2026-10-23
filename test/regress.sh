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
#    4. Local modifications: refused by pull, discarded with --overwrite
#    5. .git-assetsync registry: sources, unlink, mv, commit consistency
#    6. Commit proposals: pull stages, SQUASH_MSG
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
#   22. Filter steps in order, move / copy, named filters
#   23. Commands in filters: convert, run, trust
#   24. verify: is the committed state reproducible?
#   25. diff, difftool, and pull --release (once another release)
#   26. map: releases from a local folder; the pre-push check
#   27. edit: .git-assetsync in the editor
#   28. Release notes of skipped releases
#   29. restore: back to what the release gave
#   30. rm: remove entries and their files
#   31. A directory with files of others
#   32. Ignored paths, errors while writing, checkout form
#   33. Comments and own lines in .git-assetsync
#   34. add and mv make no directories; pull and restore do
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

# commitp - commit what is staged with the proposed message, if anything
commitp() { git diff --cached --quiet 2>/dev/null || git commit -q --no-edit >/dev/null 2>&1; }

# pullcm ARGS... - 'git assetsync pull' (which only stages, like git merge
# --squash), then commit what it staged with the proposed message; the
# output and exit code are those of pull
pullcm() { git assetsync pull "$@"; local r=$?; commitp; return $r; }

# pullc PATH... - pull and commit without the editor, quietly
pullc() { pullcm "$@" >/dev/null 2>&1; }

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

# A local folder a source is mapped to is only read - it may be a read-only
# network share. readonly DIR... - make the folders read-only (where the
# system allows; not for root, partly on Windows) and note their state:
# paths, sizes, modification times, contents; writable DIR... - writable
# again, to put a new release there; untouched DIR... - the differences
# from the noted state (none: empty)
folder_state() {
  "$PYTHON" - "$1" <<'EOF2'
import hashlib, os, sys
top = sys.argv[1]
for d, dirs, files in sorted(os.walk(top)):
    dirs.sort()
    for n in sorted(dirs + files):
        p = os.path.join(d, n)
        st = os.lstat(p)
        data = open(p, "rb").read() if os.path.isfile(p) else b""
        print(os.path.relpath(p, top).replace(os.sep, "/"), st.st_size if data else "-",
              st.st_mtime_ns, hashlib.sha256(data).hexdigest()[:16])
EOF2
}
readonly_dir() { for d; do chmod -R a-w "$d"; folder_state "$d" > "$d.state"; done; }
writable() { for d; do chmod -R u+w "$d"; done; }
untouched() { for d; do folder_state "$d" | diff "$d.state" - | grep '^[<>]'; done; }

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

# filt NAME STEP-OPTIONS... - define (or change) the named filter NAME in
# the current repository, and commit it
filt() {
  { git assetsync filter add "$@" || git assetsync filter set "$@"; } >/dev/null 2>&1
  git commit -q -m "filter $1" -- .git-assetsync
}

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
mkdir bin                 # add makes no directory, as cp
OUT=$(asd add acme/tool bin/tool.bin --asset 'tool-*.bin' 2>&1)
check "add stages, like git add" "$(git status --porcelain | oneline)" "A  .git-assetsync A  bin/tool.bin "
check "add: says how to commit" "$(echo "$OUT" | grep -cxE '    git commit|\(it offers the proposed commit message; a copy stays in \.git/ASSETSYNC_MSG\)')" "2"
check "add: file is the asset" "$(cat bin/tool.bin)" "tool 1.0"
check "added, not committed yet: '?'" "$(git assetsync status -s --no-fetch)" " ? bin/tool.bin"
check "... a section of its own" "$(git assetsync status --no-fetch | grep -A2 '^Not committed yet:' | grep -cE "^${TAB}new file:[[:space:]]+bin/tool\.bin\$")" "1"
check "add: source" "$(reg source.acme/tool.url)" "https://github.com/acme/tool"
check "add: no release key (latest)" "$(reg file.bin/tool.bin.release)" ""
check "add: entry" "$(reg file.bin/tool.bin.source) $(reg file.bin/tool.bin.asset) $(reg file.bin/tool.bin.synced)" \
  "acme/tool tool-*.bin v1.0"
check "add: digest" "$(reg file.bin/tool.bin.digest)" "sha256:$(sha "$F/tool-1.0.bin")"
check "add: blob as git add stores it" "$(reg file.bin/tool.bin.blob)" "$(git rev-parse :bin/tool.bin)"
git commit -q --no-edit
check "add: proposed commit message" "$(msg)" \
  "[assetsync] Add bin/tool.bin from acme/tool v1.0 Release: https://github.com/acme/tool/releases/tag/v1.0 Title:   Tool 1.0 Asset:   tool-1.0.bin "
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
check "status: relative path from subdirectory" "$(cd bin && git assetsync status -s)" "P  tool.bin"
check "status: exit code 0" "$(rc git assetsync status)" "0"
check "status --exit-code: 1" "$(rc git assetsync status --exit-code)" "1"
check "pull without paths refused" "$(rc git assetsync pull)" "2"
check "pull without paths: message" "$(git assetsync pull 2>&1)" "error: specify file(s) or --all"
# into a pipe closed early (head): the pull still finishes, exit 141 like git
out=$(PYTHONUNBUFFERED=1 git assetsync pull -v bin/tool.bin 2>/dev/null | head -1; echo "rc=${PIPESTATUS[0]}"); commitp
check "pull -v: where it comes from first" "$(printf '%s\n' "$out" | head -1)" \
  "bin/tool.bin: tool-*.bin from acme/tool, latest release; synced v1.0"
check "pull into a closed pipe: finished, exit 141" "$(printf '%s\n' "$out" | tail -1)" "rc=141"
check "pull: content" "$(cat bin/tool.bin)" "tool 1.1"
check "pull: commit message" "$(msg)" \
  "[assetsync] Update bin/tool.bin to acme/tool v1.1 (was v1.0) Release: https://github.com/acme/tool/releases/tag/v1.1 Asset:   tool-1.1.bin "
check "pull: commit has file and entry" "$(git show --name-only --format= HEAD | sort | oneline)" ".git-assetsync bin/tool.bin "
check "pull: no assetid where there is a digest" "$(reg file.bin/tool.bin.assetid)" ""
check "status into a closed pipe: stops, exit 141" "$(PYTHONUNBUFFERED=1 git assetsync status | (exec 0<&-); echo "${PIPESTATUS[0]}")" "141"
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
asd add acme/tool other.bin --asset 'tool-*.bin' >/dev/null 2>&1 && git commit -q --no-edit
asset tool-1.3.bin "tool 1.3"
release acme/tool v1.3 13 "$F/tool-1.3.bin"
N=$(git rev-list --count HEAD)
quiet pullcm --all
check "pull --all: both updated" "$(cat bin/tool.bin other.bin | oneline)" "tool 1.3 tool 1.3 "
check "pull --all: one commit for all" "$(($(git rev-list --count HEAD) - N)) $(git log -1 --format=%s)" \
  "1 [assetsync] Update 2 files from acme/tool"
check "... with the message of each" "$(git log -1 --format=%B | grep -c '^Update [a-z/.]* to acme/tool v1.3 (was v1.[12])$')" "2"
# an entry refused: the others are pulled and committed anyway, exit code 2
asset tool-1.4.bin "tool 1.4"
release acme/tool v1.4 14 "$F/tool-1.4.bin"
echo mine > other.bin
check "pull --all: a refused entry left out" "$(rc pullcm --all) $(git log -1 --format=%s) $(cat other.bin)" \
  "2 [assetsync] Update bin/tool.bin to acme/tool v1.4 (was v1.3) mine"
git checkout -q other.bin

# release notes, shortened, in the message of an update
cd "$T"
asset rn.txt "rn 1"
printf 'First release\n' > "$F/notes1.md"
release --notes "$F/notes1.md" acme/rn v1 10 "$F/rn.txt"
new_repo r1b
addc acme/rn rn.txt
check "add: no release notes" "$(git log -1 --format=%B | grep -c 'First release')" "0"
asset rn.txt "rn 2"
printf '<!-- template\r\ncomment -->\r\n## What'"'"'s Changed\r\n\r\n\r\n* Fix A by @x\r\n* Fix B\r\n\r\n' > "$F/notes2.md"
release --notes "$F/notes2.md" acme/rn v2 11 "$F/rn.txt"
git assetsync pull rn.txt >/dev/null 2>&1; git commit -q >/dev/null 2>&1   # with the editor: comment lines stripped
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
# a command's help starts with its line from the command list
check "help: the command's line first" \
  "$(asd -h | grep -c '^  status  *show the state of the synced files$') $(asd status -h | grep -c '^Show the state of the synced files\.$')" "1 1"
check "help: basic commands first, then the advanced ones" \
  "$(asd -h | grep -E '^(basic|advanced) commands:$|^  [a-z][a-z-]*  ' | sed 's/^  \([a-z-]*\) .*/\1/' | oneline)" \
  "basic commands: status pull diff difftool restore add rm unlink mv advanced commands: set edit verify source filter cache hooks "
check "help: also for actions" "$(asd source rename -h | grep -c '^Rename a source and all references to it\.$')" "1"
# with Python 3.14 or later the help is colored - the command list too - when the
# output would be (--color, color.ui, NO_COLOR); before, it isn't
if "$PYTHON" -c 'import argparse, inspect, sys; sys.exit("color" not in inspect.signature(argparse.ArgumentParser).parameters)'; then
  ESC=$(printf '\033')
  check "help: the command list colored like the rest" \
    "$(FORCE_COLOR=1 asd -h --color=always | grep -cE "^  ${ESC}\[[0-9;]*mstatus${ESC}\[0m|^${ESC}\[[0-9;]*musage: ")" "2"
  check "help: no colors with --no-color, color.ui=never" \
    "$(FORCE_COLOR=1 asd status -h --no-color | grep -c "$ESC") $(git config color.ui never; FORCE_COLOR=1 asd -h | grep -c "$ESC"; git config --unset color.ui)" "0 0"
fi
check "help: the list short, the command's own description complete" \
  "$(asd -h | grep -c '^  difftool  *same in the configured difftool$') $(asd difftool -h | grep -c '^Show local modifications against what the release gave in the configured$')" "1 1"


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
quiet asd add acme/multi a.zip --asset '*.zip' --release 'toolA-*'
check "pattern: newest by date, not by name" "$(cat a.zip)" "toolA-20261015"
check "pattern: release key, in the entry" "$(reg file.a.zip.release) $(reg source.acme/multi.release)" "toolA-* "
quiet asd add acme/multi a2.zip --asset '*.zip'
check "source name without options: that source" "$(cat a2.zip) $(reg file.a2.zip.source)" "toolA-20261015 acme/multi"
quiet asd add https://github.com/acme/multi latest.zip --asset '*.zip'
check "latest: no prerelease, no draft" "$(cat latest.zip)" "toolA-20261015"
check "URL: the source with that URL, one per URL" "$(reg file.latest.zip.source) $(reg file.latest.zip.release)" "acme/multi "
quiet asd add acme/multi b.zip --asset '*.zip' --release toolB-20261017
check "exact tag: pinned" "$(cat b.zip)" "toolB-20261017"
check "source name with --release: the same source" "$(reg file.b.zip.source) $(reg file.b.zip.release)" \
  "acme/multi toolB-20261017"
quiet asd add acme/multi pre.zip --asset '*.zip' --release 'toolA-*' --prerelease
check "pattern with --prerelease" "$(cat pre.zip)" "toolA-20261019"
check "prerelease key" "$(reg file.pre.zip.prerelease)" "true"
quiet asd add acme/multi prelatest.zip --asset '*.zip' --prerelease
check "--prerelease without pattern: newest incl. prereleases" "$(cat prelatest.zip)" "toolA-20261019"
quiet asd add acme/multi pinpre.zip --asset '*.zip' --release toolA-20261019
check "exact tag of a prerelease" "$(cat pinpre.zip)" "toolA-20261019"
check "exact tag of a draft: not found" "$(asd add acme/multi d.zip --asset '*.zip' --release toolA-20261020 2>&1)" \
  "error: no release with tag 'toolA-20261020' in acme/multi"
check "pattern without match" "$(asd add acme/multi x.zip --asset '*.zip' --release 'toolC-*' 2>&1)" \
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
quiet asd add acme/slash slash.bin --asset slash.bin --release tools/v2
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
quiet asd add acme/many old.bin --asset old.bin --release 'special-*'
check "paging: match on page 2" "$(cat old.bin 2>/dev/null)" "old"
check "paging: 2 pages + download" "$(calls)" "3"

check "no releases at all" "$(mkdir -p "$GH/github.com/acme/empty"; asd add acme/empty x.bin --asset x 2>&1)" \
  "error: no release in acme/empty"
check "unknown repository" "$(asd add acme/nothing x.bin --asset x --release 'v*' 2>&1)" \
  "error: repository acme/nothing not found (or no access)"
check "unknown repository (latest)" "$(asd add acme/nothing x.bin --asset x 2>&1)" \
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
check "asset glob with no match" "$(asd add acme/app x.deb --asset 'app-*.deb' 2>&1)" \
  "error: release v3 of acme/app has no asset matching 'app-*.deb' (assets: app-linux.tar.gz, app-macos.tar.gz, app-windows.zip)"
check "asset glob with 2 matches" "$(asd add acme/app x.tgz --asset 'app-*.tar.gz' 2>&1)" \
  "error: 'app-*.tar.gz' matches 2 assets of release v3 of acme/app: app-linux.tar.gz, app-macos.tar.gz - use a more specific pattern"
check "nothing written on error" "$(git status --porcelain)" ""
quiet asd add acme/app app.tgz --asset 'app-linux.*' && git commit -q --no-edit
check "asset glob with 1 match" "$(cat app.tgz)" "linux"
check "no --asset, several assets" "$(asd add acme/app y.tgz 2>&1)" \
  "error: release v3 of acme/app has 3 assets: app-linux.tar.gz, app-macos.tar.gz, app-windows.zip - choose one with --asset PATTERN"

# the newest release lacks the asset: an error, no fallback to older ones
asset other.txt other
release acme/app v4 11 "$F/other.txt"
check "new release without the asset: error" "$(st)" "E"
check "... message" "$(git assetsync status 2>&1 | head -1)" \
  "error: app.tgz: release v4 of acme/app has no asset matching 'app-linux.*' (assets: other.txt)"
check "... exit code 2" "$(rc git assetsync status)" "2"
check "... pull fails" "$(rc pullcm app.tgz)" "2"
cd "$T"

# without --asset: the release's only asset; no asset key recorded
asset single.bin "single 1"
release acme/single v1 10 "$F/single.bin"
new_repo r3a
addc acme/single single.bin
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
addc acme/re re.bin --asset re.bin
asset re.bin "second upload"
reupload acme/re v1 "$F/re.bin"
check "asset replaced: pending" "$(st)" "P"
check "asset replaced: note" "$(git assetsync status | grep -c 'asset replaced in release v1')" "1"
pullc re.bin
check "asset replaced: pulled" "$(cat re.bin)" "second upload"
check "asset replaced: message" "$(git log -1 --format=%s)" "[assetsync] Update re.bin from acme/re v1 (asset replaced)"

# a wrong digest in the release: nothing is changed
asset bad.bin bad
release --baddigest acme/bad v1 10 "$F/bad.bin"
new_repo r3c
OUT=$(asd add acme/bad bad.bin --asset bad.bin 2>&1)
check "digest mismatch: error" "$(echo "$OUT" | grep -c 'downloaded file has sha256:.*, but the release lists sha256:0000')" "1"
check "digest mismatch: nothing written" "$(ls; git status --porcelain)" ""

# releases from before GitHub reported digests: computed on download
asset nod.bin nodigest
release --nodigest acme/nod v1 10 "$F/nod.bin"
quiet asd add acme/nod nod.bin --asset nod.bin
check "no digest in the API: computed" "$(reg file.nod.bin.digest)" "sha256:$(sha "$F/nod.bin")"
# ... and a re-upload noticed by what GitHub says about the asset (a new id)
git commit -q --no-edit
check "no digest: assetid recorded" "$(reg file.nod.bin.assetid | cut -c1-7)" "sha256:"
asset nod.bin nodigesT      # the same size: only the id tells
reupload acme/nod v1 "$F/nod.bin"
check "no digest: re-upload pending" "$(st nod.bin)" "P"
pullc nod.bin
check "... pulled" "$(cat nod.bin) $(git log -1 --format=%s)" "nodigesT [assetsync] Update nod.bin from acme/nod v1 (asset replaced)"
check "... then up to date" "$(st nod.bin)" ""


# =============================================================================
section "4. Local modifications: refused by pull, discarded with --overwrite"
# =============================================================================
cd "$T"
asset lm.txt "lm 1"
release acme/lm v1 10 "$F/lm.txt"
new_repo r4
addc acme/lm lm.txt --asset lm.txt

# committed modification
echo changed > lm.txt && git commit -qam "local change"
check "committed modification: M" "$(st)" " M"
check "status: section" "$(git assetsync status | grep -cE "^${TAB}modified:[[:space:]]+lm\.txt  \(NOT ALLOWED\)")" "1"
check "status --exit-code: 1" "$(rc git assetsync status --exit-code)" "1"
check "pull refused" "$(rc pullcm lm.txt)" "2"
check "pull refused: message" "$(git assetsync pull lm.txt 2>&1 | grep -c 'local modifications NOT ALLOWED')" "1"
check "... file unchanged" "$(cat lm.txt)" "changed"
mkdir -p sub
check "... the proposed command fits the current directory" \
  "$(cd sub && git assetsync pull ../lm.txt 2>&1 | grep -o "discard them with '[^']*'")" \
  "discard them with 'git assetsync restore -SW ../lm.txt'"
out=$(pullcm --overwrite lm.txt 2>/dev/null)
check "pull --overwrite restores" "$(cat lm.txt)" "lm 1"
check "pull --overwrite: a committed modification isn't lost, not named" "$(printf '%s\n' "$out" | grep -c '^discarded:')" "0"
check "pull --overwrite: message" "$(msg)" \
  "[assetsync] Restore lm.txt from acme/lm v1 Release: https://github.com/acme/lm/releases/tag/v1 Asset:   lm.txt Local modifications of this repository were discarded. "
check "after restore: clean" "$(st)" ""
echo mine > lm.txt
out=$(pullcm --overwrite lm.txt 2>/dev/null)
id=$(printf '%s\n' "$out" | sed -n 's/^discarded: lm.txt (git show \([0-9a-f]*\) to get it back)$/\1/p')
check "pull --overwrite: an uncommitted one named, to get back" "$(git show "$id") $(cat lm.txt) $(st)" "mine lm 1 "

# uncommitted modification, with a new release
echo dirty > lm.txt
check "uncommitted modification: M" "$(st)" " M"
check "status: NOT ALLOWED" "$(git assetsync status | grep -cE "^${TAB}modified:[[:space:]]+lm\.txt  \(NOT ALLOWED\)")" "1"
asset lm.txt "lm 2"
release acme/lm v2 11 "$F/lm.txt"
check "pending + uncommitted" "$(st)" "PM"
check "pull refused" "$(git assetsync pull lm.txt 2>&1 | grep -c "local modifications NOT ALLOWED.*git assetsync restore -SW lm.txt")" "1"
check "... file unchanged" "$(cat lm.txt)" "dirty"
check "pull --all --overwrite: discards and updates" \
  "$(pullcm --all --overwrite 2>&1 | grep -c 'warning: lm.txt: discarding local modifications')" "1"
check "... content" "$(cat lm.txt)" "lm 2"
check "... message" "$(git log -1 --format=%s)" "[assetsync] Update lm.txt to acme/lm v2 (was v1)"

# uncommitted deletion
rm lm.txt
check "deleted: D" "$(st)" " D"
check "deleted: pull refused" "$(rc git assetsync pull lm.txt)" "2"
pullc --overwrite lm.txt
check "deleted: pull --overwrite restores" "$(cat lm.txt)" "lm 2"

# a change back to the asset version is no modification
echo changed > lm.txt && git commit -qam "local change"
git show HEAD~1:lm.txt > lm.txt
check "worktree back to the asset: still modified (committed)" "$(st)" " M"
check "... listed once, NOT ALLOWED" \
  "$(git assetsync status | grep -cE "^${TAB}modified:[[:space:]]+lm\.txt  \(NOT ALLOWED\)\$")" "1"
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
  "error: 'hand.txt' exists and differs from hand.txt - use --overwrite to replace it"
rm hand.txt
pullc hand.txt
check "hand-written entry: pulled" "$(cat hand.txt) $(git log -1 --format=%s)" "hand [assetsync] Add hand.txt from h v1"
check "hand-written entry: base recorded" "$(reg file.hand.txt.synced)" "v1"


# =============================================================================
section "5. .git-assetsync registry: sources, unlink, mv, commit consistency"
# =============================================================================
cd "$T"
asset one.bin one
asset two.bin two
release acme/pair v1 10 "$F/one.bin" "$F/two.bin"
new_repo r5
addc acme/pair one.bin --asset one.bin
addc https://github.com/acme/pair.git two.bin --asset two.bin
check "same URL and selection: one source" "$(git config -f .git-assetsync --get-regexp 'source\..*\.url' | lines)" "1"
check "source by name" "$(rc asd add acme/pair three.bin --asset one.bin)" "0"
git reset -q --hard
quiet asd add acme/pair x.bin --asset one.bin --release v1
check "source name with --release: the same source" "$(reg file.x.bin.source) $(reg file.x.bin.release)" "acme/pair v1"
git reset -q --hard; rm -f x.bin
check "already synced: refused" "$(asd add acme/pair one.bin --asset two.bin 2>&1)" \
  "error: 'one.bin' is already synced (use --force to replace its entry)"
quiet asd add --force acme/pair one.bin --asset two.bin
check "add --force: replaced" "$(cat one.bin) $(reg file.one.bin.asset)" "two two.bin"
git reset -q --hard
echo changed > one.bin
check "add --force: local modifications kept" "$(asd add --force acme/pair one.bin --asset two.bin 2>&1 | oneline; cat one.bin)" \
  "error: 'one.bin' has local modifications - use --overwrite to discard them changed"
quiet asd add --force --overwrite acme/pair one.bin --asset two.bin
check "... discarded with --overwrite" "$(cat one.bin) $(reg file.one.bin.asset)" "two two.bin"
git reset -q --hard
echo mine > mine.bin
check "existing different file: refused" "$(asd add acme/pair mine.bin --asset one.bin 2>&1 | tail -1)" \
  "error: 'mine.bin' exists and differs from one.bin - use --overwrite to replace it"
check "... file kept" "$(cat mine.bin)" "mine"
check "--force doesn't overwrite it" "$(asd add --force acme/pair mine.bin --asset one.bin 2>&1 | tail -1 | oneline; cat mine.bin)" \
  "error: 'mine.bin' exists and differs from one.bin - use --overwrite to replace it mine"
out=$(asd add --overwrite acme/pair mine.bin --asset one.bin 2>/dev/null)
check "add --overwrite: replaced" "$(cat mine.bin) $(git status --porcelain mine.bin)" "one A  mine.bin"
id=$(printf '%s\n' "$out" | sed -n 's/^discarded: mine.bin (git show \([0-9a-f]*\) to get it back)$/\1/p')
check "add --overwrite: what it discarded, to get back" "$(git show "$id")" "mine"
git reset -q --hard; rm -f mine.bin; echo staged > mine.bin; git add mine.bin
out=$(asd add --overwrite acme/pair mine.bin --asset one.bin 2>/dev/null)
id=$(printf '%s\n' "$out" | sed -n 's/^discarded: mine.bin (git show \([0-9a-f]*\) to get it back)$/\1/p')
check "add --overwrite: a staged file too (the index is replaced)" "$(git show "$id")" "staged"
git reset -q --hard; rm -f mine.bin; echo mine > mine.bin
cp "$F/one.bin" same.bin
check "existing identical file: fine" "$(rc asd add acme/pair same.bin --asset one.bin)" "0"
git reset -q --hard; rm -f mine.bin same.bin
check "an existing directory: a directory entry" "$(mkdir -p dir && asd add acme/pair dir --asset one.bin 2>/dev/null | head -1)" \
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

# mv of a directory with entries in it: all of them follow (like git mv)
quiet git assetsync mv two.bin sub && git commit -qm "two in sub"
echo mine > sub/own.txt
check "mv dir with entries: -n" "$( (git assetsync mv -n sub tools; git status --porcelain) | oneline)" \
  "would move sub -> tools (2 entries) ?? sub/own.txt "
check "mv dir with entries" "$(git assetsync mv sub tools)" "moved sub -> tools (2 entries kept)"
check "... staged, own file along" "$(git status --porcelain | oneline)" \
  "M  .git-assetsync R  sub/one.bin -> tools/one.bin R  sub/two.bin -> tools/two.bin ?? tools/own.txt "
check "... entries renamed" "$(reg file.tools/one.bin.source) $(reg file.tools/two.bin.source)" "acme/pair acme/pair"
check "... clean" "$(git commit -qm mv && st)" ""
check "mv into itself: refused" "$(git assetsync mv tools tools/x 2>&1)" "error: cannot move 'tools' into itself"
check "mv dir without entries: refused" "$(mkdir plain && git assetsync mv plain x 2>&1)" "error: 'plain' is not synced"
git reset -q --hard HEAD~2 && rm -rf tools plain

# pull stages its file and entry; other uncommitted entries stay as they are
asset one.bin "one v2"
asset two.bin "two v2"
release acme/pair v2 11 "$F/one.bin" "$F/two.bin"
git config -f .git-assetsync file.two.bin.asset 'two*' && git add .git-assetsync
quiet git assetsync pull sub/one.bin
check "pull: staged with another uncommitted entry" "$(git status --porcelain | oneline) $(reg file.two.bin.asset)" \
  "M  .git-assetsync M  sub/one.bin  two*"
git commit -q --no-edit
check "uncommitted [source] changes go along" "$(git config -f .git-assetsync source.acme/pair.note x && git add .git-assetsync && pullc two.bin; git status --porcelain)" ""
check "... in the commit" "$(git show --format= --name-only HEAD | sort | oneline)" ".git-assetsync two.bin "


# =============================================================================
section "6. Commit proposals: pull stages, SQUASH_MSG"
# =============================================================================
cd "$T"
asset p.txt "p 1"
release acme/p v1 10 "$F/p.txt"
new_repo r6
quiet asd add acme/p p1.txt --asset p.txt
quiet asd add acme/p p2.txt --asset p.txt
check "two adds: proposals collected" "$(grep -c '^\[assetsync\] Add ' .git/SQUASH_MSG)" "2"
git commit -q --no-edit
check "commit takes both" "$(git log -1 --format=%B | grep -c '^\[assetsync\] Add ')" "2"
check "SQUASH_MSG removed by git" "$(ls .git/SQUASH_MSG 2>/dev/null)" ""
check "... the copy stays" "$(grep -c '^\[assetsync\] Add ' .git/ASSETSYNC_MSG)" "2"
mkdir -p sub
check "copy: path relative to the current directory" \
  "$(cd sub && git assetsync add acme/p p3.txt --asset p.txt 2>&1 | grep -o 'a copy stays in .*')" \
  "a copy stays in ../.git/ASSETSYNC_MSG)"
git commit -q -m "another message"
check "copy: a commit without it" "$(ls .git/SQUASH_MSG 2>/dev/null; grep -c '^\[assetsync\] Add sub/p3.txt' .git/ASSETSYNC_MSG)" "1"
asset p.txt "p 2"
release acme/p v2 11 "$F/p.txt"
OUT=$(git assetsync pull p1.txt 2>&1); RC=$?
check "pull: staged, not committed" "$RC $(git status --porcelain | oneline)$(git log -1 --format=%s)" \
  "0 M  .git-assetsync M  p1.txt another message"
check "pull: hint" "$(echo "$OUT" | grep -c '^p1.txt: updated and staged. Commit with:')" "1"
check "pull: proposed message in SQUASH_MSG" "$(head -1 .git/SQUASH_MSG)" "[assetsync] Update p1.txt to acme/p v2 (was v1)"
git commit -q --no-edit
check "pull: a plain commit takes it" "$(git log -1 --format=%s)" "[assetsync] Update p1.txt to acme/p v2 (was v1)"
# a SQUASH_MSG git wrote itself (e.g. merge --squash): the proposal is added to it
echo "squash of someone else" > .git/SQUASH_MSG
OUT=$(git assetsync pull p2.txt 2>&1)
check "SQUASH_MSG of git's own: the proposal added" \
  "$(head -1 .git/SQUASH_MSG) $(grep -c '^\[assetsync\] Update p2.txt' .git/SQUASH_MSG) $(echo "$OUT" | grep -cx '    git commit')" \
  "squash of someone else 1 1"
check "... the copy: all of it" "$(cmp -s .git/SQUASH_MSG .git/ASSETSYNC_MSG && echo same)" "same"
git commit -q --no-edit
asset p.txt "p 3"
release acme/p v3 12 "$F/p.txt"
quiet git assetsync pull p1.txt
check "after a commit the next proposal starts afresh, the copy too" \
  "$(grep -c 'squash of someone else' .git/ASSETSYNC_MSG) $(head -1 .git/ASSETSYNC_MSG)" \
  "0 [assetsync] Update p1.txt to acme/p v3 (was v2)"
git commit -q --no-edit
quiet git assetsync pull p2.txt && git commit -q --no-edit
check "... and commits" "$(git log -1 --format=%s)$(git status --porcelain)" \
  "[assetsync] Update p2.txt to acme/p v3 (was v2)"
# several entries: one proposal for all; other staged files are the user's
asset p.txt "p 4"
release acme/p v4 13 "$F/p.txt"
echo other > other.txt; git add other.txt
OUT=$(git assetsync pull --all 2>&1)
check "pull --all: all staged, one proposal" \
  "$(echo "$OUT" | grep -c '^3 files: updated and staged') $(cat p1.txt p2.txt sub/p3.txt | oneline)$(git status --porcelain | oneline)" \
  "1 p 4 p 4 p 4 M  .git-assetsync A  other.txt M  p1.txt M  p2.txt M  sub/p3.txt "
git commit -q --no-edit
check "... a plain commit takes the proposed message" "$(git log -1 --format=%s)" "[assetsync] Update 3 files from acme/p"


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
check "--no-fetch: worktree still checked" "$(st --no-fetch p2.txt)" " M"
git checkout -q p2.txt
reset_calls
quiet git assetsync status
check "status: one request for both entries of the source" "$(calls)" "1"
# other selections of the same source: its releases are listed once, also
# for the releases a pull skips
asset p.txt "p 5"
release acme/p v5 14 "$F/p.txt"
quiet git assetsync set p1.txt --release 'v*'
quiet git assetsync set p2.txt --prerelease
check "two selections" "$(reg file.p1.txt.release) $(reg file.p2.txt.prerelease) $(st p1.txt)$(st p2.txt)" "v* true PP"
reset_calls
quiet git assetsync status
check "status: the releases listed once for two selections" "$(grep -c 'releases?per_page' "$GH/calls.log")" "1"
reset_calls
quiet git assetsync pull p1.txt p2.txt
check "pull: the releases listed once, also for those skipped" \
  "$(grep -c 'releases?per_page' "$GH/calls.log") $(git diff --cached --name-only | oneline)" "1 .git-assetsync p1.txt p2.txt "
git reset -q --hard


# =============================================================================
section "8. Line endings"
# =============================================================================
cd "$T"
printf 'line 1\r\nline 2\r\n' > "$F/crlf.txt"
printf 'line 1\nline 2\n' > "$F/lf.txt"
release acme/eol v1 10 "$F/crlf.txt" "$F/lf.txt"

new_repo r8
printf '* text=auto\n' > .gitattributes && git add .gitattributes && git commit -qm attrs
addc acme/eol crlf.txt --asset crlf.txt
check "text=auto: stored normalized" "$(git cat-file -p HEAD:crlf.txt | od -c | grep -c '\\r')" "0"
check "text=auto: blob as git add stores it" "$(reg file.crlf.txt.blob)" "$(git hash-object --path=crlf.txt "$F/crlf.txt")"
check "text=auto: clean" "$(st) $(git status --porcelain)" " "
cd "$T"

new_repo r8b
git config core.autocrlf true
addc acme/eol lf.txt --asset lf.txt
check "autocrlf: checked out with CRLF" "$(od -c lf.txt | grep -c '\\r')" "1"
check "autocrlf: clean" "$(st) $(git status --porcelain)" " "
check "autocrlf: registry has no warning-causing LF" "$(git status --porcelain .git-assetsync)" ""
cd "$T"

# .gitattributes changed afterwards (normalization on): content still the asset
new_repo r8c
addc acme/eol crlf.txt --asset crlf.txt
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
  addc acme/fw fw.bin --asset fw.bin
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
  addc acme/fw fw.bin --asset fw.bin
  printf '*.bin filter=lfs diff=lfs merge=lfs -text\n' > .gitattributes && git add .gitattributes
  git add --renormalize . && git commit -qm "to LFS"
  check "moved to LFS afterwards: committed as pointer" "$(git cat-file -p HEAD:fw.bin | head -1)" "version https://git-lfs.github.com/spec/v1"
  check "moved to LFS afterwards: unmodified" "$(st)" ""
  cd "$T"

  # big binaries not in LFS: a hint
  head -c 1048576 /dev/zero > "$F/big.bin"
  release acme/big v1 10 "$F/big.bin"
  new_repo r9c
  check "big binary, no LFS: hint" "$(asd add acme/big big.bin --asset big.bin 2>&1 | grep -c "git lfs track big.bin")" "1"
  git reset -q --hard
  printf '*.bin filter=lfs diff=lfs merge=lfs -text\n' > .gitattributes && git add .gitattributes && git commit -qm lfs
  check "big binary in LFS: no hint" "$(asd add --force acme/big big.bin --asset big.bin 2>&1 | grep -c 'git lfs track')" "0"
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
check "unsafe paths: pull --all writes nothing" "$(pullcm --all >/dev/null 2>&1; ls -a .git/hooks | grep -c '^post-merge$'; ls ../evil.txt 2>/dev/null)" "0"
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
check "gh missing" "$(ASSETSYNC_GH=/nonexistent/gh asd add acme/rb r.txt --asset r.txt 2>&1 | sed 's/ (.*) / /')" \
  "error: cannot run the GitHub CLI '/nonexistent/gh' - install it from https://cli.github.com and log in with 'gh auth login'"
check "gh fails" "$(ASSETSYNC_GH="\"$PYTHON\" -c 'import sys; sys.stderr.write(\"gh: Bad credentials (HTTP 401)\\n\"); sys.exit(1)'" asd add acme/rb r.txt --asset r.txt 2>&1)" \
  "error: acme/rb: 'gh api repos/acme/rb/releases/latest' failed: gh: Bad credentials (HTTP 401)"
check "add: path outside the repository" "$(asd add acme/rb ../r.txt --asset r.txt 2>&1)" \
  "error: cannot add '../r.txt': not a path inside the working tree"
check "add: the registry itself" "$(asd add acme/rb .git-assetsync --asset r.txt 2>&1)" \
  "error: cannot add '.git-assetsync': .git-assetsync itself"
check "add: bad URL" "$(asd add ftp://x/y r.txt --asset r.txt 2>&1)" \
  "error: 'ftp://x/y' is not a URL like https://github.com/owner/repo"
# wildcard characters in a file name are taken literally: 'we[i]rd f.txt'
# must not stage 'weird f.txt' (no '*' or '?': not allowed on Windows)
echo other > 'weird f.txt'
quiet asd add acme/rb 'we[i]rd f.txt' --asset r.txt
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
check "unknown host without type" "$(asd add https://ghe.example.com/acme/ent e.txt --asset e.txt 2>&1)" \
  "error: https://ghe.example.com/acme/ent: platform of ghe.example.com unknown - give its type (add --type github|gitlab, or 'git assetsync source set-type <source> github|gitlab')"
reset_calls
addc https://ghe.example.com/acme/ent e.txt --asset e.txt --type github
check "GitHub Enterprise: fetched" "$(cat e.txt)" "enterprise"
check "GitHub Enterprise: --hostname" "$(grep -c '^api --hostname ghe.example.com ' "$GH/calls.log")" "2"
check "GitHub Enterprise: type recorded" "$(reg source.acme/ent.type)" "github"
check "GitHub Enterprise: status" "$(st)" ""
check "unknown type" "$(git config -f .git-assetsync source.acme/ent.type bitbucket; git assetsync status 2>&1 | head -1)" \
  "error: e.txt: https://ghe.example.com/acme/ent: unknown type 'bitbucket' (supported: github, gitlab)"
git checkout -q .git-assetsync
# GH_HOST must not redirect requests for github.com (gh would follow it)
reset_calls
GH_HOST=ghe.example.com quiet asd add -n acme/tool x.txt
check "github.com: --hostname always given" "$(grep -c '^api --hostname github.com ' "$GH/calls.log")" "1"


# =============================================================================
section "12. Dry runs"
# =============================================================================
cd "$T"
asset dr.txt "dr 1"
release acme/dr v1 10 "$F/dr.txt"
new_repo r12
reset_calls
check "add -n: output" "$(asd add -n acme/dr dr.txt --asset dr.txt 2>&1)" \
  "would add dr.txt from acme/dr v1 (dr.txt, latest release)"
check "add -n: nothing changed, no download" "$(git status --porcelain; ls; calls)" "1"
addc acme/dr dr.txt --asset dr.txt
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
check "hooks: not installed" "$(git assetsync hooks | oneline)" \
  "pre-push: not installed (install with 'git assetsync hooks install') post-merge: not installed (install with 'git assetsync hooks install') "
check "hooks install" "$(git assetsync hooks install | oneline)" "pre-push: installed post-merge: installed "
check "hooks: installed" "$(git assetsync hooks | oneline)" "pre-push: installed post-merge: installed "
check "hook runs 'hook post-merge'" "$(grep -c '^git assetsync hook post-merge "\$@" </dev/null || true$' .git/hooks/post-merge)" "1"
check "hook: nothing to report" "$(sh .git/hooks/post-merge 2>&1 | head -1)" ""
echo changed > dr.txt
check "hook output" "$(sh .git/hooks/post-merge 2>&1 | head -1)" \
  "assetsync: dr.txt: local modifications NOT ALLOWED"
git checkout -q dr.txt
check "pre-push hook sees new releases" "$(sh .git/hooks/pre-push 2>&1 | head -1)" \
  "assetsync: dr.txt: upstream pending (v1 -> v2)"
check "pre-push hook: exit 0" "$(rc sh .git/hooks/pre-push)" "0"
check "pre-push hook: git-assetsync missing never blocks" \
  "$(HOME=$T/nohome sh .git/hooks/pre-push >/dev/null 2>&1; echo $?)" "0"
check "hooks install: again" "$(git assetsync hooks install | oneline)" \
  "pre-push: already installed post-merge: already installed "
check "hooks uninstall" "$(git assetsync hooks uninstall | oneline)" "pre-push: removed post-merge: removed "
# our lines as an older version wrote them: updated in place
printf '#!/bin/sh\necho before\n# git-assetsync: reminders\ngit assetsync hook pre-push "$@" || true\necho after\n' > .git/hooks/pre-push
check "hooks: outdated" "$(git assetsync hooks | head -1)" "pre-push: outdated (update with 'git assetsync hooks install')"
check "hooks install: old hook updated" "$(git assetsync hooks install | head -1)" "pre-push: updated"
check "... in place" "$(grep -v '^#' .git/hooks/pre-push | oneline)" \
  'echo before git_assetsync_refs=$([ $# -eq 0 ] || cat) printf '"'%s\\n'"' "$git_assetsync_refs" | git assetsync hook pre-push "$@" || [ $? -ne 3 ] || exit 1 [ -z "$git_assetsync_refs" ] || exec <<git_assetsync_refs_end $git_assetsync_refs git_assetsync_refs_end echo after '
quiet git assetsync hooks uninstall
check "... uninstall keeps the rest" "$(oneline < .git/hooks/pre-push)" "#!/bin/sh echo before echo after "
rm .git/hooks/pre-push
printf '#!/bin/sh\necho mine\n' > .git/hooks/post-merge
printf '#!/bin/sh\necho mine\n' > .git/hooks/pre-push
check "hooks: a hook of another tool" "$(git assetsync hooks | head -1)" \
  "pre-push: hook of another tool, without our lines (add them with 'git assetsync hooks install --force')"
git config core.hooksPath .git/hooks
check "hooks: the directory set by core.hooksPath" "$(git assetsync hooks 2>&1 | head -1 | tr '\\' /)" "hooks directory: $T/r12/.git/hooks (core.hooksPath)"
git config --unset core.hooksPath
OUT=$(git assetsync hooks install)
check "existing hook: not touched" "$(echo "$OUT" | grep -c 'post-merge: hook exists')" "1"
check "existing pre-push hook: lines to add first" "$(echo "$OUT" | grep -c 'pre-push: hook exists, add these lines to .* (first: ')" "1"
check "... and how to have them added" "$(echo "$OUT" | grep -c "^(or run 'git assetsync hooks install --force' to add them)$")" "2"
printf '#!/bin/sh\ngit lfs pre-push "$@"\nexec true\n' > .git/hooks/pre-push
check "hooks install --force" "$(git assetsync hooks install --force | oneline)" \
  "pre-push: lines added to the existing hook post-merge: lines added to the existing hook "
check "... right after the #! line" "$(sed -n 1,3p .git/hooks/pre-push | cut -c1-16 | oneline) $(tail -2 .git/hooks/pre-push | oneline)" \
  "#!/bin/sh # git-assetsync: git_assetsync_re  git lfs pre-push \"\$@\" exec true "
check "... then: already installed" "$(git assetsync hooks install --force | oneline)" "pre-push: already installed post-merge: already installed "
quiet git assetsync hooks uninstall
check "... uninstall keeps the others' lines" "$(oneline < .git/hooks/pre-push) $(oneline < .git/hooks/post-merge)" \
  "#!/bin/sh git lfs pre-push \"\$@\" exec true  #!/bin/sh echo mine "
rm .git/hooks/pre-push .git/hooks/post-merge
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
OUT=$(asd add https://gitlab.com/grp/proj gl.bin --asset 'gl.b*' 2>&1)
check "GitLab: add" "$(cat gl.bin)" "gl 1"
check "GitLab: source without type" "$(reg source.grp/proj.url) $(reg source.grp/proj.type)" "https://gitlab.com/grp/proj "
check "GitLab: digest computed" "$(reg file.gl.bin.digest)" "sha256:$(sha "$F/gl.bin")"
check "GitLab: glab with --hostname" "$(grep -c '^glab api --hostname gitlab.com ' "$GH/calls.log")" "2"
check "GitLab: generic package downloaded via the API" \
  "$(grep -c '^glab api --hostname gitlab.com projects/grp%2Fproj/packages/generic/pkg/v1/gl.bin$' "$GH/calls.log")" "1"
git commit -q --no-edit
check "GitLab: message" "$(msg)" \
  "[assetsync] Add gl.bin from grp/proj v1 Release: https://gitlab.com/grp/proj/-/releases/v1 Title:   GL 1 Asset:   gl.bin "
check "GitLab: clean" "$(st)" ""
check "GitLab: URL of a page of the project" "$(rc asd add https://gitlab.com/grp/proj/-/releases gl2.txt --asset gl.txt)" "0"
check "... same source" "$(reg file.gl2.txt.source)" "grp/proj"
git reset -q --hard; rm -f gl2.txt
check "GitLab: several assets need --asset" "$(asd add https://gitlab.com/grp/proj x.bin 2>&1)" \
  "error: release v1 of grp/proj has 2 assets: gl.bin, gl.txt - choose one with --asset PATTERN"

# a new release: pending, pull with release notes
asset gl.bin "gl 2"
printf '## Changes\n* faster\n' > "$F/gl-notes.md"
release --host gitlab.com --notes "$F/gl-notes.md" grp/proj v2 11 "$F/gl.bin"
check "GitLab: pending" "$(st)" "P"
pullc gl.bin
check "GitLab: pulled" "$(cat gl.bin)" "gl 2"
check "GitLab: message with notes" "$(msg)" \
  "[assetsync] Update gl.bin to grp/proj v2 (was v1) Release: https://gitlab.com/grp/proj/-/releases/v2 Asset:   gl.bin Release notes:   ## Changes   * faster "

# upcoming releases (released_at in the future) count as prereleases
asset gl.bin "gl 3 upcoming"
release --host gitlab.com --pre grp/proj v3 30 "$F/gl.bin"
check "GitLab: upcoming release not latest" "$(st)" ""
quiet asd add https://gitlab.com/grp/proj pre.bin --asset gl.bin --release 'v*' --prerelease
check "GitLab: upcoming with --prerelease" "$(cat pre.bin)" "gl 3 upcoming"
check "GitLab: pattern by date, without upcoming" \
  "$(asd add -n https://gitlab.com/grp/proj x.bin --asset gl.bin --release 'v*' 2>&1)" \
  "would add x.bin from grp/proj v2 (gl.bin, newest release matching v*)"
check "GitLab: exact tag" "$(asd add -n https://gitlab.com/grp/proj x.bin --asset gl.txt --release v1 2>&1)" \
  "would add x.bin from grp/proj v1 (gl.txt, release v1)"
git reset -q --hard; rm -f pre.bin

# subgroups; tags with '/'
asset sub.txt sub
release --host gitlab.com grp/sub/deep tools/v1 10 "$F/sub.txt"
quiet asd add https://gitlab.com/grp/sub/deep sub.txt --release tools/v1
check "GitLab: subgroup and tag with '/'" "$(cat sub.txt)" "sub"

# asset links: job artifacts and uploads via the API, other servers plainly
for kind in job upload http; do
  asset "$kind.txt" "via $kind"
  release --host gitlab.com --links $kind grp/$kind v1 10 "$F/$kind.txt"
  reset_calls
  OUT=$(asd add https://gitlab.com/grp/$kind $kind.txt 2>&1)
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
check "GitLab: failed download" "$(pullcm http.txt 2>&1 | grep -c 'download of .*/nothing/http.txt failed: HTTP 404')" "1"
check "... nothing changed" "$(cat http.txt; git status --porcelain)" "via http"

# self-managed GitLab: by name, or with type
asset sm.txt selfmanaged
release --host gitlab.example.org grp/sm v1 10 "$F/sm.txt"
release --host code.example.org grp/sm v1 10 "$F/sm.txt"
quiet asd add https://gitlab.example.org/grp/sm sm1.txt
check "self-managed GitLab, 'gitlab' in the host name" "$(cat sm1.txt)" "selfmanaged"
check "self-managed GitLab, other name: needs type" "$(asd add https://code.example.org/grp/sm sm2.txt 2>&1)" \
  "error: https://code.example.org/grp/sm: platform of code.example.org unknown - give its type (add --type github|gitlab, or 'git assetsync source set-type <source> github|gitlab')"
quiet asd add https://code.example.org/grp/sm sm2.txt --type gitlab
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
quiet asd add https://gitlab.com/grp/many old.bin --release 'special-*'
check "GitLab: paging, match on page 2" "$(cat old.bin 2>/dev/null) $(calls)" "old 3"

check "GitLab: unknown project" "$(asd add https://gitlab.com/grp/nothing x.bin 2>&1)" \
  "error: project grp/nothing not found (or no access)"
check "GitLab: no releases" "$(mkdir -p "$GH/gitlab.com/grp/empty"; asd add https://gitlab.com/grp/empty x.bin 2>&1)" \
  "error: no release in grp/empty"
check "GitLab: not a project URL" "$(asd add https://gitlab.com/grp x.bin 2>&1)" \
  "error: 'https://gitlab.com/grp' is not a GitLab project URL (https://gitlab.com/group/project)"
check "glab missing" "$(ASSETSYNC_GLAB=/nonexistent/glab asd add https://gitlab.com/grp/proj x.bin 2>&1 | sed 's/ (.*) / /')" \
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
addc acme/src a.txt
addc acme/src b.txt --release v0
check "source: one per URL" "$(git assetsync source | oneline)" "acme/src "
check "source -v" "$(git assetsync source -v | oneline)" "acme/src${TAB}https://github.com/acme/src (2 files) "

# the release selection is the entry's: set --release, staged only; pull
# updates the file and commits both
OUT=$(git assetsync set a.txt --release 'v*' --prerelease)
check "set --release: output" "$(echo "$OUT" | head -1)" \
  "a.txt: latest release -> newest release matching v* (prereleases too)"
check "set --release: keys of the entry" "$(reg file.a.txt.release) $(reg file.a.txt.prerelease) $(reg file.b.txt.release)" "v* true v0"
check "set --release: staged" "$(git status --porcelain | oneline)" "M  .git-assetsync "
check "set --release: pending" "$(st a.txt) $(st b.txt)" "P "
pullc a.txt
check "set --release + pull: one commit" "$(cat a.txt) $(git show --name-only --format= HEAD | sort | oneline)" "s1 v2 .git-assetsync a.txt "
check "set --no-prerelease only" "$(git assetsync set a.txt --no-prerelease >/dev/null; reg file.a.txt.release) $(reg file.a.txt.prerelease)" "v* "
check "set --latest: latest again" "$(git assetsync set a.txt --latest >/dev/null; reg file.a.txt.release)" ""
pullc a.txt
check "... pulled back to the latest" "$(cat a.txt)" "s1 v1"
check "unknown source" "$(git assetsync source set-url nope https://github.com/a/b 2>&1)" \
  "error: no source 'nope' in .git-assetsync (known: acme/src)"

# a selection still in the [source] (before 0.16): an error, not the latest release
git config -f .git-assetsync source.acme/src.release v0
check "selection in the [source]: an error" "$(git assetsync status -s a.txt 2>&1 | head -1)" \
  "error: a.txt: [source \"acme/src\"] has release = v0 - the release selection is the entry's now: 'git assetsync set a.txt --release v0', then remove it from the [source] ('git assetsync edit')"
git checkout -q .git-assetsync
# rename, set-url, set-type
quiet git assetsync source rename acme/src pinned
check "rename: section and references" "$(reg source.pinned.url) $(reg file.a.txt.source) $(reg file.b.txt.source)" \
  "https://github.com/acme/src pinned pinned"
check "rename: to an existing name" "$(git assetsync source rename pinned pinned 2>&1)" "error: source 'pinned' already exists"
check "add --type: not for an existing source of another type" \
  "$(asd add -n acme/src c.txt --type gitlab 2>&1)" \
  "error: source pinned is of type (derived from the host) - change it with 'git assetsync source set-type pinned gitlab'"
git commit -q -m "rename source"
check "rename: still clean" "$(git assetsync status -s)" ""
asset s1.txt "moved v1"
release acme/moved v0 10 "$F/s1.txt"
quiet git assetsync source set-url pinned https://github.com/acme/moved.git
check "set-url" "$(reg source.pinned.url)" "https://github.com/acme/moved"
check "set-url: pending (other asset)" "$(st b.txt)" "P"
git reset -q --hard
addc acme/moved o.txt
check "set-url: a URL another source has" "$(git assetsync source set-url pinned acme/moved 2>&1)" \
  "error: source 'acme/moved' already has this URL - move the files to it with 'git assetsync set <file>... --source acme/moved'"
git reset -q --hard HEAD~1
check "set-type" "$(git assetsync source set-type pinned gitlab >/dev/null; reg source.pinned.type)" "gitlab"
check "set-type --unset" "$(git assetsync source set-type pinned --unset >/dev/null; reg source.pinned.type)" ""
check "set-type: unknown" "$(git assetsync source set-type pinned svn 2>&1)" "error: unknown type 'svn' (supported: github, gitlab)"
git reset -q --hard

# the asset of a file: changed with add --force
asset other.txt other
release acme/src v3 12 "$F/s1.txt" "$F/other.txt"
check "two assets now: hint at set" "$(git assetsync status a.txt 2>&1 | head -1)" \
  "error: a.txt: release v3 of acme/src has 2 assets: other.txt, s1.txt - choose one with 'git assetsync set a.txt --asset PATTERN'"
quiet asd add --force acme/src a.txt --asset 's1*'
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
addc acme/set x.bin --asset x.bin --release v1
addc acme/set y.bin --asset y.bin --release v1
check "nothing to change" "$(git assetsync set x.bin 2>&1)" \
  "error: nothing to change: give --source, --release/--latest/--prerelease, --asset/--no-asset or --filter/--no-filter"
check "same selection: nothing to change" "$(git assetsync set x.bin --release v1)" "nothing to change"

# another release selection for one file of two: only its entry
OUT=$(git assetsync set x.bin --latest)
check "set --latest: the entry" "$(echo "$OUT" | head -1) $(reg file.x.bin.release) $(reg file.y.bin.release)" \
  "x.bin: release v1 -> latest release  v1"
check "set: staged only" "$(git status --porcelain | oneline)" "M  .git-assetsync "
check "set: base kept" "$(reg file.x.bin.synced)" "v1"
check "set: pending" "$(st x.bin)" "P"
check "set: other file unchanged" "$(st y.bin)" ""
pullc x.bin
check "set + pull" "$(cat x.bin) $(git log -1 --format=%s)" "x v2 [assetsync] Update x.bin to acme/set v2 (was v1)"
check "set -n: nothing changed" "$(git assetsync set -n y.bin --latest | head -1; git status --porcelain)" \
  "would: y.bin: release v1 -> latest release"

# another project (a fork): base kept, the asset counts as unknown
OUT=$(git assetsync set x.bin --source me/set-fork)
check "set --source: output" "$(echo "$OUT" | head -1)" \
  "x.bin: source acme/set -> me/set-fork (https://github.com/me/set-fork)"
check "... a new source, the old one stays while used" "$(reg file.x.bin.source) $(reg source.me/set-fork.url) $(reg source.acme/set.url)" \
  "me/set-fork https://github.com/me/set-fork https://github.com/acme/set"
check "set --source: synced removed, base kept" "$(reg file.x.bin.synced)|$(reg file.x.bin.blob)" "|$(git rev-parse HEAD:x.bin)"
check "set --source: still unmodified" "$(git assetsync status x.bin | grep -c 'pending:    x.bin  (entry changed, release v2)')" "1"
pullc x.bin
check "set --source + pull" "$(cat x.bin) $(git log -1 --format=%s)" "fork x v2 [assetsync] Update x.bin to me/set-fork v2"
# local modifications stay modifications
echo mine > x.bin && git commit -qam mine
quiet git assetsync set x.bin --source https://github.com/acme/set
check "set: modified stays modified" "$(st x.bin)" "PM"
git reset -q --hard HEAD~1

# another asset of the same release; the same content: only the entry
quiet git assetsync set y.bin --asset 'y*'
pullc y.bin
check "set --asset, same file: recorded" "$(git log -1 --format=%s) $(reg file.y.bin.asset)" \
  "[assetsync] Record y.bin as acme/set v1 (file unchanged) y*"
quiet git assetsync set y.bin --asset x.bin
check "set --asset: pending" "$(st y.bin)" "P"
pullc y.bin
check "set --asset + pull" "$(cat y.bin) $(git log -1 --format=%s)" "x v1 [assetsync] Update y.bin to acme/set v1"
check "set --no-asset" "$(git assetsync set y.bin --no-asset >/dev/null; reg file.y.bin.asset)" ""
git reset -q --hard
check "set --release and --latest" "$(git assetsync set y.bin --release v1 --latest 2>&1 | tail -1)" \
  "git assetsync set: error: argument --latest: not allowed with argument --release"
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
check "releases outside a repository" "$(asd source releases acme/rl | oneline)" \
  "v3      2026-10-13  (draft) v2-rc1  2026-10-12  Rel 2 RC  (prerelease) v1.1    2026-10-11  (latest) v1      2026-10-10  Rel 1 v0      2026-10-09 "
check "releases -n" "$(asd source releases acme/rl -n 2 | lines)" "2"
check "releases --assets" "$(asd source releases acme/rl --assets | tail -5 | oneline)" \
  "v1      2026-10-10  Rel 1     kib.bin    2.9 KiB     small.bin  3 bytes v0      2026-10-09     (no assets) "
new_repo r17
addc acme/rl a.bin --asset small.bin
addc acme/rl b.bin --asset small.bin --release 'v*' --prerelease
check "releases: selected by entries" "$(git assetsync source releases acme/rl | grep '^v2-rc1 ' | oneline)" \
  "v2-rc1  2026-10-12  Rel 2 RC  (prerelease, selected by b.bin) "
check "releases: latest selected" "$(git assetsync source releases acme/rl | grep '^v1.1 ')" \
  "v1.1    2026-10-11  (latest, selected by a.bin)"
check "releases of a source by name" "$(git assetsync source releases acme/rl -n 1)" \
  "v3  2026-10-13  (draft)"
check "releases: GitLab, upcoming" "$(asd source releases https://gitlab.com/grp/proj -n 2 | oneline)" \
  "v3  2026-10-30  (upcoming) v2  2026-10-11  (latest) "
check "releases: none" "$(asd source releases https://gitlab.com/grp/empty)" "no releases in grp/empty"
check "releases: unknown project" "$(asd source releases acme/nothing 2>&1)" "error: repository acme/nothing not found (or no access)"


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
filt zwin --extract --strip 1 --include 'include/*.h' 'lib/x64/*.lib' --exclude '*.pdb'
mkdir -p lib
OUT=$(asd add madler/zlib lib/zlib/ --asset 'zlib-*-win64.zip' --filter zwin 2>&1)
check "dir: added" "$(echo "$OUT" | grep '^added')" "added lib/zlib/ <- madler/zlib v1.3 (zlib-1.3-win64.zip)"
check "dir: files (ignored *.lib included)" "$(git ls-files lib | oneline)" \
  "lib/zlib/include/zconf.h lib/zlib/include/zlib.h lib/zlib/lib/x64/zlib.lib "
check "dir: [dir] entry with its filter" "$(reg dir.lib/zlib.filter) $(git config -f .git-assetsync --get-all filter.zwin.step | oneline)" \
  "zwin extract strip 1 include 'include/*.h' 'lib/x64/*.lib' exclude '*.pdb' "
check "dir: tree as staged" "$(reg dir.lib/zlib.tree)" "$(git write-tree --prefix=lib/zlib/)"
check "dir: filterhash" "$(reg dir.lib/zlib.filterhash | wc -c | tr -d ' ')" "17"
git commit -q --no-edit
check "dir: message" "$(git log -1 --format=%B | grep -E '^(\[assetsync\] Add|Filter|Files)' | oneline)" \
  "[assetsync] Add lib/zlib/ from madler/zlib v1.3 Filter:  zwin Files:   3 added, 0 removed, 0 changed (3 in total) "
check "dir: clean" "$(st) $(git status --porcelain)" " "
check "dir: nothing to pull" "$(git assetsync status | tail -1)" "nothing to pull, 1 directory unmodified"
check "dir: status -v" "$(git assetsync status -v | grep -c "unmodified: lib/zlib/  (zlib-\*-win64.zip from madler/zlib, latest release, filter zwin;")" "1"
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
check "dir: message" "$(git log -1 --format=%B | grep -E '^(\[assetsync\] Update|Files)' | oneline)" \
  "[assetsync] Update lib/zlib/ to madler/zlib v1.3.1 (was v1.3) Files:   1 added, 1 removed, 1 changed (3 in total) "
check "dir: clean after pull" "$(st) $(git status --porcelain)" " "

# local modifications: only the files of the release count - files of
# others there (untracked or committed) and ignored ones don't
echo build > lib/zlib/build.log
check "dir: ignored file: no modification" "$(st)" ""
echo mine > lib/zlib/mine.h
check "dir: a file of others: no modification" "$(st)" ""
git add lib/zlib/mine.h && git commit -qm "a file of mine"
check "... also committed" "$(st)" ""
echo changed >> lib/zlib/include/zlib.h
check "dir: changed file: modified" "$(st)" " M"
check "dir: NOT ALLOWED" "$(git assetsync status | grep -cE "^${TAB}modified:[[:space:]]+lib/zlib/  \(NOT ALLOWED\)")" "1"
# commands that only look store nothing in the repository (also with files of
# others there, untracked ones too)
echo untracked > lib/zlib/other.txt
OBJ=$(find .git/objects -type f | lines)
quiet git assetsync status; quiet git assetsync status -s; quiet git assetsync diff
quiet git assetsync difftool -y -- -x true; quiet git assetsync verify lib/zlib
check "status, diff, verify: no new objects" "$(find .git/objects -type f | lines)" "$OBJ"
rm lib/zlib/other.txt
check "dir: pull refused" "$(rc pullcm lib/zlib)" "2"
git commit -qam "local change"
check "dir: committed modification" "$(st)" " M"
pullc --overwrite lib/zlib
check "dir: --overwrite restores" "$(cat lib/zlib/include/zlib.h) $(git log -1 --format=%s)" "zlib 1.3.1 [assetsync] Restore lib/zlib/ from madler/zlib v1.3.1"
check "dir: --overwrite: files of others and ignored ones kept" "$(ls lib/zlib | oneline)" "build.log include lib mine.h "
check "dir: clean after restore" "$(st) $(git status --porcelain)" " "

# another filter (set): pending, pulled from the cache
filt zh --extract --strip 1 --include 'include/*.h'
quiet git assetsync set lib/zlib --filter zh
check "set filter: staged" "$(reg dir.lib/zlib.filter) $(git status --porcelain | oneline)" "zh M  .git-assetsync "
check "set filter: pending" "$(git assetsync status | grep -c 'pending:    lib/zlib/  (filter changed)')" "1"
reset_calls
pullc lib/zlib
check "filter changed: pulled, the files of others kept" "$(git ls-files lib | oneline)" "lib/zlib/include/new.h lib/zlib/include/zlib.h lib/zlib/mine.h "
check "filter changed: message" "$(git log -1 --format=%s)" "[assetsync] Update lib/zlib/ from madler/zlib v1.3.1 (filter changed)"
check "filter changed: no download (cache)" "$(downloads)" "0"
check "set --no-filter" "$(git assetsync set lib/zlib --no-filter; reg dir.lib/zlib.filter)" \
  "lib/zlib/: filter zh -> (none)
.git-assetsync staged (use \"git assetsync status\" to see what changes, \"git assetsync pull <file>...\" to update)"
check "set --filter: unknown" "$(git assetsync set lib/zlib --filter nope 2>&1)" \
  "error: no filter 'nope' in .git-assetsync - define it first with 'git assetsync filter add nope ...'"
git reset -q --hard

# entries must not overlap
check "overlap: file in a dir" "$(asd add madler/zlib lib/zlib/x.txt --asset checksums.txt 2>&1)" \
  "error: cannot add 'lib/zlib/x.txt': overlaps with the entry for lib/zlib - entries must not overlap"
check "overlap: dir around a dir" "$(asd add madler/zlib lib/ --asset checksums.txt 2>&1)" \
  "error: cannot add 'lib/': overlaps with the entry for lib/zlib - entries must not overlap"
git config -f .git-assetsync file.lib/zlib/y.txt.source madler/zlib
check "overlap in the registry: error" "$(git assetsync status 2>&1 | grep -c 'overlaps with the entry for')" "2"
git checkout -q .git-assetsync

# a file from an archive; a filter giving several files for a file
mkdir -p "$T/b/firmware" && echo fw > "$T/b/firmware/fw.bin" && echo doc > "$T/b/firmware/doc.txt"
mkarchive "$F/bundle.zip" "$T/b"
release acme/bundle v1 10 "$F/bundle.zip"
filt fwbin --extract --include fw.bin
filt ex --extract
filt fwsub --extract --subdir firmware
quiet asd add acme/bundle fw.bin --filter fwbin
check "file from an archive" "$(cat fw.bin) $(reg file.fw.bin.filter)" "fw fwbin"
check "file: several files" "$(asd add acme/bundle two.bin --filter ex 2>&1)" \
  "error: two.bin: the filter gives 2 files, a file needs exactly one - narrow the filter, or add 'two.bin/' as a directory"
check "dir from the same archive" "$(asd add -n acme/bundle fwdir/ --filter fwsub)" \
  "would add fwdir/ from acme/bundle v1 (bundle.zip, latest release, filter fwsub)"
check "add --filter: unknown" "$(asd add acme/bundle x/ --filter nope 2>&1)" \
  "error: no filter 'nope' in .git-assetsync - define it first with 'git assetsync filter add nope ...'"
git reset -q --hard; rm -f fw.bin

# a directory of all assets (no --asset); a guard against many or big ones
asset a1.txt a1; asset a2.txt a2
release acme/many-assets v1 10 "$F/a1.txt" "$F/a2.txt"
OUT=$(asd add acme/many-assets all/ 2>/dev/null)
check "all assets: listed" "$(echo "$OUT" | head -1)" "all/: all 2 assets of acme/many-assets v1: a1.txt (3 bytes), a2.txt (3 bytes)"
check "all assets: taken" "$(git ls-files all | oneline)" "all/a1.txt all/a2.txt "
check "all assets: message" "$(sed -n 1,5p .git/SQUASH_MSG | grep Assets)" "Assets:  a1.txt, a2.txt"
git reset -q --hard; rm -rf all
i=1; set --
while [ $i -le 11 ]; do asset "m$i.txt" "m$i"; set -- "$@" "$F/m$i.txt"; i=$((i + 1)); done
release acme/eleven v1 10 "$@"
check "more than 10 assets: all taken" "$(asd add acme/eleven many/ >/dev/null 2>&1; git ls-files many | lines)" "11"
check "dir --asset with several matches" "$(asd add -n acme/eleven m1/ --asset 'm1*' | sed 's/(.*,/(...,/')" \
  "would add m1/ from acme/eleven v1 (..., latest release)"
git reset -q --hard; rm -rf many

# a directory with files of others: the release's files go next to them; one
# in the way only with --overwrite
mkdir -p own && echo mine > own/mine.txt
check "dir with files of others: added next to them" "$(asd add acme/many-assets own/ >/dev/null 2>&1; ls own | oneline)" \
  "a1.txt a2.txt mine.txt "
git reset -q --hard; rm -rf own
mkdir -p own && echo mine > own/mine.txt && echo old > own/a1.txt
check "a file of others in the way: refused" "$(asd add acme/many-assets own/ 2>&1 >/dev/null)" \
  "error: 'own/': files of others in the way of the release: own/a1.txt - use --overwrite to replace them"
check "... also with --force" "$(asd add --force acme/many-assets own/ 2>&1 >/dev/null | tail -1)" \
  "error: 'own/': files of others in the way of the release: own/a1.txt - use --overwrite to replace them"
quiet asd add --overwrite acme/many-assets own/
check "with --overwrite: replaced, the others kept" "$(ls own | oneline)$(cat own/a1.txt)" "a1.txt a2.txt mine.txt a1"
check "... only the release's files staged" "$(git status --porcelain own | oneline)" "A  own/a1.txt A  own/a2.txt ?? own/mine.txt "
git reset -q --hard; rm -rf own

# a hand-written [dir] entry: pull fetches it
printf '[source "h"]\n\turl = https://github.com/acme/many-assets\n[dir "hand"]\n\tsource = h\n' > .git-assetsync
git add .git-assetsync && git commit -qm "hand-written dir"
check "hand-written dir: new" "$(st hand)" "N"
pullc hand
check "hand-written dir: pulled" "$(git ls-files hand | oneline) $(git log -1 --format=%s)" "hand/a1.txt hand/a2.txt  [assetsync] Add hand/ from h v1"

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
mkdir -p eol/sub && printf 'x\r\ny\r\n' > eol/sub/keep.txt && printf 'two\r\n' > eol/two.txt
printf 'bin\000two\n' > eol/two.bin
mkarchive "$F/eol.tar.gz" eol
release acme/eol-dir v1 10 "$F/eol.tar.gz"
new_repo r18b
printf '* text=auto\n' > .gitattributes
if git lfs version >/dev/null 2>&1; then printf '*.bin filter=lfs diff=lfs merge=lfs -text\n' >> .gitattributes; fi
git add .gitattributes && git commit -qm attrs
filt ex --extract
mkdir -p d/sub && printf '*.txt -text\n' > d/sub/.gitattributes && git add d && git commit -qm "attributes of mine"
addc acme/eol-dir d/ --filter ex
check "dir: text=auto: normalized" "$(git cat-file -p HEAD:d/crlf.txt | od -c | grep -c '\\r')" "0"
if git lfs version >/dev/null 2>&1; then
  check "dir: LFS: pointer" "$(git cat-file -p HEAD:d/data.bin | head -1)" "version https://git-lfs.github.com/spec/v1"
fi
check "dir: eol/LFS: clean" "$(st) $(git status --porcelain)" " "
check "dir: a .gitattributes of mine there counts" "$(git cat-file -p HEAD:d/sub/keep.txt | od -c | grep -c '\\r')" "1"
check "dir: eol/LFS: verify stores them alike" "$(git assetsync verify d)" "d/: verified (v1)"

# GitLab: a directory of several assets (no digests)
asset g1.txt g1; asset g2.txt g2
release --host gitlab.com grp/dir v1 10 "$F/g1.txt" "$F/g2.txt"
addc https://gitlab.com/grp/dir gl/
check "GitLab dir" "$(git ls-files gl | oneline) $(st gl)" "gl/g1.txt gl/g2.txt  "
asset g1.txt "g1 v2"
release --host gitlab.com grp/dir v2 11 "$F/g1.txt" "$F/g2.txt"
pullc gl
check "GitLab dir: pulled" "$(cat gl/g1.txt) $(git log -1 --format=%B | grep Files)" "g1 v2 Files:   0 added, 0 removed, 1 changed (2 in total)"
addc acme/tool t.bin --asset 'tool-*.bin'
check "files and directories unmodified" "$(git assetsync status | tail -1)" "nothing to pull, all 1 file and 2 directories unmodified"


# =============================================================================
section "19. Archives: formats, executables, unsafe members"
# =============================================================================
cd "$T"
mkdir -p fmt/sub && echo one > fmt/one.txt && echo two > fmt/sub/two.txt && printf '#!/bin/sh\n' > fmt/run.sh
new_repo r19
filt ex --extract
filt ex-strip --extract --strip 1
filt ex-subdir --extract --subdir nope
filt ex-c --extract --include '*.c'
for ext in zip tar tar.gz tgz tar.bz2 tar.xz; do
  mkarchive "$F/fmt.$ext" "$T/fmt"
  release acme/fmt-$ext v1 10 "$F/fmt.$ext"
  quiet asd add acme/fmt-$ext "x-$ext/" --filter ex
  check "extract $ext" "$(git ls-files -s "x-$ext" | awk '{print $1, $4}' | oneline)" \
    "100644 x-$ext/one.txt 100755 x-$ext/run.sh 100644 x-$ext/sub/two.txt "
done
printf 'plain\n' | gzip > "$F/plain.txt.gz"
release acme/gz v1 10 "$F/plain.txt.gz"
quiet asd add acme/gz plain.txt --filter ex
check "extract a .gz file" "$(cat plain.txt)" "plain"
# a step that matches nothing does nothing; only no files at all is an error
check "extract: a file that isn't an archive" "$(asd add acme/many-assets x/ --filter ex 2>&1 >/dev/null)" \
  "error: x/ filter ex: 'extract': 'a1.txt' is not an archive (zip, tar, tar.gz/bz2/xz, .gz/.bz2/.xz, 7z) - choose the archives with a pattern"
check "strip: files with fewer directories left out" "$(asd add acme/fmt-zip x/ --filter ex-strip >/dev/null 2>&1; git ls-files x | oneline)" \
  "x/two.txt "
git reset -q --hard; git clean -qfd
check "subdir missing: no files left" "$(asd add acme/fmt-zip x/ --filter ex-subdir 2>&1)" \
  "error: x/: the filter leaves no files"
check "nothing left" "$(asd add acme/fmt-zip x/ --filter ex-c 2>&1)" \
  "error: x/: the filter leaves no files"
git reset -q --hard; git clean -qfd

for kind in slip abs symlink git case winname dup; do
  for ext in zip tar; do
    mkevil "$F/evil-$kind.$ext" $kind
    release acme/evil-$kind-$ext v1 10 "$F/evil-$kind.$ext"
    OUT=$(asd add acme/evil-$kind-$ext "e/" --filter ex 2>&1)
    check "unsafe $kind ($ext): refused" "$(echo "$OUT" | grep -c '^error: e/[ :]')" "1"
    check "unsafe $kind ($ext): nothing written" "$(ls -A e 2>/dev/null; git status --porcelain; ls ../evil.txt 2>/dev/null)" ""
  done
done
mkevil "$F/evil-hardlink.tar" hardlink
release acme/evil-hardlink v1 10 "$F/evil-hardlink.tar"
check "unsafe hardlink (tar): refused" "$(asd add acme/evil-hardlink e/ --filter ex 2>&1 | grep '^error')" \
  "error: e/ filter ex: evil-hardlink.tar: 'hard' is a hard link"
printf 'PK\003\004broken' > "$F/broken.zip"
release acme/broken v1 10 "$F/broken.zip"
check "broken archive" "$(asd add acme/broken e/ --filter ex 2>&1 | grep -c '^error: e/ filter ex: broken.zip: cannot unpack')" "1"
# the executable bit as the release gives it, also committed by pull with
# core.filemode=false (Windows), where git takes modes from the index or HEAD
git reset -q --hard; git clean -qfd
mkdir -p "$T/xb1" "$T/xb2"; printf 'x\n' > "$T/xb1/run.sh"; printf 'x\n' > "$T/xb2/run.txt"
mkarchive "$F/xb1.tar" "$T/xb1"; mkarchive "$F/xb2.tar" "$T/xb2"
release acme/xbit v1 10 "$F/xb1.tar"
git config core.filemode false
filt ex-run --extract --move 'run.*' run
addc acme/xbit run --filter ex-run
check "executable: committed" "$(git ls-tree HEAD run | cut -d' ' -f1)" "100755"
release acme/xbit v2 11 "$F/xb2.tar"
pullc run
check "... no longer executable: pulled" "$(git ls-tree HEAD run | cut -d' ' -f1) $(git ls-files -s run | cut -d' ' -f1)" "100644 100644"
release acme/xbit v3 12 "$F/xb1.tar"
pullc run
check "... executable again: pulled" "$(git ls-tree HEAD run | cut -d' ' -f1) $(git ls-files -s run | cut -d' ' -f1)" "100755 100755"
git config --unset core.filemode


# =============================================================================
section "20. Download cache"
# =============================================================================
cd "$T"
asset c.txt cached
release acme/cache v1 10 "$F/c.txt"
release --host gitlab.com grp/cache v1 10 "$F/c.txt"
new_repo r20
reset_calls
quiet asd add acme/cache a.txt
quiet asd add acme/cache b.txt
check "cache: downloaded once (GitHub, by digest)" "$(downloads)" "1"
check "cache: stored by SHA-256" "$(ls "$ASSETSYNC_CACHE/sha256" | grep -c "^$(sha "$F/c.txt")\$")" "1"
N=$(ls "$ASSETSYNC_CACHE/sha256" | lines)
reset_calls
quiet asd add https://gitlab.com/grp/cache c.txt
quiet asd add https://gitlab.com/grp/cache d.txt
check "cache: downloaded once (GitLab, by the index)" "$(downloads)" "1"
check "cache: same content once" "$(ls "$ASSETSYNC_CACHE/sha256" | lines)" "$N"
# GitLab: a file of the cache deleted by hand, the asset re-uploaded since -
# the digest in the index is no promise of the platform
asset c3.txt gitlab3
release --host gitlab.com grp/cache3 v1 10 "$F/c3.txt"
quiet asd add https://gitlab.com/grp/cache3 g1.txt
rm "$ASSETSYNC_CACHE/sha256/$(sha "$F/c3.txt")"
printf 'gitlab3, re-uploaded\n' > "$GH/gitlab.com/grp/cache3/1/assets/c3.txt"
check "cache: GitLab file deleted by hand, asset re-uploaded" \
  "$(asd add https://gitlab.com/grp/cache3 g2.txt 2>&1 | grep -c '^error'; cat g2.txt)" "0
gitlab3, re-uploaded"
# GitLab: a link pointing to another URL (same link id) is another file
asset c4.txt gitlab4
release --host gitlab.com grp/cache4 v1 10 "$F/c4.txt"
quiet asd add https://gitlab.com/grp/cache4 h.txt && git commit -q --no-edit
sedi 's/"links": "api"/"links": "upload"/' "$GH/gitlab.com/grp/cache4/1/release.json"
printf 'gitlab4, new link\n' > "$GH/gitlab.com/grp/cache4/1/assets/c4.txt"
check "GitLab: a link to another URL pending (assetid)" "$(st h.txt)" "P"
check "cache: GitLab link to another URL: not the cached file" "$(git assetsync verify h.txt | grep -c 'verified')" "0"
reset_calls
check "cache: pull --overwrite from the cache" "$(echo x > a.txt; git commit -qam x; pullcm --overwrite a.txt >/dev/null 2>&1; cat a.txt) $(downloads)" "cached 0"
rm -rf "$ASSETSYNC_CACHE"
check "cache: deleted cache is filled again" "$(asd add acme/cache e.txt >/dev/null 2>&1; ls "$ASSETSYNC_CACHE/sha256" | lines)" "1"
check "cache: unusable" "$(ASSETSYNC_CACHE=$T/r20/a.txt/x asd add acme/cache f.txt 2>&1 | sed 's/ (.*) / /' | tr '\\' /)" \
  "error: cannot create the download cache $T/r20/a.txt/x - set ASSETSYNC_CACHE to another directory"
# cache: list, prune, clear (with a cache of its own here)
check "cache list: what it is" "$(git assetsync cache list | grep -c '  github.com/acme/cache  v1  c.txt$')" "1"
SAVED_CACHE=$ASSETSYNC_CACHE; export ASSETSYNC_CACHE=$T/cache20
printf 'content1\n' > "$F/x1.txt"; printf 'content2\n' > "$F/x2.txt"
release acme/cache2 v1 10 "$F/x1.txt" "$F/x2.txt"
quiet asd add acme/cache2 x1.txt --asset x1.txt
quiet asd add acme/cache2 x2.txt --asset x2.txt
check "cache: summary" "$(git assetsync cache | head -1 | sed 's/^.*: //')" "2 files, 18 bytes"
check "cache: limits" "$(git assetsync cache | tail -1)" \
  "cleaned up automatically: files unused for 90 days (assetsync.cacheMaxAge, assetsync.cacheMaxSize)"
check "cache dir" "$(git assetsync cache dir | tr '\\' /)" "$T/cache20"
C1=$ASSETSYNC_CACHE/sha256/$(sha "$F/x1.txt"); C2=$ASSETSYNC_CACHE/sha256/$(sha "$F/x2.txt")
touch -t 202501011200 "$C1"; touch -t 202506011200 "$C2"
check "cache list: last used, newest first" "$(git assetsync cache list | sed 's/^ *//' | oneline)" \
  "9 bytes  2025-06-01  github.com/acme/cache2  v1  x2.txt 9 bytes  2025-01-01  github.com/acme/cache2  v1  x1.txt "
check "cache prune -n" "$(git assetsync cache prune -n | tail -1)" "would remove 2 files (18 bytes) from the download cache"
check "cache prune -n: nothing removed" "$(ls "$ASSETSYNC_CACHE/sha256" | lines)" "2"
check "cache prune --max-size: least recently used" \
  "$(git assetsync cache prune --older-than 100000 --max-size 10 | head -1 | sed 's/  */ /g')" \
  "removed 9 bytes 2025-01-01 github.com/acme/cache2 v1 x1.txt"
check "cache prune: its index entry too" "$(ls "$ASSETSYNC_CACHE/sha256" | lines) $(ls "$ASSETSYNC_CACHE/index" | lines)" "1 1"
check "cache: used again = kept" "$(asd add acme/cache2 x1b.txt --asset x2.txt >/dev/null 2>&1; git assetsync cache prune | tail -1)" \
  "removed 0 files (0 bytes) from the download cache - files used in the last minutes are kept"
touch -t 202501011200 "$ASSETSYNC_CACHE/sha256/.tmp-1-abc"
quiet git assetsync cache prune
check "cache prune: leftovers" "$(ls -a "$ASSETSYNC_CACHE/sha256" | grep -c tmp)" "0"
check "cache clear" "$(git assetsync cache clear | tail -1)" "removed 1 file (9 bytes) from the download cache"
check "cache: empty" "$(git assetsync cache list | grep -c 'is empty')" "1"
check "cache prune: nothing recent, no hint about it" "$(git assetsync cache prune)" \
  "removed 0 files (0 bytes) from the download cache"
check "cache prune --max-size: bad size" "$(git assetsync cache prune --max-size lots 2>&1)" \
  "error: 'lots' is not a size like 500M or 2G"
check "cache: bad cacheMaxAge" "$(git -c assetsync.cacheMaxAge=soon assetsync cache 2>&1)" \
  "error: assetsync.cacheMaxAge: 'soon' is not a number of days"
check "cache: no limits" "$(git -c assetsync.cacheMaxAge=off assetsync cache prune)" \
  "no limits set (assetsync.cacheMaxAge, assetsync.cacheMaxSize) - nothing to do"
# automatically after a download, at most once a day
git config assetsync.cacheMaxAge 30
quiet pullcm --overwrite x1.txt          # downloads x1 again
touch -t 202501011200 "$C1"
echo x > x2.txt; git commit -qam x; quiet pullcm --overwrite x2.txt
check "cache: automatic, not twice a day" "$(ls "$ASSETSYNC_CACHE/sha256" | lines)" "2"
touch -t 202501011200 "$ASSETSYNC_CACHE/last-prune"; rm "$C2"
echo y > x2.txt; git commit -qam y; quiet pullcm --overwrite x2.txt
check "cache: automatic after a download" "$(ls "$ASSETSYNC_CACHE/sha256" | grep -c "$(sha "$F/x1.txt")")" "0"
git config --unset assetsync.cacheMaxAge
export ASSETSYNC_CACHE=$SAVED_CACHE


# =============================================================================
section "21. 7z archives (an external 7-Zip)"
# =============================================================================
cd "$T"
FAKE7Z="\"$PYTHON\" \"$TD/fake_7z.py\""
new_repo r21
filt ex --extract
filt exnd --extract --exclude doc.txt
# x7 NAME JSON - release acme/7z-NAME with the fake archive NAME.7z
x7() { mkfake7z "$F/$1.7z" "$2" && release acme/7z-$1 v1 10 "$F/$1.7z"; }
x7 ok '[{"path": "a.txt", "content": "a"}, {"path": "sub", "attrs": "D drwxr-xr-x"},
        {"path": "sub/run.sh", "content": "run", "attrs": "A -rwxr-xr-x"},
        {"path": "win.txt", "content": "w", "attrs": "A"}]'
ASSETSYNC_7Z=$FAKE7Z quiet asd add acme/7z-ok ok/ --filter ex
check "7z: unpacked" "$(git ls-files -s ok | awk '{print $1, $4}' | oneline)" \
  "100644 ok/a.txt 100755 ok/sub/run.sh 100644 ok/win.txt "
check "7z: listing checked first" "$(head -1 "$GH/7z.log" | cut -d' ' -f1-3)" "l -sccUTF-8 -slt"
rm -f "$GH/7z.log"
check "7z: older 7-Zip without -scc" "$(git reset -q --hard; FAKE_7Z_OLD=1 ASSETSYNC_7Z=$FAKE7Z asd add acme/7z-ok ok2/ --filter ex >/dev/null 2>&1; git ls-files ok2 | lines) $(grep -c -- '-scc' "$GH/7z.log") $(lines < "$GH/7z.log")" "3 2 4"
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
  OUT=$(ASSETSYNC_7Z=$FAKE7Z asd add acme/7z-$name e/ --filter ex 2>&1)
  check "7z: $name refused" "$(echo "$OUT" | grep -c "^error: e/ filter ex: $name.7z.*$msg")" "1"
  check "7z: $name: nothing written" "$(ls -A e 2>/dev/null; git status --porcelain; ls ../evil.txt 2>/dev/null)" ""
done
if ! command -v cygpath >/dev/null; then    # symbolic links: not on Windows
  x7 sneaky '[{"path": "a.txt", "content": "a"}, {"path": "x", "sneaky_link": "/etc"}]'
  check "7z: link unpacked although listed as a file: refused" \
    "$(ASSETSYNC_7Z=$FAKE7Z asd add acme/7z-sneaky e/ --filter ex 2>&1 | grep '^error')" \
    "error: e/ filter ex: sneaky.7z: 'x' is no regular file"
fi
check "7z: 7-Zip not runnable" "$(ASSETSYNC_7Z=/nonexistent/7z asd add acme/7z-ok e/ --filter ex 2>&1 | grep '^error' | sed 's/ (.*) / /')" \
  "error: cannot run 7-Zip '/nonexistent/7z' - install it or set ASSETSYNC_7Z"
check "7z without --filter ex: kept as it is" "$(ASSETSYNC_7Z=/nonexistent/7z asd add -n acme/7z-ok raw/)" \
  "would add raw/ from acme/7z-ok v1 (ok.7z, latest release)"
if ! command -v cygpath >/dev/null; then
  # no 7-Zip at all: a PATH with only git and Python
  mkdir -p "$T/only" && ln -sf "$(command -v git)" "$T/only/git" && ln -sf "$(command -v "$PYTHON")" "$T/only/$PYTHON"
  check "7z: no 7-Zip" "$(PATH=$T/only "$PYTHON" "$S" add acme/7z-ok e/ --filter ex 2>&1 | grep '^error')" \
    "error: e/ filter ex: ok.7z is a 7z archive: unpacking it needs 7-Zip - install it (https://www.7-zip.org; 7zz or 7z) or set ASSETSYNC_7Z"
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
  quiet asd add acme/real7z real/ --filter exnd
  check "real 7-Zip: unpacked" "$(git ls-files real | oneline)" "real/inc/x.h real/run.sh "
  if ! command -v cygpath >/dev/null; then   # no executable bit in archives made on Windows
    check "real 7-Zip: executable" "$(git ls-files -s real/run.sh | cut -c1-6)" "100755"
    ln -s doc.txt "$T/s7/link"
    (cd "$T/s7" && "$SZ" a -bd -snl "$F/reallink.7z" doc.txt link >/dev/null)
    release acme/real7zlink v1 10 "$F/reallink.7z"
    # only if this 7-Zip stored the link as one (p7zip on macOS follows it)
    if "$SZ" l -slt "$F/reallink.7z" | grep -q '^Attributes = .* l'; then
      check "real 7-Zip: symbolic link refused" "$(asd add acme/real7zlink rl/ --filter ex 2>&1 | grep '^error')" \
        "error: rl/ filter ex: reallink.7z: 'link' is a symbolic link"
    else
      check "real 7-Zip: link stored as a file: a file" "$(asd add acme/real7zlink rl/ --filter ex >/dev/null 2>&1; git ls-files rl | oneline)" "rl/doc.txt rl/link "
    fi
  fi
fi


# =============================================================================
section "22. Filter steps in order, move / copy, named filters"
# =============================================================================
cd "$T"
mkdir -p pk/boards/boardA pk/boards/boardB pk/src/x pk/src/y pk/lib
echo A > pk/boards/boardA/app.bin; echo B > pk/boards/boardB/app.bin; echo r > pk/boards/boardA/README
echo a > pk/src/x/a.h; echo b > pk/src/y/b.h; echo z > pk/lib/z.lib
mkarchive "$F/pkg.zip" "$T/pk"
printf 'fw\000' > "$F/fw.bin"
release acme/pk v1 10 "$F/pkg.zip" "$F/fw.bin"
new_repo r22
# steps in the order of the options, one per option; its patterns count together
filt ord --include '*.zip' --extract --include '*.h' '*.lib' --exclude 'z*'
check "order: as given" "$(git config -f .git-assetsync --get-all filter.ord.step | oneline)" \
  "include '*.zip' extract include '*.h' '*.lib' exclude 'z*' "
quiet asd add acme/pk o/ --filter ord
check "order: result" "$(git ls-files o | oneline)" "o/src/x/a.h o/src/y/b.h "
git reset -q --hard; rm -rf o
filt ordm --include '*.zip' --extract --include '*.h' --include '*.lib' --exclude 'z*' 'q*'
check "two --include options: two steps" "$(git config -f .git-assetsync --get-all filter.ordm.step | oneline)" \
  "include '*.zip' extract include '*.h' include '*.lib' exclude 'z*' 'q*' "

# move / copy
filt mv --extract --move '*.h' include/ --move 'boards/*/app.bin' 'firmware/{parent}.bin' \
  --copy 'lib/*.lib' 'libs/{stem}-copy{ext}' --move 'boards/' 'docs/{path}'
quiet asd add acme/pk m/ --asset pkg.zip --filter mv
check "move/copy: result" "$(git ls-files m | oneline)" \
  "m/docs/boards/boardA/README m/firmware/boardA.bin m/firmware/boardB.bin m/include/a.h m/include/b.h m/lib/z.lib m/libs/z-copy.lib "
check "move: content follows" "$(cat m/firmware/boardB.bin)" "B"
git commit -q --no-edit
check "move/copy: clean" "$(st m)" ""
filt coll --extract --move app.bin bin/
filt anch --extract --move '*/app.bin' bin/
filt repl --extract --move src/x/a.h src/y/b.h
filt nomatch --extract --move '*.c' src/
filt outside --extract --move '*.h' ../up/
check "move: collision" "$(asd add acme/pk x/ --asset pkg.zip --filter coll 2>&1 | grep '^error')" \
  "error: x/ filter coll: 'move app.bin bin/': 'boards/boardA/app.bin' and 'boards/boardB/app.bin' would both become 'bin/app.bin'"
check "move: a pattern with '/' is anchored" "$(asd add acme/pk x/ --asset pkg.zip --filter anch >/dev/null 2>&1; git ls-files x/bin | lines)" "0"
git reset -q --hard; git clean -qfd
check "move: would replace" "$(asd add acme/pk x/ --asset pkg.zip --filter repl 2>&1 | grep '^error')" \
  "error: x/ filter repl: 'move src/x/a.h src/y/b.h': 'src/x/a.h' would replace 'src/y/b.h'"
check "move: no match, nothing to do" "$(rc asd add acme/pk x/ --asset pkg.zip --filter nomatch)" "0"
git reset -q --hard; git clean -qfd
check "move: unknown placeholder" "$(git assetsync filter add bad1 --move '*' '{base}' 2>&1)" \
  "error: filter step 'move '*' '{base}'': unknown placeholder {base} (known: {path}, {dir}, {parent}, {name}, {stem}, {ext})"
check "move: target outside" "$(asd add acme/pk x/ --asset pkg.zip --filter outside 2>&1 | grep -c "unsafe path '../up/a.h'")" "1"
git status --porcelain | grep -q . && git reset -q --hard
# what the pattern matches moves: a file, or a directory with all below it;
# TARGET is its new path, TARGET/ the directory it goes into, under its name
filt mvdir --extract --move src/ code
filt mvinto --extract --move src/ code/
filt mvname --extract --copy src '{name}-all'
filt mvall --extract --move '*' all/
check "move: a directory renamed (TARGET)" \
  "$(quiet asd add acme/pk x/ --asset pkg.zip --filter mvdir; git ls-files x | grep -v '^x/boards\|^x/lib' | oneline)" "x/code/x/a.h x/code/y/b.h "
git reset -q --hard; git clean -qfd
check "move: a directory into TARGET/, under its name" \
  "$(quiet asd add acme/pk x/ --asset pkg.zip --filter mvinto; git ls-files x | grep -v '^x/boards\|^x/lib' | oneline)" "x/code/src/x/a.h x/code/src/y/b.h "
git reset -q --hard; git clean -qfd
check "copy: placeholders are the directory's" \
  "$(quiet asd add acme/pk x/ --asset pkg.zip --filter mvname; git ls-files x/src-all x/src | oneline)" \
  "x/src-all/x/a.h x/src-all/y/b.h x/src/x/a.h x/src/y/b.h "
git reset -q --hard; git clean -qfd
check "move: '*' moves each top-level file and directory, as it is" \
  "$(quiet asd add acme/pk x/ --asset pkg.zip --filter mvall; git ls-files x | oneline)" \
  "x/all/boards/boardA/README x/all/boards/boardA/app.bin x/all/boards/boardB/app.bin x/all/lib/z.lib x/all/src/x/a.h x/all/src/y/b.h "
git reset -q --hard; git clean -qfd

# named filters: defined once, used per asset of one release
new_repo r22c
OUT=$(git assetsync filter add headers --extract --include '*.h' --move '*.h' include/)
check "filter add" "$(echo "$OUT" | head -1)" \
  "filter headers: extract, include '*.h', move '*.h' include/ (new); .git-assetsync staged"
check "filter add: exists" "$(git assetsync filter add headers --extract 2>&1)" \
  "error: filter 'headers' already exists (change it with 'git assetsync filter set headers ...')"
check "filter set: unknown" "$(git assetsync filter set nope --extract 2>&1)" "error: no filter 'nope' in .git-assetsync (known: headers)"
quiet git assetsync filter add fw --move '*' fw/
check "filter list: not used" "$(git assetsync filter | oneline)" "fw${TAB}(1 step; not used) headers${TAB}(3 steps; not used) "
quiet git assetsync filter add sdk --apply '*.zip' headers --apply '*.bin' fw
git commit -qm filters
quiet asd add acme/pk v/ --filter sdk
check "filter steps: branches per asset" "$(git ls-files v | oneline)" "v/fw/fw.bin v/include/a.h v/include/b.h "
check "entry: filter = name" "$(reg dir.v.filter) $(git config -f .git-assetsync --get-all dir.v.step)" "sdk "
git commit -q --no-edit
check "filter list: used by" "$(git assetsync filter | grep -E '^(headers|sdk)' | oneline)" \
  "headers${TAB}(3 steps; used by filter sdk) sdk${TAB}(2 steps; used by v/) "
check "filter show" "$(git assetsync filter show headers | oneline)" "extract include '*.h' move '*.h' include/ (used by filter sdk) "
check "filter remove: refused while used" "$(git assetsync filter remove fw 2>&1)" "error: filter 'fw' is used by filter sdk"
check "clean" "$(st v)" ""
# a changed named filter: its users are pending
quiet git assetsync filter set headers --extract --include 'a.h' --move '*.h' include/
check "changed filter: user pending" "$(git assetsync status | grep -c 'pending:    v/  (filter changed)')" "1"
pullc v
check "changed filter: pulled" "$(git ls-files v | oneline)" "v/fw/fw.bin v/include/a.h "
# renaming changes the steps and entries that use it, nothing else
quiet git assetsync filter rename headers hdr
quiet git assetsync filter rename sdk sdk2
check "rename: references" "$(git config -f .git-assetsync --get-all filter.sdk2.step | oneline)$(reg dir.v.filter)" \
  "apply '*.zip' hdr apply '*.bin' fw sdk2"
check "rename: not pending" "$(st v)" ""
git commit -q -m "rename filter"
# filter test: local files or the assets of a release; nothing else changes
check "filter test: a local file" "$(git assetsync filter test hdr "$F/pkg.zip")" "2 bytes  include/a.h"
check "filter test: a directory" "$(git assetsync filter test fw "$T/pk/src" | oneline)" "2 bytes  fw/x/a.h 2 bytes  fw/y/b.h "
check "filter test: --source" "$(git assetsync filter test sdk2 --source acme/pk 2>/dev/null | oneline)" \
  "3 bytes  fw/fw.bin 2 bytes  include/a.h "
check "filter test: --source, input and steps shown" "$(git assetsync filter test sdk2 --source acme/pk 2>&1 >/dev/null | oneline)" \
  "input: acme/pk v1: fw.bin, pkg.zip apply '*.zip' hdr  1 of 2 files -> 1 file apply '*.bin' fw   1 of 2 files -> 1 file "
check "filter test: what each step did" "$(git assetsync filter test hdr "$F/pkg.zip" 2>&1 >/dev/null | oneline)" \
  "extract              1 archive -> 6 files include a.h          6 -> 1 file move '*.h' include/  1 file moved "
check "filter test -o" "$(git assetsync filter test sdk2 --source acme/pk -o "$T/ftout" 2>/dev/null; cat "$T/ftout/include/a.h")" \
  "2 files written to $T/ftout
a"
check "filter test -o: not empty" "$(git assetsync filter test sdk2 --source acme/pk -o "$T/ftout" 2>&1 | tr '\\' /)" \
  "error: '$T/ftout' is not an empty directory"
check "filter test: no input" "$(git assetsync filter test hdr 2>&1)" \
  "error: give the input: FILE... (local files, as if they were the assets) or --source SOURCE (the assets of its release)"
check "filter test: missing file" "$(git assetsync filter test hdr nothing.zip 2>&1)" "error: 'nothing.zip' not found"
check "filter test: unknown filter" "$(git assetsync filter test nope "$F/pkg.zip" 2>&1)" "error: no filter 'nope' in .git-assetsync (known: fw, hdr, sdk2)"
check "filter test: error as in pull" "$(git assetsync filter test hdr "$F/fw.bin" 2>&1 | grep '^error')" \
  "error: filter hdr: 'extract': 'fw.bin' is not an archive (zip, tar, tar.gz/bz2/xz, .gz/.bz2/.xz, 7z) - choose the archives with a pattern"
check "filter test: extract by pattern, the rest kept" \
  "$(git assetsync filter add zips --extract '*.zip' >/dev/null && git assetsync filter test zips "$F/fw.bin" "$F/pkg.zip" 2>/dev/null | grep -cE 'fw\.bin$|a\.h$')" "2"
check "filter add: --extract with patterns" "$(git config -f .git-assetsync --get-all filter.zips.step)" "extract '*.zip'"
git reset -q .git-assetsync && git checkout -q .git-assetsync
check "filter test: nothing changed" "$(git status --porcelain)" ""
# errors
check "unknown filter in a filter" "$(git assetsync filter add x --apply '*' nope 2>&1)" "error: unknown filter 'nope' (in 'apply '*' nope')"
quiet git assetsync filter add a1 --include x
check "filter using itself" "$(git assetsync filter set a1 --apply '*' a1 2>&1)" "error: filter 'a1' uses itself (via a1)"
quiet git assetsync filter add a2 --apply '*' a1
check "filters using each other" "$(git assetsync filter set a1 --apply '*' a2 2>&1)" "error: filter 'a1' uses itself (via a1 -> a2)"
filt ren --move '*' pkg.zip
filt useren --apply fw.bin ren
check "filter result collides" "$(asd add acme/pk x/ --filter useren 2>&1 | grep '^error')" \
  "error: x/ filter useren: 'apply fw.bin ren': its 'pkg.zip' collides with a file outside the filter"
filt nom --apply '*.tar' fw
check "apply: no match, nothing applied" "$(asd add acme/pk x/ --filter nom >/dev/null 2>&1; git ls-files x | oneline)" "x/fw.bin x/pkg.zip "
git reset -q --hard; git clean -qfd
filt drop --exclude '*'
filt usedrop --apply fw.bin drop
check "apply: a filter may leave nothing of its part" "$(asd add acme/pk x/ --filter usedrop >/dev/null 2>&1; git ls-files x | oneline)" "x/pkg.zip "
git reset -q --hard; git clean -qfd
filt bad --move '*' ../up/
filt usebad --apply fw.bin bad
check "error in a nested filter: named" "$(asd add acme/pk x/ --filter usebad 2>&1 | grep -c "^error: x/ filter usebad filter bad: .*unsafe path '../up/fw.bin'")" "1"
check "invalid filter name" "$(git assetsync filter add 'a b' --extract 2>&1)" \
  "error: invalid filter name 'a b' (letters, digits, '.', '+', '-', '_')"
check "filter add without steps" "$(git assetsync filter add e 2>&1)" \
  "error: give the steps of the filter (--extract, --include, --move, ...)"
git reset -q --hard
# an entry with a missing filter, or with steps of its own
git config -f .git-assetsync dir.v.filter gone
check "entry: missing filter" "$(git assetsync status v 2>&1 | head -1)" \
  "error: v/: filter 'gone' not found in .git-assetsync (define it with 'git assetsync filter add gone ...')"
git reset -q --hard
# a registry with only filters stays
new_repo r22b
quiet git assetsync filter add only --extract
check "only a filter: registry kept" "$(git status --porcelain | oneline)" "A  .git-assetsync "


# =============================================================================
section "23. Commands in filters: convert, run, trust"
# =============================================================================
cd "$T"
printf 'hello\n' > "$F/notes.txt"
printf 'fw\n' > "$F/fw.bin"
printf 'ab\n' > "$F/data.hex"
release acme/cmd v1 10 "$F/notes.txt" "$F/fw.bin" "$F/data.hex"
new_repo r23
mkdir tools && printf 'import sys\nopen(sys.argv[2], "wb").write(open(sys.argv[1], "rb").read().upper())\n' > tools/upper.py
git add tools && git commit -qm tools
filt conv --convert '*.txt' 'gen/{stem}.TXT' "\"$PYTHON\" {root}/tools/upper.py {in} {out}" \
  --convert '*.bin' 'gen/' 'cp {in} {out}/{stem}.c && cp {in} {out}/{stem}.h' \
  --convert '*.hex' '{stem}.c' 'tr a-z A-Z < {in} > {out}'
check "convert: stored" "$(git config -f .git-assetsync --get-all filter.conv.step | head -1)" \
  "convert '*.txt' 'gen/{stem}.TXT' '\"$PYTHON\" {root}/tools/upper.py {in} {out}'"
check "not trusted: refused" "$(asd add acme/cmd c/ --filter conv 2>&1 | grep '^error')" \
  "error: filter conv runs commands and isn't trusted in this repository yet - check with 'git assetsync filter trust', then trust with 'git assetsync filter trust conv'"
check "not trusted: nothing written" "$(ls c 2>/dev/null; git status --porcelain)" ""
OUT=$(git assetsync filter trust)
check "trust: list" "$(echo "$OUT" | head -1)" "filter conv: not trusted"
check "trust: commands and scripts" "$(echo "$OUT" | grep -c '(runs tools/upper.py of this repository)')" "1"
check "trust: hint" "$(echo "$OUT" | tail -1)" \
  '  (use "git assetsync filter trust <name>..." or "git assetsync filter trust --all" to trust them in this repository)'
check "trust NAME" "$(git assetsync filter trust conv)" "filter conv: trusted"
check "trust: local config only" "$(git config --local --get-all assetsync.trusted | sed 's/^[0-9a-f]* //') $(git status --porcelain)" "conv "
quiet asd add acme/cmd c/ --filter conv
check "convert: result" "$(git ls-files c | oneline)" "c/data.c c/gen/fw.c c/gen/fw.h c/gen/notes.TXT "
check "convert: by a script of the repository" "$(cat c/gen/notes.TXT)" "HELLO"
check "convert: with sh redirection" "$(cat c/data.c)" "AB"
git commit -q --no-edit
check "convert: clean" "$(st c)" ""
# a changed script: the filter changes, and needs a new trust
printf 'import sys\nopen(sys.argv[2], "wb").write(open(sys.argv[1], "rb").read().upper() + b"!")\n' > tools/upper.py
git commit -qam "new upper"
check "changed script: pending" "$(git assetsync status | grep -c 'pending:    c/  (filter changed)')" "1"
check "changed script: warning" "$(git assetsync status | grep -c "filter conv runs commands and isn't trusted here yet")" "1"
check "changed script: trust list" "$(git assetsync filter trust | head -1)" "filter conv: changed since trusted (used by c/)"
check "changed script: pull refused" "$(rc pullcm c)" "2"
# like a terminal that ends at once (Windows takes NUL for one): not trusted
check "trust prompt at end of input: no" "$(printf '' | "$PYTHON" -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("a", sys.argv[1]); m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m); print(m.ask("q? "))' "$S" 2>/dev/null | tail -1)" "False"
quiet git assetsync filter trust --all
pullc c
check "changed script: pulled" "$(cat c/gen/notes.TXT)" "HELLO
!"
# without trust in CI: ASSETSYNC_TRUST=all
filt rn --run '*' 'cp -R {in}/. {out}/ && echo "$ASSETSYNC_RELEASE $ASSETSYNC_ENTRY {in} {out}" > {out}/env.txt'
check "ASSETSYNC_TRUST=all" "$(ASSETSYNC_TRUST=all asd add acme/cmd r/ --filter rn >/dev/null 2>&1; git ls-files r | oneline)" \
  "r/data.hex r/env.txt r/fw.bin r/notes.txt "
check "run: environment, {in} and {out}" "$(cat r/env.txt)" "v1 r/ in out"
check "ASSETSYNC_TRUST=all: not recorded" "$(git assetsync filter trust | grep '^filter rn')" "filter rn: not trusted (used by r/)"
git reset -q --hard; rm -rf r
# run with a pattern: only those files, the result replaces them
filt rp --run '*.txt' 'tr a-z A-Z < {in}/notes.txt > {out}/NOTES.txt; ls {in} > {out}/given.txt'
filt rpc --run '*.txt' 'cp {in}/notes.txt {out}/fw.bin'
filt rp0 --run '*.none' 'false'
quiet git assetsync filter trust --all
quiet asd add acme/cmd rp/ --filter rp
check "run PATTERN: only the matching files, replaced by the result" "$(git ls-files rp | oneline)$(cat rp/given.txt)" \
  "rp/NOTES.txt rp/data.hex rp/fw.bin rp/given.txt notes.txt"
git reset -q --hard; rm -rf rp
check "run PATTERN: a result at another file's path" "$(asd add acme/cmd e/ --filter rpc 2>&1 | grep -c "its 'fw.bin' collides with a file it wasn't given")" "1"
check "run PATTERN: no match, nothing done" "$(asd add acme/cmd r0/ --filter rp0 >/dev/null 2>&1; git ls-files r0 | oneline)" \
  "r0/data.hex r0/fw.bin r0/notes.txt "
git reset -q --hard; rm -rf r0
check "run without a pattern (before 0.19.0): what to write now" \
  "$(git config -f .git-assetsync filter.old.step "run 'cp -R {in}/. {out}/'"; git assetsync filter show old 2>&1 | tail -1)" \
  "error: filter step 'run 'cp -R {in}/. {out}/'': run needs a pattern first, like the other steps - for all files: run '*' 'cp -R {in}/. {out}/'"
git checkout -q .git-assetsync
# errors
filt fail --convert '*.txt' x.out 'echo broken >&2; exit 3'
filt none --convert '*.txt' x.out 'true'
filt clash --convert '*.txt' 'fw.bin' 'cp {in} {out}'
quiet git assetsync filter trust --all
check "command fails" "$(asd add acme/cmd e/ --filter fail 2>&1 | grep '^error')" \
  "error: e/ filter fail: 'convert '*.txt' x.out 'echo broken >&2; exit 3'': notes.txt: command failed (exit code 3): broken"
check "command writes nothing" "$(asd add acme/cmd e/ --filter none 2>&1 | grep '^error')" \
  "error: e/ filter none: 'convert '*.txt' x.out true': notes.txt: the command wrote no file {out}"
filt names --copy notes.txt U/notes.txt --convert 'U/*.txt' 'U/{stem}.TXT' 'echo {in} {out} > {out}' \
  --convert '*.txt' 'gen/{stem}.c' 'echo {in} {out} > {out}' --convert '*.bin' '{path}' 'echo {in} {out} > {out}' \
  --convert '*.hex' 'h/' 'echo {in} {out} > {out}/x'
quiet git assetsync filter trust names
quiet asd add acme/cmd n/ --filter names
check "convert: {in} and {out} are short names (reproducible)" "$(cat n/gen/notes.c n/fw.bin n/h/x | oneline)" \
  "notes.txt notes.c fw.bin out/fw.bin data.hex out "
check "convert: names differing only in case: out/NAME" "$(cat n/U/notes.TXT)" "notes.txt out/notes.TXT"
git reset -q --hard; rm -rf n
check "command result collides" "$(asd add acme/cmd e/ --filter clash 2>&1 | grep '^error')" \
  "error: e/ filter clash: 'convert '*.txt' fw.bin 'cp {in} {out}'': 'notes.txt' would give 'fw.bin', which is already there"
if ! command -v cygpath >/dev/null; then
  filt lnk --convert '*.txt' 'l/' 'ln -s /etc/passwd {out}/x'
  quiet git assetsync filter trust lnk
  check "command result: a link refused" "$(asd add acme/cmd e/ --filter lnk 2>&1 | grep -c "'x' is no regular file")" "1"
fi
check "errors: nothing written" "$(ls e 2>/dev/null; git status --porcelain)" ""
# filter test runs commands only if trusted, too
quiet git assetsync filter trust --revoke conv
check "trust --revoke" "$(git assetsync filter trust | grep '^filter conv')" "filter conv: not trusted (used by c/)"
check "filter test: not trusted" "$(git assetsync filter test conv "$F/notes.txt" 2>&1 | cut -c1-40)" "error: filter conv runs commands and isn"
quiet git assetsync filter trust conv
check "filter test: commands" "$(git assetsync filter test conv "$F/notes.txt" "$F/data.hex" "$F/fw.bin" | oneline)" \
  "3 bytes  data.c 3 bytes  gen/fw.c 3 bytes  gen/fw.h 7 bytes  gen/notes.TXT "
check "trust: a filter without commands" "$(git assetsync filter trust only-steps 2>&1; filt plain --extract; git assetsync filter trust plain)" \
  "error: no filter 'only-steps' in .git-assetsync
filter plain runs no commands - nothing to trust"


# =============================================================================
section "24. verify: is the committed state reproducible?"
# =============================================================================
cd "$T"
printf 'v1\n' > "$F/vf.txt"
release acme/vf v1 10 "$F/vf.txt" "$F/pkg.zip"
new_repo r24
filt hdr --extract --include '*.h' --move '*.h' include/
filt rnd --convert '*.txt' '{name}' 'echo $$ > {out}'
filt rnddir --copy vf.txt keep/v.txt --convert vf.txt 'gen/{stem}.c' 'echo $$ > {out}'
quiet git assetsync filter trust rnd rnddir
addc acme/vf f.txt --asset vf.txt
addc acme/vf d/ --asset pkg.zip --filter hdr
check "verify: all verified" "$(git assetsync verify | oneline)" "d/: verified (v1) f.txt: verified (v1) "
check "verify: exit code 0" "$(rc git assetsync verify)" "0"
check "verify -v: where they come from" "$(git assetsync verify -v | oneline)" \
  "d/: pkg.zip from acme/vf, latest release, filter hdr; synced v1 d/: verified (v1) f.txt: vf.txt from acme/vf, latest release; synced v1 f.txt: verified (v1) "
ASSETSYNC_TRUST=all addc acme/vf r.txt --asset vf.txt --filter rnd
ASSETSYNC_TRUST=all addc acme/vf rd/ --asset vf.txt --filter rnddir
check "verify: not reproducible (file)" "$(git assetsync verify r.txt)" "r.txt: differs from what v1 gives now"
check "verify: not reproducible (directory)" "$(git assetsync verify rd | oneline)" \
  "rd/: differs from what v1 gives now: ${TAB}M${TAB}gen/vf.c "
check "verify: exit code 1" "$(rc git assetsync verify)" "1"
check "verify: nothing changed" "$(git status --porcelain)" ""
# a changed filter, an entry not synced, a re-uploaded asset, a deleted release
quiet git assetsync filter set hdr --extract --include 'a.h'
check "verify: filter changed since the sync" "$(git assetsync verify d)" \
  "d/: its filter changed since the sync - pull first, then verify"
git checkout -q .git-assetsync
printf '[file "hand.txt"]\n\tsource = acme/vf\n' >> .git-assetsync
git config -f .git-assetsync source.acme/vf.url >/dev/null || true
check "verify: not synced" "$(git assetsync verify hand.txt)" "hand.txt: not synced yet, nothing to verify"
git checkout -q .git-assetsync
printf 'v1 again\n' > "$F/vf.txt"
reupload acme/vf v1 "$F/vf.txt"
check "verify: asset re-uploaded" "$(git assetsync verify f.txt 2>/dev/null)" \
  "f.txt: the assets of v1 differ from those it was synced with (re-uploaded?)"
rm -rf "$GH/github.com/acme/vf/1"
check "verify: release gone" "$(git assetsync verify f.txt 2>&1)" "error: f.txt: release v1 of acme/vf no longer exists"
check "verify: exit code 2" "$(rc git assetsync verify f.txt)" "2"
# stored differently since (moved to LFS): still the same
if git lfs version >/dev/null 2>&1; then
  printf 'bin\000\n' > "$F/vb.bin"
  release acme/vb v1 10 "$F/vb.bin"
  addc acme/vb vb.bin
  printf '*.bin filter=lfs diff=lfs merge=lfs -text\n' > .gitattributes && git add .gitattributes
  git add --renormalize . && git commit -qm "to LFS"
  check "verify: moved to LFS since" "$(git assetsync verify vb.bin)" "vb.bin: verified (v1)"
fi



# =============================================================================
section "25. diff, difftool, and pull --release (once another release)"
# =============================================================================
cd "$T"
printf 'one\ntwo\n' > "$F/df.txt"
release acme/df v1 10 "$F/df.txt"
printf 'one\ntwo changed\n' > "$F/df.txt"
release acme/df v2 11 "$F/df.txt"
mkdir -p "$F/dd1" "$F/dd2"
printf 'a\n' > "$F/dd1/a.txt"; printf 'b\n' > "$F/dd1/b.txt"
printf 'a\n' > "$F/dd2/a.txt"; printf 'b2\n' > "$F/dd2/b.txt"; printf 'c\n' > "$F/dd2/c.txt"
mkarchive "$F/dd-1.zip" "$F/dd1"; mkarchive "$F/dd-2.zip" "$F/dd2"
release acme/dd v1 10 "$F/dd-1.zip"
release acme/dd v2 11 "$F/dd-2.zip"
new_repo r25
filt unzip --extract
addc acme/df f.txt
addc acme/dd d/ --release v1 --filter unzip
quiet git assetsync set d --latest && git commit -qm latest -- .git-assetsync
check "diff: nothing to show" "$(git assetsync diff)" ""
check "diff: exit code 0" "$(rc git assetsync diff -- --exit-code)" "0"
# local changes: base -> working tree
printf 'one\nmine\n' > f.txt
check "diff: local change" "$(git assetsync diff | grep -E '^(---|\+\+\+|[-+][a-z])' | oneline)" \
  "--- synced/f.txt +++ local/f.txt -two changed +mine "
check "diff: options after --" "$(git assetsync diff -- --stat | head -1 | tr -s ' ')" " f.txt | 2 +-"
check "diff: --exit-code" "$(rc git assetsync diff -- --exit-code)" "1"
check "diff: status hints at it" \
  "$(git assetsync status | grep -c 'git assetsync diff <file>')" "1"
git commit -qam "by hand"
check "diff: committed changes are local too" "$(git assetsync diff -- --name-only)" "f.txt"
check "diff: status hints at it for a committed modification" \
  "$(git assetsync status | grep -c 'git assetsync diff <file>')" "1"
quiet pullcm --overwrite f.txt
check "diff: nothing after --overwrite" "$(git assetsync diff)" ""
# a directory: changed and deleted files; a file of others isn't shown
printf 'a mine\n' > d/a.txt; rm d/b.txt; printf 'x\n' > d/x.txt
check "diff: directory" "$(git assetsync diff d -- --name-status | oneline)" \
  "M${TAB}d/a.txt D${TAB}d/b.txt "
check "diff: only the paths given" "$(git assetsync diff f.txt)" ""
check "diff: nothing changed" "$(git status --porcelain | oneline)" " M d/a.txt  D d/b.txt ?? d/x.txt "
git checkout -q d && rm d/x.txt
# what pull would bring
check "diff --upstream" "$(git assetsync diff --upstream -- --name-status 2>/dev/null | oneline)" \
  "M${TAB}d/b.txt A${TAB}d/c.txt "
check "diff --upstream: prefixes" "$(git assetsync diff --upstream | grep -E '^\+\+\+' | oneline)" \
  "+++ upstream/d/b.txt +++ upstream/d/c.txt "
check "diff --upstream: pull takes it from the cache" \
  "$(reset_calls; quiet pullcm d; downloads)" "0"
check "diff --upstream: nothing left" "$(git assetsync diff --upstream)" ""
check "diff --upstream --release" "$(git assetsync diff --upstream --release v1 -- --name-status 2>/dev/null | oneline)" \
  "M${TAB}d/b.txt D${TAB}d/c.txt M${TAB}f.txt "
check "diff --release: requires --upstream" "$(git assetsync diff --release v1 2>&1)" \
  "error: --release requires --upstream"
check "diff --release: unknown tag" "$(git assetsync diff --upstream --release v9 f.txt 2>&1)" \
  "error: f.txt: no release with tag 'v9' in acme/df"
# pull --release: once another release, the selection stays
check "pull --release: dry run" "$(git assetsync pull -n --release v1 f.txt | head -1)" \
  "would: Update f.txt to acme/df v1 (was v2)"
out=$(pullcm --release v1 f.txt)
check "pull --release: hint" "$(printf '%s\n' "$out" | tail -1)" \
  "note: f.txt: it still selects v2 - 'git assetsync pull f.txt' goes back to it; to stay on v1: 'git assetsync set f.txt --release v1'"
check "pull --release: content" "$(cat f.txt | oneline)" "one two "
check "pull --release: synced" "$(reg file.f.txt.synced)" "v1"
check "pull --release: selection unchanged" "$(reg file.f.txt.release)" ""
check "pull --release: message" "$(git log -1 --format=%s)" "[assetsync] Update f.txt to acme/df v1 (was v2)"
check "pull --release: status pending" "$(git assetsync status -s f.txt)" "P  f.txt"
check "pull --release: up to date" "$(git assetsync pull --release v1 f.txt)" "f.txt: up to date"
check "pull --release: pattern = newest matching" "$(git assetsync pull -n --release 'v*' f.txt | head -1)" \
  "would: Update f.txt to acme/df v2 (was v1)"
check "pull --release: not with --all" "$(git assetsync pull --all --release v1 2>&1)" \
  "error: --release needs the files to pull, not --all"
check "pull --release: unknown tag" "$(git assetsync pull --release v9 f.txt 2>&1)" \
  "error: f.txt: no release with tag 'v9' in acme/df"
pullc f.txt
check "pull: back to the selected release" "$(reg file.f.txt.synced) $(cat f.txt | oneline)" "v2 one two changed "
# difftool: a fake tool prints "TOOL <dir of LOCAL> <dir/name of REMOTE>",
# with -d the files of both directories
cat > "$T/faketool.sh" <<'EOF2'
if [ -d "$1" ]; then
  echo "DIRS $(cd "$1" && find . ! -type d | sort | tr '\n' ' ')| $(cd "$2" && find . ! -type d | sort | tr '\n' ' ')"
else
  echo "TOOL $(basename "$(dirname "$1")") $(basename "$(dirname "$2")")/$(basename "$2")"
fi
EOF2
git config difftool.fake.cmd "sh '$T/faketool.sh' \"\$LOCAL\" \"\$REMOTE\""
git config diff.tool fake
check "difftool: nothing to show" "$(git assetsync difftool -y)" ""
printf 'mine\n' > f.txt; printf 'a mine\n' > d/a.txt; printf 'b mine\n' > d/b.txt
check "difftool: file by file, the working files" "$(git assetsync difftool -y | oneline)" \
  "TOOL synced-v2 d/a.txt TOOL synced-v2 d/b.txt TOOL synced-v2 r25/f.txt "
OUT=$(printf 'n\ny\n' | git assetsync difftool)
check "difftool prompt: n then y" "$(echo "$OUT" | grep -o 'TOOL .*')" "TOOL synced-v2 d/b.txt"
check "difftool prompt text" "$(echo "$OUT" | grep -c "Viewing (2/3): 'd/b.txt'")" "1"
check "difftool prompt names tool" "$(printf 'q\n' | git assetsync difftool | grep -c "Launch 'fake' \[Y/n/q\]?")" "1"
check "difftool prompt: EOF quits" "$(git assetsync difftool </dev/null | grep -c 'TOOL ')" "0"
check "difftool prompt: q quits" "$(printf 'q\n' | git assetsync difftool | grep -c 'TOOL ')" "0"
check "difftool with path: asks too, as git difftool" "$(printf 'n\n' | git assetsync difftool f.txt | grep -c 'TOOL ')" "0"
check "difftool -y with path" "$(git assetsync difftool -y f.txt </dev/null)" "TOOL synced-v2 r25/f.txt"
check "difftool.prompt = false" "$(git -c difftool.prompt=false assetsync difftool f.txt </dev/null)" "TOOL synced-v2 r25/f.txt"
check "... --prompt asks anyway" "$(printf 'n\n' | git -c difftool.prompt=false assetsync difftool --prompt f.txt | grep -c 'TOOL ')" "0"
check "-y and --prompt: the last counts" \
  "$(git assetsync difftool --prompt -y f.txt </dev/null) $(printf 'n\n' | git assetsync difftool -y --prompt f.txt | grep -c 'TOOL ')" \
  "TOOL synced-v2 r25/f.txt 0"
check "difftool -d: two directories" "$(git assetsync difftool -d)" \
  "DIRS ./d/a.txt ./d/b.txt ./f.txt | ./d/a.txt ./d/b.txt ./f.txt "
git checkout -q f.txt d
check "difftool --upstream --release: temp copies" \
  "$(git assetsync difftool -y --upstream --release v1 2>/dev/null | oneline)" \
  "TOOL synced-v2 upstream-v1/b.txt TOOL synced-v2 upstream-v1/c.txt TOOL synced-v2 upstream-v1/f.txt "
check "difftool -d --upstream --release" "$(git assetsync difftool -d --upstream --release v1 d)" \
  "DIRS ./d/b.txt ./d/c.txt | ./d/b.txt "
check "difftool --release: requires --upstream" "$(git assetsync difftool --release v1 2>&1)" \
  "error: --release requires --upstream"
# LFS: the content is compared, not the pointers
if git lfs version >/dev/null 2>&1; then
  printf 'lfs one\n' > "$F/lf.dat"
  release acme/lf v1 10 "$F/lf.dat"
  printf '*.dat filter=lfs diff=lfs merge=lfs -text\n' > .gitattributes
  git add .gitattributes && git commit -qm lfs
  addc acme/lf lf.dat
  printf 'lfs mine\n' > lf.dat
  check "diff: LFS content" "$(git assetsync diff lf.dat | grep -E '^[-+][a-z]' | oneline)" "-lfs one +lfs mine "
fi


# =============================================================================
section "26. map: releases from a local folder; the pre-push check"
# =============================================================================
cd "$T"
L=$T/localrel
mkdir -p "$L/v1" "$L/v2"
printf 'one\n' > "$L/v1/t.bin"; printf 'two\n' > "$L/v2/t.bin"
touch -t 202610121200 "$L/v1/t.bin"; touch -t 202610101200 "$L/v2/t.bin"   # v1 is newer
readonly_dir "$L"
new_repo r26
check "map" "$(git assetsync source map https://github.com/acme/loc "$L" | tr '\\' /)" \
  "[local] https://github.com/acme/loc -> $L"
check "map: in .git/config" "$(git config assetsync.https://github.com/acme/loc.localpath | tr '\\' /)" "$L"
check "map: list" "$(git assetsync source map | tr '\\' /)" "[local] https://github.com/acme/loc -> $L"
reset_calls
addc https://github.com/acme/loc t.bin
check "map: newest by file date, not by name" "$(reg file.t.bin.synced) $(cat t.bin)" "v1 one"
check "map: nothing asked online" "$(calls)" "0"
check "map: commit message" "$(git log -1 --format=%B | grep '^Release:')" \
  "Release: v1 (from a local folder, not published)"
check "map: not in .git-assetsync" "$(grep -ci 'localrel' .git-assetsync)" "0"
check "map: status names the folder" "$(git assetsync status | grep -c 'from the local folder')" "1"
check "map: up to date" "$(git assetsync status -s)" ""
check "map: local folder untouched" "$(untouched "$L")" ""
writable "$L"; mkdir -p "$L/v3"; printf 'three\n' > "$L/v3/t.bin"; readonly_dir "$L"
check "map: a new release folder" "$(git assetsync status | grep 'pending:' | sed 's/^[[:space:]]*//')" \
  "pending:    t.bin  (v1 -> v3, local folder)"
pullc t.bin
check "map: pulled" "$(reg file.t.bin.synced) $(cat t.bin)" "v3 three"
check "map: local folder untouched by pull" "$(untouched "$L")" ""
writable "$L"; printf 'three, rebuilt\n' > "$L/v3/t.bin"; readonly_dir "$L"
check "map: rebuilt in place" "$(git assetsync status -s)" "P  t.bin"
pullc t.bin
check "map: pulled again" "$(cat t.bin)" "three, rebuilt"
check "map: releases" "$(git assetsync source releases acme/loc | cut -c1-2 | oneline)" "re v3 v1 v2 "
check "map: no release" "$(git assetsync pull -n --release v9 t.bin 2>&1 | tr '\\' /)" \
  "error: t.bin: no release with tag 'v9' in acme/loc (local folder $L)"
check "map: verify" "$(git assetsync verify)" "t.bin: verified (v3)"
# a source given by name
quiet git assetsync source rename acme/loc loc && git commit -qm rename -- .git-assetsync
check "map: --unset by source name" "$(git assetsync source map loc --unset)" \
  "removed local mapping for https://github.com/acme/loc"
check "map: by source name" "$(git assetsync source map loc "$L" | cut -d' ' -f1-2)" \
  "[local] https://github.com/acme/loc"
check "map: not a directory" "$(git assetsync source map loc "$L/v1/t.bin" 2>&1 | grep -c 'is not a directory')" "1"
# flat: the files of all releases in one folder, rel20260410.7z -> rel20260410
FL=$T/flatrel
mkdir -p "$FL/sub" && printf 'ignored\n' > "$FL/sub/x.xml"
for d in 20260213 20260410; do
  printf 'data %s\n' $d > "$FL/rel$d.7z"; printf '<v>%s</v>\n' $d > "$FL/rel$d.xml"
done
printf 'old\n' > "$FL/rel20250101.tar.gz"; printf 'hidden\n' > "$FL/.rel20991231.xml"
touch -t 202501011200 "$FL/rel20250101.tar.gz"
touch -t 202602131200 "$FL/rel20260213.7z" "$FL/rel20260213.xml"
touch -t 202604101200 "$FL/rel20260410.7z" "$FL/rel20260410.xml"
readonly_dir "$FL"
cd "$T"; new_repo r26f
check "map --flat" "$(git assetsync source map --flat https://github.com/acme/flat "$FL" | tr '\\' / | sed 's/^.* -> //')" "$FL (flat)"
check "map --flat: list" "$(git assetsync source map | grep -c '(flat)$')" "1"
check "flat: releases by file name" "$(git assetsync source releases acme/flat --assets | sed 1d | awk '{print $1}' | oneline)" \
  "rel20260410 rel20260410.7z rel20260410.xml rel20260213 rel20260213.7z rel20260213.xml rel20250101 rel20250101.tar.gz "
check "flat: one asset of two" "$(git assetsync add https://github.com/acme/flat v.xml 2>&1 | grep -c 'assets')" "1"
addc https://github.com/acme/flat v.xml --asset '*.xml'
check "flat: newest release, the asset chosen" "$(reg file.v.xml.synced) $(cat v.xml)" "rel20260410 <v>20260410</v>"
check "flat: pinned tag" "$(git assetsync pull -n --release rel20260213 v.xml | head -1)" \
  "would: Update v.xml to acme/flat rel20260213 (was rel20260410)"
check "flat: .tar.gz is one extension" "$(git assetsync source releases acme/flat | grep -c '^rel20250101 ')" "1"
check "map --flat: only with DIR" "$(git assetsync source map --flat acme/flat 2>&1)" \
  "error: --flat goes with the folder: source map --flat URL|SOURCE DIR"
quiet git assetsync source map https://github.com/acme/flat "$FL"
check "map again without --flat: folders" "$(git config assetsync.https://github.com/acme/flat.layout; git assetsync source releases acme/flat | sed -n 2p | cut -d' ' -f1)" "sub"
quiet git assetsync source map https://github.com/acme/flat --unset
check "map --unset: layout too" "$(git config --get-regexp 'assetsync\..*flat' | lines)" "0"
# --pattern: several sources share a folder
SH=$T/sharedrel
mkdir -p "$SH/tool-1" "$SH/tool-2" "$SH/lib-1"
printf 't1\n' > "$SH/tool-1/t.bin"; printf 't2\n' > "$SH/tool-2/t.bin"; printf 'l1\n' > "$SH/lib-1/l.bin"
touch -t 202601011200 "$SH/tool-1/t.bin"; touch -t 202602011200 "$SH/tool-2/t.bin"
touch -t 202603011200 "$SH/lib-1/l.bin"
readonly_dir "$SH"
check "map --pattern" "$(git assetsync source map acme/tool "$SH" --pattern 'tool-*' | tr '\\' / | sed 's/^.* -> //')" \
  "$SH (only tool-*)"
quiet git assetsync source map acme/lib "$SH" --pattern 'lib-*'
check "map --pattern: in .git/config" "$(git config assetsync.https://github.com/acme/tool.pattern)" "tool-*"
check "map --pattern: list" "$(git assetsync source map | sed 's/^.* -> //' | tr '\\' / | oneline)" \
  "$SH (only tool-*) $SH (only lib-*) "
check "map --pattern: only matching folders" "$(git assetsync source releases acme/tool | sed 1d | cut -d' ' -f1 | oneline)" \
  "tool-2 tool-1 "
check "... named" "$(git assetsync source releases acme/tool | head -1 | tr '\\' /)" \
  "releases in the local folder $SH, only tool-* (git assetsync source map)"
addc acme/tool t.bin
check "map --pattern: latest of the matching ones" "$(reg file.t.bin.synced) $(cat t.bin)" "tool-2 t2"
check "map --pattern: other tags not seen" "$(git assetsync pull -n --release lib-1 t.bin 2>&1 | tr '\\' /)" \
  "error: t.bin: no release with tag 'lib-1' in acme/tool (local folder $SH, only tool-*)"
check "map --pattern: only with DIR" "$(git assetsync source map acme/tool --pattern 'x*' 2>&1)" \
  "error: --pattern goes with the folder: source map URL|SOURCE DIR --pattern PATTERN"
check "map --pattern: nothing matching" "$(git assetsync source map acme/tool "$SH" --pattern 'x*' 2>&1 | grep -c 'has no release folders matching x\* yet')" "1"
quiet git assetsync source map acme/tool "$SH"
check "map again without --pattern: all" "$(git config assetsync.https://github.com/acme/tool.pattern; git assetsync source releases acme/tool | sed 1d | lines)" "3"
check "map --pattern: local folder untouched" "$(untouched "$SH")" ""
writable "$SH"; mkdir -p "$SH/flat"
printf 'a\n' > "$SH/flat/tool-1.bin"; printf 'b\n' > "$SH/flat/lib-1.bin"; readonly_dir "$SH"
check "map --flat --pattern" "$(git assetsync source map acme/tool "$SH/flat" --flat --pattern 'tool-*' | sed 's/^.* (/(/')" \
  "(flat, only tool-*)"
check "... only matching files" "$(git assetsync source releases acme/tool | sed 1d | cut -d' ' -f1 | oneline)" "tool-1 "
quiet git assetsync source map acme/tool --unset
check "map --unset: pattern too" "$(git config --get-regexp 'assetsync\..*tool' | lines)" "0"
# --sort name: the newest release is the one with the greatest name
SN=$T/sortrel
for d in rel20260101 rel20260501 rel20261022; do mkdir -p "$SN/$d"; printf '%s\n' $d > "$SN/$d/s.bin"; done
touch -t 202601011200 "$SN/rel20261022/s.bin"; touch -t 202612011200 "$SN/rel20260501/s.bin"
readonly_dir "$SN"
check "map --sort name" "$(git assetsync source map acme/sorted "$SN" --sort name | sed 's/^.* (/(/')" "(sorted by name)"
check "... in .git/config" "$(git config assetsync.https://github.com/acme/sorted.sort)" "name"
check "--sort name: releases by name" "$(git assetsync source releases acme/sorted | sed 1d | cut -d' ' -f1 | oneline)" \
  "rel20261022 rel20260501 rel20260101 "
addc acme/sorted s.bin --release rel20260101
quiet git assetsync set s.bin --latest && git commit -qm latest -- .git-assetsync
check "--sort name: latest by name" "$(git assetsync status | grep 'pending: *s.bin' | sed 's/^[[:space:]]*//')" \
  "pending:    s.bin  (rel20260101 -> rel20261022, local folder)"
pullc s.bin
check "--sort name: skipped by name" "$(git log -1 --format=%B | grep '^Since:')" "Since:   rel20260501"
quiet git assetsync set s.bin --release 'rel202605*' && git commit -qm pattern -- .git-assetsync
check "--sort name: pattern" "$(git assetsync pull -n s.bin)" "would: Update s.bin to acme/sorted rel20260501 (was rel20261022)"
quiet git assetsync set s.bin --latest && git commit -qm latest -- .git-assetsync
quiet git assetsync source map acme/sorted "$SN"
check "map again without --sort: by date" "$(git config assetsync.https://github.com/acme/sorted.sort; git assetsync pull -n s.bin)" \
  "would: Update s.bin to acme/sorted rel20260501 (was rel20261022)"
check "--sort: only with DIR" "$(git assetsync source map acme/sorted --sort name 2>&1)" \
  "error: --sort goes with the folder: source map URL|SOURCE DIR --sort name"
quiet git assetsync source map acme/sorted --unset
cd "$T/r26"
# the pre-push check: the release must be on the server, with these assets
git init -q --bare "$T/r26.git" && git remote add origin "$T/r26.git"
quiet git assetsync hooks install
git config assetsync.pushCheck error
OUT=$(git push -q origin main 2>&1); RC=$?
check "push check: refused (error)" "$RC $(git ls-remote origin main | lines)" "1 0"
check "push check: message" \
  "$(echo "$OUT" | grep -c "assetsync: t.bin: synced from release v3, which is not on the server (https://github.com/acme/loc) - publish it there first")" "1"
check "push check: refusal named" "$(echo "$OUT" | grep -c 'push refused (assetsync.pushCheck = error)')" "1"
check "push check: --no-verify" "$(rc git push -q --dry-run --no-verify origin main)" "0"
git config assetsync.pushCheck warn
# a command after our lines in the hook (like git lfs pre-push) still gets
# the pushed refs on stdin
printf 'cat > "%s/after.log"\n' "$T" >> .git/hooks/pre-push
OUT=$(git push -q origin main 2>&1); RC=$?
check "push check: warn pushes" "$RC $(echo "$OUT" | grep -c 'pushing anyway')" "0 1"
check "pre-push: stdin kept for later commands" \
  "$(grep -c "^refs/heads/main $(git rev-parse HEAD) refs/heads/main " "$T/after.log")" "1"
check "pre-push: nothing pushed: EOF for later commands, no blank line" \
  "$(sh .git/hooks/pre-push origin "$T/r26.git" </dev/null >/dev/null 2>&1; wc -c < "$T/after.log" | tr -d ' ')" "0"
check "pre-push: by hand, a variable of that name in the environment isn't passed on" \
  "$(echo 'refs/heads/x 1 refs/heads/x 0' | git_assetsync_refs=junk sh .git/hooks/pre-push >/dev/null 2>&1; cat "$T/after.log")" \
  "refs/heads/x 1 refs/heads/x 0"
rm .git/hooks/pre-push; quiet git assetsync hooks install
check "push check: by hand (HEAD)" "$(git assetsync hook pre-push 2>&1 | grep -c 'not on the server')" "0"
# published as tested: no warning; other assets on the server: a warning
cp "$L/v3/t.bin" "$F/t.bin"; release acme/loc v3 13 "$F/t.bin"
check "push check: local folder untouched" "$(untouched "$L")" ""
writable "$L"; mkdir -p "$L/v4"; printf 'four\n' > "$L/v4/t.bin"; readonly_dir "$L"
pullc t.bin
printf 'four, other build\n' > "$F/t.bin"; release acme/loc v4 14 "$F/t.bin"
OUT=$(git push -q origin main 2>&1)
check "push check: other assets on the server" \
  "$(echo "$OUT" | grep -c 'synced from assets of release v4 that differ from those on the server')" "1"
printf 'four\n' > "$F/t.bin"; reupload acme/loc v4 "$F/t.bin"
git commit -q --allow-empty -m next
check "push check: the same assets: quiet" "$(git push -q origin main 2>&1 | grep -c 'server')" "0"
check "push check: off" "$(git -c assetsync.pushCheck=off assetsync hook pre-push 2>&1 | grep -c 'pushing anyway')" "0"
# a server that can't be asked never refuses
git commit -q --allow-empty -m next2
sedi 's/^\tsynced = v4$/\tsynced = v5/' .git-assetsync && git commit -qam v5
OUT=$(ASSETSYNC_GH=false git -c assetsync.pushCheck=error push -q origin main 2>&1); RC=$?
check "push check: server not reachable" "$RC $(echo "$OUT" | grep -c 'cannot check whether release v5 is on the server')" "0 1"
check "map: the local folders untouched" "$(untouched "$L" "$FL" "$SH" "$SN")" ""
writable "$L" "$FL" "$SH" "$SN"
# the digest of a local asset is remembered (in the download cache) with
# its size and modification time: status doesn't read it again until it
# changes; pull reads what it takes
cd "$T"
LD=$T/localdig; mkdir -p "$LD/v1"; printf 'dig\n' > "$LD/v1/d.bin"; touch -t 202610121200 "$LD/v1/d.bin"
SAVED_CACHE=$ASSETSYNC_CACHE; export ASSETSYNC_CACHE=$T/cache26
new_repo r26d
quiet git assetsync source map https://github.com/acme/dig "$LD"
addc https://github.com/acme/dig d.bin
check "local digest: remembered" "$(ls "$ASSETSYNC_CACHE/local" | lines) $(ls "$ASSETSYNC_CACHE" | oneline)" "1 local "
chmod a-r "$LD/v1/d.bin"
check "local digest: status doesn't read the file again" "$(git assetsync status -s 2>&1)" ""
chmod a+r "$LD/v1/d.bin"
printf 'dig, rebuilt\n' > "$LD/v1/d.bin"; touch -t 202610121300 "$LD/v1/d.bin"
check "local digest: a changed file is read again" "$(st)" "P"
quiet git assetsync pull d.bin
check "... pull takes it" "$(cat d.bin) $(reg file.d.bin.digest)" "dig, rebuilt sha256:$(sha "$LD/v1/d.bin")"
check "local digest: cache clear removes them" "$(git assetsync cache clear >/dev/null; ls "$ASSETSYNC_CACHE/local" | lines)" "0"
export ASSETSYNC_CACHE=$SAVED_CACHE


# =============================================================================
section "27. edit: .git-assetsync in the editor"
# =============================================================================
cd "$T"
new_repo r27
check "edit: no registry" "$(git assetsync edit 2>&1)" \
  "error: no .git-assetsync yet - take files from release assets with 'git assetsync add'"
asset e.txt "e 1"
release acme/e v1 10 "$F/e.txt"
addc acme/e e.txt
check "edit: unchanged" "$(git assetsync edit)" ".git-assetsync: no changes"
# "editors": scripts that change the file they get
printf 'git config -f "$1" file.e.txt.release v1\n' > "$T/ed-pin.sh"
check "edit: staged" "$(GIT_EDITOR="sh '$T/ed-pin.sh'" git assetsync edit)" \
  '.git-assetsync staged (use "git assetsync status" to see what changes, "git assetsync pull <file>..." to update)'
check "edit: the change" "$(reg file.e.txt.release) $(git status --porcelain | oneline)" "v1 M  .git-assetsync "
git commit -qm pinned
printf 'git config -f "$1" source.other.url https://github.com/acme/other\ngit config -f "$1" file.x.txt.source nosuch\ngit config -f "$1" dir.e.txt/sub.source acme/e\n' > "$T/ed-gaps.sh"
OUT=$(GIT_EDITOR="sh '$T/ed-gaps.sh'" git assetsync edit 2>&1)
check "edit: warnings" "$(echo "$OUT" | grep '^warning:' | oneline)" \
  "warning: .git-assetsync: [source \"other\"] is not used by any file warning: .git-assetsync: [file \"e.txt\"] overlaps with the entry for e.txt/sub warning: .git-assetsync: [dir \"e.txt/sub\"] lacks synced or tree (what it was synced with) - pull takes the release warning: .git-assetsync: [file \"x.txt\"]: no [source \"nosuch\"] warning: .git-assetsync: [file \"x.txt\"] lacks synced or blob (what it was synced with) - pull takes the release "
check "edit: staged despite warnings" "$(git status --porcelain | oneline)" "M  .git-assetsync "
git reset -q --hard
printf 'printf "[file\\n" >> "$1"\n' > "$T/ed-broken.sh"
OUT=$(GIT_EDITOR="sh '$T/ed-broken.sh'" git assetsync edit 2>&1); RC=$?
check "edit: broken file" "$RC $(echo "$OUT" | grep -c "not staged; fix it with 'git assetsync edit'")" "2 1"
check "edit: broken: nothing staged" "$(git diff --cached --name-only)" ""
git checkout -q .git-assetsync
check "edit: editor fails" "$(GIT_EDITOR=false git assetsync edit 2>&1)" "error: the editor failed; nothing staged"
printf ': > "$1"\n' > "$T/ed-empty.sh"
GIT_EDITOR="sh '$T/ed-empty.sh'" git assetsync edit >/dev/null 2>&1
check "edit: emptied: removal staged" "$(git status --porcelain | oneline)" "D  .git-assetsync "


# =============================================================================
section "28. Release notes of skipped releases"
# =============================================================================
cd "$T"
for v in 1 2 3 4; do printf 'sk %s\n' $v > "$F/sk.txt"; printf 'Notes of v%s.\n' $v > "$F/sk-notes.md"
  case $v in
    3) release --pre --notes "$F/sk-notes.md" acme/sk v$v 1$v "$F/sk.txt" ;;
    *) release --notes "$F/sk-notes.md" acme/sk v$v 1$v "$F/sk.txt" ;;
  esac
done
printf 'x\n' > "$F/sk.txt"; release --notes "$F/sk-notes.md" acme/sk other-1 12T18:00:00Z "$F/sk.txt"
new_repo r28
addc acme/sk s.txt --release v1
quiet git assetsync set s.txt --release 'v*' && git commit -qm pattern -- .git-assetsync
pullc s.txt
check "skipped: listed (pattern, no prerelease)" "$(git log -1 --format=%B | grep '^Since:')" "Since:   v2"
check "skipped: their notes too, newest first" \
  "$(git log -1 --format=%B | grep -E '^(Release notes|  Notes)' | oneline)" \
  "Release notes v4:   Notes of v4. Release notes v2:   Notes of v2. "
check "going back: reverted, no notes" "$(pullcm --release v1 s.txt >/dev/null 2>&1; git log -1 --format=%B | grep -cE '^Reverted: v4, v2$|^Release notes|Notes of')" "1"
quiet git -c assetsync.notesTotalLines=1 assetsync pull s.txt; commitp
check "notesTotalLines: the rest only linked" "$(git log -1 --format=%B | grep -E '^(Release notes|  Notes|\[\.\.\.)' | oneline)" \
  "Release notes v4:   Notes of v4. [... notes of v2 and older: see the release pages] "
quiet pullcm --release v1 s.txt
quiet git -c assetsync.notesLines=0 assetsync pull s.txt; commitp
check "notesLines=0: no notes, still the list" "$(git log -1 --format=%B | grep -cE '^Since:   v2$|Notes of')" "1"
check "notesLines: not a number" "$(git -c assetsync.notesLines=many assetsync pull --release v1 s.txt 2>&1 | grep -c "assetsync.notesLines: 'many' is not a number of lines")" "1"

# the changelog step: text from the assets with the release notes
mkdir -p "$F/cl"; : > "$F/cl/CHANGELOG.txt"
for v in 1 2 3; do
  printf 'cl %s\n' $v > "$F/cl/a.txt"
  { printf 'c%s: change %s\n' $v $v; cat "$F/cl/CHANGELOG.txt"; } > "$F/cl.tmp" && mv "$F/cl.tmp" "$F/cl/CHANGELOG.txt"
  mkarchive "$F/cl-$v.tar.gz" "$F/cl"
  printf 'Notes of c%s.\n' $v > "$F/cl-notes.md"
  release --notes "$F/cl-notes.md" acme/cl c$v 2$v "$F/cl-$v.tar.gz"
done
quiet git assetsync filter add cl --extract --changelog CHANGELOG.txt --exclude CHANGELOG.txt
quiet git assetsync filter add cla --extract --changelog '*.txt' --include a.txt
check "changelog: the step" "$(git config -f .git-assetsync --get-all filter.cl.step | oneline)" \
  "extract changelog CHANGELOG.txt exclude CHANGELOG.txt "
check "changelog: needs a pattern" "$(git assetsync filter add x --changelog 2>&1 | grep -c 'expected at least one argument')" "1"
git commit -qm filters -- .git-assetsync
addc acme/cl cl/ --release c1 --filter cl
addc acme/cl a.txt --release c1 --filter cla
check "changelog: not for a new entry" "$(git log -1 --format=%B | grep -c Changelog)" "0"
check "changelog: the file stays out" "$(git ls-files cl a.txt | oneline)" "a.txt cl/a.txt "
check "filter test: read" "$(git assetsync filter test cl --source acme/cl --release c1 2>&1 | grep '^changelog')" \
  "changelog CHANGELOG.txt  1 file read"
quiet git assetsync set cl a.txt --release 'c*' && git commit -qm pattern -- .git-assetsync
pullc cl a.txt
check "changelog: after the notes of the release, before those skipped" \
  "$(git log -1 --format=%B | grep -E '^(Release notes|Changelog|  )' | oneline)" \
  "Release notes c3:   Notes of c3. Changelog (CHANGELOG.txt):   c3: change 3   c2: change 2   c1: change 1 Release notes c2:   Notes of c2. Release notes c3:   Notes of c3. Changelog (CHANGELOG.txt):   c3: change 3   c2: change 2   c1: change 1 Changelog (a.txt):   cl 3 Release notes c2:   Notes of c2. "
quiet pullcm --release c1 cl
quiet git -c assetsync.notesLines=1 assetsync pull cl; commitp
check "changelog: shortened" "$(git log -1 --format=%B | grep -A2 '^Changelog' | oneline)" \
  "Changelog (CHANGELOG.txt):   c3: change 3   [... more in CHANGELOG.txt] "
# rebuilt: the same release with a new archive - its changelog again, no notes
{ printf 'c3: rebuilt\n'; cat "$F/cl/CHANGELOG.txt"; } > "$F/cl.tmp" && mv "$F/cl.tmp" "$F/cl/CHANGELOG.txt"
mkarchive "$F/cl-3.tar.gz" "$F/cl"
reupload acme/cl c3 "$F/cl-3.tar.gz"
pullc cl
check "changelog: also for replaced assets" "$(git log -1 --format=%B | grep -E '^(\[assetsync\]|Release notes|Changelog|  )' | oneline)" \
  "[assetsync] Update cl/ from acme/cl c3 (asset replaced) Changelog (CHANGELOG.txt):   c3: rebuilt   c3: change 3   c2: change 2   c1: change 1 "
printf 'bin\000ary\n' > "$F/log.bin"; printf 'text\n' > "$F/log.txt"
quiet git assetsync filter add clb --changelog 'log.*'
check "filter test: not text skipped" "$(git assetsync filter test clb "$F/log.bin" "$F/log.txt" 2>&1 | grep '^changelog')" \
  "changelog 'log.*'  1 file read, 1 skipped (not text)"
quiet git assetsync filter remove clb
# encodings: UTF-8, else Windows-1252; UTF-16 with a BOM
mkdir -p "$F/enc1" "$F/enc2"
printf 'k1\n' > "$F/enc1/keep.bin"; printf 'w\n' > "$F/enc1/w.txt"; printf 'u\n' > "$F/enc1/u.txt"
printf 'k2\n' > "$F/enc2/keep.bin"
printf '\304nderung\n' > "$F/enc2/w.txt"
"$PYTHON" -c 'import sys; open(sys.argv[1], "wb").write("Ünicode\n".encode("utf-16"))' "$F/enc2/u.txt"
release acme/enc e1 20 "$F/enc1/keep.bin" "$F/enc1/u.txt" "$F/enc1/w.txt"
release acme/enc e2 21 "$F/enc2/keep.bin" "$F/enc2/u.txt" "$F/enc2/w.txt"
quiet git assetsync filter add enc --changelog '*.txt' --exclude '*.txt'
git commit -qm enc -- .git-assetsync
addc acme/enc enc/ --release e1 --filter enc
quiet git assetsync set enc --latest && git commit -qm latest -- .git-assetsync
pullc enc
check "changelog: Windows-1252, UTF-16" "$(git log -1 --format=%B | grep -A1 '^Changelog' | grep -v '^--' | oneline)" \
  "Changelog (u.txt):   Ünicode Changelog (w.txt):   Änderung "
# prereleases count when the source takes them; one release forward: as before
quiet pullcm --release v1 s.txt
quiet git assetsync set s.txt --latest --prerelease && git commit -qm pre -- .git-assetsync
pullc s.txt
check "skipped: prereleases when taken" "$(git log -1 --format=%B | grep '^Since:')" "Since:   v3, other-1, v2"
quiet pullcm --release v3 s.txt; pullc s.txt
check "one release forward: no list" "$(git log -1 --format=%B | grep -cE '^Since:|^Release notes:$')" "1"

# =============================================================================
section "29. restore: back to what the release gave"
# =============================================================================
cd "$T"
mkdir -p rs/sub && echo one > rs/a.txt && echo two > rs/sub/b.txt && printf '#!/bin/sh\n' > rs/run.sh
mkarchive "$F/rs.tar.gz" rs
asset rf.txt "rf 1"
release acme/rs v1 10 "$F/rs.tar.gz" "$F/rf.txt"
new_repo r29
printf 'build/\n' > .gitignore && git add .gitignore && git commit -qm ignore
quiet git assetsync filter add unpack --extract && git commit -qm filter
addc acme/rs d/ --asset rs.tar.gz --filter unpack
addc acme/rs f.txt --asset rf.txt
# a file: the working tree by default
echo changed > f.txt
check "restore: file" "$(git assetsync restore f.txt) $(cat f.txt) $(st f.txt)" "discarded: f.txt (git show 5ea2ed416fbd to get it back)
f.txt: restored (acme/rs v1) rf 1 "
check "restore: nothing to restore" "$(git assetsync restore f.txt)" "f.txt: nothing to restore"
check "restore: what it discarded, to get back" "$(git show 5ea2ed416fbd)" "changed"
echo staged > f.txt && git add f.txt
check "restore: a staged change isn't lost, not named" "$(git assetsync restore f.txt)" "f.txt: restored (acme/rs v1)"
quiet git assetsync restore -S f.txt
# staged changes: -S restores the index only, -SW both
echo changed > f.txt && git add f.txt
check "restore -S: the index only" "$(git assetsync restore -S f.txt) $(git diff --cached --quiet; echo $?) $(cat f.txt)" \
  "f.txt: restored in the index (acme/rs v1) 0 changed"
git add f.txt
check "restore -SW: both" "$(git assetsync restore -SW f.txt) $(git status --porcelain f.txt)$(cat f.txt)" \
  "discarded: f.txt (git show 5ea2ed416fbd to get it back)
f.txt: restored and staged (acme/rs v1) rf 1"
# a committed modification: restore -SW, then commit
echo changed > f.txt && git commit -qam change
check "committed modification: status names restore" \
  "$(git assetsync status | grep -c 'use "git assetsync restore -SW <file>..." to restore the release asset')" "1"
check "... and so does pull" "$(git assetsync pull f.txt 2>&1 | grep -o "discard them with '[^']*'")" \
  "discard them with 'git assetsync restore -SW f.txt'"
check "restore without -S: still to commit" "$(git assetsync restore f.txt >/dev/null; st f.txt)" " M"
quiet git assetsync restore -SW f.txt && git commit -qm "back"
check "... -SW and committed: clean" "$(st f.txt)" ""
rm f.txt
check "restore: a deleted file" "$(git assetsync restore f.txt >/dev/null; cat f.txt) $(st f.txt)" "rf 1 "
# line endings as .gitattributes says now
printf '*.txt text eol=crlf\n' > .gitattributes && git add .gitattributes && git commit -qm crlf
echo changed > f.txt
check "restore: line endings as configured now" "$(git assetsync restore f.txt >/dev/null; tr -cd '\r' < f.txt | wc -c | tr -d ' ') $(st f.txt)" "1 "
git rm -q .gitattributes && git commit -qm "no crlf" && git checkout -q -- . && rm -f f.txt && git checkout -q -- f.txt
# from a subdirectory
mkdir -p s2 && echo changed > f.txt
check "restore: from a subdirectory" "$(cd s2 && git assetsync restore ../f.txt) $(cat f.txt)" "discarded: f.txt (git show 5ea2ed416fbd to get it back)
f.txt: restored (acme/rs v1) rf 1"
# a directory: changed, deleted and new files; ignored ones stay; modes as synced
echo x > d/a.txt; rm d/sub/b.txt; echo new > d/new.txt; mkdir -p d/build && echo out > d/build/o.log
git rm -q --cached d/run.sh
check "restore dir: the working tree" "$(git assetsync restore d) $(cd d && find . -type f | sort | oneline)$(cat d/a.txt d/sub/b.txt | oneline)" \
  "discarded: d/a.txt (git show 587be6b4c3f9 to get it back)
d/: restored (acme/rs v1) ./a.txt ./build/o.log ./new.txt ./run.sh ./sub/b.txt one two "
check "... the index not, files of others stay" "$(git status --porcelain d | oneline)" "D  d/run.sh ?? d/new.txt ?? d/run.sh "
echo x > d/a.txt
check "restore -SW dir" "$(git assetsync restore -SW d) $(git status --porcelain d | grep -v new.txt)$(git ls-files -s d/run.sh | cut -d' ' -f1) $(st d)" \
  "discarded: d/a.txt (git show 587be6b4c3f9 to get it back)
d/: restored and staged (acme/rs v1) 100755 "
rm d/new.txt
# errors: not synced yet, base not available
git config -f .git-assetsync file.h.txt.source acme/rs
check "restore: not synced yet" "$(git assetsync restore h.txt 2>&1)" "error: h.txt: not synced yet - use 'git assetsync pull h.txt'"
git checkout -q .git-assetsync
git config -f .git-assetsync file.f.txt.blob 0123456789012345678901234567890123456789
check "restore: base not available" \
  "$(git assetsync restore f.txt 2>&1 | grep -c "error: f.txt: its synced version is not available (.*) - get it again with 'git assetsync pull --overwrite f.txt'")" "1"
git checkout -q .git-assetsync
check "restore: a path inside a directory entry" "$(git assetsync restore d/a.txt 2>&1)" \
  "error: 'd/a.txt' is part of the directory entry d/ - only the entry as a whole can be changed"
check "... nor unlink, set" "$(rc git assetsync unlink d/sub) $(rc git assetsync set d/a.txt --no-filter)" "2 2"
# a path inside a directory entry selects it for status, diff, verify, pull
echo x > d/a.txt
check "status: a path inside a directory entry" "$(git assetsync status -s d/sub/b.txt)" " M d/"
check "diff: a path inside a directory entry" "$(git assetsync diff d/a.txt -- --stat | head -1 | cut -d'|' -f1 | tr -d ' ')" "d/a.txt"
check "verify: a path inside a directory entry" "$(git assetsync verify d/a.txt)" "d/: verified (v1)"
check "pull: a path inside a directory entry" "$(git assetsync pull d/a.txt d/sub 2>&1 | grep -c "^error: d/: local modifications NOT ALLOWED")" "1"
quiet git assetsync restore d


# =============================================================================
section "30. rm: remove entries and their files"
# =============================================================================
cd "$T/r29"
git reset -q --hard && git clean -qfd
addc acme/rs g.txt --asset rf.txt
check "rm -n" "$(git assetsync rm -n g.txt; git status --porcelain)" "would remove g.txt"
check "rm: file and entry, staged" "$(git assetsync rm g.txt) $(ls g.txt 2>&1 >/dev/null | grep -c 'No such') $(git status --porcelain | oneline)$(reg file.g.txt.source)" \
  "removed g.txt 1 M  .git-assetsync D  g.txt "
git commit -qm "rm g"
# uncommitted changes: refused, also for the others given; -f removes anyway
addc acme/rs g.txt --asset rf.txt
echo changed > g.txt && git add g.txt     # staged: git rm takes it from the index too
check "rm: refused with uncommitted changes" "$( (git assetsync rm f.txt g.txt 2>&1; cat g.txt; reg file.f.txt.source) | oneline)" \
  "error: g.txt: has uncommitted changes - use -f to remove it anyway changed acme/rs "
check "rm -f" "$(git assetsync rm -f g.txt) $(ls g.txt 2>/dev/null)$(reg file.g.txt.source)" "discarded: g.txt (git show 5ea2ed416fbd to get it back)
removed g.txt "
git commit -qm "rm g"
# a committed modification doesn't count; a file already deleted is fine
addc acme/rs g.txt --asset rf.txt
echo changed > g.txt && git commit -qam change
check "rm: a committed modification is fine" "$(git assetsync rm g.txt)" "removed g.txt"
git reset -q --hard HEAD
rm g.txt && git commit -qam "deleted"
check "rm: file already deleted" "$(git assetsync rm g.txt) $(git status --porcelain | oneline)" "removed g.txt M  .git-assetsync "
git commit -qm "rm g"
# a directory: only its own files count and go, files of others and ignored
# ones stay; from a subdirectory
echo new > d/new.txt; mkdir -p d/build && echo out > d/build/o.log; echo x > d/a.txt
check "rm dir: a changed file refused" "$(git assetsync rm d 2>&1)" "error: d/: has uncommitted changes - use -f to remove it anyway"
mkdir -p s2
check "rm -f dir, from a subdirectory: files of others kept" \
  "$(cd s2 && git assetsync rm -f ../d) $(cd d && find . -type f | sort | oneline)$(git ls-files d | lines)" \
  "discarded: d/a.txt (git show 587be6b4c3f9 to get it back)
removed d/ (1 other file kept) ./build/o.log ./new.txt 0"
check "... the source stays while used" "$(reg dir.d.source)$(reg source.acme/rs.url)" "https://github.com/acme/rs"
check "rm: a path inside an entry" "$(rc git assetsync rm d/a.txt)" "2"

# =============================================================================
section "31. A directory with files of others: only the release's files are the entry's"
# =============================================================================
cd "$T"
mkdir -p ov1/include ov1/lib ov2/include ov2/lib ov3/include ov4/docs
echo a1 > ov1/include/a.h; echo b > ov1/include/b.h; echo lib > ov1/lib/x.lib
echo a2 > ov2/include/a.h; echo c > ov2/include/c.h; echo lib > ov2/lib/x.lib
cp -R ov2/. ov3/; echo theirs > ov3/include/mine.h
cp -R ov2/. ov4/; echo readme > ov4/README.MD; echo doc > ov4/docs/x.txt
for v in 1 2 3 4; do mkarchive "$F/ov-$v.tar.gz" "$T/ov$v"; done
release acme/ov v1 10 "$F/ov-1.tar.gz"
new_repo r31
filt unpack --extract
mkdir -p third/include && echo mine > third/README.md && echo mine > third/include/mine.h
git add third && git commit -qm "files of mine"
addc acme/ov third/ --release v1 --filter unpack
check "added next to the files of others" "$(git ls-files third | oneline)" \
  "third/README.md third/include/a.h third/include/b.h third/include/mine.h third/lib/x.lib "
check "... clean" "$(st third) $(git status --porcelain)" " "
check "... the commit has the release's files" "$(git show --name-only --format= HEAD | oneline)" \
  ".git-assetsync third/include/a.h third/include/b.h third/lib/x.lib "
echo changed >> third/README.md
check "a file of others changed: no modification" "$(st third)" ""
git add third/README.md
# the next release: its files replaced and deleted, those of others left alone
quiet git assetsync set third --latest && git commit -qm latest -- .git-assetsync
release acme/ov v2 11 "$F/ov-2.tar.gz"
quiet git assetsync pull third
check "pull: the release's files replaced and deleted" "$(cd third && find . -type f | sort | oneline)$(cat third/include/a.h)" \
  "./README.md ./include/a.h ./include/c.h ./include/mine.h ./lib/x.lib a2"
check "... stages its files; others' staged change stays as it is" "$(git status --porcelain | oneline)" \
  "M  .git-assetsync M  third/README.md M  third/include/a.h D  third/include/b.h A  third/include/c.h "
check "... message: what changed in its files" "$(grep '^Files:' .git/SQUASH_MSG)" \
  "Files:   1 added, 1 removed, 1 changed (3 in total)"
git commit -q --no-edit
# a file of others in the way of a new release file: refused; --overwrite replaces it
release acme/ov v3 12 "$F/ov-3.tar.gz"
check "pull: a file of others in the way" "$(pullcm third 2>&1 | grep '^error')" \
  "error: 'third/': files of others in the way of the release: third/include/mine.h - use --overwrite to replace them"
check "... nothing changed" "$(cat third/include/mine.h) $(git status --porcelain)" "mine "
pullc --overwrite third
check "pull --overwrite: replaced, now the release's" "$(cat third/include/mine.h) $(st third) $(reg dir.third.synced)" "theirs  v3"
# in the way: a name differing only in case, a file where a directory is needed
echo mine > third/docs && git add third/docs && git commit -qm docs
release acme/ov v4 13 "$F/ov-4.tar.gz"
check "pull: in the way also by case, or as a file" "$(pullcm third 2>&1 | grep '^error')" \
  "error: 'third/': files of others in the way of the release: third/README.md, third/docs - use --overwrite to replace them"
rm -rf "$GH/github.com/acme/ov/4"
# a clone doesn't have the base (it was committed with files of others): status
# doesn't check, verify gets it; restore and pull get it when needed
quiet git assetsync mv third vendor
check "mv: files of others moved along" "$(git reset -q --hard; git assetsync mv third vendor)" \
  "moved third -> vendor (entry kept; 2 other files moved along)"
git commit -qm mv
cd "$T" && git clone -q --no-local r31 r31c && cd r31c
check "clone: not checked" "$(git assetsync status | grep -c "warning: vendor/: which files are those of v3 isn't known in this clone - local modifications not checked ('git assetsync verify vendor/' gets it)")" "1"
check "... verify gets it" "$(git assetsync verify vendor) $(git assetsync status | grep -c 'not checked')" "vendor/: verified (v3) 0"
cd "$T" && rm -rf r31c && git clone -q --no-local r31 r31c && cd r31c
echo changed > vendor/include/a.h; echo changed > vendor/README.md
check "clone: restore gets the base" "$(git assetsync restore vendor) $(cat vendor/include/a.h vendor/README.md | oneline)" \
  "discarded: vendor/include/a.h (git show 5ea2ed416fbd to get it back)
vendor/: restored (acme/ov v3) a2 changed "
git checkout -q vendor
cd "$T" && rm -rf r31c && git clone -q --no-local r31 r31c && cd r31c
echo changed > vendor/include/a.h
check "clone: pull --overwrite gets the base" "$(pullcm --overwrite vendor 2>/dev/null | tail -1; cat vendor/include/a.h)" \
  "vendor/: restored - the same as committed, nothing to commit
a2"
# ... unless the release it was synced with is gone: pull refuses, --overwrite only adds
cd "$T" && rm -rf r31c && git clone -q --no-local r31 r31c && cd r31c
rm -rf "$GH/github.com/acme/ov/3"
release acme/ov v5 14 "$F/ov-1.tar.gz"
check "base gone: pull refused" "$(pullcm vendor 2>&1)" \
  "error: vendor/: which files are those of v3 isn't known in this clone, and release v3 of acme/ov no longer exists - with --overwrite the files of v5 are added, none deleted"
quiet pullcm --overwrite vendor
check "... --overwrite: added, none deleted" "$(cd vendor && find . -type f | sort | oneline)$(cat vendor/include/a.h)" \
  "./README.md ./docs ./include/a.h ./include/b.h ./include/c.h ./include/mine.h ./lib/x.lib a1"
check "... now known" "$(st vendor) $(git ls-tree -r --name-only $(reg dir.vendor.tree) | oneline)" " include/a.h include/b.h lib/x.lib "
# a file of the release renamed in case only is its own, not in the way
mkdir -p "$T/ov6/include" && echo a6 > "$T/ov6/include/A.h" && echo lib > "$T/ov6/x.lib"
mkarchive "$F/ov-6.tar.gz" "$T/ov6"
release acme/ov v6 15 "$F/ov-6.tar.gz"
quiet pullcm vendor
check "a file renamed in case: replaced" "$(git ls-files vendor/include | oneline)$(cat vendor/include/A.h)" \
  "vendor/include/A.h vendor/include/c.h vendor/include/mine.h a6"
# rm: the release's files go, those of others stay
check "rm: files of others kept" "$(git assetsync rm vendor) $(cd vendor && find . -type f | sort | oneline)" \
  "removed vendor/ (4 other files kept) ./README.md ./docs ./include/c.h ./include/mine.h "

# =============================================================================
section "32. Ignored paths, errors while writing, files as git checkout writes them"
# =============================================================================
cd "$T"
printf 'a\n' > "$F/ig.txt"; asset ig.bin "ig 1"
release acme/ig v1 16 "$F/ig.bin" "$F/ig.txt"
new_repo r32
echo '*.bin' > .gitignore && git add .gitignore && git commit -qm ignore
# a file entry at a path the repository ignores: added like a directory's files
mkdir bin
check "add: a file at an ignored path" "$(rc asd add acme/ig bin/ig.bin --asset ig.bin) $(git ls-files bin)" \
  "0 bin/ig.bin"
git commit -qm add
# a file where its directory should be: add refuses; an error writing
# (pull, which makes missing directories): reported, no traceback
echo x > blocker && git add blocker && git commit -qm blocker
check "add: a file where its directory should be" "$(asd add acme/ig blocker/ig.txt --asset ig.txt 2>&1)" \
  "error: cannot add 'blocker/ig.txt': 'blocker' is not a directory"
mkdir w && quiet asd add acme/ig w/ig.txt --asset ig.txt && git commit -qm w
rm -r w && echo x > w
out=$(asd pull --overwrite w/ig.txt 2>&1); r=$?
check "pull: a file where its directory should be" \
  "$r $(printf '%s\n' "$out" | grep -c Traceback) $(printf '%s\n' "$out" | grep -c '^error: w')" "2 0 1"
rm w && git checkout -q w
check "... nothing changed" "$(git status --porcelain)" ""
# rm -f / --overwrite: a staged version that is neither committed nor in the
# working tree is named too
echo staged > bin/ig.bin && git add bin/ig.bin && echo work > bin/ig.bin
out=$(asd rm -f bin/ig.bin)
w=$(printf '%s\n' "$out" | sed -n 's/^discarded: bin\/ig.bin (git show \([0-9a-f]*\) to get it back)$/\1/p')
s=$(printf '%s\n' "$out" | sed -n 's/^discarded: bin\/ig.bin, as staged (git show \([0-9a-f]*\) to get it back)$/\1/p')
check "rm -f: the working tree's and the staged version named" "$(git show "$w") $(git show "$s") $(printf '%s\n' "$out" | tail -1)" \
  "work staged removed bin/ig.bin"
git commit -qm rm
# files of a directory are written as git checkout writes them (here: CRLF)
printf '*.txt eol=crlf\n' > .gitattributes && git add .gitattributes && git commit -qm crlf
bytes() { "$PYTHON" -c 'import sys; print(repr(open(sys.argv[1], "rb").read()))' "$1"; }
quiet asd add acme/ig f.txt --asset ig.txt
quiet asd add acme/ig d/
check "a directory's files in checkout form, like a file's" "$(bytes f.txt) $(bytes d/ig.txt)" "b'a\r\n' b'a\r\n'"
echo mine > d/mine.txt && git add d/mine.txt 2>/dev/null && git commit -qm "add, with a file of mine"
check "... clean" "$(st)" ""
# rm -n changes nothing - also where it doesn't know the files of a directory
cd "$T" && git clone -q --no-local r32 r32c && cd r32c
check "rm -n: base not in the clone: nothing got, nothing kept" \
  "$(git assetsync rm -n d; git for-each-ref refs/assetsync | lines; git status --porcelain)" "would remove d/
0"
# restore -S: only the index goes - a staged version named, the working tree stays
echo staged > f.txt && git add f.txt 2>/dev/null && echo work > f.txt
out=$(git assetsync restore -S f.txt)
s=$(printf '%s\n' "$out" | sed -n 's/^discarded: f.txt, as staged (git show \([0-9a-f]*\) to get it back)$/\1/p')
check "restore -S: the staged version named, not the working tree's" \
  "$(git show "$s") $(printf '%s\n' "$out" | grep -c '^discarded:') $(printf '%s\n' "$out" | tail -1) $(cat f.txt)" \
  "staged 1 f.txt: restored in the index (acme/ig v1) work"
git checkout -q f.txt
# filter steps with an empty pattern are malformed, as for the other steps
check "include/exclude with an empty pattern: malformed" \
  "$(asd filter add e --include a '' 2>&1 | grep -c '^error: malformed filter step'; asd filter add e --exclude '' 2>&1 | grep -c '^error: malformed filter step')" "1
1"

# =============================================================================
section "33. Comments and own lines in .git-assetsync: only the lines that change"
# =============================================================================
cd "$T"
printf 'c1\n' > "$F/cm1.txt"; printf 'c2\n' > "$F/cm2.txt"
release acme/cm v1 16 "$F/cm1.txt" "$F/cm2.txt"
new_repo r33
quiet asd add acme/cm a.txt --asset cm1.txt --release v1
quiet asd add acme/cm b.txt --asset cm2.txt
quiet asd filter add f1 --extract --strip 1
quiet asd filter add f2 --include '*.h'
git commit -qm add
"$PYTHON" - <<'EOF'
s = open(".git-assetsync").read()
s = s.replace('[file "a.txt"]', '# --- group A ---\n[file "a.txt"]   ; the a file')
s = s.replace('\trelease = v1', '    release   = v1   ; pinned for X')
s = s.replace('[file "b.txt"]', '\n# b: keep this comment\n[file "b.txt"]')
s = s.replace('\tstep = strip 1', '\t# then strip\n\tstep = strip 1')
s = s.replace('[filter "f2"]', '# f2: headers only\n[filter "f2"]  # f2 header note')
s += "\n# trailing note\n"
open(".git-assetsync", "w", newline="\n").write(s)
EOF
git commit -qam comments
# changed lines: '-'/'+' lines of the last change to .git-assetsync, unstaged or staged
changed() { git diff -U0 HEAD -- .git-assetsync | grep -E '^[-+][^-+]' | sed 's/^\([-+]\)[[:space:]]*/\1/' | oneline; }
comments() { grep -cE '^# --- group A ---$|; the a file$|; pinned for X$|^# b: keep this comment$|^	# then strip$|^# f2: headers only$|# f2 header note$|^# trailing note$' .git-assetsync; }
quiet asd set a.txt --release 'v*'
check "registry: set changes only the value - indent, spacing, comment stay" \
  "$(changed)" "-release   = v1   ; pinned for X +release   = v*   ; pinned for X "
git commit -qm set
printf 'c1 v2\n' > "$F/cm1.txt"; release acme/cm v2 17 "$F/cm1.txt" "$F/cm2.txt"
quiet asd pull a.txt
check "registry: pull changes only its keys' lines" "$(changed | tr ' ' '\n' | grep -E '^[-+]' | oneline)$(comments)" \
  "-synced -digest -blob +synced +digest +blob 8"
git commit -qm pull
line=$(grep -n '^\[filter "f1"\]' .git-assetsync | cut -d: -f1)
quiet asd filter set f1 --extract --strip 2 --exclude '*.md'
check "registry: filter set replaces the steps where they are" \
  "$(grep -n '^\[filter "f1"\]' .git-assetsync | cut -d: -f1) $(git config -f .git-assetsync --get-all filter.f1.step | oneline)$(comments)" \
  "$line extract strip 2 exclude '*.md' 8"
check "... the steps after its first, its comments after them" \
  "$(sed -n "$((line + 1)),$((line + 4))p" .git-assetsync | sed 's/^[[:space:]]*//' | oneline)" \
  "step = extract step = strip 2 step = exclude '*.md' # then strip "
git commit -qm "filter set"
quiet asd filter rename f2 g2
check "registry: a renamed section keeps its header's comment" "$(changed)" \
  '-[filter "f2"]  # f2 header note +[filter "g2"]  # f2 header note '
git commit -qm rename
quiet asd mv b.txt c.txt
check "registry: mv - the comment above stays above" \
  "$(grep -B1 '^\[file "c.txt"\]' .git-assetsync | head -1)" "# b: keep this comment"
git commit -qm mv
quiet asd unlink a.txt
check "registry: unlink removes the section, not the comments of others" \
  "$(grep -c 'a.txt' .git-assetsync) $(comments) $(tail -1 .git-assetsync)" "0 6 # trailing note"
check "... the group heading above it is its own line" "$(grep -c '^# --- group A ---$' .git-assetsync)" "1"
git commit -qm unlink
# line endings as git checkout writes it: with eol=crlf a CRLF registry stays
# so - only the changed line differs
echo '.git-assetsync eol=crlf' > .gitattributes && git add .gitattributes
"$PYTHON" -c 'd = open(".git-assetsync", "rb").read(); open(".git-assetsync", "wb").write(d.replace(b"\n", b"\r\n"))'
git commit -qam crlf
quiet asd set c.txt --release v1
n=$(wc -l < .git-assetsync | tr -d ' ')
check "registry with eol=crlf: stays CRLF, only the changed line differs" \
  "$(git diff --numstat HEAD -- .git-assetsync | cut -f1,2 | tr '\t' ' ') $(tr -cd '\r' < .git-assetsync | wc -c | tr -d ' ')" "1 0 $n"
git commit -qam set
# with core.autocrlf an LF registry gets CRLF, so git add doesn't warn
git rm -q .gitattributes && git commit -qm "no attributes"
"$PYTHON" -c 'd = open(".git-assetsync", "rb").read(); open(".git-assetsync", "wb").write(d.replace(b"\r\n", b"\n"))'
git commit -qam lf
git config core.autocrlf true
quiet asd set c.txt --release v2
check "registry with core.autocrlf: in working tree form, no warning from git add" \
  "$(tr -cd '\r' < .git-assetsync | wc -c | tr -d ' ') $(git add .git-assetsync 2>&1 | grep -c warning)" "$(wc -l < .git-assetsync | tr -d ' ') 0"
git config --unset core.autocrlf

# =============================================================================
section "34. add and mv make no directories (as cp and git mv); pull and restore do"
# =============================================================================
new_repo r34
check "add: a file into a directory that isn't there" \
  "$(asd add acme/cm new/a.txt --asset cm1.txt 2>&1; ls -d new 2>/dev/null)" "error: directory 'new' does not exist"
check "... also with -n" "$(asd add -n acme/cm new/a.txt --asset cm1.txt 2>&1)" "error: directory 'new' does not exist"
mkdir sub
check "... from a subdirectory: the path in the repository" \
  "$(cd sub && asd add acme/cm new/a.txt --asset cm1.txt 2>&1)" "error: directory 'sub/new' does not exist"
check "add: a directory whose parent isn't there" \
  "$(asd add acme/cm x/y/ 2>&1; ls -d x 2>/dev/null)" "error: directory 'x' does not exist"
check "add: a new directory itself is fine (as cp -r)" "$(rc asd add acme/cm d/) $(ls d | oneline)" "0 cm1.txt cm2.txt "
mkdir s && quiet asd add acme/cm s/a.txt --asset cm1.txt && git commit -qm add
check "mv: into a directory that isn't there (as git mv)" "$(asd mv d z/d 2>&1; ls -d z 2>/dev/null)" \
  "error: destination directory does not exist, source=d, destination=z/d"
check "mv: into one that is" "$(mkdir z && asd mv d z/d) $(ls z/d | oneline)" "moved d -> z/d (entry kept) cm1.txt cm2.txt "
git commit -qm mv
rm -r s z
check "restore: makes the directories" "$(quiet asd restore s/a.txt z/d; cat s/a.txt; ls z/d | oneline)" "c1 v2
cm1.txt cm2.txt "
rm -r s
check "pull: makes the directories" "$(quiet asd pull --overwrite s/a.txt; cat s/a.txt)" "c1 v2"

# =============================================================================
echo
echo "passed: $PASSED, failed: $FAILED"
[ "$FAILED" -eq 0 ]
