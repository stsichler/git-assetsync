#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# SPDX-License-Identifier: MIT-0
# Copyright (c) 2026 Stefan Sichler - https://github.com/stsichler/git-assetsync
# Developed together with Claude (Anthropic).
#
# Found this file in your repository? It was probably copied there. Run it
# with --help, or see the manual linked at the end of the following text.
"""
git-assetsync - keep files in sync with release assets of other projects.

A repository lists its synced files and directories in .git-assetsync at
its root (git-config format, like .gitmodules), each taken from release
assets of a project on GitHub or GitLab:

    [source "owner/tool"]
        url = https://github.com/owner/tool
        release = tool-*       ; optional: the newest release (by date) whose
                               ; tag matches; an exact tag pins the source
                               ; to that release; without: the latest release
        prerelease = true      ; optional: prereleases (GitLab: upcoming
                               ; releases) count too
        type = github          ; optional: github or gitlab, for hosts other
                               ; than github.com, gitlab.com and gitlab.*
    [file "bin/tool.bin"]
        source = owner/tool
        asset = tool-*-linux.bin   ; optional: asset of the release (glob, must
                                   ; match one); without: its only asset
        synced = <tag of the release the file comes from>
        digest = sha256:<hash of that asset>
        blob = <id of the file as committed>
    [dir "third_party/zlib"]       ; the directory belongs to the entry
        source = madler/zlib
        asset = zlib-*.tar.gz      ; optional: the assets (glob); without: all
        filter = zlib-headers      ; optional: the filter applied to the assets
        synced = ...; digest = ...; filterhash = <of the filter>
        tree = <id of the directory as committed>
    [filter "zlib-headers"]        ; a filter: its steps, in this order
        step = extract
        step = strip 1
        step = include '*.h' LICENSE

An entry records what the committed file (directory) comes from, so the
local state is known offline; only the check for new releases asks the
platform. It must stay exactly what its release gives: pull refuses local
modifications (in a directory: also untracked files; ignored ones don't
count); restore brings back what the release gave, pull --overwrite
updates anyway.

Filter steps (no code is run): extract [PATTERN...] (unpack the matching
files, default all, which must be archives: zip, tar, tar.gz/bz2/xz,
.gz/.bz2/.xz, and 7z with an external 7-Zip - 7zz/7z on the PATH or
ASSETSYNC_7Z; unsafe members - paths outside, links, names invalid on
Windows - are refused), subdir PATH (only that directory, as the root),
strip N (N leading directories off; files with fewer are left out),
include / exclude PATTERN... (only /
not the files matching any of them; gitignore-like), move / copy PATTERN
TARGET (TARGET/: into that directory; else a path with {path} {dir}
{parent} {name} {stem} {ext}), apply PATTERN NAME (the filter NAME on the
matching files only), convert PATTERN TARGET COMMAND (each matching file:
{in} -> {out}, which replaces it at TARGET; TARGET/: {out} a directory),
run COMMAND ({in} a directory with all files, {out} one for the result).
A step that matches no files does nothing; a filter that leaves no files
at all is an error, and so are results that would replace each other.
Commands run with sh -c (ASSETSYNC_SH; on Windows Git's sh) in a working
directory where {in} and {out} are short relative names (fw.bin, fw.c),
so results are the same everywhere; {root} is the repository's root (for
scripts: {root}/tools/x.py). Placeholders are filled in quoted, also as
ASSETSYNC_* variables. Commands run only in filters trusted in this
repository (see trust; CI: ASSETSYNC_TRUST=all). Filters are named; the
steps come from the options of filter add / set, in the order given. Downloads are kept in a cache (ASSETSYNC_CACHE; default
~/.cache/git-assetsync, %LOCALAPPDATA%\\git-assetsync; see cache).

Commands (run inside the repository; without a command: status). PATH may
be a file or a directory (= all entries below it); a path inside a
directory entry stands for that entry in status, diff, difftool, verify
and pull (commands that change entries refuse it). Options follow the
command. Only pull commits (like git pull, one commit per entry); the
other commands only change the working tree or stage, and you commit.

Basic commands - what you need day to day:

    status [PATH...]            state of the entries like `git status`: new
                                releases (or another filter) to pull, local
                                modifications
        -s, --short             short format: upstream/committed/worktree
                                columns (upstream: P pending, N new; E error)
        -v, --verbose           also list all files with their sources
        --exit-code             exit 1 if something is to pull or a file is
                                modified
        --no-fetch              don't ask the platform for new releases

    pull PATH... | --all        update the files (directories) to the selected
                                release and commit with a message naming it
                                (with its release notes and those of skipped
                                releases, shortened: assetsync.notesLines per
                                release, default 20, assetsync.notesTotalLines
                                in all, default 60); refused
                                if modified (committed or not); a directory
                                is replaced as a whole
        --all                   all files with something to pull
        --release TAG|PATTERN   this release instead of the selected one (a
                                pattern: the newest matching), once: the
                                selection stays, status shows the selected
                                one as pending (to stay: set --release)
        --overwrite             discard local modifications
        --no-edit               commit without opening the editor
        -v, --verbose           first name where each entry comes from: its
                                asset(s), source, release selection, filter,
                                the release synced (as status -v)
        --no-commit             only stage; a plain `git commit` offers the
                                proposed message (via .git/SQUASH_MSG)
        -n, --dry-run           only report what would happen

    diff [PATH...] [-- OPTS]    local modifications: what the release gave
                                (synced) -> working tree; as one `git diff`
                                (pager, colors; OPTS such as --stat go to it)
        --committed             only the committed ones (synced -> HEAD)
        --upstream              what pull would bring (synced -> what the
                                selected release gives now, filtered)
        --release TAG|PATTERN   with --upstream: what pull --release would
                                bring (as with pull: replace `pull` by
                                `diff --upstream` to see what it would do)

    difftool [PATH...] [-- OPTS]  the same in the difftool (diff.tool), file by
                                file (asks first if no PATH is given); OPTS go
                                to `git difftool` (e.g. -t meld); the working
                                file itself is passed, the other sides as
                                temporary copies
        --committed, --upstream, --release  as for diff
        -d, --dir-diff          all files at once, as two directories (e.g. a
                                directory entry in Meld; temporary copies)
        -y, --no-prompt         don't ask before each file
        --prompt                ask even if PATHs are given

    restore PATH...             like `git restore`: discard local
                                modifications - back to what the release
                                gave (the synced version), offline, without
                                pulling; nothing is committed
        -S, --staged            restore the index instead of the working tree
        -W, --worktree          restore the working tree (the default; with
                                -S: both)

    add PATH SOURCE             take the file PATH from an asset of the
                                release SOURCE selects - or with PATH/ (or
                                an existing directory) the directory, which
                                then belongs to the entry; SOURCE: the name
                                of a [source], or a URL (owner/repo:
                                github.com) - the source with that URL and
                                release selection, else a new one named
                                'owner/repo' (a number appended if taken);
                                PATH and .git-assetsync are staged like `git
                                add` - a plain `git commit` offers the
                                proposed message
        --asset PATTERN         the asset (glob; a file: exactly one match,
                                default the release's only asset; a
                                directory: all matching, default all - more
                                than 10 or 100 MiB only with --force)
        --filter NAME           the filter to apply to the assets
        --release TAG|PATTERN   release to take (exact tag: pinned) or the
                                newest one matching (default: the latest)
        --prerelease            prereleases count too (with a pattern, or
                                instead of the latest)
        --type github|gitlab    platform of the URL's host (default: derived
                                from it: github.com, gitlab.com, gitlab.*)
        --force                 replace an existing entry (unless modified)
        --overwrite             replace an existing file, or files in an
                                existing directory (they become the
                                entry's), or local modifications of an
                                entry replaced with --force
        -n, --dry-run           only show what would be done

    rm PATH...                  remove entries and their files, staged (like
                                `git rm`; refused with uncommitted changes -
                                in a directory also untracked files - unless
                                -f; ignored files stay)
        -f, --force             remove them anyway (the changes are lost)
        -n, --dry-run           only show what would be removed
    unlink PATH...              remove entries (the files are kept); also
                                broken ones, by their name
    mv OLD NEW                  move a file or directory (git mv), keeping its
                                entry
        -n, --dry-run           (both) only show what would be done

Advanced commands - change entries, sources and filters; set up:

    set PATH... OPTIONS         change entries, like source does for sources:
                                only .git-assetsync is staged, pull updates
        --source URL|SOURCE     take the files from another source (as for
                                add, with --release/--prerelease/--type); if
                                they are all files of their source, the
                                source itself is changed
        --release TAG|PATTERN, --latest, --prerelease, --no-prerelease,
        --type github|gitlab    (without --source) another release
                                selection or platform for these files only
        --asset PATTERN, --no-asset  another asset (--no-asset: the only one,
                                for a directory all)
        --filter NAME, --no-filter  another filter, or none
        -n, --dry-run           only show what would change

    edit                        open .git-assetsync in the editor (like `git
                                config --edit`), then check it (warnings
                                about gaps) and stage it; for usual changes
                                set, source, filter, unlink and mv are safer

    source                      list the [source]s (-v: with URL, release
                                selection, the release it selects now
                                (--no-fetch: not asked), file count)
    source rename OLD NEW       rename a [source] and all references to it
    source set-url NAME URL     change the URL of a [source]
    source set-release NAME TAG|PATTERN | --unset
                                select another release: a tag pins the
                                source to it, a pattern takes the newest
                                matching, --unset the latest again
        --prerelease, --no-prerelease  prereleases count too, or not
    source set-type NAME github|gitlab | --unset
                                platform of the host (--unset: derived)
                                (all: only .git-assetsync is staged; pull
                                updates the files and commits the change)
    source map [URL|SOURCE [DIR]]
                                take the releases of a source from the local
                                folder DIR instead (local development and
                                tests; never committed): one subdirectory
                                per release, named like its tag, with the
                                assets; newest = newest file date. Without
                                DIR: list the mappings
        --flat                  DIR holds the assets of all releases as files;
                                a file belongs to the release named like it
                                without its extension (.tar.gz etc. count as
                                one): rel1.7z, rel1.xml -> release rel1
        --global                for all repositories (default: this one)
        --unset                 remove the mapping

    filter                      list the filters (and who uses them)
    filter show NAME            the steps of a filter
    filter test NAME FILE...    apply a filter to local files (as if they were
                                the assets; a directory: its files), show
                                what each step did and list the result;
                                nothing else changes
        --source SOURCE         instead: the assets of its release (with
                                --release, --prerelease, --type as for add;
                                --asset PATTERN: only the matching ones)
        -o, --output DIR        write the result to DIR (new or empty)
    filter add NAME STEP-OPTIONS...  define a new filter; the steps in the
                                order given:
        --extract [PATTERN...], --subdir PATH, --strip N, --include PATTERN,
        --exclude PATTERN, --move PATTERN TARGET, --copy PATTERN TARGET,
        --apply PATTERN NAME, --convert PATTERN TARGET COMMAND, --run COMMAND
                                (consecutive --include / --exclude: one step)
    filter set NAME STEP-OPTIONS...  replace the steps of a filter
    filter rename OLD NEW       rename a filter, also where it is used
    filter remove NAME          remove a filter nothing uses

    trust                       list the filters that run commands, with their
                                state (trusted, not trusted, changed since
                                trusted) and the scripts they run; asks on a
                                terminal
    trust NAME... | --all       trust these filters (all), as they are now -
                                in .git/config, never committed
        --revoke                no longer trust them

    verify [PATH...]            filter the assets each entry was synced with
                                again and compare with the recorded base:
                                is the committed state reproducible? (exit
                                1 if not); nothing in the repository changes
        -v, --verbose           first name where each entry comes from (as
                                status -v)

    releases SOURCE|URL         list the releases, newest first, marked:
                                latest, prerelease (GitLab: upcoming), draft,
                                selected by which [source]; also outside a
                                repository (with a URL)
        --assets                also list the assets, with their sizes
        -n N, --all             the newest N releases (default 10), or all
        --type github|gitlab    platform of the URL's host

    cache                       the download cache: where, how big, the limits
    cache list                  its files, most recently used first
    cache prune                 remove what wasn't used for 90 days (or as
                                configured: assetsync.cacheMaxAge DAYS,
                                assetsync.cacheMaxSize SIZE; 0/off: none) -
                                also done automatically after a download, at
                                most once a day
        --older-than DAYS, --max-size SIZE  other limits (SIZE: 500M, 2G)
        -n, --dry-run           only show what would be removed
    cache clear [-n]            remove everything
    cache dir                   print its directory (e.g. for CI caching)

    install-hooks               install pre-push/post-merge hooks (or update
                                them): reminders about new releases, local
                                modifications, errors; pre-push also warns
                                if a pushed entry's release isn't on the
                                platform with these assets (e.g. from a
                                local folder): assetsync.pushCheck = warn |
                                error (refuses the push) | off
        --force                 add our lines to existing hooks of other
                                tools, right after the #! line (default:
                                show the lines to add)
    uninstall-hooks             remove them again
    hook pre-push|post-merge    what the installed hooks run

    Common options:
        --color[=WHEN], --no-color  always, never or auto (default)
        --remote                ignore mappings to local folders (status,
                                pull, diff, add, set, verify, releases, ...)

Exit codes: 0 ok, 1 unfinished (not committed, --exit-code), 2 error.

Files stored in Git LFS and line-ending conversions are handled: a file
is recorded as `git add` stores it. Output is colored like git's
(color.assetsync / color.ui, --color, NO_COLOR).

GitHub is accessed through the GitHub CLI (`gh api`, logged in with `gh
auth login` or GH_TOKEN), GitLab through the GitLab CLI (`glab api`,
`glab auth login` or GITLAB_TOKEN); ASSETSYNC_GH / ASSETSYNC_GLAB set
other commands for them.

Requires Python >= 3.8, Git >= 2.28, and gh or glab (git-lfs for LFS
files, 7-Zip for 7z archives).
Works on Linux, macOS and Windows.
Manual: https://github.com/stsichler/git-assetsync/blob/main/MANUAL.md
"""

import argparse
import bz2
import fnmatch
import gzip
import hashlib
import json
import lzma
import os
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import time
import zipfile
import zlib
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path, PureWindowsPath
from types import SimpleNamespace
from typing import Any, Optional
from urllib.error import HTTPError, URLError
from urllib.parse import quote, unquote, urlparse
from urllib.request import urlopen

__version__ = "0.13.2"
REGISTRY = ".git-assetsync"
EXIT_OK, EXIT_PENDING, EXIT_ERROR = 0, 1, 2
EXIT_REFUSED = 3          # hook pre-push: refuse the push (assetsync.pushCheck = error)
HOOK_MARKER = "git-assetsync"
# What the installed hooks run - an interface, so that later versions need no
# reinstall. Only EXIT_REFUSED blocks a push; any other failure (e.g.
# git-assetsync not installed) never does. pre-push: the pushed refs on stdin
# are kept for the commands after these lines (e.g. git lfs pre-push; empty:
# nothing, so they get EOF, not a blank line); git always passes arguments,
# run by hand there is nothing to read. Names as in git-filesync's hook, so
# both blocks can follow each other in one hook.
HOOKS = {
    "pre-push": "\n".join([
        'git_assetsync_refs=$([ $# -eq 0 ] || cat)',
        f'''printf '%s\\n' "$git_assetsync_refs" | git assetsync hook pre-push "$@" || '''
        f'[ $? -ne {EXIT_REFUSED} ] || exit 1',
        '[ -z "$git_assetsync_refs" ] || exec <<git_assetsync_refs_end',
        '$git_assetsync_refs',
        'git_assetsync_refs_end']),
    "post-merge": 'git assetsync hook post-merge "$@" </dev/null || true',
}
REGISTRY_HEADER = ("# git-assetsync: files and directories of this repository that are taken\n"
                   "# from release assets of other projects. Maintained by 'git assetsync';\n"
                   "# synced/digest/blob/tree record what each one comes from.\n")
# add warns about binary files at least this big that are not stored in LFS
LFS_HINT_SIZE = 1 << 20
# the subject of every proposed commit message starts with it: which commits
# came from git-assetsync (as git-filesync's '[filesync] ')
COMMIT_PREFIX = "[assetsync] "
# release notes in a commit message: at most this many lines of this length per
# release (assetsync.notesLines), this many in all (assetsync.notesTotalLines)
NOTES_LINES, NOTES_WIDTH, NOTES_TOTAL_LINES = 20, 200, 60
# releases skipped (or reverted) by a pull, listed in its commit message: at most
LIST_RELEASES = 10
# unpacking archives: at most this much and this many files (zip bombs)
MAX_EXTRACT_SIZE, MAX_EXTRACT_FILES = 2 << 30, 100000
# all assets of a release for a directory (add without --asset): more needs --force
MAX_ALL_ASSETS, MAX_ALL_SIZE = 10, 100 << 20
# download cache: files unused for this many days are removed (assetsync.cacheMaxAge),
# automatically at most once a day; files used in the last minutes are never removed
CACHE_MAX_AGE, CACHE_PRUNE_EVERY, CACHE_GRACE = 90, 86400, 600


class FsError(Exception):
    pass


# --------------------------------------------------------------------------
# colors
# --------------------------------------------------------------------------

STYLES = {"bold": "1", "dim": "2", "red": "31", "green": "32", "yellow": "33",
          "cyan": "36", "boldred": "1;31"}
_color = {"out": False, "err": False}


def setup_colors(mode, cwd=None):
    """Decide per stream like git: --color, NO_COLOR, color.assetsync/color.ui."""
    def want(stream):
        if mode == "always":
            return True
        if mode == "never" or os.environ.get("NO_COLOR"):
            return False
        tty = "true" if stream.isatty() else "false"
        p = git(["config", "--get-colorbool", "color.assetsync", tty], cwd=cwd, check=False)
        return out(p) == "true"
    _color["out"], _color["err"] = want(sys.stdout), want(sys.stderr)
    if os.name == "nt" and (_color["out"] or _color["err"]):
        os.system("")          # enables ANSI escape processing in the Windows console


def paint(text, style, stream="out"):
    if not style or not _color[stream]:
        return text
    return f"\033[{STYLES[style]}m{text}\033[m"


def warn(msg):
    print(f"{paint('warning:', 'yellow', 'err')} {msg}", file=sys.stderr)


def error(msg):
    print(f"{paint('error:', 'boldred', 'err')} {msg}", file=sys.stderr)


# --------------------------------------------------------------------------
# git plumbing helpers
# --------------------------------------------------------------------------

_clean_env = None


def clean_env():
    """Environment without repository-local GIT_* variables.

    Hooks may run with GIT_DIR & co. set for this repository; other
    programs (gh) must not inherit them.
    """
    global _clean_env
    if _clean_env is None:
        p = subprocess.run(["git", "rev-parse", "--local-env-vars"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        names = set(p.stdout.decode().split()) if p.returncode == 0 else set()
        names |= {"GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX",
                  "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY"}
        _clean_env = {k: v for k, v in os.environ.items() if k not in names}
    return _clean_env


def git(args, cwd=None, data=None, check=True, env=None):
    p = subprocess.run(["git"] + [str(a) for a in args], cwd=cwd, input=data,
                       env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and p.returncode != 0:
        err = p.stderr.decode("utf-8", "replace").strip()
        raise FsError(f"git {args[0]} failed: {err}")
    return p


def out(p):
    return p.stdout.decode("utf-8", "replace").strip()


def lit(path):
    """Pathspec matching exactly this path: no wildcards, no magic. Not via
    GIT_LITERAL_PATHSPECS, which would leak into hooks run by `git commit`."""
    return f":(literal){path}"


def cmd_arg(path):
    """A path as pathspec argument in a git command shown to the user."""
    if re.search(r"[*?\[\\]|^:", path):
        path = lit(path)
    return path if re.fullmatch(r"[\w./@+-]+", path) else f'"{path}"'


def plural(n, word):
    """'1 file' / '2 files'."""
    return f"{n} {word}{'' if n == 1 else 's'}"


def is_true(value):
    return (value or "").lower() in ("true", "yes", "on", "1")


def norm_url(url):
    u = url.strip().rstrip("/")
    return u[:-4] if u.endswith(".git") else u


def repo_label(url):
    """'https://github.com/owner/repo' -> 'owner/repo'."""
    m = re.search(r"([^/:]+/[^/:]+?)(?:\.git)?/?$", url.strip())
    return m.group(1) if m else url


# --------------------------------------------------------------------------
# Git LFS
# --------------------------------------------------------------------------

LFS_HEADER = b"version https://git-lfs.github.com/spec/v1\n"


def lfs_pointer(data):
    """(sha256, size) if data is a Git LFS pointer, else None."""
    if len(data) < 1024 and data.startswith(LFS_HEADER):
        oid = re.search(rb"^oid sha256:([0-9a-f]{64})$", data, re.M)
        size = re.search(rb"^size (\d+)$", data, re.M)
        if oid and size:
            return oid.group(1).decode(), int(size.group(1))
    return None


def lfs_smudge(run, data, path, where):
    """Content behind an LFS pointer, via `git lfs smudge` in that repository
    (local LFS store first, then the repository's LFS server)."""
    p = run(["lfs", "smudge", "--", path], data=data, check=False)
    if p.returncode or lfs_pointer(p.stdout):
        msg = p.stderr.decode("utf-8", "replace").strip().splitlines()
        raise FsError(f"'{path}' is stored in Git LFS in {where}, but its content is not "
                      f"available ({msg[-1] if msg else 'is git-lfs installed?'})")
    return p.stdout


# --------------------------------------------------------------------------
# release platforms
# --------------------------------------------------------------------------

@dataclass
class Asset:
    name: str
    id: str
    size: Optional[int] = None
    digest: Optional[str] = None   # 'sha256:<hex>' if the platform reports it
    url: Optional[str] = None      # where to download it (GitLab: the link's URL)


@dataclass
class Release:
    tag: str                  # identifies the release (opaque string)
    title: str
    date: str                 # publication date, ISO 8601 (UTC)
    url: str                  # web page of the release
    prerelease: bool = False
    draft: bool = False
    assets: list = field(default_factory=list)
    notes: str = ""           # description / changelog (Markdown)
    local: bool = False       # from a local folder (map), not published


class NotFound(FsError):
    pass


def cli_command(var, default):
    """A platform CLI command: the environment variable var (split like a
    shell would, e.g. 'python3 fake_gh.py' for tests) or default."""
    cmd = os.environ.get(var, "").strip()
    return shlex.split(cmd) if cmd else [default]


class Platform:
    """Releases of a project on a hosting platform. The platform's CLI (`gh
    api`, `glab api`) serves only as an authenticated HTTP client - it
    handles login, self-hosted instances and SSO; the REST semantics are
    ours, so the CLI's own output formats don't matter. Subclasses give the
    API paths and turn the answers into Releases."""

    PER_PAGE = 100
    CLI = CLI_VAR = CLI_NAME = CLI_URL = KIND = ""
    # API paths, and a release from the API's answer: given by the subclasses
    project_path = list_path = latest_path = property(lambda self: "")

    def tag_path(self, tag):
        raise NotImplementedError

    @staticmethod
    def release(d) -> Release:
        raise NotImplementedError

    def __init__(self, host, project, label):
        self.host, self.project, self.label = host, project, label

    where = property(lambda self: self.label)    # for messages

    def api(self, path, headers=(), stdout=None):
        """Raw response of a GET request; NotFound for HTTP 404. The host is
        always given: the CLIs would otherwise take it from the environment
        (GH_HOST) or from the repository they run in."""
        cli = cli_command(self.CLI_VAR, self.CLI)
        args = ["api", "--hostname", self.host]
        for h in headers:
            args += ["-H", h]
        try:
            p = subprocess.run(cli + args + [path], stdout=stdout or subprocess.PIPE,
                               stderr=subprocess.PIPE, env=clean_env())
        except OSError as e:
            raise FsError(f"cannot run the {self.CLI_NAME} '{cli[0]}' ({e.strerror}) - install "
                          f"it from {self.CLI_URL} and log in with '{self.CLI} auth login'")
        if p.returncode:
            err = p.stderr.decode("utf-8", "replace").strip()
            if re.search(r"\bHTTP 404\b", err):
                raise NotFound(err)
            last = err.splitlines()[-1] if err else f"exit code {p.returncode}"
            raise FsError(f"{self.label}: '{self.CLI} api {path}' failed: {last}")
        return p.stdout

    def json(self, path):
        try:
            return json.loads(self.api(path).decode("utf-8"))
        except ValueError as e:
            raise FsError(f"{self.label}: unexpected answer to '{self.CLI} api {path}': {e}")

    def not_found(self):
        return FsError(f"{self.KIND} {self.label} not found (or no access)")

    def check_project(self):
        """Error if the project doesn't exist (or isn't accessible)."""
        try:
            self.api(self.project_path)
        except NotFound:
            raise self.not_found()

    def get(self, path):
        """Release at an API path, None if there is none."""
        try:
            return self.release(self.json(path))
        except NotFound:
            return None

    def latest(self):
        """The release the platform calls latest, None if there is none."""
        r = self.get(self.latest_path)
        if not r:
            self.check_project()
        return r

    def by_tag(self, tag):
        return self.get(self.tag_path(quote(tag, safe="")))

    def releases(self, limit=None):
        """All releases (page by page, independent of the CLI's paging); with
        limit, at least that many (if there are) - the platforms list the
        newest first, by their own order."""
        result, page = [], 1
        while True:
            try:
                items = self.json(f"{self.list_path}?per_page={self.PER_PAGE}&page={page}")
            except NotFound:
                raise self.not_found()
            if not isinstance(items, list):
                raise FsError(f"{self.label}: unexpected answer listing the releases")
            result += [self.release(d) for d in items]
            if len(items) < self.PER_PAGE or limit and len(result) >= limit:
                return result
            page += 1


class GitHub(Platform):
    """Releases of a GitHub repository (also GitHub Enterprise)."""

    CLI, CLI_VAR, CLI_NAME, CLI_URL, KIND = \
        "gh", "ASSETSYNC_GH", "GitHub CLI", "https://cli.github.com", "repository"

    project_path = property(lambda self: f"repos/{self.project}")
    list_path = property(lambda self: f"repos/{self.project}/releases")
    # marked as latest, or the newest that is neither a prerelease nor a draft
    latest_path = property(lambda self: f"repos/{self.project}/releases/latest")

    def tag_path(self, tag):
        return f"repos/{self.project}/releases/tags/{tag}"

    @staticmethod
    def release(d):
        assets = [Asset(a.get("name", ""), str(a.get("id", "")), a.get("size"),
                        a.get("digest")) for a in d.get("assets") or []]
        return Release(d.get("tag_name", ""), d.get("name") or "",
                       d.get("published_at") or d.get("created_at") or "",
                       d.get("html_url", ""), bool(d.get("prerelease")),
                       bool(d.get("draft")), assets, d.get("body") or "")

    def download(self, asset, dest):
        with open(dest, "wb") as f:
            self.api(f"repos/{self.project}/releases/assets/{asset.id}",
                     headers=["Accept: application/octet-stream"], stdout=f)


class GitLab(Platform):
    """Releases of a GitLab project (gitlab.com or self-managed). Assets are
    the release's links; GitLab reports no digests. Releases with a future
    release date ('upcoming') count as prereleases; there are no drafts."""

    CLI, CLI_VAR, CLI_NAME, CLI_URL, KIND = \
        "glab", "ASSETSYNC_GLAB", "GitLab CLI", "https://gitlab.com/gitlab-org/cli", "project"

    pid = property(lambda self: quote(self.project, safe=""))
    project_path = property(lambda self: f"projects/{self.pid}")
    list_path = property(lambda self: f"projects/{self.pid}/releases")
    # the newest by release date
    latest_path = property(lambda self: f"projects/{self.pid}/releases/permalink/latest")

    def tag_path(self, tag):
        return f"projects/{self.pid}/releases/{tag}"

    @staticmethod
    def release(d):
        links = (d.get("assets") or {}).get("links") or []
        assets = [Asset(a.get("name", ""), str(a.get("id", "")), url=a.get("url", ""))
                  for a in links]
        return Release(d.get("tag_name", ""), d.get("name") or "",
                       d.get("released_at") or d.get("created_at") or "",
                       (d.get("_links") or {}).get("self", ""),
                       bool(d.get("upcoming_release")), False, assets,
                       d.get("description") or "")

    def api_path(self, url):
        """API path for downloading a link on this host - with the login of
        the CLI, as private projects need: API URLs (e.g. generic packages),
        and job artifact and upload URLs, which have API equivalents. None
        for other URLs."""
        u = urlparse(url)
        if (u.hostname or "").lower() != self.host or u.scheme not in ("https", "http"):
            return None
        path = u.path         # still percent-encoded, as the API wants it
        query = f"?{u.query}" if u.query else ""
        if "/api/v4/" in path:
            return path.split("/api/v4/", 1)[1] + query
        m = re.fullmatch(r"/(.+?)/-/jobs/(\d+)/artifacts/raw/(.+)", path)
        if m:
            return f"projects/{quote(unquote(m.group(1)), safe='')}/jobs/{m.group(2)}" \
                   f"/artifacts/{m.group(3)}{query}"
        m = re.fullmatch(r"/-/project/(\d+)/uploads/([0-9a-f]{32})/(.+)", path)
        if m:
            return f"projects/{m.group(1)}/uploads/{m.group(2)}/{m.group(3)}"
        m = re.fullmatch(r"/(.+?)/uploads/([0-9a-f]{32})/(.+)", path)
        if m:
            return f"projects/{quote(unquote(m.group(1)), safe='')}/uploads/{m.group(2)}" \
                   f"/{m.group(3)}"
        return None

    def download(self, asset, dest):
        path = self.api_path(asset.url)
        if path:
            with open(dest, "wb") as f:
                self.api(path, stdout=f)
        else:
            http_download(asset.url, dest, f"{asset.name} of {self.label}")


def http_download(url, dest, what):
    """Plain download of a URL elsewhere (no login: public files only)."""
    scheme = urlparse(url).scheme
    if scheme not in ("https", "http"):
        raise FsError(f"{what}: cannot download '{url}'")
    if scheme == "http":
        warn(f"{what}: downloading over unencrypted http ({url})")
    try:
        with urlopen(url, timeout=60) as r, open(dest, "wb") as f:
            shutil.copyfileobj(r, f, 1 << 20)
    except HTTPError as e:
        raise FsError(f"{what}: download of {url} failed: HTTP {e.code} (only links to API "
                      "URLs, job artifacts and uploads of the project are downloaded with "
                      "your login)")
    except (URLError, OSError) as e:
        raise FsError(f"{what}: download of {url} failed: {getattr(e, 'reason', e)}")


class LocalAsset(Asset):
    """An asset in a local folder: its digest is computed when needed."""

    # a property where Asset has a field: fine at runtime, not for type checkers
    @property
    def digest(self):  # pyright: ignore[reportIncompatibleVariableOverride]
        if self._digest is None:
            self._digest = sha256_file(self.url)[0]
        return self._digest

    @digest.setter
    def digest(self, value):  # pyright: ignore[reportIncompatibleVariableOverride]
        self._digest = value


def flat_tag(name):
    """Tag of a file in a flat local folder: its name without the extension
    ('.tar.gz' and the like count as one): rel1.7z, rel1.tar.gz -> rel1."""
    stem, dot, _ = name.rpartition(".")
    if not dot or not stem:
        return name
    if stem.lower().endswith(".tar") and len(stem) > 4:
        stem = stem[:-4]
    return stem


class LocalFolder:
    """Releases in a local folder a source URL is mapped to (see map), for
    local development and tests: each subdirectory is a release named like
    its tag, its files are the assets - or, flat, its files are the assets,
    grouped into releases by their names without extension. A release is
    dated by its newest file. No notes, prereleases or drafts; nothing is
    cached."""

    def __init__(self, folder, url, flat=False):
        self.dir, self.flat = Path(folder), flat
        self.host, self.project = parse_url(url)
        self.label = self.project

    where = property(lambda self: f"{self.label} (local folder {self.dir})")

    def check_project(self):
        if not self.dir.is_dir():
            raise FsError(f"local folder {self.dir} of {self.label} not found (see "
                          "'git assetsync source map')")

    @staticmethod
    def files_in(d):
        return sorted((f for f in d.iterdir() if f.is_file() and not f.name.startswith(".")),
                      key=lambda f: f.name)

    @staticmethod
    def release(tag, files, d):
        """The release tag with these files as assets (none: dated by d)."""
        mtime = max([f.stat().st_mtime for f in files] or [d.stat().st_mtime])
        date = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(mtime)) + \
            f".{int(mtime % 1 * 1e6):06d}Z"
        assets = [LocalAsset(f.name, f.name, f.stat().st_size, url=str(f)) for f in files]
        return Release(tag, tag, date, "", assets=assets, local=True)

    def releases(self, limit=None):
        self.check_project()
        if self.flat:
            groups = {}
            for f in self.files_in(self.dir):
                groups.setdefault(flat_tag(f.name), []).append(f)
            return [self.release(tag, files, self.dir) for tag, files in sorted(groups.items())]
        return [self.release(d.name, self.files_in(d), d) for d in sorted(self.dir.iterdir())
                if d.is_dir() and not d.name.startswith(".")]

    def latest(self):
        rels = self.releases()
        return max(rels, key=lambda r: r.date) if rels else None

    def by_tag(self, tag):
        self.check_project()
        if not tag or tag in (".", "..") or re.search(r"[/\\]", tag):
            return None
        if self.flat:
            files = [f for f in self.files_in(self.dir) if flat_tag(f.name) == tag]
            return self.release(tag, files, self.dir) if files else None
        d = self.dir / tag
        return self.release(tag, self.files_in(d), d) if d.is_dir() else None


PLATFORMS = {"github": GitHub, "gitlab": GitLab}
# source URLs mapped to local folders (see map): normalized URL -> (folder,
# flat); loaded by main() unless --remote is given
MAPPINGS = {}
MAP_REGEX = r"^assetsync\..+\.(localpath|layout)$"


def local_mappings(scope=None, cwd=None):
    """List of (scope, config key, url, folder, flat) from assetsync.<url>.
    localpath entries (and their layout = flat in the same scope), in git's
    precedence order (system, global, local: last wins)."""
    args = ["config", "--show-scope"] + ([scope] if scope else []) + ["--get-regexp", MAP_REGEX]
    paths, flat = [], set()
    for line in out(git(args, cwd=cwd, check=False)).splitlines():
        sc, _, rest = line.partition("\t")
        key, _, val = rest.partition(" ")
        url, _, var = key[len("assetsync."):].rpartition(".")
        if var == "localpath":
            paths.append((sc, key, url, val))
        elif val.strip().lower() == "flat":
            flat.add((sc, url))
    return [(sc, key, url, d, (sc, url) in flat) for sc, key, url, d in paths]


def mappings_for(url, scope=None, cwd=None):
    """local_mappings() for this URL only."""
    return [m for m in local_mappings(scope, cwd) if norm_url(m[2]) == norm_url(url)]


def parse_url(url):
    """(host, project path) of a source URL."""
    u = urlparse(url)
    path = norm_url(u.path.split("/-/")[0]).strip("/")
    if u.scheme not in ("https", "http") or not u.hostname or not path:
        raise FsError(f"'{url}' is not a URL like https://github.com/owner/repo")
    return u.hostname.lower(), path


def source_url(arg):
    """URL for add's SOURCE argument: 'owner/repo' means github.com."""
    if re.fullmatch(r"[\w.-]+/[\w.-]+", arg):
        return f"https://github.com/{norm_url(arg)}"
    host, path = parse_url(arg)
    return f"{urlparse(arg).scheme}://{host}/{path}"


def platform_of(url, kind=None, remote=False):
    """Platform client for a source URL - its local folder if it is mapped
    to one (unless remote); kind: its type key, else derived from the host."""
    if not remote and norm_url(url) in MAPPINGS:
        folder, flat = MAPPINGS[norm_url(url)]
        return LocalFolder(folder, url, flat)
    host, path = parse_url(url)
    kind = (kind or ("github" if host == "github.com" else
                     "gitlab" if host == "gitlab.com" or "gitlab" in host.split(".")[0]
                     else "")).lower()
    if kind not in PLATFORMS:
        if kind:
            raise FsError(f"{url}: unknown type '{kind}' (supported: "
                          f"{', '.join(sorted(PLATFORMS))})")
        raise FsError(f"{url}: platform of {host} unknown - give its type (add --type "
                      "github|gitlab, or 'git assetsync source set-type <source> "
                      "github|gitlab')")
    if kind == "github" and path.count("/") != 1:
        raise FsError(f"'{url}' is not a GitHub repository URL (https://{host}/owner/repo)")
    if path.count("/") < 1:
        raise FsError(f"'{url}' is not a GitLab project URL (https://{host}/group/project)")
    return PLATFORMS[kind](host, path, path)


def is_pattern(rule):
    return any(c in rule for c in "*?[")


def select_release(origin, rule, prerelease):
    """The release a source takes: an exact tag (pinned), the newest release
    by date whose tag matches a pattern, or - without rule - the latest.
    Tags are opaque: never compared or sorted by name. Drafts never count,
    prereleases only with prerelease (or when pinned to one)."""
    if rule and not is_pattern(rule):
        r = origin.by_tag(rule)
        if not r:
            raise FsError(f"no release with tag '{rule}' in {origin.where}")
        return r
    if not rule and not prerelease:
        r = origin.latest()
        if not r:
            raise FsError(f"no release in {origin.where}")
        return r
    cands = [r for r in origin.releases() if not r.draft and (prerelease or not r.prerelease)
             and (not rule or fnmatch.fnmatchcase(r.tag, rule))]
    if not cands:
        what = f"with a tag matching '{rule}'" if rule else ""
        raise FsError(f"no release {what} in {origin.where}".replace("  ", " ")
                      + ("" if prerelease else " (prereleases not counted)"))
    return max(cands, key=lambda r: r.date)


def match_asset(release, pattern, label, choose="--asset PATTERN"):
    """The one asset of release whose name matches pattern; without
    pattern, the release's only asset. choose: how to give a pattern."""
    if not pattern:
        if len(release.assets) == 1:
            return release.assets[0]
        names = ", ".join(a.name for a in release.assets)
        raise FsError(f"release {release.tag} of {label} has "
                      + (f"{len(release.assets)} assets: {names} - choose one with {choose}"
                         if names else "no assets"))
    found = [a for a in release.assets if fnmatch.fnmatchcase(a.name, pattern)]
    if len(found) == 1:
        return found[0]
    if not found:
        names = ", ".join(a.name for a in release.assets) or "none"
        raise FsError(f"release {release.tag} of {label} has no asset matching "
                      f"'{pattern}' (assets: {names})")
    raise FsError(f"'{pattern}' matches {len(found)} assets of release {release.tag} of "
                  f"{label}: {', '.join(a.name for a in found)} - use a more specific pattern")


def select_assets(release, pattern, label, is_dir, choose="--asset PATTERN"):
    """The assets an entry takes: for a file the one matching pattern (or
    the release's only one); for a directory all matching (or all)."""
    if not is_dir:
        return [match_asset(release, pattern, label, choose)]
    found = [a for a in release.assets if not pattern or fnmatch.fnmatchcase(a.name, pattern)]
    if not found and pattern:
        names = ", ".join(a.name for a in release.assets) or "none"
        raise FsError(f"release {release.tag} of {label} has no asset matching '{pattern}' "
                      f"(assets: {names})")
    if not found:
        raise FsError(f"release {release.tag} of {label} has no assets")
    return found


def assets_digest(pairs):
    """The digest recorded for an entry's assets [(name, digest)]: that of
    the asset if it is one, else one over all names and digests. None if a
    digest is missing."""
    if not pairs or any(not d or not d.lower().startswith("sha256:") for _, d in pairs):
        return None
    if len(pairs) == 1:
        return pairs[0][1].lower()
    text = "".join(f"{n}\t{d.lower()}\n" for n, d in sorted(pairs))
    return "sha256:" + hashlib.sha256(text.encode("utf-8")).hexdigest()


def cache_root():
    """The download cache: ASSETSYNC_CACHE, or the platform's cache dir."""
    if os.environ.get("ASSETSYNC_CACHE"):
        return Path(os.environ["ASSETSYNC_CACHE"])
    if os.name == "nt":
        base = os.environ.get("LOCALAPPDATA") or str(Path.home() / "AppData" / "Local")
    else:
        base = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    return Path(base) / "git-assetsync"


def sha256_file(path):
    """('sha256:<hex>', size) of a file."""
    h, size = hashlib.sha256(), 0
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
            size += len(chunk)
    return "sha256:" + h.hexdigest(), size


def get_asset(origin, release, asset):
    """(file, digest) of an asset in the download cache, downloaded and
    checked first if it isn't there. Contents are kept by their SHA-256; an
    index maps platform, project, tag and asset to it, for platforms that
    report no digests (GitLab). Assets in a local folder are not cached."""
    if isinstance(origin, LocalFolder):
        return Path(asset.url), asset.digest
    root = cache_root()
    store, index = root / "sha256", root / "index"
    key = "\n".join([type(origin).__name__, origin.host, origin.project, release.tag,
                     asset.id, asset.name])
    entry = index / hashlib.sha256(key.encode("utf-8")).hexdigest()
    listed = asset.digest.lower() if (asset.digest or "").lower().startswith("sha256:") else None
    known = listed            # else what the index says: no promise, a re-upload may differ
    if not known and entry.is_file():
        known = entry.read_text(encoding="utf-8", errors="replace").split("\n", 1)[0].strip()
    if known and (store / known[7:]).is_file():
        try:
            os.utime(store / known[7:])       # last used: for cleaning up the cache
        except OSError:
            pass
        return store / known[7:], known
    try:
        store.mkdir(parents=True, exist_ok=True)
        index.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        raise FsError(f"cannot create the download cache {root} ({e.strerror}) - "
                      "set ASSETSYNC_CACHE to another directory")
    what = f"{asset.name} of {origin.label} {release.tag}"
    print(paint(f"Downloading {asset.name} ({origin.label} {release.tag}) ...", "dim", "err"),
          file=sys.stderr)
    tmp = store / f".tmp-{os.getpid()}-{entry.name[:16]}"
    try:
        origin.download(asset, tmp)
        digest, size = sha256_file(tmp)
        if listed and listed != digest:
            raise FsError(f"{what}: downloaded file has {digest}, but the release lists {listed}")
        if asset.size is not None and asset.size != size:
            raise FsError(f"{what}: downloaded {size} bytes, but the release lists {asset.size}")
        os.replace(tmp, store / digest[7:])
    finally:
        if tmp.exists():
            tmp.unlink()
    part = entry.with_name(f"{entry.name}.tmp{os.getpid()}")
    # the digest; then what it is, for 'cache list'
    part.write_text(f"{digest}\n{origin.host}/{origin.project}\t{release.tag}\t{asset.name}\n",
                    encoding="utf-8")
    os.replace(part, entry)
    auto_prune()
    return store / digest[7:], digest


def cache_files():
    """[(file, size, last used, [descriptions])] of the files in the cache,
    most recently used first. A description: 'host/project  tag  asset'."""
    root = cache_root()
    names = {}
    for f in (root / "index").glob("*") if (root / "index").is_dir() else []:
        try:
            lines = f.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        if lines and lines[0].startswith("sha256:") and len(lines) > 1:
            names.setdefault(lines[0][7:], []).append("  ".join(lines[1].split("\t")))
    result = []
    for f in (root / "sha256").glob("*") if (root / "sha256").is_dir() else []:
        if f.is_file() and not f.name.startswith("."):
            st = f.stat()
            result.append((f, st.st_size, st.st_mtime, sorted(names.get(f.name, []))))
    return sorted(result, key=lambda x: x[2], reverse=True)


def parse_size(text):
    """Bytes of '500M', '2G', '1.5GiB', '100k', '1000' (1024-based)."""
    m = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*([kmgt]?)(?:i?b)?\s*", text or "", re.I)
    if not m:
        raise FsError(f"'{text}' is not a size like 500M or 2G")
    return int(float(m.group(1)) * 1024 ** " kmgt".index(m.group(2).lower() or " "))


def cache_limits():
    """(max age in days, max size in bytes) from assetsync.cacheMaxAge
    (default CACHE_MAX_AGE) and assetsync.cacheMaxSize (default none);
    None = no limit ('0' or 'off')."""
    off = ("0", "off", "false", "no", "never")
    age, size = (out(git(["config", f"assetsync.{key}"], check=False)).strip()
                 for key in ("cacheMaxAge", "cacheMaxSize"))
    if not age:
        max_age = CACHE_MAX_AGE
    elif age.lower() in off:
        max_age = None
    elif age.isdigit():
        max_age = int(age)
    else:
        raise FsError(f"assetsync.cacheMaxAge: '{age}' is not a number of days")
    return max_age, None if not size or size.lower() in off else parse_size(size)


def prune_cache(max_age, max_size, dry_run=False, grace=True):
    """Remove from the cache what wasn't used for max_age days, then the
    least recently used until it is at most max_size - with grace never what
    was used in the last minutes; also leftovers (unfinished downloads, index entries
    without their file). Returns the removed [(file, size, last used,
    descriptions)]."""
    now, removed = time.time(), []
    files = cache_files()
    total = sum(size for _, size, _, _ in files)
    for item in reversed(files):                  # least recently used first
        f, size, used, _ = item
        if grace and now - used < CACHE_GRACE:
            continue
        if (max_age is not None and now - used > max_age * 86400) or \
                (max_size is not None and total > max_size):
            if not dry_run:
                try:
                    f.unlink()
                except OSError:
                    continue
            removed.append(item)
            total -= size
    if not dry_run:
        root = cache_root()
        gone = {f.name for f, _, _, _ in removed}
        for f in (root / "index").glob("*") if (root / "index").is_dir() else []:
            try:
                if ".tmp" in f.name:
                    stale = now - f.stat().st_mtime > 86400
                else:
                    first = f.read_text(encoding="utf-8", errors="replace").split("\n", 1)[0]
                    stale = first[7:] in gone or not (root / "sha256" / first[7:]).is_file()
                if stale:
                    f.unlink()
            except OSError:
                pass
        for f in (root / "sha256").glob(".tmp-*") if (root / "sha256").is_dir() else []:
            try:
                if now - f.stat().st_mtime > 86400:
                    f.unlink()
            except OSError:
                pass
    return removed


def auto_prune():
    """After a download: clean up the cache by the configured limits, at most
    once a day. Never fails a command."""
    marker = cache_root() / "last-prune"
    try:
        if marker.is_file() and time.time() - marker.stat().st_mtime < CACHE_PRUNE_EVERY:
            return
        max_age, max_size = cache_limits()
        marker.write_text("", encoding="ascii")
        if max_age is not None or max_size is not None:
            prune_cache(max_age, max_size)
    except (FsError, OSError) as e:
        warn(f"download cache not cleaned up: {e}")


# --------------------------------------------------------------------------
# filters: unpacking archives and selecting files, without running code
# --------------------------------------------------------------------------

# filter steps; the options of filter add / set have the same names
STEPS = ("extract", "subdir", "strip", "include", "exclude", "move", "copy", "apply",
         "convert", "run")
# the steps that run commands: only in trusted filters (see trust)
COMMAND_STEPS = ("convert", "run")
# placeholders in the target of move / copy, for a file a/b/c.txt
PLACEHOLDERS = ("path", "dir", "parent", "name", "stem", "ext")
WIN_RESERVED = re.compile(r"(?i)(con|prn|aux|nul|com[0-9]|lpt[0-9])(\..*)?")


def safe_path(name, what):
    """Normalized relative path of an archive member (or asset), None for
    the archive's root; an error for paths that could escape the target or
    that are no valid file names on every platform (Windows included)."""
    parts = [p for p in name.replace("\\", "/").split("/") if p not in ("", ".")]
    if name.startswith(("/", "\\")) or ".." in parts:
        raise FsError(f"{what}: unsafe path '{name}'")
    for p in parts:
        if p.lower().rstrip(". ") == ".git":
            raise FsError(f"{what}: unsafe path '{name}' (.git)")
        if re.search(r'[<>:"|?*\x00-\x1f]', p) or p[-1] in ". " or WIN_RESERVED.fullmatch(p):
            raise FsError(f"{what}: '{name}' is not a valid file name on every platform")
    return "/".join(parts) or None


class Work:
    """Temporary files of a filter run. The files of a stage are
    {path: (file, executable)}; files are never changed once written."""

    def __init__(self, what, cwd=None, env=None, trusted=()):
        self.what = what
        self.dir = Path(tempfile.mkdtemp(prefix="assetsync-"))
        self.n = self.size = self.count = 0
        self.cwd, self.env = cwd, env or {}   # for commands: repository root, ASSETSYNC_*
        self.trusted = set(trusted)           # filters whose commands may run

    def new_dir(self):
        self.n += 1
        d = self.dir / f"d{self.n}"
        d.mkdir()
        return d

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        shutil.rmtree(self.dir, ignore_errors=True)

    def copy(self, src, size_hint=None):
        """A new file with the content of the stream src, within the limits."""
        self.count += 1
        if self.count > MAX_EXTRACT_FILES:
            raise FsError(f"{self.what}: more than {MAX_EXTRACT_FILES} files")
        self.n += 1
        dest = self.dir / str(self.n)
        with open(dest, "wb") as f:
            for chunk in iter(lambda: src.read(1 << 20), b""):
                self.size += len(chunk)
                if self.size > MAX_EXTRACT_SIZE:
                    raise FsError(f"{self.what}: more than {MAX_EXTRACT_SIZE >> 30} GiB unpacked")
                f.write(chunk)
        return dest


def add_member(files, rel, value, what):
    if rel in files:
        raise FsError(f"{what}: '{rel}' comes more than once")
    files[rel] = value


def archive_kind(path):
    """'zip', 'tar', '7z', 'gz', 'bz2', 'xz' by the content, or None."""
    with open(path, "rb") as f:
        head = f.read(265)
    if head[:4] in (b"PK\x03\x04", b"PK\x05\x06"):
        return "zip"
    if head.startswith(b"7z\xbc\xaf\x27\x1c"):
        return "7z"
    if head[257:262] == b"ustar":
        return "tar"
    for magic, kind in ((b"\x1f\x8b", "gz"), (b"BZh", "bz2"), (b"\xfd7zXZ\x00", "xz")):
        if head.startswith(magic):
            return "tar" if tarfile.is_tarfile(str(path)) else kind
    return None


def extract_zip(path, name, files, work):
    what = f"{work.what}: {name}"
    try:
        with zipfile.ZipFile(path) as z:
            for info in z.infolist():
                mode = info.external_attr >> 16 if info.create_system == 3 else 0
                if info.filename.endswith("/") or stat.S_ISDIR(mode):
                    continue
                if stat.S_ISLNK(mode):
                    raise FsError(f"{what}: '{info.filename}' is a symbolic link")
                if mode and not stat.S_ISREG(mode):
                    raise FsError(f"{what}: '{info.filename}' is no regular file")
                if info.flag_bits & 1:
                    raise FsError(f"{what}: '{info.filename}' is encrypted")
                rel = safe_path(info.filename, what)
                if rel:
                    with z.open(info) as src:
                        add_member(files, rel, (work.copy(src), bool(mode & 0o111)), what)
    except (zipfile.BadZipFile, zipfile.LargeZipFile, NotImplementedError, OSError) as e:
        raise FsError(f"{what}: cannot unpack: {e}")


def extract_tar(path, name, files, work):
    what = f"{work.what}: {name}"
    try:
        with tarfile.open(str(path), "r:*") as t:
            for m in t:
                if m.isdir():
                    continue
                if m.issym() or m.islnk():
                    raise FsError(f"{what}: '{m.name}' is a {'symbolic' if m.issym() else 'hard'}"
                                  " link")
                if not m.isfile():
                    raise FsError(f"{what}: '{m.name}' is no regular file")
                rel = safe_path(m.name, what)
                if rel:
                    add_member(files, rel, (work.copy(t.extractfile(m)), bool(m.mode & 0o111)),
                               what)
    except (tarfile.TarError, EOFError, OSError, zlib.error) as e:
        raise FsError(f"{what}: cannot unpack: {e}")


def sevenzip_command():
    """7-Zip: ASSETSYNC_7Z (split like a shell would), else 7zz, 7z, 7za or
    7zr on the PATH, on Windows also in Program Files; None if not found."""
    cmd = os.environ.get("ASSETSYNC_7Z", "").strip()
    if cmd:
        return shlex.split(cmd)
    for name in ("7zz", "7z", "7za", "7zr"):
        found = shutil.which(name)
        if found:
            return [found]
    if os.name == "nt":
        for var in ("ProgramFiles", "ProgramW6432", "ProgramFiles(x86)"):
            exe = Path(os.environ.get(var) or "/nonexistent") / "7-Zip" / "7z.exe"
            if exe.is_file():
                return [str(exe)]
    return None


def run_7z(what, command, args, optional):
    """Run a 7-Zip command; the optional switches are left out for older
    versions that don't know them (exit code 7: command line error)."""
    cmd = sevenzip_command()
    if not cmd:
        raise FsError(f"{what} is a 7z archive: unpacking it needs 7-Zip - install it "
                      "(https://www.7-zip.org; 7zz or 7z) or set ASSETSYNC_7Z")
    for opts in (optional, []):
        try:
            p = subprocess.run(cmd + [command] + opts + args, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=clean_env())
        except OSError as e:
            raise FsError(f"cannot run 7-Zip '{cmd[0]}' ({e.strerror}) - install it or set "
                          "ASSETSYNC_7Z")
        if p.returncode != 7 or not opts:
            break
    if p.returncode:        # 1 = warnings (e.g. files not extracted): not accepted
        msg = (p.stderr.strip() or p.stdout.strip()).decode("utf-8", "replace").splitlines()
        raise FsError(f"{what}: 7-Zip failed: {msg[-1] if msg else f'exit code {p.returncode}'}")
    return p.stdout


def extract_7z(path, name, files, work):
    """A 7z archive, with an external 7-Zip: its listing is checked first
    (links, special and encrypted files, unsafe paths, sizes), then it is
    unpacked into an empty directory, which is checked again (no links,
    valid names). The executable bit comes from the listing, so all
    platforms get the same."""
    what = f"{work.what}: {name}"
    listing = run_7z(what, "l", ["-slt", "--", str(path)], ["-sccUTF-8"])
    text = listing.decode("utf-8", "replace").replace("\r\n", "\n")
    if "\n----------\n" not in text:
        raise FsError(f"{what}: unexpected listing from 7-Zip")
    executable, size, count = {}, 0, 0
    for block in text.split("\n----------\n", 1)[1].split("\n\n"):
        info = {k: v for k, sep, v in (line.partition(" = ") for line in block.splitlines())
                if sep}
        member = info.get("Path")
        if member is None:
            continue
        win, _, unix = info.get("Attributes", "").partition(" ")
        if "D" in win or unix.startswith("d") or info.get("Folder") == "+":
            continue
        if info.get("Encrypted") == "+":
            raise FsError(f"{what}: '{member}' is encrypted")
        if unix[:1] == "l":
            raise FsError(f"{what}: '{member}' is a symbolic link")
        if unix[:1] not in ("", "-"):
            raise FsError(f"{what}: '{member}' is no regular file")
        parts = member.replace("\\", "/").split("/")
        if member.startswith(("/", "\\")) or re.match(r"[A-Za-z]:", member) or ".." in parts:
            raise FsError(f"{what}: unsafe path '{member}'")
        size += int(info.get("Size") or 0)
        count += 1
        if size > MAX_EXTRACT_SIZE or work.size + size > MAX_EXTRACT_SIZE:
            raise FsError(f"{what}: more than {MAX_EXTRACT_SIZE >> 30} GiB unpacked")
        if work.count + count > MAX_EXTRACT_FILES:
            raise FsError(f"{what}: more than {MAX_EXTRACT_FILES} files")
        executable["/".join(p for p in parts if p not in ("", "."))] = unix[3:4] == "x"
    work.n += 1
    target = work.dir / f"7z-{work.n}"
    target.mkdir()
    run_7z(what, "x", ["-y", f"-o{target}", "--", str(path)],
           ["-sccUTF-8", "-bd", "-bso0", "-bsp0"])
    for root, dirs, names in os.walk(target):
        for n in dirs + names:
            p = Path(root) / n
            if p.is_symlink() or not (p.is_dir() or p.is_file()):
                raise FsError(f"{what}: '{p.relative_to(target).as_posix()}' is no regular file")
        for n in names:
            p = Path(root) / n
            rel = safe_path(p.relative_to(target).as_posix(), what)
            work.size += p.stat().st_size
            work.count += 1
            if work.size > MAX_EXTRACT_SIZE or work.count > MAX_EXTRACT_FILES:
                raise FsError(f"{what}: more than {MAX_EXTRACT_SIZE >> 30} GiB or "
                              f"{MAX_EXTRACT_FILES} files unpacked")
            add_member(files, rel, (p, executable.get(rel, False)), what)


def extract_single(path, name, kind, files, work):
    """A compressed single file (.gz, .bz2, .xz): named without the suffix."""
    what = f"{work.what}: {name}"
    opener = {"gz": gzip.open, "bz2": bz2.open, "xz": lzma.open}[kind]
    base = re.sub(r"(?i)\.(gz|bz2|xz)$", "", name)
    try:
        with opener(path) as src:
            add_member(files, base, (work.copy(src), False), what)
    except (OSError, EOFError, lzma.LZMAError, zlib.error) as e:
        raise FsError(f"{what}: cannot unpack: {e}")


def extract_all(files, work, what):
    """Unpack the archives files into one root; a file that is no archive
    is an error (as a broken one), and so is a path coming from two."""
    result = {}
    for rel, (path, executable) in sorted(files.items()):
        kind = archive_kind(path)
        if not kind:
            raise FsError(f"{what}: '{rel}' is not an archive (zip, tar, tar.gz/bz2/xz, "
                          ".gz/.bz2/.xz, 7z) - choose the archives with a pattern")
        if kind == "zip":
            extract_zip(path, rel, result, work)
        elif kind == "7z":
            extract_7z(path, rel, result, work)
        elif kind == "tar":
            extract_tar(path, rel, result, work)
        else:
            extract_single(path, rel, kind, result, work)
    return result


def glob_regex(pattern):
    """Regex for a gitignore-like pattern, matched against a path relative to
    the filter's root: without a '/' it matches a name at any depth, a
    leading or inner '/' anchors it, a trailing '/' matches directories only;
    '*' and '?' don't match '/', '**/' matches any number of directories. A
    matching directory stands for everything below it."""
    dir_only = pattern.endswith("/")
    pat = pattern.strip("/")
    anchored = "/" in pattern.rstrip("/")
    rx, i = "", 0
    while i < len(pat):
        if pat.startswith("**/", i):
            rx, i = rx + "(?:[^/]*/)*", i + 3
        elif pat.startswith("**", i):
            rx, i = rx + ".*", i + 2
        elif pat[i] == "*":
            rx, i = rx + "[^/]*", i + 1
        elif pat[i] == "?":
            rx, i = rx + "[^/]", i + 1
        elif pat[i] == "[" and "]" in pat[i + 2:]:
            j = pat.index("]", i + 2)
            cls = pat[i + 1:j]
            rx += "[" + ("^" + cls[1:] if cls.startswith("!") else cls).replace("\\", "\\\\") + "]"
            i = j + 1
        else:
            rx, i = rx + re.escape(pat[i]), i + 1
    return re.compile(("" if anchored else "(?:.*/)?") + rx
                      + ("/.*" if dir_only else "(?:/.*)?") + r"\Z", re.S)


def parse_step(step):
    """(name, args) of a filter step; an error for an unknown or malformed one."""
    try:
        words = shlex.split(step)
    except ValueError as e:
        raise FsError(f"filter step '{step}': {e}")
    name, args = (words[0], words[1:]) if words else ("", [])
    ok = {"extract": all(args),
          "subdir": len(args) == 1 and bool(args[0].strip("/")),
          "strip": len(args) == 1 and args[0].isdigit() and int(args[0]) > 0,
          "include": bool(args), "exclude": bool(args),
          "move": len(args) == 2 and all(args), "copy": len(args) == 2 and all(args),
          "apply": len(args) == 2 and all(args),
          "convert": len(args) == 3 and all(args), "run": len(args) == 1 and bool(args[0])}.get(name)
    if ok is None:
        raise FsError(f"unknown filter step '{step}' (known: {', '.join(STEPS)})")
    if not ok:
        raise FsError(f"malformed filter step '{step}'")
    if name in ("move", "copy", "convert"):
        for p in re.findall(r"\{([^{}]*)\}", args[1]):
            if p not in PLACEHOLDERS:
                raise FsError(f"filter step '{step}': unknown placeholder {{{p}}} (known: "
                              + ", ".join(f"{{{k}}}" for k in PLACEHOLDERS) + ")")
    return name, args


def path_values(rel):
    """The placeholders {path} {dir} {parent} {name} {stem} {ext} of rel."""
    d, _, name = rel.rpartition("/")
    stem, ext = os.path.splitext(name)
    return {"path": rel, "dir": d, "parent": d.rpartition("/")[2], "name": name,
            "stem": stem, "ext": ext}


def fill(template, values, quote=False):
    """template with the placeholders in values filled in (shell-quoted
    for a command); other {...} are left as they are."""
    def value(m):
        if m.group(1) not in values:
            return m.group(0)
        return shlex.quote(values[m.group(1)]) if quote else values[m.group(1)]
    return re.sub(r"\{(\w+)\}", value, template)


def target_path(template, rel, what):
    """Where move / copy put the file rel: into the directory template if it
    ends with '/', else to the path template with its placeholders filled
    in. Relative to the filter's root."""
    values = path_values(rel)
    path = template + values["name"] if template.endswith("/") else fill(template, values)
    result = safe_path(path.lstrip("/"), what)
    if not result:
        raise FsError(f"{what}: '{rel}' gets no file name from '{template}'")
    return result


def shell_command():
    """The shell for filter commands: ASSETSYNC_SH, sh on the PATH, or on
    Windows the sh of Git for Windows."""
    cmd = os.environ.get("ASSETSYNC_SH", "").strip()
    if cmd:
        return shlex.split(cmd)
    found = shutil.which("sh")
    if found:
        return [found]
    if os.name == "nt":
        p = git(["--exec-path"], check=False)
        for base in Path(out(p) or ".").parents:
            for sh in (base / "bin" / "sh.exe", base / "usr" / "bin" / "sh.exe"):
                if sh.is_file():
                    return [str(sh)]
    raise FsError("no 'sh' found to run filter commands (Git for Windows has one) - "
                  "set ASSETSYNC_SH")


def run_command(command, values, work, what, cwd):
    """Run a filter command with sh -c in its working directory cwd, where
    {in} and {out} are - short relative names, so that tools deriving names
    from them (like xxd -i) give the same everywhere. The placeholders are
    filled in (quoted) and in the environment as ASSETSYNC_*; {root} is the
    repository's root, for its scripts."""
    values = dict(values, root=Path(work.cwd).as_posix())
    text = fill(command, values, quote=True)
    env = dict(clean_env(), **work.env, **{f"ASSETSYNC_{k.upper()}": v for k, v in values.items()})
    try:
        p = subprocess.run(shell_command() + ["-c", text], cwd=cwd, stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    except OSError as e:
        raise FsError(f"{what}: cannot run the shell ({e.strerror}) - set ASSETSYNC_SH")
    if p.returncode:
        msg = (p.stderr.strip() or p.stdout.strip()).decode("utf-8", "replace").splitlines()
        raise FsError(f"{what}: command failed (exit code {p.returncode})"
                      + (f": {msg[-1]}" if msg else ""))


def collect_dir(root, what, work):
    """{path: (file, executable)} of the files a command wrote below root:
    regular files only, valid names, within the limits."""
    files = {}
    for dirpath, dirs, names in os.walk(root):
        for n in dirs + names:
            p = Path(dirpath) / n
            if p.is_symlink() or not (p.is_dir() or p.is_file()):
                raise FsError(f"{what}: '{p.relative_to(root).as_posix()}' is no regular file")
        for n in names:
            p = Path(dirpath) / n
            st = p.stat()
            work.size += st.st_size
            work.count += 1
            if work.size > MAX_EXTRACT_SIZE or work.count > MAX_EXTRACT_FILES:
                raise FsError(f"{what}: more than {MAX_EXTRACT_SIZE >> 30} GiB or "
                              f"{MAX_EXTRACT_FILES} files")
            rel = safe_path(p.relative_to(root).as_posix(), what)
            files[rel] = (p, os.name != "nt" and bool(st.st_mode & 0o111))
    return files


def materialize(files, root):
    """Write files {path: (file, executable)} below root, for a command."""
    for rel, (src, executable) in files.items():
        dest = root / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dest)
        set_executable(dest, executable)


ROOT_PREFIXES = ("{root}/", "$ASSETSYNC_ROOT/", "${ASSETSYNC_ROOT}/")


def referenced_files(command, repo):
    """[(path, blob id)] of the files of the repository a command names
    (like {root}/tools/bin2c.py): part of the filter's hash, so that a
    changed script changes the filter."""
    try:
        words = shlex.split(command)
    except ValueError:
        words = command.split()
    found = {}
    for w in words:
        prefix = next((p for p in ROOT_PREFIXES if w.startswith(p)), None)
        rel = w[len(prefix):] if prefix else ""
        if rel and "{" not in rel and not path_problem(rel) and (repo.top / rel).is_file():
            found[rel] = repo.worktree_blob(repo.top / rel)
    return sorted(found.items())


def own_lines(steps, repo):
    """A filter's steps, with the files its commands name and their ids."""
    lines = []
    for step in steps:
        lines.append(step)
        name, args = parse_step(step)
        if name in COMMAND_STEPS and repo:
            lines += [f"  uses {p} {oid}" for p, oid in referenced_files(args[-1], repo)]
    return lines


def expand_steps(steps, filters, chain=(), repo=None):
    """The steps with the named filters they use, resolved - to check them
    and to notice changes (names left out: renaming changes nothing); with
    repo, also the files the commands name."""
    result = []
    for step in steps:
        name, args = parse_step(step)
        if name != "apply":
            result += own_lines([step], repo)
            continue
        if args[1] not in filters:
            raise FsError(f"unknown filter '{args[1]}' (in '{step}')")
        if args[1] in chain:
            raise FsError(f"filter '{args[1]}' uses itself (via {' -> '.join(chain)})")
        result += [f"apply {shlex.quote(args[0])} {{"] \
            + expand_steps(filters[args[1]], filters, chain + (args[1],), repo) + ["}"]
    return result


def used_filters(steps, filters, seen=None):
    """Names of the filters the steps use, also through other filters."""
    seen = [] if seen is None else seen
    for step in steps:
        name, args = parse_step(step)
        if name == "apply" and args[1] in filters and args[1] not in seen:
            seen.append(args[1])
            used_filters(filters[args[1]], filters, seen)
    return seen


def runs_commands(steps):
    return any(parse_step(s)[0] in COMMAND_STEPS for s in steps)


def trust_hash(name, filters, repo):
    """What a trust is for: a filter's own steps and the files its commands
    name (filters it applies are trusted on their own)."""
    text = "\n".join(own_lines(filters[name], repo))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def trusted_values(repo):
    """['<hash> <name>'] in the repository's own config (never committed)."""
    p = repo.git(["config", "--local", "--get-all", "assetsync.trusted"], check=False)
    return out(p).splitlines()


def is_trusted(repo, name, filters):
    h = trust_hash(name, filters, repo)
    return any(v.split(" ", 1)[0] == h for v in trusted_values(repo))


def set_trust(repo, name, filters, trust=True):
    """Trust (or no longer trust) the filter as it is now."""
    values = [v for v in trusted_values(repo) if v.partition(" ")[2] != name]
    if trust:
        values.append(f"{trust_hash(name, filters, repo)} {name}")
    repo.git(["config", "--local", "--unset-all", "assetsync.trusted"], check=False)
    for v in values:
        repo.git(["config", "--local", "--add", "assetsync.trusted", v])


def untrusted(repo, steps, filters):
    """Filters the steps use that run commands and are not trusted here."""
    return [n for n in used_filters(steps, filters)
            if runs_commands(filters[n]) and not is_trusted(repo, n, filters)]


def show_commands(name, filters, repo, indent="  "):
    for step in filters[name]:
        kind, args = parse_step(step)
        if kind in COMMAND_STEPS:
            print(f"{indent}{step}")
            for p, _ in referenced_files(args[-1], repo):
                print(f"{indent}  (runs {p} of this repository)")


def ask(question):
    """A yes from the user on a terminal (end of input counts as no -
    Windows takes the NUL device for a terminal)."""
    try:
        return input(question).strip().lower() in ("y", "yes")
    except EOFError:
        print()
        return False


def ensure_trusted(repo, steps, filters):
    """The filters whose commands may run for steps: all they use - if
    those that run commands are trusted, or ASSETSYNC_TRUST=all, or the
    user trusts them now (asked on a terminal). Else an error."""
    missing = untrusted(repo, steps, filters)
    if missing and os.environ.get("ASSETSYNC_TRUST", "").strip().lower() != "all":
        if not (sys.stdin.isatty() and sys.stdout.isatty()):
            raise FsError(f"filter {and_list(missing)} run{'s' if len(missing) == 1 else ''} "
                          "commands and isn't trusted in this repository yet - check with 'git "
                          f"assetsync trust', then trust with 'git assetsync trust {missing[0]}'")
        for name in missing:
            print(f"filter {name} runs commands:")
            show_commands(name, filters, repo)
            if not ask(f"Trust filter {name} in this repository? [y/N] "):
                raise FsError(f"filter {name} not trusted - check with 'git assetsync trust', "
                              f"then trust with 'git assetsync trust {name}'")
            set_trust(repo, name, filters)
    return set(used_filters(steps, filters))


def run_steps(files, steps, work, filters=None, chain=(), report=None):
    """Apply the filter steps to {path: (file, executable)}; filters: the
    named filters {name: steps}, for 'apply' steps. A step that matches no
    files does nothing; only a filter that leaves no files at all is an
    error (checked_result), and one whose results would replace each other.
    report(step, text): told what each step did (filter test)."""
    filters = filters or {}
    for step in steps:
        name, args = parse_step(step)
        before, info = len(files), None
        if name in ("move", "copy"):
            rx = glob_regex(args[0])
            matched = sorted(r for r in files if rx.match(r))
            info = (f"{plural(len(matched), 'file')} {'moved' if name == 'move' else 'copied'}"
                    if matched else "no files match")
            moved = set() if name == "copy" else set(matched)
            rest = {r: v for r, v in files.items() if r not in moved}
            new, origin = {}, {}
            for r in matched:
                t = target_path(args[1], r, f"{work.what}: '{step}'")
                if t in new:
                    raise FsError(f"{work.what}: '{step}': '{origin[t]}' and '{r}' would both "
                                  f"become '{t}'")
                if t in rest:
                    raise FsError(f"{work.what}: '{step}': '{r}' would replace '{t}'")
                new[t], origin[t] = files[r], r
            rest.update(new)
            files = rest
        elif name == "apply":
            pattern, fname = args
            if fname not in (filters or {}):
                raise FsError(f"{work.what}: unknown filter '{fname}'")
            if fname in chain:
                raise FsError(f"{work.what}: filter '{fname}' uses itself")
            rx = glob_regex(pattern)
            subset = {r: v for r, v in files.items() if rx.match(r)}
            if not subset:
                if report:
                    report(step, "no files match")
                continue
            rest = {r: v for r, v in files.items() if r not in subset}
            outer, work.what = work.what, f"{work.what} filter {fname}"
            try:
                result = run_steps(subset, filters[fname], work, filters, chain + (fname,))
            finally:
                work.what = outer
            for r, v in result.items():
                if r in rest:
                    raise FsError(f"{work.what}: '{step}': its '{r}' collides with a file "
                                  "outside the filter")
                rest[r] = v
            files = rest
            info = f"{len(subset)} of {plural(before, 'file')} -> {plural(len(result), 'file')}"
        elif name in COMMAND_STEPS:
            fname = chain[-1] if chain else None
            if fname not in work.trusted:
                raise FsError(f"{work.what}: '{step}': filter {fname} is not trusted")
            what = f"{work.what}: '{step}'"
            if name == "run":
                d = work.new_dir()
                materialize(files, d / "in")
                (d / "out").mkdir()
                run_command(args[0], {"in": "in", "out": "out"}, work, what, d)
                files = collect_dir(d / "out", what, work)
                if report:
                    report(step, f"{before} -> {plural(len(files), 'file')}")
                continue
            pattern, target, command = args
            rx = glob_regex(pattern)
            matched = sorted(r for r in files if rx.match(r))
            info = f"{plural(len(matched), 'file')} converted" if matched else "no files match"
            converted = set(matched)
            rest = {r: v for r, v in files.items() if r not in converted}
            new, origin = {}, {}
            for r in matched:
                values = path_values(r)
                into_dir = target.endswith("/")
                t = fill(target.rstrip("/") if into_dir else target, values).lstrip("/")
                t = safe_path(t, what) or ""
                if not into_dir and not t:
                    raise FsError(f"{what}: '{r}' gets no file name from '{target}'")
                # {in} and {out}: names in the command's working directory
                d = work.new_dir()
                materialize({values["name"]: files[r]}, d)
                if into_dir:
                    out_name = "out" if values["name"] != "out" else "out.d"
                else:
                    out_name = t.rpartition("/")[2]
                    if out_name.lower() == values["name"].lower():   # also on case-
                        out_name = f"out/{out_name}"                 # insensitive disks
                outp = d / out_name
                (outp if into_dir else outp.parent).mkdir(parents=True, exist_ok=True)
                run_command(command, dict(values, **{"in": values["name"], "out": out_name}),
                            work, f"{what}: {r}", d)
                if into_dir:
                    result = {f"{t}/{k}" if t else k: v
                              for k, v in collect_dir(outp, f"{what}: {r}", work).items()}
                elif outp.is_file() and not outp.is_symlink():
                    result = {t: (outp, os.name != "nt" and bool(outp.stat().st_mode & 0o111))}
                else:
                    raise FsError(f"{what}: {r}: the command wrote no file {{out}}")
                for k, v in result.items():
                    if k in new:
                        raise FsError(f"{what}: '{origin[k]}' and '{r}' would both give '{k}'")
                    if k in rest:
                        raise FsError(f"{what}: '{r}' would give '{k}', which is already there")
                    new[k], origin[k] = v, r
            rest.update(new)
            files = rest
        elif name == "extract":
            rxs = [glob_regex(a) for a in args]
            archives = {r: v for r, v in files.items() if not rxs or any(x.match(r) for x in rxs)}
            if not archives:
                info = "no files match"
            else:
                rest = {r: v for r, v in files.items() if r not in archives}
                for r, v in extract_all(archives, work, f"{work.what}: '{step}'").items():
                    add_member(rest, r, v, f"{work.what}: '{step}'")
                files = rest
                info = (f"{plural(len(archives), 'archive')} -> "
                        f"{plural(len(files) - before + len(archives), 'file')}")
        elif name == "subdir":
            sub = args[0].strip("/") + "/"
            files = {r[len(sub):]: v for r, v in files.items() if r.startswith(sub)}
        elif name == "strip":
            # files with no more than n directories are left out
            n, new = int(args[0]), {}
            for r, v in files.items():
                parts = r.split("/")
                if len(parts) > n:
                    add_member(new, "/".join(parts[n:]), v, f"{work.what}: '{step}'")
            files = new
        else:
            rxs = [glob_regex(a) for a in args]
            files = {r: v for r, v in files.items()
                     if any(x.match(r) for x in rxs) == (name == "include")}
        if report:
            if info is None:
                info = (plural(before, "file") if len(files) == before
                        else f"{before} -> {plural(len(files), 'file')}")
            report(step, info)
    if chain:            # a named filter: may leave nothing of its part
        return files
    return checked_result(files, work.what)


def checked_result(files, what):
    """The files a filter gives for an entry: some, and none that differ
    only in case."""
    if not files:
        raise FsError(f"{what}: the filter leaves no files")
    seen = {}
    for r in files:
        other = seen.setdefault(r.lower(), r)
        if other != r:
            raise FsError(f"{what}: '{other}' and '{r}' differ only in case")
    return files


def filter_hash(steps, filters, repo=None):
    """Recorded with an entry, to notice a changed filter - also of a named
    filter it uses, or of a script its commands run (None: no filter)."""
    if not steps:
        return None
    text = "\n".join(expand_steps(steps, filters, (), repo))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def entry_files(origin, release, assets, steps, filters, work):
    """The files an entry gets: {path: (file, executable)} after the filter,
    and the digest of its assets."""
    files, pairs = {}, []
    for a in assets:
        rel = safe_path(a.name, f"{work.what}: asset")
        path, digest = get_asset(origin, release, a)
        add_member(files, rel, (path, False), work.what)
        pairs.append((a.name, digest))
    return run_steps(files, steps, work, filters), assets_digest(pairs)


class Context:
    """Creates platform clients and caches the release selection of each
    source, so a run asks the platform once per source."""

    def __init__(self, args):
        self.fetch = not getattr(args, "no_fetch", False)
        self.override = None      # pull/diff --release: this rule instead of the source's
        self._selected = {}

    def release(self, url, spec, override=True):
        """(origin, selected release) for a source URL and its selection keys
        (with override: the --release rule of pull/diff instead of its own)."""
        rule = self.override if override and self.override else spec.get("release")
        key = (norm_url(url), spec.get("type"), rule, is_true(spec.get("prerelease")))
        if key not in self._selected:
            origin = platform_of(url, spec.get("type"))
            try:
                self._selected[key] = origin, select_release(
                    origin, rule, is_true(spec.get("prerelease")))
            except FsError as e:
                self._selected[key] = e
        result = self._selected[key]
        if isinstance(result, FsError):
            raise result
        return result


# --------------------------------------------------------------------------
# this repository
# --------------------------------------------------------------------------

class Repo:
    def __init__(self):
        p = git(["rev-parse", "--show-toplevel"], check=False)
        if p.returncode:
            raise FsError("not inside a Git working tree")
        self.top = Path(out(p)).resolve()
        self.gitdir = Path(out(git(["rev-parse", "--absolute-git-dir"])))
        # shell aliases run in the top-level dir and pass the original
        # subdirectory in GIT_PREFIX
        prefix = os.environ.get("GIT_PREFIX")
        self.base = Path.cwd() / prefix if prefix else Path.cwd()

    def git(self, args, **kw):
        return git(args, cwd=self.top, **kw)

    def user_path(self, s):
        return (self.base / s).resolve()

    def rel(self, path):
        try:
            return Path(os.path.relpath(Path(path).resolve(), self.top)).as_posix()
        except ValueError:            # Windows: another drive
            raise FsError(f"'{path}' is outside the repository")

    def worktree_blob(self, path):
        """Blob id of the (clean-filtered) working tree file, None if missing.
        For a file tracked in LFS here, this is the id of its LFS pointer."""
        if not path.is_file():
            return None
        return out(self.git(["hash-object", f"--path={self.rel(path)}", str(path)]))

    def add_file(self, path, rel):
        """Store a file as `git add` would store it at rel (eol normalization,
        LFS clean filter per .gitattributes); returns the blob id."""
        return out(self.git(["hash-object", "-w", f"--path={rel}", str(path)]))

    def read_blob(self, oid):
        return self.git(["cat-file", "blob", oid]).stdout

    def read_content(self, oid, rel):
        """Actual content of a blob of this repo: LFS pointers are resolved."""
        data = self.read_blob(oid)
        if lfs_pointer(data):
            data = lfs_smudge(self.git, data, rel, "this repository")
        return data

    def store(self, content):
        return out(self.git(["hash-object", "-w", "--stdin", "--no-filters"], data=content))

    def checkout_form(self, oid, rel):
        """A blob as `git checkout` writes it to rel (eol conversion, smudge
        filters per .gitattributes / core.autocrlf)."""
        return self.git(["cat-file", "--filters", f"--path={rel}", oid]).stdout

    def to_worktree(self, content, rel):
        """Normalized content in this repo's working tree form."""
        return self.checkout_form(self.store(content), rel)

    def as_local(self, content, rel):
        """Blob id normalized content gets when stored at rel now, i.e. after
        checkout and checkin conversion with the current .gitattributes."""
        work = self.to_worktree(content, rel)
        return out(self.git(["hash-object", "-w", f"--path={rel}", "--stdin"], data=work))

    def index_path(self):
        p = Path(out(self.git(["rev-parse", "--git-path", "index"])))
        return p if p.is_absolute() else self.top / p

    @contextmanager
    def temp_index(self, copy=False):
        """Environment for git commands on a temporary index: empty, or with
        copy a copy of the index (which stays as it is)."""
        with tempfile.TemporaryDirectory(prefix="assetsync-") as td:
            index = Path(td) / "index"
            if copy and self.index_path().exists():
                shutil.copyfile(self.index_path(), index)
            yield dict(os.environ, GIT_INDEX_FILE=str(index))

    def make_tree(self, entries):
        """Tree object with the given (mode, id, path) entries, via a
        temporary index."""
        with self.temp_index() as env:
            if entries:
                data = "".join(f"{m} {o}\t{p}\0" for m, o, p in entries)
                self.git(["update-index", "-z", "--add", "--index-info"],
                         data=data.encode("utf-8"), env=env)
            return out(self.git(["write-tree"], env=env))

    def tree_entries(self, tree):
        """[(mode, type, id, path)] of all entries below a tree."""
        p = self.git(["ls-tree", "-r", "-z", tree])
        result = []
        for item in p.stdout.decode("utf-8", "replace").split("\0"):
            if item:
                info, _, path = item.partition("\t")
                mode, kind, oid = info.split(" ")
                result.append((mode, kind, oid, path))
        return result

    def content_id(self, oid, rel):
        """Blob id of the actual content (differs from oid for an LFS pointer)."""
        if not lfs_pointer(self.read_blob(oid)):
            return oid
        return self.store(self.read_content(oid, rel))

    def head_mode(self, rel):
        """Mode of the file rel in HEAD, None if HEAD has none."""
        parent, _, name = rel.rpartition("/")
        p = self.git(["ls-tree", "-z", f"HEAD:{parent}" if parent else "HEAD"], check=False)
        for item in p.stdout.decode("utf-8", "replace").split("\0"):
            info, _, path = item.partition("\t")
            if path == name and info.split(" ")[1:2] == ["blob"]:
                return info.split(" ")[0]
        return None

    def worktree_items(self, rel):
        """[(mode, id, path)] of the files at rel as `git add -A` would
        stage them (untracked ones included, ignored ones not), computed with
        a copy of the index, which stays as it is."""
        with self.temp_index(copy=True) as env:
            self.git(["add", "-A", "--", lit(rel)], env=env, check=False)
            p = self.git(["ls-files", "-s", "-z", "--", lit(rel)], env=env)
        items = []
        for item in p.stdout.decode("utf-8", "replace").split("\0"):
            if item:
                info, _, path = item.partition("\t")
                mode, oid, _ = info.split(" ")
                items.append((mode, oid, path))
        return items

    def head_object(self, rel):
        """(type, id) of what HEAD has at rel: ('blob' | 'tree', id), or None."""
        p = self.git(["rev-parse", "--verify", "-q", f"HEAD:{rel}"], check=False)
        if p.returncode:
            return None
        oid = out(p)
        return out(self.git(["cat-file", "-t", oid])), oid

    def tree_names(self, tree):
        """Paths of the files below a tree."""
        return [path for _, kind, _, path in self.tree_entries(tree) if kind == "blob"]

    def worktree_tree(self, rel):
        """Tree the directory rel would get by `git add -A` (untracked files
        included, ignored ones not); None if there are no files. Computed
        with a copy of the index, which stays as it is."""
        with self.temp_index(copy=True) as env:
            self.git(["add", "-A", "--", lit(rel)], env=env, check=False)
            p = self.git(["write-tree", f"--prefix={rel}/"], env=env, check=False)
            return out(p) if p.returncode == 0 else None

    def dir_files(self, rel):
        """Files in the working tree below rel that git sees: tracked and
        untracked ones, not ignored ones."""
        p = self.git(["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--",
                      lit(rel)])
        names = dict.fromkeys(n for n in p.stdout.decode("utf-8", "replace").split("\0") if n)
        return [n for n in names if (self.top / n).is_file()]

    def state_file(self, prefix, name):
        """.git/<prefix><name> for state kept between commands (name made
        safe as a file name)."""
        return self.gitdir / (prefix + re.sub(r"[^A-Za-z0-9._-]", "_", name))

    def fix_eol(self, path):
        """Rewrite a file written by `git config -f` (LF) in working tree form,
        so core.autocrlf repositories don't warn about it."""
        data = path.read_bytes().replace(b"\r\n", b"\n")
        conv = self.to_worktree(data, self.rel(path))
        if conv != path.read_bytes():
            path.write_bytes(conv)


# --------------------------------------------------------------------------
# .git-assetsync
# --------------------------------------------------------------------------

SECTIONS = ("source", "file", "dir", "filter")
# kinds of entries: their section and the key of their base
BASE_KEY = {"file": "blob", "dir": "tree"}
# keys of a [source] that select its release
SPEC_KEYS = ("release", "prerelease", "type")


def parse_registry(raw):
    """{section: {subsection: {key: value}}} from `git config --list -z`."""
    result = {s: {} for s in SECTIONS}
    for item in raw.decode("utf-8", "replace").split("\0"):
        if not item:
            continue
        key, has_val, val = item.partition("\n")
        if not has_val:
            val = "true"     # a key without '= value' is a boolean true in git config
        sect, _, rest = key.partition(".")
        # subsections may contain dots (file paths): the key is after the last
        sub, _, name = rest.rpartition(".")
        if sect in result and sub:
            values = result[sect].setdefault(sub, {})
            if name == "step":          # the only key with several values, in order
                values.setdefault("step", []).append(val)
            else:
                values[name] = val
    return result


def registry_entries(parsed):
    """({path: values}, {path: kind}) of the [file] and [dir] sections; a
    path in both is taken as [dir] and reported by its entry."""
    entries, kinds = {}, {}
    for kind in ("file", "dir"):
        for rel, values in parsed[kind].items():
            if rel in entries:
                kinds[rel] = "both"
            else:
                kinds[rel] = kind
            entries[rel] = values
    return entries, kinds


def source_spec(source):
    """The release selection keys a [source] has (or a command asks for)."""
    return {k: source[k] for k in SPEC_KEYS if source.get(k)}


def spec_text(spec):
    """'latest release' / 'release v1.2' / 'newest release matching tool-*'."""
    rule = spec.get("release")
    pre = " (prereleases too)" if is_true(spec.get("prerelease")) else ""
    if not rule:
        return ("newest release" if pre else "latest release") + pre
    if not is_pattern(rule):
        return f"release {rule}"
    return f"newest release matching {rule}{pre}"


def origin_text(entry):
    """Where an entry comes from, as status -v, pull -v and verify -v show it:
    'tool-*.bin from acme/tool, latest release, filter x; synced v1.2'."""
    synced = f"synced {entry.synced}" if entry.synced else "not synced yet"
    what = entry.asset or ("all assets" if entry.is_dir else "only asset")
    steps = f", filter {entry.filter}" if entry.filter else ""
    return f"{what} from {entry.name}, {spec_text(entry.spec)}{steps}; {synced}"


def path_problem(rel):
    """Why rel can't be a synced file, None if it can. Entries come from a
    committed file, possibly written by others: a pull must never write
    outside the working tree or into a .git directory."""
    parts = re.split(r"[/\\]", rel)
    if not rel or "\n" in rel or PureWindowsPath(rel).anchor or ".." in parts:
        return "not a path inside the working tree"
    if any(p in ("", ".") for p in parts):
        return "not a normalized path"
    if any(p.lower().rstrip(". ") == ".git" for p in parts):
        return "inside a .git directory"
    if rel == REGISTRY:
        return f"{REGISTRY} itself"
    return None


class Registry:
    """The repository's .git-assetsync: [source], [file] and [dir] sections.
    files holds the entries of both kinds, kinds their kind."""

    def __init__(self, repo):
        self.repo = repo
        self.path = repo.top / REGISTRY
        self.sources, self.files, self.kinds, self.filters = {}, {}, {}, {}
        self.dry_run = False      # only change the in-memory state
        if self.path.exists():
            p = git(["config", "-f", self.path, "--list", "-z"], check=False)
            if p.returncode:
                raise FsError(f"{REGISTRY}: cannot parse: "
                              + p.stderr.decode("utf-8", "replace").strip())
            parsed = parse_registry(p.stdout)
            self.sources = parsed["source"]
            self.files, self.kinds = registry_entries(parsed)
            self.filters = {n: list(v.get("step") or []) for n, v in parsed["filter"].items()}

    def section(self, rel):
        return "dir" if self.kinds.get(rel) in ("dir", "both") else "file"

    def new_entry(self, rel, kind):
        self.kinds[rel] = kind
        self.files[rel] = {}

    def overlapping(self, rel, exclude=None):
        """Entries that overlap rel: the same path, below it or above it."""
        return sorted(r for r in self.files if r != exclude and
                      (r == rel or r.startswith(rel + "/") or rel.startswith(r + "/")))

    def entries(self):
        return [Entry(self, rel) for rel in sorted(self.files)]

    def _cfg(self, *args):
        if self.dry_run:
            return
        if not self.path.exists():
            self.path.write_bytes(REGISTRY_HEADER.encode())
        git(["config", "-f", self.path] + list(args))

    def set_file(self, rel, name, value):
        """Set (value None: remove) a key of a [file] or [dir]."""
        key = f"{self.section(rel)}.{rel}.{name}"
        if value is None:
            if name in self.files.get(rel, {}):
                self._cfg("--unset-all", key)
                del self.files[rel][name]
        else:
            self._cfg(key, value)
            self.files.setdefault(rel, {})[name] = value

    def find_source(self, url, spec, exclude=None):
        """Key of a [source] with url and exactly the selection keys of spec."""
        for name, s in self.sources.items():
            if name != exclude and norm_url(s.get("url", "")) == norm_url(url) and \
                    source_spec(s) == spec:
                return name
        return None

    def new_source_name(self, url):
        """Unused key for a new [source]: 'owner/repo' derived from the URL,
        with a number appended if that key already belongs to another source."""
        base = repo_label(url) or "source"
        name, n = base, 2
        while name in self.sources:
            name, n = f"{base}-{n}", n + 1
        return name

    def source_name(self, url, spec):
        """Key of the [source] for url+spec (found by URL, not by key),
        or the key a new one would get."""
        return self.find_source(url, spec) or self.new_source_name(url)

    def add_source(self, url, spec):
        """Key of the [source] for url+spec, created if necessary."""
        name = self.find_source(url, spec)
        if name:
            return name
        name = self.new_source_name(url)
        self._cfg(f"source.{name}.url", url)
        self.sources[name] = {"url": url}
        for k, v in spec.items():
            self._cfg(f"source.{name}.{k}", v)
            self.sources[name][k] = v
        return name

    def set_source(self, name, key, value):
        """Set (value None: remove) a key of a [source]."""
        if value is None:
            if key in self.sources[name]:
                self._cfg("--unset-all", f"source.{name}.{key}")
                del self.sources[name][key]
        else:
            self._cfg(f"source.{name}.{key}", value)
            self.sources[name][key] = value

    def set_spec(self, name, spec):
        """Set the release selection keys of a [source] to spec."""
        for key in SPEC_KEYS:
            self.set_source(name, key, spec.get(key))

    def remove_source(self, name):
        self._cfg("--remove-section", f"source.{name}")
        del self.sources[name]

    def rename_source(self, old, new):
        self._cfg("--rename-section", f"source.{old}", f"source.{new}")
        self.sources[new] = self.sources.pop(old)
        for rel, f in self.files.items():
            if f.get("source") == old:
                self.set_file(rel, "source", new)

    def source_files(self, name):
        return sorted(rel for rel, f in self.files.items() if f.get("source") == name)

    def set_filter(self, name, steps):
        """Create or replace the named filter [filter "name"]."""
        if name in self.filters:
            self._cfg("--remove-section", f"filter.{name}")
        for step in steps:
            self._cfg("--add", f"filter.{name}.step", step)
        self.filters[name] = list(steps)

    def remove_filter(self, name):
        self._cfg("--remove-section", f"filter.{name}")
        del self.filters[name]

    def filter_users(self, name):
        """Entries using the named filter, and named filters with a 'filter'
        step using it."""
        def uses(steps):
            return any(parse_step(s)[0] == "apply" and parse_step(s)[1][1] == name
                       for s in steps)
        return [f"{r}/" if self.kinds.get(r) == "dir" else r
                for r in sorted(self.files) if self.files[r].get("filter") == name] + \
            [f"filter {n}" for n in sorted(self.filters) if uses(self.filters[n])]

    def rename_filter(self, old, new):
        """Rename a named filter and the 'filter' steps that use it."""
        self._cfg("--rename-section", f"filter.{old}", f"filter.{new}")
        self.filters[new] = self.filters.pop(old)

        def renamed(steps):
            result = []
            for step in steps:
                kind, args = parse_step(step)
                result.append(shlex.join(["apply", args[0], new])
                              if kind == "apply" and args[1] == old else step)
            return result
        for rel, values in self.files.items():
            if values.get("filter") == old:
                self.set_file(rel, "filter", new)
        for name, steps in list(self.filters.items()):
            if renamed(steps) != steps:
                self.set_filter(name, renamed(steps))

    def remove_file(self, rel, keep_source=None):
        """Remove a [file] or [dir]; its [source] too when no other entry
        uses it (unless it is keep_source)."""
        section = self.section(rel)
        src = self.files.pop(rel, {}).get("source")
        self._cfg("--remove-section", f"{section}.{rel}")
        self.kinds.pop(rel, None)
        if src and src != keep_source and src in self.sources and \
                not any(f.get("source") == src for f in self.files.values()):
            self._cfg("--remove-section", f"source.{src}")
            del self.sources[src]

    def rename_file(self, old, new):
        section = self.section(old)
        self._cfg("--rename-section", f"{section}.{old}", f"{section}.{new}")
        self.files[new] = self.files.pop(old)
        self.kinds[new] = self.kinds.pop(old)

    def finish(self):
        """Fix line endings and stage the registry (or its removal when empty)."""
        if self.dry_run:
            return
        if self.path.exists():
            if not self.sources and not self.files and not self.filters:
                self.path.unlink()
            else:
                self.repo.fix_eol(self.path)
        self.repo.git(["add", "-A", "--", REGISTRY])

    def uncommitted(self):
        """Entries that differ from the committed .git-assetsync in what they
        record about the file. Which [source] they belong to doesn't count: a
        changed source may go into any commit."""
        p = self.repo.git(["config", "--blob", f"HEAD:{REGISTRY}", "--list", "-z"], check=False)
        head, kinds = registry_entries(parse_registry(p.stdout)) if p.returncode == 0 else ({}, {})

        def base(entry, kind):
            return None if entry is None else \
                (kind, {k: v for k, v in entry.items() if k != "source"})
        return {rel for rel in set(head) | set(self.files)
                if base(head.get(rel), kinds.get(rel)) !=
                base(self.files.get(rel), self.kinds.get(rel))}


class Entry:
    """One [file] or [dir] entry: a file of this repository taken from a
    release asset, or a directory taken from release assets (it belongs to
    the entry completely)."""

    def __init__(self, reg, rel):
        self.reg, self.rel = reg, rel

    kind = property(lambda self: self.reg.section(self.rel))
    is_dir = property(lambda self: self.kind == "dir")
    # how the entry is shown: a directory with a trailing '/'
    shown = property(lambda self: self.rel + ("/" if self.is_dir else ""))
    filter = property(lambda self: self.v.get("filter") or None)   # name of its [filter]
    # its filter as steps: the named filter applied to all files
    steps = property(lambda self: [shlex.join(["apply", "*", self.filter])] if self.filter
                     else [])

    @property
    def v(self):
        return self.reg.files.get(self.rel, {})

    @property
    def target(self):
        problem = path_problem(self.rel)
        if problem:
            raise FsError(f"'{self.rel}' in {REGISTRY}: {problem}")
        return self.reg.repo.top / self.rel

    @property
    def source(self):
        return self.reg.sources.get(self.name, {})

    name = property(lambda self: self.v.get("source", ""))   # key of the [source]
    url = property(lambda self: self.source.get("url", ""))
    spec = property(lambda self: source_spec(self.source))
    asset = property(lambda self: self.v.get("asset", ""))
    synced = property(lambda self: self.v.get("synced", ""))
    digest = property(lambda self: self.v.get("digest", ""))
    # the base: blob of a file, tree of a directory, as committed
    blob = property(lambda self: self.v.get(BASE_KEY[self.kind], ""))
    filterhash = property(lambda self: self.v.get("filterhash") or None)

    def set(self, name, value):
        self.reg.set_file(self.rel, name, value)


def select_entries(repo, reg, paths, containing=False):
    """Entries for the given files/directories (all entries if none given).
    A path inside a directory entry: with containing that entry (commands
    that look at it or pull it), else an error (commands that change it)."""
    if not paths:
        return reg.entries()
    result = []
    for s in paths:
        if s in reg.files and path_problem(s):     # a broken entry, by its name
            result.append(Entry(reg, s))
            continue
        rel = repo.rel(repo.user_path(s))
        if rel in reg.files:
            result.append(Entry(reg, rel))
            continue
        under = [e for e in reg.entries() if rel == "." or e.rel.startswith(rel + "/")]
        if not under:
            around = next((e for e in reg.entries() if rel.startswith(e.rel + "/")), None)
            if around and containing:
                under = [around]
            elif around:
                raise FsError(f"'{rel}' is part of the directory entry {around.shown} - only "
                              "the entry as a whole can be changed")
            else:
                raise FsError(f"'{rel}' is not synced (use 'git assetsync add' to add it)")
        result += under
    seen, unique = set(), []
    for e in result:
        if e.rel not in seen:
            seen.add(e.rel)
            unique.append(e)
    return unique


# --------------------------------------------------------------------------
# evaluation
# --------------------------------------------------------------------------

@dataclass
class State:
    """What evaluate() finds out about an entry."""
    entry: Any
    rel: str
    error: Optional[str] = None
    warnings: list = field(default_factory=list)
    fetched: bool = False     # upstream checked
    origin: Any = None
    release: Any = None       # the release the source selects now
    assets: list = field(default_factory=list)   # its assets the entry takes
    asset: Optional[Asset] = None   # the first of them (the one of a file)
    committed: Optional[str] = None   # see evaluate()
    worktree: str = "clean"
    local: str = "clean"
    head_blob: Optional[str] = None   # committed blob of a file, tree of a directory
    changed: bool = False     # what pull would take differs from the base:
    tag_changed: bool = False     # another release,
    digest_changed: bool = False  # other assets in the same release,
    filter_changed: bool = False  # or another filter
    pending: bool = False     # something for pull to do
    modified: bool = False    # local modifications (not allowed)
    base_now: Optional[str] = None    # base as it would be stored now


def base_unavailable(st, e):
    msg = (f"synced version {st.entry.blob[:12]} not available, counts as modified ({e})")
    if msg not in st.warnings:
        st.warnings.append(msg)
    return False


def matches_base(repo, st, oid):
    """Is a blob (of HEAD, or of the working tree file: then not stored) the
    synced asset, i.e. the base recorded in .git-assetsync? Also when it is
    stored differently since (.gitattributes changed: LFS, line endings)."""
    entry = st.entry
    if not entry.blob:
        return False
    if oid == entry.blob:
        return True
    try:
        data = repo.git(["cat-file", "blob", oid], check=False).stdout
        ptr = lfs_pointer(data)
        # in LFS now: the pointer names the content's hash, no download needed
        if ptr and not entry.steps and entry.digest == f"sha256:{ptr[0]}":
            return True
        if st.base_now is None:
            st.base_now = repo.as_local(repo.read_content(entry.blob, st.rel), st.rel)
        return oid == st.base_now
    except FsError as e:
        return base_unavailable(st, e)


def tree_matches_base(repo, st, tree):
    """matches_base() for the tree of a directory entry: the base tree
    re-stored file by file with the current .gitattributes if it differs."""
    entry = st.entry
    if not entry.blob:
        return False
    if tree == entry.blob:
        return True
    try:
        if st.base_now is None:
            items = []
            for mode, kind, oid, path in repo.tree_entries(entry.blob):
                full = f"{st.rel}/{path}"
                if kind == "blob":
                    oid = repo.as_local(repo.read_content(oid, full), full)
                items.append((mode, oid, path))
            st.base_now = repo.make_tree(items)
        return tree == st.base_now
    except FsError as e:
        return base_unavailable(st, e)


def local_state_file(repo, st):
    entry = st.entry
    known = bool(entry.blob)
    cur = repo.worktree_blob(entry.target)
    p = repo.git(["rev-parse", "--verify", "-q", f"HEAD:{entry.rel}"], check=False)
    head = st.head_blob = out(p) if p.returncode == 0 else None
    if head and known:
        st.committed = "unmodified" if matches_base(repo, st, head) else "adapted"
    if cur is None:
        st.worktree = "deleted" if head else "missing"
    elif not head:
        st.worktree = "added"
    elif repo.git(["diff", "--quiet", "HEAD", "--", lit(entry.rel)],
                  check=False).returncode == 1:
        st.worktree = "modified"
    if cur is None:
        st.local = "missing"
    elif not known:
        st.local = "clean"
    elif st.worktree == "clean":
        st.local = "clean" if st.committed == "unmodified" else "modified"
    else:
        st.local = "clean" if matches_base(repo, st, cur) else "modified"


def local_state_dir(repo, st):
    """As local_state_file(), for a directory: all files git sees there
    count - untracked ones too, not ignored ones."""
    entry = st.entry
    known = bool(entry.blob)
    obj = repo.head_object(entry.rel)
    head = st.head_blob = obj[1] if obj and obj[0] == "tree" else None
    if obj and not head:
        st.committed = "adapted"             # committed as a file
    elif head and known:
        st.committed = "unmodified" if tree_matches_base(repo, st, head) else "adapted"
    files = repo.dir_files(entry.rel)
    dirty = repo.git(["status", "--porcelain", "-z", "--untracked-files=all", "--",
                      lit(entry.rel)]).stdout.strip(b"\0")
    if not files:
        st.worktree = "deleted" if head else "missing"
    elif not head:
        st.worktree = "added"
    elif dirty:
        st.worktree = "modified"
    if not files:
        st.local = "missing"
    elif not known:
        st.local = "clean"
    elif st.worktree == "clean":
        st.local = "clean" if st.committed == "unmodified" else "modified"
    else:
        st.local = "clean" if tree_matches_base(repo, st, repo.worktree_tree(entry.rel)) \
            else "modified"


def evaluate(ctx, repo, entry):
    """State of an entry in three independent respects:
    upstream  - synced assets and filter vs. those of the release the source
                selects now (changed; only checked when fetching)
    committed - committed file (directory) vs. the base: the synced assets
                after the filter ('unmodified' | 'adapted' | None if not
                committed)
    worktree  - working file (directory) vs. committed version
                ('clean' | 'modified' | 'deleted' | 'added' | 'missing')
    local     - working file (directory) vs. the base ('clean' | 'modified'
                | 'missing')"""
    st = State(entry=entry, rel=entry.rel)
    problem = path_problem(entry.rel)
    if problem:
        st.error = (f"{problem} - entry ignored; remove it with "
                    f"'git assetsync unlink {shlex.quote(entry.rel)}'")
        return st
    if entry.reg.kinds.get(entry.rel) == "both":
        st.error = (f"both a [file] and a [dir] entry in {REGISTRY} - remove it with "
                    f"'git assetsync unlink {path_arg(repo, entry.rel)}' and add it again")
        return st
    others = entry.reg.overlapping(entry.rel, exclude=entry.rel)
    if others:
        st.error = f"overlaps with the entry for {', '.join(others)} - entries must not overlap"
        return st
    if not entry.url:
        st.error = f"incomplete entry in {REGISTRY} (needs a source with url)"
        return st
    try:
        if "step" in entry.v:
            raise FsError("filter steps belong to a named filter - define one with 'git "
                          "assetsync filter add NAME ...' and use it with 'git assetsync set "
                          f"{path_arg(repo, entry.rel)} --filter NAME'")
        if entry.filter and entry.filter not in entry.reg.filters:
            raise FsError(f"filter '{entry.filter}' not found in {REGISTRY} (define it with "
                          f"'git assetsync filter add {entry.filter} ...')")
        expand_steps(entry.steps, entry.reg.filters)
        (local_state_dir if entry.is_dir else local_state_file)(repo, st)
    except FsError as e:
        st.error = str(e)
        return st
    # deleted committed files count as modified; never committed ones are new
    st.modified = bool(entry.blob) and (st.committed == "adapted" or st.local == "modified"
                                        or st.worktree == "deleted")
    if ctx.fetch:
        try:
            st.origin, st.release = ctx.release(entry.url, entry.spec)
            st.assets = select_assets(st.release, entry.asset, st.origin.label, entry.is_dir,
                                      f"'git assetsync set {path_arg(repo, entry.rel)} --asset PATTERN'")
        except FsError as e:
            st.error = str(e)
            return st
        st.asset = st.assets[0]
        st.fetched = True
        now = assets_digest([(a.name, a.digest) for a in st.assets])
        st.tag_changed = st.release.tag != entry.synced
        st.digest_changed = bool(now and entry.digest and now != entry.digest.lower())
        st.filter_changed = filter_hash(entry.steps, entry.reg.filters, repo) != entry.filterhash
        st.changed = st.tag_changed or st.digest_changed or st.filter_changed
    st.pending = st.changed or st.worktree == "missing"
    if st.pending:
        for name in untrusted(repo, entry.steps, entry.reg.filters):
            st.warnings.append(f"filter {name} runs commands and isn't trusted here yet "
                               f"(see 'git assetsync trust')")
    return st


def upstream_state(st):
    """(label, note) of a pending upstream change, None if there is none."""
    e = st.entry
    if st.changed and not e.synced and e.blob:
        return "pending", f"entry changed, release {st.release.tag}"
    if st.changed and not e.synced:
        return "new", f"release {st.release.tag}"
    if st.tag_changed:
        return "pending", f"{e.synced} -> {st.release.tag}"
    if st.digest_changed:
        return "pending", f"asset{'s' if len(st.assets) > 1 else ''} replaced in release {e.synced}"
    if st.filter_changed:
        return "pending", "filter changed"
    if st.worktree == "missing":
        return "new", "not in the working tree yet"
    return None


def describe(st):
    """[(text, style)] one-line summary, used for hook output."""
    if st.error:
        return [(f"ERROR: {st.error}", "boldred")]
    parts = []
    up = upstream_state(st)
    if up:
        parts.append((f"upstream {up[0]} ({up[1]})", "yellow"))
    if st.modified:
        parts.append(("local modifications NOT ALLOWED", "boldred"))
    return parts or [("up to date", "green")]


def report_error(st):
    """An entry that couldn't be evaluated (status, pull)."""
    error(f"{st.entry.shown}: {st.error}")


def render(parts, stream="out"):
    return ", ".join(paint(t, s, stream) for t, s in parts)


def short_code(st):
    """Three columns like `git status -s`: upstream, committed, working tree."""
    if st.error:
        return "E  "
    up = upstream_state(st)
    x = {"pending": "P", "new": "N"}[up[0]] if up else " "
    y = "A" if st.committed == "adapted" else " "
    z = {"modified": "M", "deleted": "D", "added": "?"}.get(st.worktree, " ")
    return x + y + z


def shown(repo, rel):
    """Path relative to the current directory, like git status shows it (a
    trailing '/' of a directory kept)."""
    path = Path(os.path.relpath(repo.top / rel, repo.base)).as_posix()
    return path + "/" if rel.endswith("/") and path != "." else path


def path_arg(repo, rel):
    """A path as argument in a command shown to the user, who runs it in
    the current directory."""
    return cmd_arg(shown(repo, rel))


def print_short(repo, sts):
    for st in sts:
        code = short_code(st)
        if code.strip():
            line = paint(code[0], "yellow") + paint(code[1], "cyan") + paint(code[2], "red")
            if code[0] == "E":
                line = paint(code, "boldred")
            print(f"{line} {shown(repo, st.entry.shown)}")


def print_long(ctx, repo, sts, verbose):
    """Sections like `git status`."""
    hints = out(repo.git(["config", "--type=bool", "advice.statusHints"], check=False)) != "false"

    def section(title, hint_lines, rows, style):
        if not rows:
            return
        print(title)
        if hints:
            for h in hint_lines:
                print(f"  ({h})")
        for label, rel, note, nstyle in rows:
            line = paint(f"{label + ':':<12}{shown(repo, rel)}", style)
            print(f"\t{line}" + (f"  {paint('(' + note + ')', nstyle)}" if note else ""))
        print()

    ok = [st for st in sts if not st.error]
    if verbose:
        rows = []
        for st in ok:
            e = st.entry
            label = st.committed or ("uncommitted" if e.blob else "not synced")
            rows.append((label, e.shown, origin_text(e), "dim"))
        section("Files:", [], rows, None)

    up_rows = []
    for st in ok:
        up = upstream_state(st)
        if up:
            local = ", local folder" if st.release and st.release.local else ""
            up_rows.append((up[0], st.entry.shown, up[1] + local, "dim"))
    section("Upstream changes to pull:",
            ['use "git assetsync diff --upstream <file>..." to see what pull would bring',
             'use "git assetsync pull <file>..." to update'],
            up_rows, "yellow")

    not_allowed = ("NOT ALLOWED", "boldred")
    adapted = [st for st in ok if st.committed == "adapted"]
    section("Locally modified files:",
            ['use "git assetsync diff --committed <file>..." to see the modifications',
             'use "git assetsync restore -SW <file>..." to restore the release asset'],
            [("modified", st.entry.shown) + not_allowed for st in adapted], "cyan")

    labels = {"modified": "modified", "deleted": "deleted", "added": "new file"}
    dirty = [st for st in ok if st.worktree in labels]
    section("Uncommitted changes:",
            ['use "git assetsync diff <file>..." to see all local changes',
             'use "git restore <file>..." to discard uncommitted changes'],
            [(labels[st.worktree], st.entry.shown) +
             (not_allowed if st.local != "clean" else (None, None)) for st in dirty], "red")

    warnings = [(st.entry.shown, w) for st in ok for w in st.warnings]
    if warnings:
        print("Warnings:")
        for rel, w in warnings:
            print(f"\t{paint('warning:', 'yellow')} {shown(repo, rel)}: {w}")
        print()

    folders = {}
    for st in ok:
        if isinstance(st.origin, LocalFolder):
            folders.setdefault(st.origin.label, st.origin.dir)
    for label, folder in sorted(folders.items()):
        print(paint(f"releases of {label} from the local folder {folder} (git assetsync source map; "
                    "--remote: the platform)", "cyan"))
    if folders:
        print()
    if not ctx.fetch:
        print("new releases not checked (--no-fetch)")
    elif not up_rows and len(ok) == len(sts):
        dirs = sum(1 for st in sts if st.entry.is_dir)
        files = len(sts) - dirs
        what = and_list(([plural(files, "file")] if files else [])
                        + ([plural(dirs, "directory").replace("directorys", "directories")]
                           if dirs else []))
        print("nothing to pull" + ("" if adapted or dirty else
                                   f", {'all ' if len(sts) > 1 else ''}{what} unmodified"))


# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------

def cmd_status(ctx, repo, args):
    """Like `git status`: exit code 0 unless --exit-code (1 = something to
    pull or a file modified) or an error (2)."""
    reg = Registry(repo)
    entries = select_entries(repo, reg, args.paths, containing=True)
    if not entries:
        if not args.short:
            print(f"no synced files ({REGISTRY} not found or empty)")
        return EXIT_OK
    sts = [evaluate(ctx, repo, e) for e in entries]
    attention = [st for st in sts if st.error or st.pending or st.modified]
    rc = EXIT_ERROR if any(st.error for st in sts) else \
        EXIT_PENDING if args.exit_code and attention else EXIT_OK
    for st in sts:
        if st.error:
            report_error(st)
    if args.short:
        print_short(repo, sts)
    else:
        print_long(ctx, repo, sts, args.verbose)
    return rc


def print_mappings(maps, url=None):
    """Print mappings with their scope; entries shadowed by a later one
    (e.g. a global mapping overridden by the repository's own) are marked."""
    effective = {norm_url(u): i for i, (_, _, u, _, _) in enumerate(maps)}
    shown = 0
    for i, (sc, _, u, d, flat) in enumerate(maps):
        if url and norm_url(u) != norm_url(url):
            continue
        note = "" if effective[norm_url(u)] == i else paint("   (overridden)", "dim")
        print(f"{paint(f'[{sc}]', 'cyan')} {u} -> {d}{' (flat)' if flat else ''}{note}")
        shown += 1
    if not shown:
        print("no mappings" + (f" for {url}" if url else ""))


def map_url(repo, arg):
    """URL for map's argument: the name of a [source] of this repository, or
    a URL (owner/repo: github.com)."""
    if repo and "://" not in arg:
        sources = Registry(repo).sources
        if arg in sources:
            if not sources[arg].get("url"):
                raise FsError(f"[source \"{arg}\"] in {REGISTRY} has no url")
            return norm_url(sources[arg]["url"])
    return norm_url(source_url(arg))


def cmd_map(args, repo):
    """Map a source URL to a local folder with releases, for local
    development and tests. Default scope is this repository's config, so
    different repositories can use different folders; --global applies to
    all repositories. Never in .git-assetsync."""
    top = repo.top if repo else None
    url = map_url(repo, args.source) if args.source else None
    if args.flat and not args.dir:
        raise FsError("--flat goes with the folder: source map --flat URL|SOURCE DIR")
    if not args.dir and not args.unset:      # listing: all scopes visible here
        print_mappings(local_mappings(cwd=top), url)
        return EXIT_OK
    if not url:
        raise FsError("--unset needs the source (URL or name) of the mapping to remove")
    if args.glob:
        scope = "--global"
    elif repo:
        scope = "--local"
    else:
        raise FsError("not inside a Git repository; use --global for a global mapping")
    name = scope[2:]
    matching = [k for _, k, _, _, _ in mappings_for(url, scope, cwd=top)]

    def remove():
        for k in matching:
            git(["config", scope, "--unset-all", k], cwd=top)
            git(["config", scope, "--unset-all", k[:-len("localpath")] + "layout"], cwd=top,
                check=False)
    if args.unset:
        if not matching:
            print(f"no {name} mapping for {url}")
            return EXIT_OK
        remove()
        print(f"removed {name} mapping for {url}")
        rest = mappings_for(url, cwd=top)
        if rest:
            print(f"now using [{rest[-1][0]}] {rest[-1][3]}" + (" (flat)" if rest[-1][4] else ""))
        return EXIT_OK
    base = repo.base if repo else Path.cwd()
    d = (base / os.path.expanduser(args.dir)).resolve()
    if not d.is_dir():
        raise FsError(f"{d} is not a directory")
    remove()
    git(["config", scope, f"assetsync.{url}.localpath", str(d)], cwd=top)
    if args.flat:
        git(["config", scope, f"assetsync.{url}.layout", "flat"], cwd=top)
    print(f"{paint(f'[{name}]', 'cyan')} {url} -> {d}" + (" (flat)" if args.flat else ""))
    if args.flat and not LocalFolder.files_in(d):
        warn(f"{d} has no files yet (flat: each file is an asset of the release named like "
             "the file without its extension)")
    elif not args.flat and not any(c.is_dir() and not c.name.startswith(".")
                                   for c in d.iterdir()):
        warn(f"{d} has no release folders yet (one subdirectory per release, named like its "
             "tag, with the assets; or use --flat)")
    if scope == "--global" and repo:
        own = mappings_for(url, "--local", cwd=top)
        if own:
            warn(f"this repository has its own mapping ({own[-1][3]}), which takes precedence")
    return EXIT_OK


def registry_blobs(repo, revs):
    """Ids of the .git-assetsync of these commits, each once (commits without
    one left out) - one git call for all, as there may be many refs."""
    if not revs:
        return []
    data = "".join(f"{rev}:{REGISTRY}\n" for rev in revs).encode("utf-8")
    p = repo.git(["cat-file", "--batch-check=%(objecttype) %(objectname)"], data=data,
                 check=False)
    return list(dict.fromkeys(line.split(" ")[1] for line in out(p).splitlines()
                              if line.startswith("blob ")))


def registry_blob(repo, oid):
    """parse_registry() of a .git-assetsync blob, None if it can't be read."""
    p = repo.git(["config", "--blob", oid, "--list", "-z"], check=False)
    return parse_registry(p.stdout) if p.returncode == 0 else None


def synced_entries(parsed):
    """{(url, tag, digest): [(path, values, source)]} of the synced entries
    of a parsed registry."""
    result = {}
    for kind in BASE_KEY:
        for rel, v in sorted(parsed[kind].items()):
            src = parsed["source"].get(v.get("source", ""), {})
            if src.get("url") and v.get("synced"):
                key = (norm_url(src["url"]), v["synced"], (v.get("digest") or "").lower())
                result.setdefault(key, []).append((rel + ("/" if kind == "dir" else ""),
                                                   v, src))
    return result


def pushed_revs(repo, args):
    """(commits a push sends, commits the remote has): from the pre-push
    hook's stdin - git always passes the remote's name and URL, so without
    them the command was run by hand: HEAD. (Not isatty(): on Windows, NUL
    is a terminal.) What the remote has: the remote side of each ref and its
    remote-tracking branches."""
    if not args.hook_args:
        sent, have, refs = ["HEAD"], [], "refs/remotes/"
    else:
        sent, have, refs = [], [], f"refs/remotes/{args.hook_args[0]}/"
        for line in sys.stdin:
            parts = line.split()
            if len(parts) == 4 and parts[1].strip("0"):
                sent.append(parts[1])
                if parts[3].strip("0"):
                    have.append(parts[3])
    p = repo.git(["for-each-ref", "--format=%(objectname)", refs], check=False)
    return sent, have + out(p).splitlines()


def push_check(repo, args):
    """pre-push: entries in the pushed commits synced from a release that
    isn't on the platform, or whose assets differ from those there - e.g.
    pulled from a local folder (map). Entries the remote already has are
    not checked again. Warns on stderr; True if such an entry was found."""
    sent, have = pushed_revs(repo, args)
    known = set()
    have_blobs = registry_blobs(repo, have)
    for oid in have_blobs:
        parsed = registry_blob(repo, oid)
        if parsed:
            known |= set(synced_entries(parsed))
    found = {}
    for oid in registry_blobs(repo, sent):
        parsed = None if oid in have_blobs else registry_blob(repo, oid)
        for key, items in (synced_entries(parsed) if parsed else {}).items():
            if key not in known:
                lst = found.setdefault(key, [])
                lst += [i for i in items if i not in lst]
    bad = False
    for (url, tag, digest), items in sorted(found.items()):
        what = paint(", ".join(dict.fromkeys(rel for rel, _, _ in items)), "yellow", "err")
        try:
            origin = platform_of(url, items[0][2].get("type"), remote=True)
            release = origin.by_tag(tag)
            if release:
                _, v, _ = items[0]
                assets = select_assets(release, v.get("asset", ""), origin.label,
                                       any(rel.endswith("/") for rel, _, _ in items))
                now = assets_digest([(a.name, a.digest) for a in assets])
                if not (now and digest and now != digest):
                    continue
        except FsError as e:
            print(f"assetsync: {what}: cannot check whether release {tag} is on the server "
                  f"({url}: {e})", file=sys.stderr)
            continue
        if release:
            print(f"assetsync: {what}: synced from assets of release {tag} that differ from "
                  f"those on the server ({url}) - publish them there first", file=sys.stderr)
        else:
            print(f"assetsync: {what}: synced from release {tag}, which is not on the server "
                  f"({url}) - publish it there first", file=sys.stderr)
        bad = True
    return bad


def hook_reminders(sts):
    """Terse notes on stderr about entries needing attention: something to
    pull, local modifications, an error."""
    attention = [st for st in sts if st.error or st.pending or st.modified]
    for st in attention:
        print(f"assetsync: {paint(st.entry.shown, 'yellow', 'err')}: "
              f"{render(describe(st), 'err')}", file=sys.stderr)
    if any(st.pending for st in attention):
        print("assetsync: run 'git assetsync pull <file>' to update", file=sys.stderr)
    if any(st.modified for st in attention):
        print("assetsync: see 'git assetsync status' and 'git assetsync diff <file>' for "
              "local modifications", file=sys.stderr)


def cmd_hook(ctx, repo, args):
    """Run by the installed hooks (HOOKS): reminders on stderr; pre-push also
    checks the pushed commits (assetsync.pushCheck = warn | error | off).
    Exit code EXIT_REFUSED only to refuse a push."""
    hook_reminders([evaluate(ctx, repo, e) for e in Registry(repo).entries()])
    if args.name != "pre-push":
        return EXIT_OK
    mode = out(repo.git(["config", "assetsync.pushCheck"], check=False)).lower() or "warn"
    if mode not in ("warn", "error", "off"):
        warn(f"assetsync.pushCheck: unknown value '{mode}', using 'warn'")
        mode = "warn"
    if mode == "off" or not push_check(repo, args):
        return EXIT_OK
    if mode == "error":
        print(paint("assetsync: push refused (assetsync.pushCheck = error)", "boldred", "err"),
              file=sys.stderr)
        return EXIT_REFUSED
    print("assetsync: pushing anyway (refuse such pushes: git config assetsync.pushCheck error)",
          file=sys.stderr)
    return EXIT_OK


def release_lines(release, assets, filter_name=None, stats=None):
    """Body lines of a commit message naming the release, assets and filter,
    and for a directory what changes in it."""
    lines = [f"Release: {release.tag} (from a local folder, not published)" if release.local
             else f"Release: {release.url or release.tag}"]
    if release.title and release.title != release.tag:
        lines.append(f"Title:   {release.title}")
    names = [a.name for a in assets]
    if len(names) == 1:
        lines.append(f"Asset:   {names[0]}")
    else:
        lines.append(f"Assets:  {', '.join(names[:5])}"
                     + (f" and {len(names) - 5} more" if len(names) > 5 else ""))
    if filter_name:
        lines.append(f"Filter:  {filter_name}")
    if stats:
        added, removed, changed, total = stats
        lines.append(f"Files:   {added} added, {removed} removed, {changed} changed "
                     f"({total} in total)")
    return lines


def notes_limits(repo):
    """(lines per release, lines in all) of release notes in commit
    messages: assetsync.notesLines, assetsync.notesTotalLines."""
    result = []
    for key, default in (("notesLines", NOTES_LINES), ("notesTotalLines", NOTES_TOTAL_LINES)):
        v = out(repo.git(["config", f"assetsync.{key}"], check=False)).strip()
        if v and not v.isdigit():
            raise FsError(f"assetsync.{key}: '{v}' is not a number of lines")
        result.append(int(v) if v else default)
    return tuple(result)


def releases_between(st):
    """('Since', [releases]) skipped by updating to st.release - newer than
    the synced one, older than the new one, selected by the source's rule
    (its pattern, prereleases only if it takes them, no drafts) - or
    ('Reverted', [releases]) when going back to an older one: the synced one
    and those in between. Newest first; None if unknown."""
    entry, new = st.entry, st.release
    try:
        old = st.origin.by_tag(entry.synced)
        if not old or not old.date or not new.date:
            return None
        rule, pre = entry.spec.get("release"), is_true(entry.spec.get("prerelease"))
        others = [r for r in st.origin.releases() if r.tag not in (old.tag, new.tag)
                  and not r.draft and (pre or not r.prerelease)
                  and (not rule or not is_pattern(rule) or fnmatch.fnmatchcase(r.tag, rule))]
    except FsError:
        return None
    if old.date < new.date:
        skipped = [r for r in others if old.date < r.date < new.date]
        return "Since", sorted(skipped, key=lambda r: r.date, reverse=True)
    reverted = [old] + [r for r in others if new.date < r.date < old.date]
    return "Reverted", sorted(reverted, key=lambda r: r.date, reverse=True)


def notes_lines(notes, max_lines=NOTES_LINES):
    """Release notes shortened for a commit message: HTML comments (left
    over from templates) and repeated blank lines dropped, at most
    NOTES_LINES lines of NOTES_WIDTH characters. Indented, so that lines
    like Markdown headings ('## Changes') don't look like comments to `git
    commit`, which would strip them when the editor opens."""
    text = notes.replace("\r\n", "\n").replace("\r", "\n")
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    lines = []
    for line in text.split("\n"):
        line = line.rstrip()
        if line or (lines and lines[-1]):
            lines.append(line if len(line) <= NOTES_WIDTH else line[:NOTES_WIDTH - 5] + "[...]")
    while lines and not lines[-1]:
        lines.pop()
    more = len(lines) > max_lines
    lines = lines[:max_lines]
    while lines and not lines[-1]:
        lines.pop()
    if more:
        lines.append("[... see the release page for more]")
    return [f"  {line}" if line else "" for line in lines]


def build_message(st, discarded, unchanged=False, stats=None, between=None,
                  limits=(NOTES_LINES, NOTES_TOTAL_LINES)):
    """Commit message for pull: what the file (directory) is updated to, or
    restored. unchanged: it stays the same (only its entry changes).
    between: releases_between(); limits: notes_limits()."""
    entry, release = st.entry, st.release
    rel, name, tag, old = entry.shown, entry.name, release.tag, entry.synced
    what = "directory" if entry.is_dir else "file"
    if not old and entry.blob:      # source or asset changed with set
        subject = (f"Record {rel} as {name} {tag} ({what} unchanged)" if unchanged else
                   f"Update {rel} to {name} {tag}")
    elif not old:
        subject = f"Add {rel} from {name} {tag}"
    elif tag != old:
        subject = f"Update {rel} to {name} {tag} (was {old})"
    elif st.digest_changed:
        subject = f"Update {rel} from {name} {tag} (asset{'s' if len(st.assets) > 1 else ''} " \
                  "replaced)"
    elif st.filter_changed:
        subject = f"Update {rel} from {name} {tag} (filter changed)"
    else:
        subject = f"Restore {rel} from {name} {tag}"
    lines = [COMMIT_PREFIX + subject, ""] + release_lines(release, st.assets, entry.filter, stats)
    kind, others = between or ("", [])
    if others:
        tags = [r.tag for r in others]
        lines.append(f"{kind + ':':<8} {', '.join(tags[:LIST_RELEASES])}"
                     + (f" and {len(tags) - LIST_RELEASES} more" if len(tags) > LIST_RELEASES
                        else ""))
    # notes of the new release, then of those skipped; none when going back
    with_notes = [release] + others if old and tag != old and kind != "Reverted" else []
    per, remaining = limits
    sections = []
    for n, r in enumerate(with_notes if per and remaining else []):
        if remaining <= 0:
            if any(x.notes.strip() for x in with_notes[n:]):
                sections += ["", f"[... notes of {r.tag} and older: see the release pages]"]
            break
        notes = notes_lines(r.notes, min(per, remaining))
        if notes:
            heading = "Release notes:" if len(with_notes) == 1 else f"Release notes {r.tag}:"
            sections += ["", heading] + notes
            remaining -= len(notes)
    lines += sections
    if discarded:
        lines += ["", "Local modifications of this repository were discarded."]
    return "\n".join(lines) + "\n"


def entry_paths(repo, items):
    """[(mode, id, path)] with LFS pointers resolved, so that diffs show the
    content (and not pointers)."""
    return [(m, repo.content_id(o, path), path) for m, o, path in items]


def base_items(repo, entry):
    """[(mode, id, path)] of the base: what the entry was synced with."""
    if not entry.blob:
        return []
    if entry.is_dir:
        return [(m, o, f"{entry.rel}/{path}") for m, k, o, path in repo.tree_entries(entry.blob)
                if k == "blob"]
    return [(repo.head_mode(entry.rel) or "100644", entry.blob, entry.rel)]


def head_items(repo, entry):
    """[(mode, id, path)] of what HEAD has for the entry."""
    obj = repo.head_object(entry.rel)
    if not obj:
        return []
    if obj[0] == "tree":
        return [(m, o, f"{entry.rel}/{path}") for m, k, o, path in repo.tree_entries(obj[1])
                if k == "blob"]
    return [(repo.head_mode(entry.rel) or "100644", obj[1], entry.rel)]


def diff_items(ctx, repo, reg, args):
    """(rc, [(state, base items, other items)]) of all entries that differ:
    other = the working tree, HEAD (--committed) or what pull would install
    (--upstream)."""
    rc, groups = EXIT_OK, []
    for entry in select_entries(repo, reg, args.paths, containing=True):
        st = evaluate(ctx, repo, entry)
        if st.error:
            report_error(st)
            rc = EXIT_ERROR
            continue
        if not (st.changed if args.upstream else st.committed == "adapted" if args.committed
                else st.local != "clean"):
            continue
        try:
            if args.upstream:
                for w in st.warnings:
                    warn(f"{entry.shown}: {w}")
                _, other = filter_items(repo, reg, entry, st.origin, st.release, st.assets)
            elif args.committed:
                other = head_items(repo, entry)
            else:
                other = repo.worktree_items(entry.rel)
            groups.append((st, entry_paths(repo, base_items(repo, entry)),
                           entry_paths(repo, other)))
        except FsError as e:
            error(f"{entry.shown}: {e}")
            rc = EXIT_ERROR
    return rc, groups


def diff_groups(ctx, repo, args):
    """Checks the options of diff / difftool and evaluates the entries."""
    if args.release and not args.upstream:
        raise FsError("--release requires --upstream")
    ctx.fetch, ctx.override = args.upstream, args.release
    return diff_items(ctx, repo, Registry(repo), args)


def cmd_diff(ctx, repo, args):
    """One `git diff <tree> <tree>` over all entries that differ: real paths,
    the repository's diff settings and pager, options after `--`."""
    rc, groups = diff_groups(ctx, repo, args)
    left = [i for _, items, _ in groups for i in items]
    right = [i for _, _, items in groups for i in items]
    if not left and not right:
        return rc
    color = {"always": ["--color=always"], "never": ["--no-color"]}.get(args.color, [])
    prefixes = ["--src-prefix=synced/", "--dst-prefix=" + (
        "upstream/" if args.upstream else "committed/" if args.committed else "local/")]
    p = subprocess.run(["git", "diff"] + color + prefixes + args.extra
                       + [repo.make_tree(left), repo.make_tree(right)], cwd=repo.top)
    if p.returncode > 1:
        rc = EXIT_ERROR
    elif p.returncode == 1 and ("--exit-code" in args.extra or "--quiet" in args.extra):
        rc = max(rc, EXIT_PENDING)      # like `git diff --exit-code`: 1 = differences
    return rc


def difftool_prompting(repo, args):
    """Ask before each file like `git difftool`: by default only when no paths
    were given; -y/--no-prompt and difftool.prompt=false turn it off,
    --prompt turns it on."""
    if args.prompt:
        return True
    if args.no_prompt or args.paths:
        return False
    return out(repo.git(["config", "--type=bool", "difftool.prompt"], check=False)) != "false"


def difftool_name(repo, extra):
    for i, a in enumerate(extra):              # -t TOOL / --tool=TOOL passed after --
        if a.startswith("--tool="):
            return a.split("=", 1)[1]
        if a in ("-t", "--tool") and i + 1 < len(extra):
            return extra[i + 1]
    for key in ("diff.tool", "merge.tool"):
        name = out(repo.git(["config", key], check=False))
        if name:
            return name
    return "difftool"


def safe_name(text):
    return re.sub(r"[^A-Za-z0-9._-]", "_", text)


def cmd_difftool(ctx, repo, args):
    """diff in the configured difftool: file by file (temp copies named
    synced-<tag>, upstream-<tag>, committed-HEAD; without --upstream /
    --committed the real working file, so edits made in the tool are kept),
    or with -d both sides as directories (`git difftool -d` of two trees)."""
    rc, groups = diff_groups(ctx, repo, args)
    if not groups:
        return rc
    if args.dir_diff:
        left = repo.make_tree([i for _, items, _ in groups for i in items])
        right = repo.make_tree([i for _, _, items in groups for i in items])
        # links to working tree files fail on Windows without the privilege
        # for symbolic links: copies there (--symlinks after -- overrides)
        copies = ["--no-symlinks"] if os.name == "nt" else []
        subprocess.run(["git", "difftool", "-d"] + copies + args.extra + [left, right],
                       cwd=repo.top)
        return rc
    pairs = []          # (state, path, base id or None, other id or None)
    for st, base, other in groups:
        old = {path: (m, o) for m, o, path in base}
        new = {path: (m, o) for m, o, path in other}
        for path in sorted(set(old) | set(new)):
            if old.get(path) != new.get(path):
                pairs.append((st, path, (old.get(path) or (None, None))[1],
                              (new.get(path) or (None, None))[1]))
    prompt = difftool_prompting(repo, args)
    tool = difftool_name(repo, args.extra)
    with tempfile.TemporaryDirectory(prefix="assetsync-") as td:
        for n, (st, path, base, other) in enumerate(pairs, 1):
            if prompt:
                print(f"\nViewing ({n}/{len(pairs)}): '{shown(repo, path)}'")
                print(f"Launch '{tool}' [Y/n/q]? ", end="", flush=True)
                answer = sys.stdin.readline()
                if not answer or answer.strip().lower().startswith("q"):   # EOF or quit
                    print()
                    break
                if answer.strip().lower().startswith("n"):
                    continue

            def tmpfile(label, oid):
                """The blob in working tree form (empty if none), named like
                the file, in a directory named label."""
                f = Path(td) / str(n) / safe_name(label) / Path(path).name    # keep the extension
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_bytes(repo.checkout_form(oid, path) if oid else b"")
                return str(f)
            synced = st.entry.synced or "none"
            left = tmpfile(f"synced-{synced}", base)
            if args.upstream:
                right = tmpfile(f"upstream-{st.release.tag}", other)
            elif args.committed:
                right = tmpfile("committed-HEAD", other)
            elif other:
                right = str(repo.top / path)
            else:
                right = tmpfile("deleted", None)
            subprocess.run(["git", "difftool", "--no-index", "-y"] + args.extra + [left, right],
                           cwd=repo.top)
    return rc


def check_other_entries(reg, rels, args):
    """One commit = these files + their entries; other uncommitted entries
    would end up in it without their files."""
    if args.no_commit:
        return
    others = reg.uncommitted() - set(rels)
    if others:
        raise FsError(f"{REGISTRY} has uncommitted changes for {', '.join(sorted(others))}"
                      " - commit them first, or use --no-commit to stage everything "
                      "and commit together")


def message_file(repo, name, msg, rels=None):
    """Keep the proposed commit message in .git/ASSETSYNC_MSG_<name>; returns
    the file and the command that commits the files (default: name) and
    their entries with it - with paths relative to the current directory,
    where it is run."""
    rels = [name] if rels is None else rels
    msgfile = repo.state_file("ASSETSYNC_MSG_", rels[0])
    msgfile.write_bytes(msg.encode("utf-8"))
    paths = " ".join(path_arg(repo, r) for r in rels + [REGISTRY])
    return msgfile, f'git commit -e -F "{shown_path(repo, msgfile)}" -- {paths}'


def propose_message(repo, msg):
    """Also put a proposed commit message into .git/SQUASH_MSG, which a plain
    `git commit` (and IDEs) offer; git removes it after the next commit.
    Proposals of several commands are collected. A SQUASH_MSG of git's own
    (e.g. from merge --squash) is left alone. Returns True if done."""
    squash = repo.gitdir / "SQUASH_MSG"
    ours = repo.state_file("ASSETSYNC_", "SQUASH_MSG")     # copy of what we wrote
    if squash.exists():
        prev = squash.read_text(encoding="utf-8", errors="replace")
        if not ours.exists() or ours.read_text(encoding="utf-8", errors="replace") != prev:
            return False
        if msg in prev:
            return True
        msg = prev.rstrip("\n") + "\n\n" + msg
    for f in (squash, ours):
        f.write_bytes(msg.encode("utf-8"))
    return True


def shown_path(repo, path):
    """A path outside the working tree (e.g. in .git) as shown to the user:
    relative to the current directory if possible."""
    try:
        return Path(os.path.relpath(path, repo.base)).as_posix()
    except ValueError:            # Windows: another drive
        return Path(path).as_posix()


def commit_hint(repo, name, msg, rels=None):
    """(command, note) for committing staged changes with the proposed
    message: a plain `git commit` if the message could be prepared for it
    (see propose_message), otherwise one with a message file."""
    if propose_message(repo, msg):
        # git drops SQUASH_MSG after any commit (also one that didn't use
        # it) and on reset; our copy stays until the next proposal
        copy = shown_path(repo, repo.state_file("ASSETSYNC_", "SQUASH_MSG"))
        return "git commit", f"it offers the proposed commit message; a copy stays in {copy}"
    _, cmd = message_file(repo, name, msg, rels)
    return cmd, "a plain 'git commit' won't offer the proposed message: .git/SQUASH_MSG is in use"


def report_staged(repo, name, msg, done, rels=None, how="Commit with"):
    """Tell how to commit what a command staged without committing."""
    cmd, note = commit_hint(repo, name, msg, rels)
    print(f"{name}: {done}. {how}:\n    {cmd}\n({note})")


def commit_staged(repo, name, msg, args, done, rels=None):
    """Commit the staged files (default: name) and their entries with the
    proposed message (in the editor unless --no-edit). With --no-commit,
    leave them staged and tell how to commit. done: e.g. 'updated and staged'."""
    rels = [name] if rels is None else rels
    if args.no_commit:
        report_staged(repo, name, msg, paint(done, "green"), rels)
        return EXIT_OK
    msgfile, _ = message_file(repo, name, msg, rels)
    if not commit_paths(repo, rels + [REGISTRY], msgfile, not args.no_edit):
        report_staged(repo, name, msg, paint("commit not done", "yellow")
                      + "; changes stay staged", rels, "Commit later with")
        return EXIT_PENDING
    msgfile.unlink()
    return EXIT_OK


def commit_paths(repo, rels, msgfile, edit):
    """Commit only these paths, as they are staged - like `git commit --
    PATHS`, which, though, takes them from the working tree again: with
    core.filemode=false (Windows) it would lose executable bits set with
    update-index --chmod. The commit is made from a temporary index (HEAD
    with these paths as staged), so hooks run as usual. True if done."""
    for name, what in (("MERGE_HEAD", "merge"), ("CHERRY_PICK_HEAD", "cherry-pick"),
                       ("REVERT_HEAD", "revert")):
        if (repo.gitdir / name).exists():
            error(f"cannot commit only these files during a {what} (like `git commit -- "
                  "PATHS`) - finish it first")
            return False
    specs = [lit(r) for r in rels]
    staged = repo.git(["ls-files", "-s", "-z", "--"] + specs).stdout
    with repo.temp_index() as env:
        if repo.git(["rev-parse", "-q", "--verify", "HEAD"], check=False).returncode == 0:
            repo.git(["read-tree", "HEAD"], env=env)
        # what HEAD has at these paths, removed; then what is staged
        old = repo.git(["ls-files", "-z", "--"] + specs, env=env).stdout
        if old:
            repo.git(["update-index", "-z", "--force-remove", "--stdin"], data=old, env=env)
        if staged:
            repo.git(["update-index", "-z", "--index-info"], data=staged, env=env)
        cmd = ["git", "commit", "-F", str(msgfile)] + (["-e"] if edit else [])
        return subprocess.run(cmd, cwd=repo.top, env=env).returncode == 0


def install_file(repo, rel, target, files, overwrite=False):
    """Store the one file of files as `git add` would at rel, write it to
    the working tree as `git checkout` would and stage it. A file already
    there that differs is only replaced with overwrite. Returns its blob."""
    (name, (src, executable)), = files.items()
    blob = repo.add_file(src, rel)
    cur = repo.worktree_blob(target)
    if cur and cur != blob and not overwrite:
        raise FsError(f"'{rel}' exists and differs from {name} - use --overwrite to replace it")
    if target.is_dir():
        raise FsError(f"'{rel}' is a directory")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(repo.checkout_form(blob, rel))
    set_executable(target, executable)
    repo.git(["add", "--", lit(rel)])
    # also -x: with core.filemode=false (Windows) `git add` keeps the old mode
    repo.git(["update-index", f"--chmod={'+' if executable else '-'}x", "--", rel])
    return blob


def set_executable(path, executable):
    mode = path.stat().st_mode
    os.chmod(path, mode | 0o111 if executable else mode & ~0o111)


def install_dir(repo, rel, target, files):
    """Make the directory rel exactly files: other files git sees there
    (tracked or untracked) are deleted, ignored ones stay. Stages it and
    returns its tree."""
    if target.exists() and not target.is_dir():
        raise FsError(f"'{rel}' is a file")
    for path in repo.dir_files(rel):
        if path[len(rel) + 1:] not in files:
            (repo.top / path).unlink()
    if target.is_dir():
        for d in sorted((d for d in target.rglob("*") if d.is_dir()), reverse=True):
            try:
                d.rmdir()               # only empty ones
            except OSError:
                pass
    for name, (src, executable) in sorted(files.items()):
        dest = target / name
        try:
            if dest.is_dir():
                raise FsError(f"'{rel}/{name}' is a directory in the working tree")
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, dest)
            set_executable(dest, executable)
        except OSError as e:
            raise FsError(f"cannot write '{rel}/{name}': {e.strerror}")
    repo.git(["rm", "-r", "-q", "--cached", "--ignore-unmatch", "--", lit(rel)])
    paths = [f"{rel}/{name}" for name in sorted(files)]
    # -f: also files the repository ignores (e.g. *.lib) - the entry has them
    repo.git(["add", "-f", "--pathspec-from-file=-", "--pathspec-file-nul"],
             data="\0".join(lit(p) for p in paths).encode("utf-8"))
    executables = [p for p, name in zip(paths, sorted(files)) if files[name][1]]
    if executables:
        repo.git(["update-index", "--chmod=+x", "-z", "--stdin"],
                 data="\0".join(executables).encode("utf-8"))
    return out(repo.git(["write-tree", f"--prefix={rel}/"]))


def tree_stats(repo, old, new):
    """(added, removed, changed, total) files from tree old (None: none) to new."""
    total = len(repo.tree_entries(new))
    if not old:
        return total, 0, 0, total
    p = repo.git(["diff-tree", "-r", "-z", "--no-renames", "--name-status", old, new])
    status = [s for s in p.stdout.decode("utf-8", "replace").split("\0")[0::2] if s]
    return status.count("A"), status.count("D"), \
        len(status) - status.count("A") - status.count("D"), total


def one_file(files, entry_shown, rel):
    """The files of a [file] entry: exactly one."""
    if len(files) != 1:
        raise FsError(f"{entry_shown}: the filter gives {len(files)} files, a file needs exactly "
                      f"one - narrow the filter, or add '{rel}/' as a directory")
    return files


def install(repo, st, origin, release, assets, steps, filters, overwrite):
    """Fetch, filter and install what an entry gets; staged. Returns
    (digest, base, stats)."""
    entry = st.entry
    trusted = ensure_trusted(repo, steps, filters)
    env = {"ASSETSYNC_RELEASE": release.tag, "ASSETSYNC_SOURCE": origin.label,
           "ASSETSYNC_ENTRY": entry.shown}
    with Work(entry.shown, repo.top, env, trusted) as work:
        files, digest = entry_files(origin, release, assets, steps, filters, work)
        if entry.is_dir:
            tree = install_dir(repo, entry.rel, entry.target, files)
            return digest, tree, tree_stats(repo, st.head_blob, tree)
        one_file(files, entry.shown, entry.rel)
        return digest, install_file(repo, entry.rel, entry.target, files, overwrite), None


def pull_one(repo, reg, st, args):
    entry, rel = st.entry, st.entry.shown
    if not st.pending and not st.modified:
        print(f"{rel}: {paint('up to date', 'green')}")
        return EXIT_OK
    # like `git pull` with no merge possible: local modifications are never
    # overwritten silently
    if st.modified and not args.overwrite:
        what = ("committed modifications" if st.committed == "adapted" else
                "uncommitted changes")
        raise FsError(f"{rel}: {what} NOT ALLOWED - it must stay what its release "
                      f"gives; discard them with 'git assetsync restore -SW "
                      f"{path_arg(repo, rel)}', or update anyway with 'git assetsync pull "
                      f"--overwrite {path_arg(repo, rel)}'")
    # an entry without a base (written by hand): a directory with files is
    # only taken over with --overwrite (a file: only if it is the same)
    if entry.is_dir and not entry.blob and not args.overwrite and repo.dir_files(entry.rel):
        raise FsError(f"'{rel}' is not empty - with --overwrite it becomes the entry's (files "
                      "there the release doesn't give are deleted)")
    check_other_entries(reg, [entry.rel], args)
    for w in st.warnings:
        warn(f"{rel}: {w}")
    discard = st.modified
    if args.dry_run:
        msg = build_message(st, discard).splitlines()[0][len(COMMIT_PREFIX):]
        print(f"would: {msg}" + (" - discarding local modifications" if discard else ""))
        return EXIT_OK
    # before anything changes: the releases in between, and the limits of the notes
    limits = notes_limits(repo)
    between = releases_between(st) if entry.synced and st.release.tag != entry.synced \
        else None
    if discard:
        warn(f"{rel}: discarding local modifications")
    digest, base, stats = install(repo, st, st.origin, st.release, st.assets, entry.steps,
                                  reg.filters, overwrite=args.overwrite or bool(entry.blob))
    msg = build_message(st, discard, unchanged=base == entry.blob, stats=stats,
                        between=between, limits=limits)
    entry.set("synced", st.release.tag)
    entry.set("digest", digest)
    entry.set("filterhash", filter_hash(entry.steps, reg.filters, repo))
    entry.set(BASE_KEY[entry.kind], base)
    reg.finish()
    return commit_staged(repo, rel, msg, args, "updated and staged", rels=[entry.rel])


def one_off_hint(ctx, st):
    """After pull --release: the source still selects another release, which
    status shows as pending and a plain pull goes back to."""
    try:
        _, selected = ctx.release(st.entry.url, st.entry.spec, override=False)
    except FsError:
        return
    if selected.tag != st.release.tag:
        rel = path_arg(st.entry.reg.repo, st.entry.shown)
        print(f"note: {st.entry.shown}: its source still selects {selected.tag} - 'git "
              f"assetsync pull {rel}' goes back to it; to stay on {st.release.tag}: 'git "
              f"assetsync set {rel} --release {shlex.quote(st.release.tag)}'")


def cmd_pull(ctx, repo, args):
    reg = Registry(repo)
    reg.dry_run = args.dry_run
    if args.release and args.all:
        raise FsError("--release needs the files to pull, not --all")
    if args.all:
        entries = reg.entries()
    elif args.paths:
        entries = select_entries(repo, reg, args.paths, containing=True)
    else:
        raise FsError("specify file(s) or --all")
    ctx.override = args.release
    rc, done = EXIT_OK, 0
    for n, entry in enumerate(entries, 1):
        st = evaluate(ctx, repo, entry)
        if st.error:
            report_error(st)
            rc = EXIT_ERROR
            continue
        if args.all and not st.pending and not (args.overwrite and st.modified):
            continue
        done += 1
        if args.verbose:
            print(f"{entry.shown}: {paint(origin_text(entry), 'dim')}", flush=True)
        try:
            result = pull_one(repo, reg, st, args)
            rc = max(rc, result)
            if args.release and (st.pending or st.modified):
                one_off_hint(ctx, st)
        except FsError as e:   # report and carry on with the other files
            error(str(e))
            rc = EXIT_ERROR
            continue
        # the commit wasn't done: the others would be refused because of its entry
        if result == EXIT_PENDING and n < len(entries):
            warn(f"stopped after {entry.shown} - commit it first, then pull the rest")
            break
    if args.all and not done and rc == EXIT_OK:
        print(paint("everything up to date", "green"))
    return rc


def add_source(reg, args):
    """(url, spec, name) for add. The name of a [source]: that source, unless
    --release/--prerelease ask for another selection - then its URL with
    that selection (names are 'owner/repo' like the short form of a URL). A
    URL: name None, the source is found (by URL and selection) or created
    later."""
    given = source_spec({"release": args.release, "type": args.type,
                         "prerelease": "true" if args.prerelease else None})
    if args.source in reg.sources:            # name of an existing [source]
        s = reg.sources[args.source]
        spec = source_spec(s)
        if not s.get("url"):
            raise FsError(f'[source "{args.source}"] in {REGISTRY} has no url')
        if all(spec.get(k) == v for k, v in given.items()):
            return s["url"], spec, args.source
        if spec.get("type") and not given.get("type"):
            given["type"] = spec["type"]
        return s["url"], given, None
    return source_url(args.source), given, None


def large_binary_hint(repo, rels):
    """Warn about big binary files that are not stored in Git LFS: each
    update adds another copy of them to the history."""
    shown = 0
    for rel in rels:
        path = repo.top / rel
        size = path.stat().st_size
        if size < LFS_HINT_SIZE:
            continue
        with open(path, "rb") as f:
            if b"\0" not in f.read(8000):
                continue
        if out(repo.git(["check-attr", "filter", "--", rel])).endswith(": lfs"):
            continue
        shown += 1
        if shown <= 3:
            warn(f"{rel} is a binary file of {size // 1024} KiB, not stored in Git LFS - every "
                 f"update adds a copy to the history; consider 'git lfs track {path_arg(repo, rel)}' "
                 "(before committing)")
    if shown > 3:
        warn(f"... and {shown - 3} more such files")


class StepOption(argparse.Action):
    """A step option of filter add / set: collected in args.steps in the
    order given on the command line."""

    def __call__(self, parser, namespace, values, option_string=None):
        steps = getattr(namespace, "steps", None) or []
        steps.append((self.dest, values))
        namespace.steps = steps


def filter_steps(args):
    """Filter steps from the options of filter add / set, in the order given;
    consecutive --include (--exclude) options make one include (exclude)
    step with all their patterns. None if none are given."""
    steps, last = [], None
    for kind, value in getattr(args, "steps", None) or []:
        if kind == "extract":
            steps.append(shlex.join(["extract"] + list(value)))
        elif kind == "subdir":
            steps.append(shlex.join(["subdir", value]))
        elif kind == "strip":
            if value < 1:
                raise FsError("--strip needs a number of at least 1")
            steps.append(f"strip {value}")
        elif kind in ("include", "exclude"):
            if last == kind:
                steps[-1] = shlex.join(shlex.split(steps[-1]) + [value])
            else:
                steps.append(shlex.join([kind, value]))
        else:                           # move, copy, apply, convert, run
            steps.append(shlex.join([kind] + ([value] if isinstance(value, str) else list(value))))
        last = kind
    for step in steps:
        parse_step(step)
    return steps or None


def cmd_add(ctx, repo, args):
    reg = Registry(repo)
    target = repo.user_path(args.path)
    rel = repo.rel(target)
    is_dir = args.path.endswith(("/", "\\")) or target.is_dir()
    kind, shown_rel = ("dir", rel + "/") if is_dir else ("file", rel)
    problem = path_problem(rel) if rel != "." else "is the repository itself"
    if problem:
        raise FsError(f"cannot add '{rel}': {problem}")
    if is_dir and target.exists() and not target.is_dir():
        raise FsError(f"cannot add '{shown_rel}': is a file")
    if rel in reg.files and not args.force:
        raise FsError(f"'{rel}' is already synced (use --force to replace its entry)")
    if rel in reg.files and reg.section(rel) != kind:
        raise FsError(f"'{rel}' is synced as a {'directory' if reg.section(rel) == 'dir' else 'file'}"
                      f" - remove its entry with 'git assetsync unlink {path_arg(repo, rel)}' first")
    others = reg.overlapping(rel, exclude=rel)
    if others:
        raise FsError(f"cannot add '{shown_rel}': overlaps with the entry for "
                      f"{', '.join(others)} - entries must not overlap")
    if args.filter and args.filter not in reg.filters:
        raise FsError(f"no filter '{args.filter}' in {REGISTRY} - define it first with "
                      f"'git assetsync filter add {args.filter} ...'")
    steps = [shlex.join(["apply", "*", args.filter])] if args.filter else []
    url, spec, named = add_source(reg, args)
    origin, release = ctx.release(url, spec)
    assets = select_assets(release, args.asset, origin.label, is_dir)
    name = named or reg.source_name(url, spec)
    if is_dir and not args.asset and len(assets) > 1:
        total = sum(a.size or 0 for a in assets)
        print(f"{shown_rel}: all {plural(len(assets), 'asset')} of {name} {release.tag}: "
              + ", ".join(a.name + (f" ({human_size(a.size)})" if a.size is not None else "")
                          for a in assets), flush=True)
        if (len(assets) > MAX_ALL_ASSETS or total > MAX_ALL_SIZE) and not args.force:
            raise FsError(f"that is more than {MAX_ALL_ASSETS} assets or {MAX_ALL_SIZE >> 20} MiB"
                          " - choose some with --asset PATTERN, or take all with --force")
    # what an entry being replaced has from its release may go; anything else (a file
    # or directory of the user, local modifications) only with --overwrite
    overwrite = args.overwrite
    if rel in reg.files and not overwrite and Entry(reg, rel).blob:
        old = State(entry=Entry(reg, rel), rel=rel)
        (local_state_dir if is_dir else local_state_file)(repo, old)
        if old.local == "modified":
            raise FsError(f"'{shown_rel}' has local modifications - use --overwrite to "
                          "discard them")
        overwrite = True
    if is_dir and not overwrite and repo.dir_files(rel):
        raise FsError(f"'{shown_rel}' is not empty - with --overwrite it becomes the entry's "
                      "(files there the release doesn't give are deleted; ignored ones stay)")
    if args.dry_run:
        print(f"would add {shown_rel} from {name} {release.tag} "
              f"({', '.join(a.name for a in assets)}, {spec_text(spec)}"
              + (f", filter {args.filter}" if args.filter else "") + ")")
        return EXIT_OK
    obj = repo.head_object(rel)
    st = State(entry=SimpleNamespace(shown=shown_rel, rel=rel, target=target, is_dir=is_dir),
               rel=rel, head_blob=obj[1] if obj and obj[0] == "tree" else None)
    digest, base, stats = install(repo, st, origin, release, assets, steps, reg.filters,
                                  overwrite)
    if rel in reg.files:
        reg.remove_file(rel, keep_source=named)
    name = named or reg.add_source(url, spec)
    reg.new_entry(rel, kind)
    entry = Entry(reg, rel)
    for k, v in (("source", name), ("asset", args.asset), ("filter", args.filter),
                 ("synced", release.tag), ("digest", digest),
                 ("filterhash", filter_hash(steps, reg.filters, repo)), (BASE_KEY[kind], base)):
        if v:
            entry.set(k, v)
    reg.finish()
    large_binary_hint(repo, [f"{rel}/{n}" for n in repo.tree_names(base)] if is_dir else [rel])
    print(f"{paint('added', 'green')} {shown_rel} <- {name} {release.tag} "
          f"({', '.join(a.name for a in assets)})")
    if repo.git(["diff", "--cached", "--quiet", "HEAD", "--", lit(rel), REGISTRY],
                check=False).returncode == 0:
        print(f"{shown_rel}: entry and {'directory' if is_dir else 'file'} unchanged, "
              "nothing to commit")
        return EXIT_OK
    # staged only, like git add; the proposed message is prepared for the commit
    msg = "\n".join([f"{COMMIT_PREFIX}Add {shown_rel} from {name} {release.tag}", ""]
                    + release_lines(release, assets, args.filter, stats)) + "\n"
    report_staged(repo, shown_rel, msg, paint("staged", "green"), rels=[rel])
    return EXIT_OK


def registry_problems(reg):
    """Gaps in the registry that status (or pull) would report, as text."""
    problems = []
    used = {v.get("source") for v in reg.files.values()}
    for name, src in sorted(reg.sources.items()):
        if not src.get("url"):
            problems.append(f'[source "{name}"] has no url')
        else:
            try:
                platform_of(src["url"], src.get("type"), remote=True)
            except FsError as e:
                problems.append(f'[source "{name}"]: {e}')
        if name not in used:
            problems.append(f'[source "{name}"] is not used by any file')
    for name in sorted(reg.filters):
        try:
            expand_steps([shlex.join(["apply", "*", name])], reg.filters)
        except FsError as e:
            problems.append(f'[filter "{name}"]: {e}')
    reported = set()
    for rel in sorted(reg.files):
        v, kind = reg.files[rel], reg.section(rel)
        sect = f'[{kind} "{rel}"]'
        problem = path_problem(rel)
        if problem:
            problems.append(f"{sect}: {problem}")
            continue
        if reg.kinds.get(rel) == "both":
            problems.append(f'[file "{rel}"] and [dir "{rel}"] both exist')
        for other in reg.overlapping(rel, exclude=rel):
            if (other, rel) not in reported:
                reported.add((rel, other))
                problems.append(f"{sect} overlaps with the entry for {other}")
        if not v.get("source"):
            problems.append(f"{sect} has no source")
        elif v["source"] not in reg.sources:
            problems.append(f'{sect}: no [source "{v["source"]}"]')
        if "step" in v:
            problems.append(f"{sect}: filter steps belong to a named [filter]")
        if v.get("filter") and v["filter"] not in reg.filters:
            problems.append(f'{sect}: no [filter "{v["filter"]}"]')
        if not v.get("synced") or not v.get(BASE_KEY[kind]):
            problems.append(f"{sect} lacks synced or {BASE_KEY[kind]} (what it was synced "
                            "with) - pull takes the release")
    return problems


def cmd_edit(ctx, repo, args):
    """Open .git-assetsync in the editor (git's: GIT_EDITOR, core.editor,
    VISUAL, EDITOR), then check it and stage it."""
    path = repo.top / REGISTRY
    if not path.exists():
        raise FsError(f"no {REGISTRY} yet - take files from release assets with "
                      "'git assetsync add'")
    before = path.read_bytes()
    # run like git runs its editor ('git config --edit' exits with 0 even if
    # the editor fails): GIT_EDITOR, core.editor, VISUAL, EDITOR, via sh
    editor = out(repo.git(["var", "GIT_EDITOR"]))
    if subprocess.run(shell_command() + ["-c", f'{editor} "$@"', editor, REGISTRY],
                      cwd=repo.top).returncode:
        raise FsError("the editor failed; nothing staged")
    if path.exists() and path.read_bytes() == before:
        print(f"{REGISTRY}: no changes")
        return EXIT_OK
    try:
        reg = Registry(repo)
    except FsError as e:
        raise FsError(f"{e} - not staged; fix it with 'git assetsync edit'")
    for problem in registry_problems(reg):
        warn(f"{REGISTRY}: {problem}")
    reg.finish()
    print(f'{REGISTRY} staged (use "git assetsync status" to see what changes, '
          '"git assetsync pull <file>..." to update)')
    return EXIT_OK


def move_to_source(reg, name, entries, url, spec, named=None):
    """Point entries of [source] name at the source with url and spec - or
    exactly at [source] named. If they are all files of the source and no
    such source exists, the source itself is changed; otherwise they move
    to it (found or created) and the source is split, or removed when left
    without files. Returns a description of the change."""
    source = reg.sources[name]
    old_url, old = source.get("url", ""), source_spec(source)
    new_url = norm_url(url) != norm_url(old_url)

    def text(u, sp):
        return f"{u} ({spec_text(sp)})" if new_url else spec_text(sp)
    target = named or reg.find_source(url, spec, exclude=name)
    if not target and set(reg.source_files(name)) == {e.rel for e in entries}:
        if new_url:
            reg.set_source(name, "url", url)
        reg.set_spec(name, spec)
        return f"{name}: {text(old_url, old)} -> {text(url, spec)}"
    target = target or reg.add_source(url, spec)
    for e in entries:
        reg.set_file(e.rel, "source", target)
    rest = len(reg.source_files(name))
    if not rest:
        reg.remove_source(name)
    desc = f"{', '.join(e.rel for e in entries)}: {name} -> {target} ({text(url, spec)})"
    return desc + (f"; {name} keeps {plural(rest, 'other file')}" if rest else "")


def cmd_set(ctx, repo, args):
    """Change entries - their source, release selection or asset - where
    add would need --force, like 'source' does for sources. Only
    .git-assetsync is changed (and staged); pull then updates the files.
    The base (blob, digest) is kept, so local modifications stay
    recognized; with another URL or asset, which release asset the file
    comes from is unknown until the next pull (synced removed)."""
    select = args.release is not None or args.latest or args.prerelease is not None or \
        args.type is not None
    if not (args.source or select or args.asset is not None or args.no_asset or
            args.filter or args.no_filter):
        raise FsError("nothing to change: give --source, --release/--latest/--prerelease/"
                      "--type, --asset/--no-asset or --filter/--no-filter")
    reg = Registry(repo)
    if args.filter and args.filter not in reg.filters:
        raise FsError(f"no filter '{args.filter}' in {REGISTRY} - define it first with "
                      f"'git assetsync filter add {args.filter} ...'")
    if args.release is not None and args.latest:
        raise FsError("--release and --latest exclude each other")
    reg.dry_run = args.dry_run
    entries = select_entries(repo, reg, args.paths)
    would = "would: " if args.dry_run else ""
    changed = False
    given = add_source(reg, args) if args.source else None      # (url, spec, named)
    groups = {}
    for e in entries:
        groups.setdefault(e.name, []).append(e)
    for name, ents in groups.items():
        source = reg.sources.get(name)
        if not source or not source.get("url"):
            raise FsError(f"{ents[0].rel}: its [source \"{name}\"] in {REGISTRY} has no url")
        if given:
            url, spec, named = given
        elif select:
            url, spec, named = source["url"], source_spec(source), None
            if args.release is not None:
                spec["release"] = args.release
            if args.latest:
                spec.pop("release", None)
            if args.prerelease is not None:
                if args.prerelease:
                    spec["prerelease"] = "true"
                else:
                    spec.pop("prerelease", None)
            if args.type is not None:
                spec["type"] = args.type
        else:
            continue
        if named == name or not named and norm_url(url) == norm_url(source["url"]) \
                and spec == source_spec(source):
            continue
        platform_of(url, spec.get("type"))       # a usable URL and type
        new_url = norm_url(url) != norm_url(source["url"])
        print(would + move_to_source(reg, name, ents, url, spec, named))
        changed = True
        if new_url:      # another project: which of its assets is not known yet
            for e in ents:
                e.set("synced", None)
    if args.asset is not None or args.no_asset:
        new = None if args.no_asset else args.asset
        for e in entries:
            if (e.asset or None) != new:
                every = "(all)" if e.is_dir else "(the only one)"
                print(f"{would}{e.shown}: asset {e.asset or every} -> {new or every}")
                e.set("asset", new)
                e.set("synced", None)
                changed = True
    if args.filter or args.no_filter:
        for e in entries:
            if e.filter != args.filter:
                print(f"{would}{e.shown}: filter {e.filter or '(none)'} -> "
                      f"{args.filter or '(none)'}")
                e.set("filter", args.filter)
                changed = True
    if not changed:
        print("nothing to change")
    elif not args.dry_run:
        reg.finish()
        print(f'{REGISTRY} staged (use "git assetsync status" to see what changes, '
              '"git assetsync pull <file>..." to update)')
    return EXIT_OK


def human_size(n):
    """'512 bytes' / '1.2 KiB' / '3.4 MiB' / '1.1 GiB'."""
    if n is None:
        return ""
    for unit in ("bytes", "KiB", "MiB"):
        if n < 1024:
            return f"{n} {unit}" if unit == "bytes" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} GiB"


def filter_items(repo, reg, entry, origin, release, assets):
    """Filter the assets of release for an entry, without touching the working
    tree or the index: (digest, [(mode, id, path)]) - the files as `git add`
    would store them at their paths in the repository."""
    trusted = ensure_trusted(repo, entry.steps, reg.filters)
    env = {"ASSETSYNC_RELEASE": release.tag, "ASSETSYNC_SOURCE": origin.label,
           "ASSETSYNC_ENTRY": entry.shown}
    with Work(entry.shown, repo.top, env, trusted) as work:
        files, digest = entry_files(origin, release, assets, entry.steps, reg.filters, work)
        if not entry.is_dir:
            files = {entry.rel: f for f in one_file(files, entry.shown, entry.rel).values()}
        else:
            files = {f"{entry.rel}/{name}": f for name, f in files.items()}
        return digest, [("100755" if executable else "100644", repo.add_file(src, path), path)
                        for path, (src, executable) in sorted(files.items())]


def verify_one(repo, reg, entry):
    """(ok, text) of filtering the assets an entry was synced with again and
    comparing the result with its recorded base - without touching the
    working tree or the index. None if there is nothing to verify."""
    if not entry.synced or not entry.blob:
        return None, "not synced yet, nothing to verify"
    expand_steps(entry.steps, reg.filters)
    if filter_hash(entry.steps, reg.filters, repo) != entry.filterhash:
        return None, "its filter changed since the sync - pull first, then verify"
    origin = platform_of(entry.url, entry.spec.get("type"))
    release = origin.by_tag(entry.synced)
    if not release:
        raise FsError(f"release {entry.synced} of {origin.label} no longer exists")
    assets = select_assets(release, entry.asset, origin.label, entry.is_dir)
    st = State(entry=entry, rel=entry.rel)
    digest, items = filter_items(repo, reg, entry, origin, release, assets)
    if digest != (entry.digest or "").lower():
        return False, (f"the assets of {release.tag} differ from those it was synced with "
                       "(re-uploaded?)")
    if not entry.is_dir:
        (_, new, _), = items
        if matches_base(repo, st, new):
            return True, f"verified ({release.tag})"
        return False, f"differs from what {release.tag} gives now"
    new = repo.make_tree([(m, o, path[len(entry.rel) + 1:]) for m, o, path in items])
    if tree_matches_base(repo, st, new):
        return True, f"verified ({release.tag})"
    p = repo.git(["diff-tree", "-r", "--no-renames", "--name-status", entry.blob, new])
    changes = [f"\t{line}" for line in out(p).splitlines()]
    return False, f"differs from what {release.tag} gives now:\n" + "\n".join(changes)


def cmd_verify(ctx, repo, args):
    """Is the committed state reproducible? Filters the assets each entry
    was synced with again and compares the result with its base."""
    reg = Registry(repo)
    rc = EXIT_OK
    entries = select_entries(repo, reg, args.paths, containing=True)
    if not entries:
        print(f"no synced files ({REGISTRY} not found or empty)")
    for entry in entries:
        problem = path_problem(entry.rel)
        try:
            if problem:
                raise FsError(problem)
            if args.verbose:
                print(f"{entry.shown}: {paint(origin_text(entry), 'dim')}", flush=True)
            ok, text = verify_one(repo, reg, entry)
        except FsError as e:
            error(f"{entry.shown}: {e}")
            rc = EXIT_ERROR
            continue
        style = "green" if ok else "dim" if ok is None else "boldred"
        first, _, rest = text.partition("\n")
        print(f"{entry.shown}: {paint(first, style)}" + (f"\n{rest}" if rest else ""))
        if ok is False:
            rc = max(rc, EXIT_PENDING)
    return rc


def describe_cached(item):
    _, size, used, names = item
    what = names[0] + (f" (+{len(names) - 1} more)" if len(names) > 1 else "") if names else \
        paint("(no details: downloaded before 0.12)", "dim")
    return f"{human_size(size):>10}  {time.strftime('%Y-%m-%d', time.localtime(used))}  {what}"


def cmd_cache(args):
    """Show, list and clean up the download cache (shared by all
    repositories of this user)."""
    root = cache_root()
    action = args.action
    if action == "dir":
        print(root)
        return EXIT_OK
    if action == "list":
        files = cache_files()
        for item in files:
            print(describe_cached(item))
        if not files:
            print(f"the download cache is empty ({root})")
        return EXIT_OK
    if action in ("prune", "clear"):
        if action == "clear":
            removed = prune_cache(None, 0, args.dry_run, grace=False)
        else:
            max_age, max_size = cache_limits()
            if args.older_than is not None:
                max_age = args.older_than
            if args.max_size is not None:
                max_size = parse_size(args.max_size)
            if max_age is None and max_size is None:
                print("no limits set (assetsync.cacheMaxAge, assetsync.cacheMaxSize) - "
                      "nothing to do")
                return EXIT_OK
            removed = prune_cache(max_age, max_size, args.dry_run)
        verb = "would remove" if args.dry_run else "removed"
        for item in removed:
            print(f"{verb} {describe_cached(item).lstrip()}")
        size = sum(s for _, s, _, _ in removed)
        # kept only because they were just used (prune never removes those)
        recent = action == "prune" and \
            any(time.time() - used < CACHE_GRACE for _, _, used, _ in cache_files())
        print(f"{verb} {plural(len(removed), 'file')} ({human_size(size)}) from the download "
              f"cache" + (" - files used in the last minutes are kept" if recent else ""))
        return EXIT_OK
    files = cache_files()
    max_age, max_size = cache_limits()
    print(f"{root}: {plural(len(files), 'file')}, {human_size(sum(s for _, s, _, _ in files))}")
    limits = ([f"files unused for {max_age} days" if max_age is not None else ""] +
              [f"the least recently used above {human_size(max_size)}"
               if max_size is not None else ""])
    limits = [x for x in limits if x]
    print("cleaned up automatically: " + (" and ".join(limits) if limits else "never")
          + " (assetsync.cacheMaxAge, assetsync.cacheMaxSize)")
    return EXIT_OK


def cmd_releases(ctx, repo, args):
    """List releases newest first, marked: latest (as the platform says),
    prerelease, draft, and which sources of this repository select them -
    a help for add and set."""
    reg = Registry(repo) if repo else None
    if reg and args.source in reg.sources:
        url, kind = reg.sources[args.source].get("url", ""), reg.sources[args.source].get("type")
    else:
        url, kind = source_url(args.source), args.type
    origin = platform_of(url, kind)
    rels = sorted(origin.releases(None if args.all else args.max_count),
                  key=lambda r: r.date, reverse=True)
    if not args.all:
        rels = rels[:args.max_count]
    if isinstance(origin, LocalFolder):
        print(paint(f"releases in the local folder {origin.dir} (git assetsync source map)", "cyan"))
    if not rels:
        print(f"no releases in {origin.where}")
        return EXIT_OK
    latest = origin.latest()
    selected = {}
    for name, s in sorted(reg.sources.items()) if reg else []:
        if norm_url(s.get("url", "")) == norm_url(url):
            try:
                selected.setdefault(ctx.release(url, source_spec(s))[1].tag, []).append(name)
            except FsError as e:
                warn(f"{name}: {e}")
    width = max(len(r.tag) for r in rels)
    for r in rels:
        flags = (["latest"] if latest and r.tag == latest.tag else []) + \
            ([("upcoming" if isinstance(origin, GitLab) else "prerelease")] if r.prerelease
             else []) + (["draft"] if r.draft else []) + \
            ([f"selected by {and_list(selected[r.tag])}"] if r.tag in selected else [])
        title = r.title if r.title and r.title != r.tag else ""
        line = f"{paint(f'{r.tag:<{width}}', 'yellow')}  {r.date[:10] or '-':<10}  {title}"
        print(line.rstrip() + (f"  {paint('(' + ', '.join(flags) + ')', 'cyan')}"
                               if flags else ""))
        if args.assets:
            aw = max([len(a.name) for a in r.assets] or [0])
            for a in r.assets:
                print(f"    {a.name:<{aw}}  {human_size(a.size)}".rstrip())
            if not r.assets:
                print("    (no assets)")
    return EXIT_OK


def and_list(items):
    items = list(items)
    return ", ".join(items[:-1]) + " and " + items[-1] if len(items) > 1 else "".join(items)


def restore_items(repo, entry):
    """base_items() as they are stored now (.gitattributes may have changed
    since the sync: LFS, line endings)."""
    try:
        return [(m, repo.as_local(repo.read_content(o, path), path), path)
                for m, o, path in base_items(repo, entry)]
    except FsError as e:
        raise FsError(f"its synced version is not available ({e}) - get it again with "
                      f"'git assetsync pull --overwrite {path_arg(repo, entry.shown)}'")


def restore_worktree(repo, entry, items):
    """Write the files of items (and in a directory: delete the others git
    sees there; ignored ones stay)."""
    if entry.is_dir:
        keep = {path for _, _, path in items}
        for path in repo.dir_files(entry.rel):
            if path not in keep:
                (repo.top / path).unlink()
        dirs = entry.target.rglob("*") if entry.target.is_dir() else []
        for d in sorted((d for d in dirs if d.is_dir()), reverse=True):
            try:
                d.rmdir()               # only empty ones
            except OSError:
                pass
    for mode, oid, path in items:
        target = repo.top / path
        if target.is_dir():
            raise FsError(f"'{path}' is a directory in the working tree")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(repo.checkout_form(oid, path))
        set_executable(target, mode == "100755")


def restore_index(repo, entry, items):
    if entry.is_dir:
        repo.git(["rm", "-r", "-q", "--cached", "--ignore-unmatch", "--", lit(entry.rel)])
    data = "".join(f"{m} {o}\t{path}\0" for m, o, path in items)
    repo.git(["update-index", "-z", "--add", "--index-info"], data=data.encode("utf-8"))


def restore_one(repo, entry, staged, worktree):
    """Restore what the entry was synced with: in the working tree and/or
    the index. Returns what was done, or None if nothing differed."""
    items = restore_items(repo, entry)
    if entry.is_dir:
        base = repo.make_tree([(m, o, path[len(entry.rel) + 1:]) for m, o, path in items])
        p = repo.git(["write-tree", f"--prefix={entry.rel}/"], check=False)
        in_index = out(p) if p.returncode == 0 else None
        in_worktree = repo.worktree_tree(entry.rel)
    else:
        (mode, base, _), = items
        in_index = out(repo.git(["ls-files", "-s", "--", lit(entry.rel)])).split(" ")[1:2]
        in_index = in_index[0] if in_index else None
        in_worktree = repo.worktree_blob(entry.target)
    done = []
    if staged and in_index != base:
        restore_index(repo, entry, items)
        done.append("index")
    if worktree and in_worktree != base:
        restore_worktree(repo, entry, items)
        done.append("worktree")
    return done


def cmd_restore(ctx, repo, args):
    """Like `git restore`, but from what the entries were synced with (their
    base): the working tree by default, the index with --staged, both with
    -S -W. Offline; .git-assetsync doesn't change."""
    reg = Registry(repo)
    worktree = args.worktree or not args.staged
    rc = EXIT_OK
    for entry in select_entries(repo, reg, args.paths):
        try:
            problem = path_problem(entry.rel)
            if problem:
                raise FsError(problem)
            if not entry.blob:
                raise FsError(f"not synced yet - use 'git assetsync pull "
                              f"{path_arg(repo, entry.shown)}'")
            done = restore_one(repo, entry, args.staged, worktree)
        except FsError as e:
            error(f"{entry.shown}: {e}")
            rc = EXIT_ERROR
            continue
        what = {("index",): "restored in the index", ("worktree",): "restored",
                ("index", "worktree"): "restored and staged"}.get(tuple(done))
        if what:
            print(f"{entry.shown}: {paint(what, 'green')} ({entry.name} {entry.synced})")
        else:
            print(f"{entry.shown}: nothing to restore")
    return rc


def cmd_unlink(ctx, repo, args):
    reg = Registry(repo)
    for entry in select_entries(repo, reg, args.paths):
        if args.dry_run:
            print(f"would unlink {entry.shown}")
            continue
        what, shown_rel = ("files" if entry.is_dir else "file"), entry.shown
        reg.remove_file(entry.rel)
        print(f"{paint('unlinked', 'green')} {shown_rel} ({what} kept)")
    if not args.dry_run:
        reg.finish()
    return EXIT_OK


def cmd_rm(ctx, repo, args):
    """Like `git rm`: remove entries and their files, staged. Refused for
    all if one has uncommitted changes (in a directory: also untracked
    files), unless -f; committed modifications don't count."""
    reg = Registry(repo)
    entries = select_entries(repo, reg, args.paths)
    for entry in entries:
        problem = path_problem(entry.rel)
        if problem:
            raise FsError(f"{entry.shown}: {problem} - remove its entry with 'git assetsync "
                          f"unlink {shlex.quote(entry.rel)}'")
        changes = repo.git(["status", "--porcelain", "-z", "--untracked-files=all", "--",
                            lit(entry.rel)]).stdout.strip(b"\0")
        if changes and not args.force:
            raise FsError(f"{entry.shown}: has uncommitted changes - use -f to remove it anyway")
    for entry in entries:
        if args.dry_run:
            print(f"would remove {entry.shown}")
            continue
        repo.git(["rm", "-r", "-q", "-f", "--ignore-unmatch", "--", lit(entry.rel)])
        if entry.is_dir and entry.target.is_dir():      # untracked files (not ignored ones)
            for path in repo.dir_files(entry.rel):
                (repo.top / path).unlink()
            for d in sorted((d for d in entry.target.rglob("*") if d.is_dir()), reverse=True):
                try:
                    d.rmdir()               # only empty ones
                except OSError:
                    pass
            try:
                entry.target.rmdir()
            except OSError:
                pass
        shown_rel = entry.shown
        reg.remove_file(entry.rel)
        print(f"{paint('removed', 'green')} {shown_rel}")
    if not args.dry_run:
        reg.finish()
    return EXIT_OK


def cmd_mv(ctx, repo, args):
    reg = Registry(repo)
    old = repo.rel(repo.user_path(args.src))
    if old not in reg.files:
        raise FsError(f"'{old}' is not synced")
    dst = repo.user_path(args.dst)
    if dst.is_dir():
        dst = dst / Path(old).name
    new = repo.rel(dst)
    problem = path_problem(new)
    if problem:
        raise FsError(f"cannot move to '{new}': {problem}")
    if new in reg.files or dst.exists():
        raise FsError(f"'{new}' already exists")
    others = reg.overlapping(new, exclude=old)
    if others:
        raise FsError(f"cannot move to '{new}': overlaps with the entry for {', '.join(others)}")
    if args.dry_run:
        print(f"would move {old} -> {new}")
        return EXIT_OK
    if repo.git(["ls-files", "--error-unmatch", "--", lit(old)], check=False).returncode == 0:
        dst.parent.mkdir(parents=True, exist_ok=True)
        repo.git(["mv", "--", old, new])      # takes paths literally
    elif (repo.top / old).exists():
        dst.parent.mkdir(parents=True, exist_ok=True)
        (repo.top / old).rename(dst)
    reg.rename_file(old, new)
    reg.finish()
    print(f"{paint('moved', 'green')} {old} -> {new} (entry kept)")
    return EXIT_OK


def source_text(s, name, reg):
    """'URL (selection, N files)' for source -v."""
    return (f"{s.get('url', '')} ({spec_text(source_spec(s))}"
            + (f", type {s['type']}" if s.get("type") else "")
            + f", {plural(len(reg.source_files(name)), 'file')})")


def cmd_source(ctx, repo, args):
    """Like `git remote`: list, rename and change the [source]s. Only
    .git-assetsync is changed (and staged); `pull` then updates the files
    and commits the change with them."""
    reg = Registry(repo)
    action = args.action
    if not action:
        for name, s in sorted(reg.sources.items()):
            if not args.verbose:
                print(name)
                continue
            now = ""
            if ctx.fetch and s.get("url"):
                try:
                    now = f" - now {ctx.release(s['url'], source_spec(s))[1].tag}"
                except FsError as e:
                    warn(f"{name}: {e}")
            print(f"{name}\t{source_text(s, name, reg)}{now}")
        return EXIT_OK
    if args.name not in reg.sources:
        raise FsError(f"no source '{args.name}' in {REGISTRY}"
                      + (f" (known: {', '.join(sorted(reg.sources))})" if reg.sources else ""))
    s = reg.sources[args.name]
    old = source_spec(s)
    if action == "rename":
        new = args.value
        if not new or "\n" in new:
            raise FsError("invalid source name")
        if new in reg.sources:
            raise FsError(f"source '{new}' already exists")
        reg.rename_source(args.name, new)
        done = f"renamed {args.name} -> {new}"
    else:
        url, spec = s.get("url", ""), dict(old)
        if action == "set-url":
            url = source_url(args.value)
        elif action == "set-release":
            if args.unset and args.value or not (args.unset or args.value or
                                                 args.prerelease is not None):
                raise FsError("give either TAG|PATTERN or --unset (or only --prerelease / "
                              "--no-prerelease)")
            if args.value:
                spec["release"] = args.value
            elif args.unset:
                spec.pop("release", None)
            if args.prerelease is not None:
                if args.prerelease:
                    spec["prerelease"] = "true"
                else:
                    spec.pop("prerelease", None)
        else:   # set-type
            if bool(args.unset) == bool(args.value):
                raise FsError("give either github|gitlab or --unset")
            if args.value and args.value not in PLATFORMS:
                raise FsError(f"unknown type '{args.value}' (supported: "
                              f"{', '.join(sorted(PLATFORMS))})")
            if args.value:
                spec["type"] = args.value
            else:
                spec.pop("type", None)
        other = next((n for n, o in reg.sources.items() if n != args.name
                      and norm_url(o.get("url", "")) == norm_url(url) and source_spec(o) == spec),
                     None)
        if other:
            raise FsError(f"source '{other}' already has this URL and selection - move the files "
                          f"to it with 'git assetsync set <file>... --source {other}'")
        if action == "set-url":
            reg.set_source(args.name, "url", url)
            done = f"{args.name}: url {url}"
        else:
            for key in SPEC_KEYS:
                reg.set_source(args.name, key, spec.get(key))
            done = f"{args.name}: {spec_text(spec)}" + \
                (f", type {spec['type']}" if spec.get("type") else "") + \
                (f" (was: {spec_text(old)})" if action == "set-release" and old != spec else "")
    reg.finish()
    print(f"{paint(done, 'green')}; {REGISTRY} staged")
    files = reg.source_files(args.value if action == "rename" else args.name)
    if action != "rename" and files:
        print(f'  (use "git assetsync status" to see what changes for its '
              f'{plural(len(files), "file")}, "git assetsync pull <file>..." to update them)')
    return EXIT_OK


def cmd_filter(ctx, repo, args):
    """List, show and change the named filters [filter "NAME"]. Only
    .git-assetsync is changed (and staged); entries using a changed filter
    then show as pending, and pull applies it."""
    reg = Registry(repo)
    action = args.action
    if not action:
        for name, steps in sorted(reg.filters.items()):
            users = reg.filter_users(name)
            print(f"{name}\t({plural(len(steps), 'step')}; "
                  + (f"used by {and_list(users)}" if users else "not used") + ")")
        if not reg.filters:
            print(f"no filters in {REGISTRY}")
        return EXIT_OK
    if action == "add" and args.name in reg.filters:
        raise FsError(f"filter '{args.name}' already exists (change it with 'git assetsync "
                      f"filter set {args.name} ...')")
    if action != "add" and args.name not in reg.filters:
        raise FsError(f"no filter '{args.name}' in {REGISTRY}"
                      + (f" (known: {', '.join(sorted(reg.filters))})" if reg.filters else ""))
    users = reg.filter_users(args.name) if args.name in reg.filters else []
    if action == "test":
        return filter_test(ctx, repo, reg, args)
    if action == "show":
        for step in reg.filters[args.name]:
            print(step)
        print(f"({'used by ' + and_list(users) if users else 'not used'})")
        return EXIT_OK
    if action in ("add", "set"):
        if not re.fullmatch(r"[\w.+-]+", args.name):
            raise FsError(f"invalid filter name '{args.name}' (letters, digits, '.', '+', '-', "
                          "'_')")
        steps = filter_steps(args)
        if not steps:
            raise FsError("give the steps of the filter (--extract, --include, --move, ...)")
        expand_steps(steps, dict(reg.filters, **{args.name: steps}), (args.name,))
        reg.set_filter(args.name, steps)
        done = f"filter {args.name}: {', '.join(steps)}" + (" (new)" if action == "add" else "")
    elif action == "rename":
        if not re.fullmatch(r"[\w.+-]+", args.value):
            raise FsError(f"invalid filter name '{args.value}'")
        if args.value in reg.filters:
            raise FsError(f"filter '{args.value}' already exists")
        reg.rename_filter(args.name, args.value)
        done = f"renamed filter {args.name} -> {args.value}"
    else:   # remove
        if users:
            raise FsError(f"filter '{args.name}' is used by {and_list(users)}")
        reg.remove_filter(args.name)
        done = f"removed filter {args.name}"
    reg.finish()
    print(f"{paint(done, 'green')}; {REGISTRY} staged")
    if action == "set" and users:
        print(f'  (used by {and_list(users)}: use "git assetsync status" to see what '
              'changes, "git assetsync pull <file>..." to update)')
    return EXIT_OK


def filter_test(ctx, repo, reg, args):
    """Apply a filter to local files (as if they were the assets) or to the
    assets of a release, and list the result or write it to a directory -
    without changing anything in the repository."""
    if bool(args.files) == bool(args.source):
        raise FsError("give the input: FILE... (local files, as if they were the assets) "
                      "or --source SOURCE (the assets of its release)")
    out_dir = repo.user_path(args.output) if args.output else None
    if out_dir and (out_dir.is_file() or out_dir.is_dir() and any(out_dir.iterdir())):
        raise FsError(f"'{args.output}' is not an empty directory")
    what = f"filter {args.name}"
    trusted = ensure_trusted(repo, [shlex.join(["apply", "*", args.name])], reg.filters)
    with Work(what, repo.top, {}, trusted) as work:
        files = {}
        if args.source:
            url, spec, _ = add_source(reg, args)
            origin, release = ctx.release(url, spec)
            assets = select_assets(release, args.asset, origin.label, True)
            for a in assets:
                add_member(files, safe_path(a.name, f"{what}: asset"),
                           (get_asset(origin, release, a)[0], False), what)
            print(paint(f"input: {origin.label} {release.tag}: "
                        f"{', '.join(a.name for a in assets)}", "dim", "err"), file=sys.stderr)
        for name in args.files or []:
            path = repo.user_path(name)
            if path.is_dir():
                for p in sorted(path.rglob("*")):
                    if p.is_file():
                        rel = safe_path(p.relative_to(path).as_posix(), what)
                        add_member(files, rel, (p, os.name != "nt" and
                                                bool(p.stat().st_mode & 0o111)), what)
            elif path.is_file():
                add_member(files, safe_path(path.name, what), (path, False), what)
            else:
                raise FsError(f"'{name}' not found")
        steps = reg.filters[args.name]
        width = max(len(s) for s in steps) if steps else 0

        def report(step, text):
            print(paint(f"{step:<{min(width, 40)}}  {text}", "dim", "err"), file=sys.stderr)
        result = checked_result(run_steps(files, steps, work, reg.filters, (args.name,),
                                          report), what)
        if out_dir:
            for rel, (src, executable) in sorted(result.items()):
                dest = out_dir / rel
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(src, dest)
                set_executable(dest, executable)
            print(f"{paint(plural(len(result), 'file'), 'green')} written to {args.output}")
            return EXIT_OK
        width = max(len(human_size(src.stat().st_size)) for src, _ in result.values())
        for rel, (src, executable) in sorted(result.items()):
            print(f"{human_size(src.stat().st_size):>{width}}  {rel}"
                  + ("  (executable)" if executable else ""))
    return EXIT_OK


def cmd_trust(ctx, repo, args):
    """Filters run commands only if trusted - in this repository's own
    config, never committed: whoever can change .git-assetsync could
    otherwise run commands on every machine that pulls. A trust is for a
    filter as it is: changing it, or a script it runs, needs a new one."""
    reg = Registry(repo)
    commands = [n for n in sorted(reg.filters) if runs_commands(reg.filters[n])]
    for name in args.names:
        if name not in reg.filters:
            raise FsError(f"no filter '{name}' in {REGISTRY}")
    if args.revoke:
        if not args.names:
            raise FsError("give the filters to no longer trust")
        for name in args.names:
            set_trust(repo, name, reg.filters, trust=False)
            print(f"filter {name}: {paint('no longer trusted', 'yellow')}")
        return EXIT_OK
    names = args.names or (commands if args.all else [])
    for name in names:
        if not runs_commands(reg.filters[name]):
            print(f"filter {name} runs no commands - nothing to trust")
            continue
        set_trust(repo, name, reg.filters)
        print(f"filter {name}: {paint('trusted', 'green')}")
    if names or args.all:
        return EXIT_OK
    if not commands:
        print("no filter runs commands")
        return EXIT_OK
    names_trusted = {v.partition(" ")[2] for v in trusted_values(repo)}
    missing = []
    for name in commands:
        if is_trusted(repo, name, reg.filters):
            state = paint("trusted", "green")
        else:
            missing.append(name)
            state = paint("changed since trusted" if name in names_trusted else "not trusted",
                          "yellow")
        users = reg.filter_users(name)
        print(f"filter {name}: {state}" + (f" (used by {and_list(users)})" if users else ""))
        show_commands(name, reg.filters, repo)
    if missing and sys.stdin.isatty() and sys.stdout.isatty():
        for name in missing:
            if ask(f"Trust filter {name}? [y/N] "):
                set_trust(repo, name, reg.filters)
                print(f"filter {name}: {paint('trusted', 'green')}")
    elif missing:
        print(f'  (use "git assetsync trust <name>..." or "git assetsync trust --all" to trust '
              'them in this repository)')
    return EXIT_OK


def hook_dir(repo, action):
    hp = out(repo.git(["config", "core.hooksPath"], check=False))
    if hp:
        hookdir = Path(os.path.expanduser(hp))
        if not hookdir.is_absolute():
            hookdir = repo.top / hookdir
        warn(f"core.hooksPath is set; {action} {hookdir} "
             "(may affect other repositories using it)")
    else:
        hookdir = Path(out(repo.git(["rev-parse", "--git-path", "hooks"])))
        if not hookdir.is_absolute():
            hookdir = repo.top / hookdir
    return hookdir


def hook_snippet(cmd):
    return (f"# {HOOK_MARKER}: reminders about synced files; blocks a push only if "
            "git-assetsync refuses it\n"
            f"{cmd}\n")


def is_our_hook_line(line):
    s = line.strip()
    return s.startswith((f"# {HOOK_MARKER}:", "git assetsync hook ",
                         "git assetsync status --hook")) or \
        bool(re.search(r"\b(git_)?assetsync_(refs|EOF)", s))   # status --hook: before 0.10


def only_ours(lines):
    """A hook file with nothing but our lines (and what we wrote around them)."""
    return all(is_our_hook_line(ln) or ln.strip() in ("", "#!/bin/sh", "exit 0")
               for ln in lines)


def cmd_install_hooks(repo, args):
    hookdir = hook_dir(repo, "installing into")
    hookdir.mkdir(parents=True, exist_ok=True)
    for name, cmd in HOOKS.items():
        f = hookdir / name
        snippet = hook_snippet(cmd)
        # no 'exit 0' at the end: lines others add (e.g. git lfs) are appended
        fresh = "#!/bin/sh\n" + snippet
        if f.exists():
            text = f.read_bytes().decode("utf-8", "replace")
            lines = text.splitlines(keepends=True)
            at = next((i for i, ln in enumerate(lines) if is_our_hook_line(ln)), None)
            if at is None and args.force:
                # right after the shebang: before commands that read the pushed
                # refs from stdin (git lfs pre-push), or an exec/exit at the end
                at = 1 if lines and lines[0].startswith("#!") else 0
                f.write_bytes("".join(lines[:at] + [snippet] + lines[at:]).encode("utf-8"))
                print(f"{name}: {paint('lines added to the existing hook', 'green')}")
                continue
            if at is None:
                where = (" (first: commands after them that read the pushed refs, like git lfs "
                         "pre-push, still get them)" if name == "pre-push" else "")
                print(f"{name}: {paint('hook exists', 'yellow')}, add these lines to "
                      f"{f}{where}:\n{snippet}"
                      "(or run 'git assetsync install-hooks --force' to add them)")
                continue
            # ours: replace our lines with the current ones, in the same place
            rest = [ln for ln in lines if not is_our_hook_line(ln)]
            new = fresh if only_ours(lines) else "".join(rest[:at] + [snippet] + rest[at:])
            if new == text:
                print(f"{name}: already installed")
            else:
                f.write_bytes(new.encode("utf-8"))
                print(f"{name}: {paint('updated', 'green')}")
            continue
        f.write_bytes(fresh.encode())
        f.chmod(0o755)
        print(f"{name}: {paint('installed', 'green')}")
    return EXIT_OK


def cmd_uninstall_hooks(repo, args):
    """Remove our hooks. A hook file that only contains our snippet is deleted;
    in other hook files only our lines are removed, the rest stays untouched."""
    hookdir = hook_dir(repo, "removing from")
    for name in HOOKS:
        f = hookdir / name
        if not f.is_file():
            print(f"{name}: {paint('not installed', 'dim')}")
            continue
        lines = f.read_bytes().decode("utf-8", "replace").splitlines(keepends=True)
        rest = [ln for ln in lines if not is_our_hook_line(ln)]
        if len(rest) == len(lines):
            print(f"{name}: {paint('not installed', 'dim')} (existing hook left unchanged)")
            continue
        if only_ours(lines):
            f.unlink()
            print(f"{name}: {paint('removed', 'green')}")
        else:
            f.write_bytes("".join(rest).encode("utf-8"))
            print(f"{name}: {paint('git-assetsync lines removed', 'green')}, rest of hook kept")
    return EXIT_OK


# --------------------------------------------------------------------------

BASIC_COMMANDS = ("status", "pull", "diff", "difftool", "restore", "add", "rm", "unlink", "mv")


def command_list(sub):
    """--help: the commands with their summaries, basic ones first (the
    rest in the order they were defined, `hook` last). As in git-filesync."""
    width = max(shutil.get_terminal_size().columns - 2, 40)
    helps = {a.dest: a.help for a in sub._choices_actions}

    def group(title, names):
        lines = [f"{title}:"]
        for n in names:
            lines += textwrap.wrap(helps[n], width, initial_indent=f"  {n:<18}",
                                   subsequent_indent=" " * 20)
        return "\n".join(lines)
    advanced = [n for n in helps if n not in BASIC_COMMANDS]
    return group("basic commands", BASIC_COMMANDS) + "\n\n" + group("advanced commands", advanced)


def describe_commands(parser):
    """Let each command's -h start with its line from the command list (as
    a sentence), also for the actions of source, filter and cache."""
    for action in parser._actions:
        if isinstance(action, argparse._SubParsersAction):
            for choice in action._choices_actions:
                p = action.choices[choice.dest]
                if p.description is None and choice.help:
                    p.description = choice.help[0].upper() + choice.help[1:] + "."
                describe_commands(p)


def main(argv=None):
    for stream in (sys.stdout, sys.stderr):
        # LF line ends like git's output, also on Windows (no CRLF translation);
        # not for streams replaced by something else (no reconfigure)
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure:
            reconfigure(errors="replace", newline="\n")

    colorp = argparse.ArgumentParser(add_help=False)
    colorp.add_argument("--color", nargs="?", const="always", default="auto",
                        choices=["always", "never", "auto"], help="colored output (default: auto)")
    colorp.add_argument("--no-color", dest="color", action="store_const", const="never",
                        help="same as --color=never")

    remotep = argparse.ArgumentParser(add_help=False)
    remotep.add_argument("--remote", action="store_true",
                         help="ignore mappings to local folders (see source map): ask the platform")

    ap = argparse.ArgumentParser(prog="git assetsync",
                                 description="Keep files in sync with release assets of "
                                             "other projects.",
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--version", action="version", version=f"git-assetsync {__version__}")
    sub = ap.add_subparsers(dest="cmd", metavar="<command>")

    p = sub.add_parser("status", parents=[colorp, remotep], help="show the state of the synced files")
    p.add_argument("paths", nargs="*", help="files or directories (default: all)")
    p.add_argument("-s", "--short", action="store_true",
                   help="short format: upstream / committed / working tree columns")
    p.add_argument("-v", "--verbose", action="store_true",
                   help="also list all files with their sources")
    p.add_argument("--exit-code", action="store_true",
                   help="exit with 1 if something is to pull or a file is modified")
    p.add_argument("--no-fetch", action="store_true",
                   help="don't ask the platform for new releases")

    p = sub.add_parser("pull", parents=[colorp, remotep], help="update files to the selected release")
    p.add_argument("paths", nargs="*", metavar="PATH", help="files or directories")
    p.add_argument("--all", action="store_true", help="all files with something to pull")
    p.add_argument("--release", metavar="TAG|PATTERN",
                   help="this release instead of the one the source selects (a pattern: the "
                        "newest matching), once - the selection stays as it is")
    p.add_argument("--overwrite", action="store_true", help="discard local modifications")
    p.add_argument("--no-edit", action="store_true", help="commit without opening the editor")
    p.add_argument("-v", "--verbose", action="store_true",
                   help="first name where each entry comes from (as status -v)")
    p.add_argument("--no-commit", action="store_true",
                   help="only stage; a plain 'git commit' offers the proposed message")
    p.add_argument("-n", "--dry-run", action="store_true",
                   help="only report what would happen")

    for name, hlp in (("diff", "show local modifications against what the release gave"),
                      ("difftool", "same in the configured difftool")):
        p = sub.add_parser(name, parents=[colorp, remotep], help=hlp,
                           epilog="Options after '--' are passed to git " + name + ".")
        p.add_argument("paths", nargs="*", metavar="PATH",
                       help="files or directories (default: all)")
        g = p.add_mutually_exclusive_group()
        g.add_argument("--upstream", action="store_true",
                       help="what 'pull' would bring instead (synced -> selected release)")
        g.add_argument("--committed", action="store_true",
                       help="only the committed modifications (synced -> HEAD)")
        p.add_argument("--release", metavar="TAG|PATTERN",
                       help="with --upstream: what 'pull --release' would bring")
        if name == "difftool":
            p.add_argument("-d", "--dir-diff", action="store_true",
                           help="compare all files at once, as two directories")
            p.add_argument("-y", "--no-prompt", action="store_true",
                           help="don't ask before launching the tool for each file")
            p.add_argument("--prompt", action="store_true",
                           help="ask before each file even if paths are given")

    filterp = argparse.ArgumentParser(add_help=False)
    g = filterp.add_argument_group("filter steps (applied in the order given)")
    g.add_argument("--extract", action=StepOption, nargs="*", metavar="PATTERN",
                   help="unpack the matching files (default: all), which must be archives "
                        "(zip, tar, tar.gz/bz2/xz; .gz/.bz2/.xz files; 7z with 7-Zip)")
    g.add_argument("--subdir", action=StepOption, metavar="PATH",
                   help="only the files below PATH, as the root")
    g.add_argument("--strip", action=StepOption, type=int, metavar="N",
                   help="remove N leading directories from the paths")
    g.add_argument("--include", action=StepOption, metavar="PATTERN",
                   help="only files matching (gitignore-like; consecutive ones make one step: "
                        "files matching any of them)")
    g.add_argument("--exclude", action=StepOption, metavar="PATTERN",
                   help="not the files matching")
    g.add_argument("--move", action=StepOption, nargs=2, metavar=("PATTERN", "TARGET"),
                   help="move the matching files: into TARGET/ (with a trailing '/'), or "
                        "to TARGET with {path} {dir} {parent} {name} {stem} {ext}")
    g.add_argument("--copy", action=StepOption, nargs=2, metavar=("PATTERN", "TARGET"),
                   help="the same, keeping the files where they are")
    g.add_argument("--apply", action=StepOption, nargs=2, metavar=("PATTERN", "NAME"),
                   help="apply the filter NAME to the matching files")
    g.add_argument("--convert", action=StepOption, nargs=3,
                   metavar=("PATTERN", "TARGET", "COMMAND"),
                   help="convert each matching file with COMMAND (run by sh): {in} the file, "
                        "{out} the result, which replaces it at TARGET (placeholders as for "
                        "--move; TARGET/: {out} is a directory); {root}: the repository")
    g.add_argument("--run", action=StepOption, metavar="COMMAND",
                   help="run COMMAND on all files: {in} a directory with them, {out} an empty "
                        "directory for the result, which replaces them")

    p = sub.add_parser("restore", parents=[colorp],
                       help="restore what the release gave (the synced version), without pulling")
    p.add_argument("paths", nargs="+", metavar="PATH", help="files or directories")
    p.add_argument("-S", "--staged", action="store_true",
                   help="restore the index instead of the working tree")
    p.add_argument("-W", "--worktree", action="store_true",
                   help="restore the working tree (the default; with -S: both)")

    p = sub.add_parser("add", parents=[colorp, remotep],
                       help="take a file or directory from release assets")
    p.add_argument("--filter", metavar="NAME",
                   help="the named filter (see 'filter add') to apply to the assets")
    p.add_argument("path", metavar="PATH",
                   help="file in this repository; with a trailing '/' or an existing "
                        "directory: a directory that belongs to the entry")
    p.add_argument("source", metavar="SOURCE",
                   help=f"name of a [source] in {REGISTRY}, or URL (owner/repo: github.com)")
    p.add_argument("--asset", metavar="PATTERN",
                   help="asset of the release (glob pattern; a file: must match exactly one, "
                        "default the release's only asset; a directory: all matching, "
                        "default all)")
    p.add_argument("--release", metavar="TAG|PATTERN",
                   help="release to take: an exact tag (pinned) or the newest matching "
                        "(default: the latest release)")
    p.add_argument("--prerelease", action="store_true", help="prereleases count too")
    p.add_argument("--type", choices=sorted(PLATFORMS),
                   help="platform of the URL's host (default: derived from it)")
    p.add_argument("--force", action="store_true",
                   help="replace an existing entry; take more than 10 assets or 100 MiB")
    p.add_argument("--overwrite", action="store_true",
                   help="replace an existing file (directory content) with what the release "
                        "gives")
    p.add_argument("-n", "--dry-run", action="store_true", help="only show what would be done")

    p = sub.add_parser("set", parents=[colorp, remotep],
                       help="change entries: source, release selection, asset or filter")
    p.add_argument("paths", nargs="+", metavar="PATH", help="files or directories")
    p.add_argument("--source", metavar="URL|SOURCE",
                   help="take the files from another source (URL or name, as for add)")
    p.add_argument("--release", metavar="TAG|PATTERN",
                   help="release to take: a tag pins, a pattern takes the newest matching")
    p.add_argument("--latest", action="store_true", help="follow the latest release")
    g = p.add_mutually_exclusive_group()
    g.add_argument("--prerelease", dest="prerelease", action="store_true", default=None,
                   help="prereleases count too")
    g.add_argument("--no-prerelease", dest="prerelease", action="store_false",
                   help="prereleases don't count")
    p.add_argument("--type", choices=sorted(PLATFORMS), help="platform of the source's host")
    g = p.add_mutually_exclusive_group()
    g.add_argument("--asset", metavar="PATTERN", help="another asset (glob, exactly one match)")
    g.add_argument("--no-asset", action="store_true",
                   help="no pattern: the release's only asset (a directory: all)")
    g = p.add_mutually_exclusive_group()
    g.add_argument("--filter", metavar="NAME", help="use the named filter NAME")
    g.add_argument("--no-filter", action="store_true", help="use no filter")
    p.add_argument("-n", "--dry-run", action="store_true", help="only show what would change")

    sub.add_parser("edit", parents=[colorp],
                   help=f"open {REGISTRY} in the editor, then check and stage it")

    p = sub.add_parser("verify", parents=[colorp, remotep],
                       help="filter the synced assets again and compare with what is committed")
    p.add_argument("paths", nargs="*", metavar="PATH", help="files or directories (default: all)")
    p.add_argument("-v", "--verbose", action="store_true",
                   help="first name where each entry comes from (as status -v)")

    p = sub.add_parser("releases", parents=[colorp, remotep],
                       help="list the releases of a source (and their assets)")
    p.add_argument("source", metavar="SOURCE|URL",
                   help=f"name of a [source] in {REGISTRY}, or URL (owner/repo: github.com)")
    p.add_argument("--assets", action="store_true", help="also list the assets")
    g = p.add_mutually_exclusive_group()
    g.add_argument("-n", "--max-count", type=int, default=10, metavar="N",
                   help="the newest N releases (default: 10)")
    g.add_argument("--all", action="store_true", help="all releases")
    p.add_argument("--type", choices=sorted(PLATFORMS),
                   help="platform of the URL's host (default: derived from it)")

    p = sub.add_parser("rm", parents=[colorp],
                       help="remove entries and their files (like 'git rm'; staged)")
    p.add_argument("paths", nargs="+", metavar="PATH", help="files or directories")
    p.add_argument("-f", "--force", action="store_true",
                   help="also with uncommitted changes (they are lost)")
    p.add_argument("-n", "--dry-run", action="store_true", help="only show what would be done")

    p = sub.add_parser("unlink", parents=[colorp], help="remove entries (the files are kept)")
    p.add_argument("paths", nargs="+", metavar="PATH", help="files or directories")
    p.add_argument("-n", "--dry-run", action="store_true", help="only show what would be done")

    p = sub.add_parser("mv", parents=[colorp], help="move a file, keeping its entry")
    p.add_argument("src", metavar="OLD", help="synced file")
    p.add_argument("dst", metavar="NEW", help="new path or existing directory")
    p.add_argument("-n", "--dry-run", action="store_true", help="only show what would be done")

    p = sub.add_parser("source", parents=[colorp, remotep],
                       help="list or change the [source]s (like 'git remote')")
    p.add_argument("-v", "--verbose", action="store_true",
                   help="list with URL, release selection, the release it selects now and "
                        "file count")
    p.add_argument("--no-fetch", action="store_true",
                   help="with -v: don't ask the platform which release is selected now")
    actions = p.add_subparsers(dest="action", metavar="ACTION")
    a = actions.add_parser("rename", parents=[colorp],
                           help="rename a source and all references to it")
    a.add_argument("name", metavar="OLD", help="key of the [source]")
    a.add_argument("value", metavar="NEW")
    a = actions.add_parser("set-url", parents=[colorp], help="change the URL of a source")
    a.add_argument("name", metavar="NAME", help="key of the [source]")
    a.add_argument("value", metavar="URL")
    a = actions.add_parser("set-release", parents=[colorp],
                           help="select another release: a tag pins the source to it, a "
                                "pattern takes the newest matching; --unset: the latest")
    a.add_argument("name", metavar="NAME", help="key of the [source]")
    a.add_argument("value", metavar="TAG|PATTERN", nargs="?")
    a.add_argument("--unset", action="store_true", help="follow the latest release again")
    g = a.add_mutually_exclusive_group()
    g.add_argument("--prerelease", dest="prerelease", action="store_true", default=None,
                   help="prereleases count too")
    g.add_argument("--no-prerelease", dest="prerelease", action="store_false",
                   help="prereleases don't count (default)")
    a = actions.add_parser("set-type", parents=[colorp],
                           help="platform of the source's host (--unset: derived from it)")
    a.add_argument("name", metavar="NAME", help="key of the [source]")
    a.add_argument("value", metavar="github|gitlab", nargs="?")
    a.add_argument("--unset", action="store_true", help="derive the platform from the host")
    a = actions.add_parser("map", parents=[colorp],
                           help="take the releases of a source from a local folder (local "
                                "development, tests); this repository's config, --global: all")
    a.add_argument("source", nargs="?", metavar="URL|SOURCE",
                   help="source URL, or the name of a [source] (without DIR: list its mappings)")
    a.add_argument("dir", nargs="?", metavar="DIR",
                   help="local folder: one subdirectory per release, named like its tag, "
                        "with the assets")
    a.add_argument("--flat", action="store_true",
                   help="DIR has the assets of all releases as files: a release is named like "
                        "the file without its extension (rel1.7z, rel1.xml -> rel1)")
    a.add_argument("--unset", action="store_true", help="remove the mapping")
    a.add_argument("--global", dest="glob", action="store_true",
                   help="in the global git config, for all repositories")

    p = sub.add_parser("filter", parents=[colorp],
                       help="list, show or change the named filters [filter \"NAME\"]")
    actions = p.add_subparsers(dest="action", metavar="ACTION")
    a = actions.add_parser("show", parents=[colorp], help="the steps of a filter")
    a.add_argument("name", metavar="NAME")
    a = actions.add_parser("add", parents=[colorp, filterp],
                           help="define a new filter with the steps given (in this order)")
    a.add_argument("name", metavar="NAME")
    a = actions.add_parser("set", parents=[colorp, filterp],
                           help="replace the steps of a filter (in the order given)")
    a.add_argument("name", metavar="NAME")
    a = actions.add_parser("test", parents=[colorp, remotep],
                           help="apply a filter to local files or to the assets of a release, "
                                "and list or write the result (nothing else changes)")
    a.add_argument("name", metavar="NAME")
    a.add_argument("files", nargs="*", metavar="FILE",
                   help="input files, as if they were the assets (a directory: its files)")
    a.add_argument("--source", metavar="URL|SOURCE",
                   help="the input: the assets of the release this source selects (as for add)")
    a.add_argument("--release", metavar="TAG|PATTERN", help="with --source: as for add")
    a.add_argument("--prerelease", action="store_true", help="with --source: as for add")
    a.add_argument("--type", choices=sorted(PLATFORMS), help="with --source: as for add")
    a.add_argument("--asset", metavar="PATTERN",
                   help="with --source: only the matching assets (default: all)")
    a.add_argument("-o", "--output", metavar="DIR",
                   help="write the result to DIR (new or empty) instead of listing it")
    a = actions.add_parser("rename", parents=[colorp],
                           help="rename a filter and the steps using it")
    a.add_argument("name", metavar="OLD")
    a.add_argument("value", metavar="NEW")
    a = actions.add_parser("remove", parents=[colorp], help="remove an unused filter")
    a.add_argument("name", metavar="NAME")

    p = sub.add_parser("trust", parents=[colorp],
                       help="list the filters that run commands; trust them in this repository")
    p.add_argument("names", nargs="*", metavar="NAME", help="filters to trust")
    p.add_argument("--all", action="store_true", help="trust all filters that run commands")
    p.add_argument("--revoke", action="store_true", help="no longer trust the filters NAME")

    p = sub.add_parser("cache", parents=[colorp],
                       help="show, list or clean up the download cache")
    actions = p.add_subparsers(dest="action", metavar="ACTION")
    actions.add_parser("list", parents=[colorp],
                       help="the files, most recently used first: size, last used, what it is")
    a = actions.add_parser("prune", parents=[colorp],
                           help="remove what wasn't used for a while (default: the configured "
                                "limits, assetsync.cacheMaxAge / cacheMaxSize)")
    a.add_argument("--older-than", type=int, metavar="DAYS",
                   help="what wasn't used for DAYS days")
    a.add_argument("--max-size", metavar="SIZE",
                   help="then the least recently used, down to SIZE (e.g. 500M, 2G)")
    a.add_argument("-n", "--dry-run", action="store_true", help="only show what would be removed")
    a = actions.add_parser("clear", parents=[colorp], help="remove everything")
    a.add_argument("-n", "--dry-run", action="store_true", help="only show what would be removed")
    actions.add_parser("dir", parents=[colorp], help="print the cache's directory")

    p = sub.add_parser("install-hooks", parents=[colorp],
                       help="install the pre-push/post-merge hooks")
    p.add_argument("--force", action="store_true",
                   help="add our lines to existing hooks (right after the #! line)")
    sub.add_parser("uninstall-hooks", parents=[colorp], help="remove the hooks again")
    p = sub.add_parser("hook", parents=[colorp], help="what the installed hooks run")
    p.add_argument("name", choices=list(HOOKS))
    p.add_argument("hook_args", nargs=argparse.REMAINDER, help="the hook's arguments")
    describe_commands(ap)
    ap.epilog = command_list(sub) + (
        "\n\nWithout a command: status. 'git assetsync <command> -h' describes a command\n"
        "and lists its options.")
    # the grouped list instead of argparse's; hiding that hides <command> in the usage too
    sub.help = argparse.SUPPRESS
    ap.usage = "git assetsync [-h] [--version] <command> ..."

    argv = list(sys.argv[1:] if argv is None else argv)
    extra = []
    if argv and argv[0] in ("diff", "difftool") and "--" in argv:
        i = argv.index("--")
        argv, extra = argv[:i], argv[i + 1:]
    args = ap.parse_args(argv)
    if not args.cmd:
        args = ap.parse_args(["status"])
    args.extra = extra
    try:
        try:
            repo = Repo()
        except FsError:
            repo = None
        setup_colors(args.color, repo.top if repo else None)
        if args.cmd == "cache":               # also outside a repository
            return cmd_cache(args)
        if args.cmd == "source" and args.action == "map":   # --global: also outside one
            return cmd_map(args, repo)
        if not getattr(args, "remote", False):
            MAPPINGS.update((norm_url(u), (d, flat)) for _, _, u, d, flat in
                            local_mappings(cwd=repo.top if repo else None))
        if args.cmd == "releases":            # also outside a repository
            return cmd_releases(Context(args), repo, args)
        if repo is None:
            raise FsError("not inside a Git working tree")
        if args.cmd == "install-hooks":
            return cmd_install_hooks(repo, args)
        if args.cmd == "uninstall-hooks":
            return cmd_uninstall_hooks(repo, args)
        if args.cmd == "hook":
            args.no_fetch = args.name == "post-merge"    # pre-push: online anyway
        ctx = Context(args)
        return {"hook": cmd_hook, "status": cmd_status, "pull": cmd_pull, "diff": cmd_diff,
                "difftool": cmd_difftool, "add": cmd_add, "edit": cmd_edit,
                "set": cmd_set, "unlink": cmd_unlink, "mv": cmd_mv, "restore": cmd_restore, "rm": cmd_rm,
                "source": cmd_source, "filter": cmd_filter,
                "trust": cmd_trust, "verify": cmd_verify}[args.cmd](ctx, repo, args)
    except FsError as e:
        error(str(e))
        return EXIT_ERROR
    except KeyboardInterrupt:
        return 130
    except BrokenPipeError:
        # output piped into e.g. `head`, which exited early
        try:
            os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        except OSError:
            pass
        return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
