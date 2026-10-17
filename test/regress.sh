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
# test/fake_gh.py (via ASSETSYNC_GH): it answers 'gh api' calls from a
# fixture directory ($GH) that the 'release' helper fills - no network
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
#
# Adding a test: put it into the section it belongs to, or add a new
# section at the end that starts with 'section' and 'cd "$T"'.

# --- setup -------------------------------------------------------------------

# The script under test (absolute path): the argument, or the one in the
# directory above this test; the fake gh next to this test.
S=${1:-$(dirname "$0")/../git-assetsync.py}
S=$(cd "$(dirname "$S")" && pwd)/$(basename "$S")
FAKE=$(cd "$(dirname "$0")" && pwd)/fake_gh.py
if command -v cygpath >/dev/null; then    # Git Bash: C:/... for Python
  S=$(cygpath -m "$S"); FAKE=$(cygpath -m "$FAKE")
fi

# Scratch directory for all repositories; removed on exit. In Git Bash on
# Windows as a Windows path (C:/...), which native git and Python understand.
T=$(cd "$(mktemp -d)" && pwd -P)       # physical path (macOS: /var -> /private/var)
trap 'rm -rf "$T"' EXIT
command -v cygpath >/dev/null && T=$(cygpath -m "$T")
cd "$T" || exit 2

PYTHON=${PYTHON:-python3}

# Isolate from the user's setup: own HOME (global git config); the fake
# GitHub instead of gh, with its fixture directory $GH; asset files to
# publish are made in $F.
export HOME=$T/home GH=$T/gh F=$T/files
mkdir -p "$HOME" "$GH" "$F"
export FAKE_GH_DIR=$GH
export ASSETSYNC_GH="\"$PYTHON\" \"$FAKE\""
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
# --host HOST (default github.com)
release() {
  local pre=false draft=false latest=false nodigest=false baddigest=false title= notes= host=github.com
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
  printf '{"tag_name": "%s", "name": "%s", "published_at": "%s", "prerelease": %s, "draft": %s, "latest": %s, "nodigest": %s, "baddigest": %s}\n' \
    "$tag" "${title:-$tag}" "$date" $pre $draft $latest $nodigest $baddigest > "$base/$n/release.json"
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
  "error: release v3 of acme/app has 3 assets: app-linux.tar.gz, app-macos.tar.gz, app-windows.zip - choose one with --asset (or 'asset = PATTERN' in the entry)"

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
  "error: single.bin: release v3 of acme/single has 2 assets: extra.txt, single.bin - choose one with --asset (or 'asset = PATTERN' in the entry)"
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
check "a directory: refused" "$(mkdir -p dir && asd add dir acme/pair --asset one.bin 2>&1)" \
  "error: cannot add 'dir': is a directory"

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
check "wildcard characters in a file name" "$(cat 'we[i]rd f.txt') $(git status --porcelain | oneline)" \
  "r A  .git-assetsync A  \"we[i]rd f.txt\" ?? \"weird f.txt\" "
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
  "error: https://ghe.example.com/acme/ent: platform of ghe.example.com unknown - give its type (add --type github, or 'type = github' in its [source])"
reset_calls
addc e.txt https://ghe.example.com/acme/ent --asset e.txt --type github
check "GitHub Enterprise: fetched" "$(cat e.txt)" "enterprise"
check "GitHub Enterprise: --hostname" "$(grep -c '^api --hostname ghe.example.com ' "$GH/calls.log")" "2"
check "GitHub Enterprise: type recorded" "$(reg source.acme/ent.type)" "github"
check "GitHub Enterprise: status" "$(st)" ""
check "GitLab: not yet" "$(asd add x https://gitlab.com/group/proj --asset x 2>&1)" \
  "error: https://gitlab.com/group/proj: GitLab is not supported yet"


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
echo
echo "passed: $PASSED, failed: $FAILED"
[ "$FAILED" -eq 0 ]
