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

A repository lists its synced files in .git-assetsync at its root
(git-config format, like .gitmodules), each taken from a release asset of
a project on GitHub or GitLab:

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

An entry records the release asset the committed file comes from, so the
local state is known offline; only the check for new releases asks the
platform. The file must stay an exact copy of the asset: pull refuses
local modifications, --force discards them.

Commands (run inside the repository; without a command: status). PATH may
be a file or a directory (= all entries below it); options follow the
command.

    status [PATH...]            state of the files like `git status`: new
                                releases to pull, local modifications
        -s, --short             short format: upstream/committed/worktree
                                columns (upstream: P pending, N new; E error)
        -v, --verbose           also list all files with their sources
        --exit-code             exit 1 if something is to pull or a file is
                                modified
        --hook                  terse output on stderr (for git hooks)
        --no-fetch              don't ask the platform for new releases

    pull PATH... | --all        update the files to the selected release and
                                commit with a message naming it (with its
                                release notes, shortened); refused if a file
                                is modified (committed or not)
        --all                   all files with something to pull
        --force                 discard local modifications
        --no-edit               commit without opening the editor
        --no-commit             only stage; a plain `git commit` offers the
                                proposed message (via .git/SQUASH_MSG)
        -n, --dry-run           only report what would happen

    add PATH SOURCE             take the file PATH from an asset of the
                                release SOURCE selects; SOURCE: the name of a
                                [source], or a URL (owner/repo: github.com) -
                                the source with that URL and release
                                selection, else a new one named 'owner/repo'
                                (a number appended if taken); PATH and
                                .git-assetsync are staged like `git add` - a
                                plain `git commit` offers the proposed message
        --asset PATTERN         the asset (glob, must match exactly one;
                                default: the release's only asset)
        --release TAG|PATTERN   release to take (exact tag: pinned) or the
                                newest one matching (default: the latest)
        --prerelease            prereleases count too (with a pattern, or
                                instead of the latest)
        --type github|gitlab    platform of the URL's host (default: derived
                                from it: github.com, gitlab.com, gitlab.*)
        --force                 replace an existing entry or file
        -n, --dry-run           only show what would be done

    unlink PATH...              remove entries (the files are kept); also
                                broken ones, by their name
    mv OLD NEW                  move a file (git mv), keeping its entry
        -n, --dry-run           (both) only show what would be done

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

    install-hooks               install pre-push/post-merge reminder hooks
    uninstall-hooks             remove them again

    Common options:
        --color[=WHEN], --no-color  always, never or auto (default)

Exit codes: 0 ok, 1 unfinished (not committed, --exit-code), 2 error.

Files stored in Git LFS and line-ending conversions are handled: a file
is recorded as `git add` stores it. Output is colored like git's
(color.assetsync / color.ui, --color, NO_COLOR).

GitHub is accessed through the GitHub CLI (`gh api`, logged in with `gh
auth login` or GH_TOKEN), GitLab through the GitLab CLI (`glab api`,
`glab auth login` or GITLAB_TOKEN); ASSETSYNC_GH / ASSETSYNC_GLAB set
other commands for them.

Requires Python >= 3.8, Git >= 2.28, and gh or glab (git-lfs for LFS
files).
Works on Linux, macOS and Windows.
Manual: https://github.com/stsichler/git-assetsync/blob/main/MANUAL.md
"""

import argparse
import fnmatch
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path, PureWindowsPath
from urllib.error import HTTPError, URLError
from urllib.parse import quote, unquote, urlparse
from urllib.request import urlopen

__version__ = "0.2.0"
REGISTRY = ".git-assetsync"
EXIT_OK, EXIT_PENDING, EXIT_ERROR = 0, 1, 2
HOOK_MARKER = "git-assetsync"
HOOKS = {
    "pre-push": "git assetsync status --hook",
    "post-merge": "git assetsync status --hook --no-fetch",
}
REGISTRY_HEADER = ("# git-assetsync: files of this repository that are taken from release\n"
                   "# assets of other projects. Maintained by 'git assetsync'; [file]\n"
                   "# synced/digest/blob record the asset each file comes from.\n")
# add warns about binary files at least this big that are not stored in LFS
LFS_HINT_SIZE = 1 << 20
# release notes in a commit message: at most this many lines of this length
NOTES_LINES, NOTES_WIDTH = 20, 200


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
    size: int = None
    digest: str = None        # 'sha256:<hex>' if the platform reports it
    url: str = None           # where to download it (GitLab: the link's URL)


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

    def __init__(self, host, project, label):
        self.host, self.project, self.label = host, project, label

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

    def releases(self):
        """All releases (page by page, independent of the CLI's paging)."""
        result, page = [], 1
        while True:
            try:
                items = self.json(f"{self.list_path}?per_page={self.PER_PAGE}&page={page}")
            except NotFound:
                raise self.not_found()
            if not isinstance(items, list):
                raise FsError(f"{self.label}: unexpected answer listing the releases")
            result += [self.release(d) for d in items]
            if len(items) < self.PER_PAGE:
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


PLATFORMS = {"github": GitHub, "gitlab": GitLab}


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


def platform_of(url, kind=None):
    """Platform client for a source URL; kind: its type key, else derived
    from the host."""
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
            raise FsError(f"no release with tag '{rule}' in {origin.label}")
        return r
    if not rule and not prerelease:
        r = origin.latest()
        if not r:
            raise FsError(f"no release in {origin.label}")
        return r
    cands = [r for r in origin.releases() if not r.draft and (prerelease or not r.prerelease)
             and (not rule or fnmatch.fnmatchcase(r.tag, rule))]
    if not cands:
        what = f"with a tag matching '{rule}'" if rule else ""
        raise FsError(f"no release {what} in {origin.label}".replace("  ", " ")
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


def fetch_asset(origin, release, asset, dest):
    """Download asset to dest and check it; returns its digest."""
    print(paint(f"Downloading {asset.name} ({origin.label} {release.tag}) ...", "dim", "err"),
          file=sys.stderr)
    origin.download(asset, dest)
    h, size = hashlib.sha256(), 0
    with open(dest, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
            size += len(chunk)
    digest = "sha256:" + h.hexdigest()
    if asset.digest and asset.digest.lower().startswith("sha256:") and \
            asset.digest.lower() != digest:
        raise FsError(f"{asset.name} of {origin.label} {release.tag}: downloaded file has "
                      f"{digest}, but the release lists {asset.digest}")
    if asset.size is not None and asset.size != size:
        raise FsError(f"{asset.name} of {origin.label} {release.tag}: downloaded {size} "
                      f"bytes, but the release lists {asset.size}")
    return digest


class Context:
    """Creates platform clients and caches the release selection of each
    source, so a run asks the platform once per source."""

    def __init__(self, args):
        self.fetch = not getattr(args, "no_fetch", False)
        self._selected = {}

    def release(self, url, spec):
        """(origin, selected release) for a source URL and its selection keys."""
        key = (norm_url(url), spec.get("type"), spec.get("release"),
               is_true(spec.get("prerelease")))
        if key not in self._selected:
            origin = platform_of(url, spec.get("type"))
            try:
                self._selected[key] = origin, select_release(
                    origin, spec.get("release"), is_true(spec.get("prerelease")))
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
        return Path(os.path.relpath(Path(path).resolve(), self.top)).as_posix()

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

SECTIONS = ("source", "file")
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
            result[sect].setdefault(sub, {})[name] = val
    return result


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
    """The repository's .git-assetsync: [source] and [file] sections."""

    def __init__(self, repo):
        self.repo = repo
        self.path = repo.top / REGISTRY
        self.sources, self.files = {}, {}
        self.dry_run = False      # only change the in-memory state
        if self.path.exists():
            p = git(["config", "-f", self.path, "--list", "-z"], check=False)
            if p.returncode:
                raise FsError(f"{REGISTRY}: cannot parse: "
                              + p.stderr.decode("utf-8", "replace").strip())
            parsed = parse_registry(p.stdout)
            self.sources, self.files = parsed["source"], parsed["file"]

    def entries(self):
        return [Entry(self, rel) for rel in sorted(self.files)]

    def _cfg(self, *args):
        if self.dry_run:
            return
        if not self.path.exists():
            self.path.write_bytes(REGISTRY_HEADER.encode())
        git(["config", "-f", self.path] + list(args))

    def set_file(self, rel, name, value):
        self._cfg(f"file.{rel}.{name}", value)
        self.files.setdefault(rel, {})[name] = value

    def find_source(self, url, spec):
        """Key of a [source] with url and exactly the selection keys of spec."""
        for name, s in self.sources.items():
            if norm_url(s.get("url", "")) == norm_url(url) and source_spec(s) == spec:
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

    def rename_source(self, old, new):
        self._cfg("--rename-section", f"source.{old}", f"source.{new}")
        self.sources[new] = self.sources.pop(old)
        for rel, f in self.files.items():
            if f.get("source") == old:
                self.set_file(rel, "source", new)

    def source_files(self, name):
        return sorted(rel for rel, f in self.files.items() if f.get("source") == name)

    def remove_file(self, rel, keep_source=None):
        """Remove a [file]; its [source] too when no other file uses it
        (unless it is keep_source)."""
        src = self.files.pop(rel, {}).get("source")
        self._cfg("--remove-section", f"file.{rel}")
        if src and src != keep_source and src in self.sources and \
                not any(f.get("source") == src for f in self.files.values()):
            self._cfg("--remove-section", f"source.{src}")
            del self.sources[src]

    def rename_file(self, old, new):
        self._cfg("--rename-section", f"file.{old}", f"file.{new}")
        self.files[new] = self.files.pop(old)

    def finish(self):
        """Fix line endings and stage the registry (or its removal when empty)."""
        if self.dry_run:
            return
        if self.path.exists():
            if not self.sources and not self.files:
                self.path.unlink()
            else:
                self.repo.fix_eol(self.path)
        self.repo.git(["add", "-A", "--", REGISTRY])

    def uncommitted(self):
        """[file] entries that differ from the committed .git-assetsync in what
        they record about the file. Which [source] they belong to doesn't
        count: a changed source may go into any commit."""
        p = self.repo.git(["config", "--blob", f"HEAD:{REGISTRY}", "--list", "-z"], check=False)
        head = parse_registry(p.stdout)["file"] if p.returncode == 0 else {}

        def base(entry):
            return None if entry is None else {k: v for k, v in entry.items() if k != "source"}
        return {rel for rel in set(head) | set(self.files)
                if base(head.get(rel)) != base(self.files.get(rel))}


class Entry:
    """One [file] entry: a file of this repository taken from a release asset."""

    def __init__(self, reg, rel):
        self.reg, self.rel = reg, rel

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
    blob = property(lambda self: self.v.get("blob", ""))

    def set(self, name, value):
        self.reg.set_file(self.rel, name, value)


def select_entries(repo, reg, paths):
    """Entries for the given files/directories (all entries if none given)."""
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
    entry: object
    rel: str
    error: str = None
    warnings: list = field(default_factory=list)
    fetched: bool = False     # upstream checked
    origin: object = None
    release: object = None    # the release the source selects now
    asset: object = None      # its asset matching the entry
    committed: str = None     # see evaluate()
    worktree: str = "clean"
    local: str = "clean"
    head_blob: str = None
    changed: bool = False     # selected asset differs from the synced one
    pending: bool = False     # something for pull to do
    modified: bool = False    # local modifications (not allowed)
    base_now: str = None      # base blob as it would be stored now


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
        if ptr and entry.digest == f"sha256:{ptr[0]}":
            return True
        if st.base_now is None:
            st.base_now = repo.as_local(repo.read_content(entry.blob, st.rel), st.rel)
        return oid == st.base_now
    except FsError as e:
        msg = (f"synced version {entry.blob[:12]} not available, file counts as "
               f"modified ({e})")
        if msg not in st.warnings:
            st.warnings.append(msg)
        return False


def evaluate(ctx, repo, entry):
    """State of an entry in three independent respects:
    upstream  - synced asset vs. the asset of the release the source selects
                now (changed; only checked when fetching)
    committed - committed file vs. synced asset ('unmodified' | 'adapted' |
                None if not committed)
    worktree  - working file vs. committed version
                ('clean' | 'modified' | 'deleted' | 'added' | 'missing')
    local     - working file vs. synced asset ('clean' | 'modified' |
                'missing')"""
    st = State(entry=entry, rel=entry.rel)
    problem = path_problem(entry.rel)
    if problem:
        st.error = (f"{problem} - entry ignored; remove it with "
                    f"'git assetsync unlink {shlex.quote(entry.rel)}'")
        return st
    if not entry.url:
        st.error = f"incomplete entry in {REGISTRY} (needs a source with url)"
        return st
    try:
        cur = repo.worktree_blob(entry.target)
        p = repo.git(["rev-parse", "--verify", "-q", f"HEAD:{entry.rel}"], check=False)
        head = st.head_blob = out(p) if p.returncode == 0 else None
        # without a recorded base (entry written by hand) nothing counts as
        # modified; pull then only replaces a file that is the same
        known = bool(entry.blob)
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
    except FsError as e:
        st.error = str(e)
        return st
    # a deleted committed file counts as modified; one never committed is new
    st.modified = known and (st.committed == "adapted" or st.local == "modified"
                             or st.worktree == "deleted")
    if ctx.fetch:
        try:
            st.origin, st.release = ctx.release(entry.url, entry.spec)
            st.asset = match_asset(st.release, entry.asset, st.origin.label,
                                   f"'git assetsync add --force {cmd_arg(entry.rel)} "
                                   f"{shlex.quote(entry.name)} --asset PATTERN'")
        except FsError as e:
            st.error = str(e)
            return st
        st.fetched = True
        st.changed = st.release.tag != entry.synced or bool(
            st.asset.digest and entry.digest and st.asset.digest.lower() != entry.digest.lower())
    st.pending = st.changed or st.worktree == "missing"
    return st


def upstream_state(st):
    """(label, note) of a pending upstream change, None if there is none."""
    e = st.entry
    if st.changed and not e.synced:
        return "new", f"release {st.release.tag}"
    if st.changed and st.release.tag != e.synced:
        return "pending", f"{e.synced} -> {st.release.tag}"
    if st.changed:
        return "pending", f"asset replaced in release {e.synced}"
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
    error(f"{st.rel}: {st.error}")


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
    """Path relative to the current directory, like git status shows it."""
    return Path(os.path.relpath(repo.top / rel, repo.base)).as_posix()


def print_short(repo, sts):
    for st in sts:
        code = short_code(st)
        if code.strip():
            line = paint(code[0], "yellow") + paint(code[1], "cyan") + paint(code[2], "red")
            if code[0] == "E":
                line = paint(code, "boldred")
            print(f"{line} {shown(repo, st.rel)}")


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
            synced = f"synced {e.synced}" if e.synced else "not synced yet"
            label = st.committed or ("uncommitted" if e.blob else "not synced")
            rows.append((label, st.rel,
                         f"{e.asset or 'only asset'} from {e.name}, {spec_text(e.spec)}; "
                         f"{synced}", "dim"))
        section("Files:", [], rows, None)

    up_rows = []
    for st in ok:
        up = upstream_state(st)
        if up:
            up_rows.append((up[0], st.rel, up[1], "dim"))
    section("Upstream changes to pull:", ['use "git assetsync pull <file>..." to update'],
            up_rows, "yellow")

    not_allowed = ("NOT ALLOWED", "boldred")
    adapted = [st for st in ok if st.committed == "adapted"]
    section("Locally modified files:",
            ['use "git assetsync pull --force <file>..." to restore the release asset'],
            [("modified", st.rel) + not_allowed for st in adapted], "cyan")

    labels = {"modified": "modified", "deleted": "deleted", "added": "new file"}
    dirty = [st for st in ok if st.worktree in labels]
    section("Uncommitted changes:",
            ['use "git restore <file>..." to discard uncommitted changes'],
            [(labels[st.worktree], st.rel) +
             (not_allowed if st.local != "clean" else (None, None)) for st in dirty], "red")

    warnings = [(st.rel, w) for st in ok for w in st.warnings]
    if warnings:
        print("Warnings:")
        for rel, w in warnings:
            print(f"\t{paint('warning:', 'yellow')} {shown(repo, rel)}: {w}")
        print()

    if not ctx.fetch:
        print("new releases not checked (--no-fetch)")
    elif not up_rows and len(ok) == len(sts):
        n = len(sts)
        print("nothing to pull" + ("" if adapted or dirty else
                                   f", {'all ' if n > 1 else ''}{plural(n, 'file')} unmodified"))


# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------

def cmd_status(ctx, repo, args):
    """Like `git status`: exit code 0 unless --exit-code (1 = something to
    pull or a file modified) or an error (2)."""
    reg = Registry(repo)
    entries = select_entries(repo, reg, args.paths)
    if not entries:
        if not (args.hook or args.short):
            print(f"no synced files ({REGISTRY} not found or empty)")
        return EXIT_OK
    sts = [evaluate(ctx, repo, e) for e in entries]
    attention = [st for st in sts if st.error or st.pending or st.modified]
    rc = EXIT_ERROR if any(st.error for st in sts) else \
        EXIT_PENDING if args.exit_code and attention else EXIT_OK
    if args.hook:
        for st in attention:
            print(f"assetsync: {paint(st.rel, 'yellow', 'err')}: {render(describe(st), 'err')}",
                  file=sys.stderr)
        if any(st.pending for st in attention):
            print("assetsync: run 'git assetsync pull <file>' to update", file=sys.stderr)
        if any(st.modified for st in attention):
            print("assetsync: see 'git assetsync status' for local modifications",
                  file=sys.stderr)
        return rc
    for st in sts:
        if st.error:
            report_error(st)
    if args.short:
        print_short(repo, sts)
    else:
        print_long(ctx, repo, sts, args.verbose)
    return rc


def release_lines(release, asset):
    """Body lines of a commit message naming the release and asset."""
    lines = [f"Release: {release.url or release.tag}"]
    if release.title and release.title != release.tag:
        lines.append(f"Title:   {release.title}")
    return lines + [f"Asset:   {asset.name}"]


def notes_lines(notes):
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
    more = len(lines) > NOTES_LINES
    lines = lines[:NOTES_LINES]
    while lines and not lines[-1]:
        lines.pop()
    if more:
        lines.append("[... see the release page for more]")
    return [f"  {line}" if line else "" for line in lines]


def build_message(entry, release, asset, discarded):
    """Commit message for pull: what the file is updated to (or restored)."""
    rel, name, tag, old = entry.rel, entry.name, release.tag, entry.synced
    if not old:
        subject = f"Add {rel} from {name} {tag}"
    elif tag != old:
        subject = f"Update {rel} to {name} {tag} (was {old})"
    elif asset.digest and entry.digest and asset.digest.lower() != entry.digest.lower():
        subject = f"Update {rel} from {name} {tag} (asset replaced)"
    else:
        subject = f"Restore {rel} from {name} {tag}"
    lines = [subject, ""] + release_lines(release, asset)
    notes = notes_lines(release.notes) if old and tag != old else []
    if notes:
        lines += ["", "Release notes:"] + notes
    if discarded:
        lines += ["", "Local modifications of this repository were discarded."]
    return "\n".join(lines) + "\n"


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
    their entries with it."""
    msgfile = repo.state_file("ASSETSYNC_MSG_", name)
    msgfile.write_bytes(msg.encode("utf-8"))
    paths = " ".join([cmd_arg(r) for r in ([name] if rels is None else rels)] + [REGISTRY])
    return msgfile, f'git commit -e -F "{msgfile}" -- {paths}'


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


def commit_hint(repo, name, msg, rels=None):
    """(command, note) for committing staged changes with the proposed
    message: a plain `git commit` if the message could be prepared for it
    (see propose_message), otherwise one with a message file."""
    if propose_message(repo, msg):
        return "git commit", "it offers the proposed commit message"
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
    cmd = ["git", "commit", "-F", str(msgfile)] + ([] if args.no_edit else ["-e"]) + \
        ["--"] + [lit(r) for r in rels] + [REGISTRY]
    if subprocess.run(cmd, cwd=repo.top).returncode:
        report_staged(repo, name, msg, paint("commit not done", "yellow")
                      + "; changes stay staged", rels, "Commit later with")
        return EXIT_PENDING
    msgfile.unlink()
    return EXIT_OK


def install_asset(repo, origin, release, asset, rel, target, force=False):
    """Download asset, store it as `git add` would at rel and write it to
    the working tree as `git checkout` would. A file already there that
    differs is only overwritten with force. Returns (digest, blob)."""
    with tempfile.TemporaryDirectory(prefix="assetsync-") as td:
        f = Path(td) / "asset"
        digest = fetch_asset(origin, release, asset, f)
        blob = repo.add_file(f, rel)
    cur = repo.worktree_blob(target)
    if cur and cur != blob and not force:
        raise FsError(f"'{rel}' exists and differs from {asset.name} - "
                      "use --force to overwrite it")
    if target.is_dir():
        raise FsError(f"'{rel}' is a directory")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(repo.checkout_form(blob, rel))
    return digest, blob


def pull_one(repo, reg, st, args):
    entry, rel = st.entry, st.rel
    release, asset = st.release, st.asset
    if not st.pending and not st.modified:
        print(f"{rel}: {paint('up to date', 'green')}")
        return EXIT_OK
    # like `git pull` with no merge possible: local modifications are never
    # overwritten silently
    if st.modified and not args.force:
        what = ("committed modifications" if st.committed == "adapted" else
                "uncommitted changes")
        raise FsError(f"{rel}: {what} NOT ALLOWED - the file must stay a copy of its "
                      f"release asset; discard them with 'git assetsync pull --force "
                      f"{cmd_arg(rel)}'" + ("" if st.committed == "adapted" else
                                            f" or 'git restore {cmd_arg(rel)}'"))
    check_other_entries(reg, [rel], args)
    for w in st.warnings:
        warn(f"{rel}: {w}")
    discard = st.modified
    if args.dry_run:
        msg = build_message(entry, release, asset, discard).splitlines()[0]
        print(f"would: {msg}" + (" - discarding local modifications" if discard else ""))
        return EXIT_OK
    if discard:
        warn(f"{rel}: discarding local modifications")
    # an entry without a base (written by hand): a file already there is
    # only replaced if it is the same, or with --force
    digest, blob = install_asset(repo, st.origin, release, asset, rel, entry.target,
                                 force=args.force or bool(entry.blob))
    msg = build_message(entry, release, asset, discard)
    entry.set("synced", release.tag)
    entry.set("digest", digest)
    entry.set("blob", blob)
    reg.finish()
    repo.git(["add", "--", lit(rel)])
    return commit_staged(repo, rel, msg, args, "updated and staged")


def cmd_pull(ctx, repo, args):
    reg = Registry(repo)
    reg.dry_run = args.dry_run
    if args.all:
        entries = reg.entries()
    elif args.paths:
        entries = select_entries(repo, reg, args.paths)
    else:
        raise FsError("specify file(s) or --all")
    rc, done = EXIT_OK, 0
    for entry in entries:
        st = evaluate(ctx, repo, entry)
        if st.error:
            report_error(st)
            rc = EXIT_ERROR
            continue
        if args.all and not st.pending and not (args.force and st.modified):
            continue
        done += 1
        try:
            rc = max(rc, pull_one(repo, reg, st, args))
        except FsError as e:   # report and carry on with the other files
            error(str(e))
            rc = EXIT_ERROR
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


def large_binary_hint(repo, rel, path):
    """Warn about a big binary file that is not stored in Git LFS: each
    update adds another copy of it to the history."""
    size = path.stat().st_size
    if size < LFS_HINT_SIZE:
        return
    with open(path, "rb") as f:
        if b"\0" not in f.read(8000):
            return
    if out(repo.git(["check-attr", "filter", "--", rel])).endswith(": lfs"):
        return
    warn(f"{rel} is a binary file of {size // 1024} KiB, not stored in Git LFS - every "
         f"update adds a copy to the history; consider 'git lfs track {cmd_arg(rel)}' "
         "(before committing)")


def cmd_add(ctx, repo, args):
    reg = Registry(repo)
    target = repo.user_path(args.path)
    rel = repo.rel(target)
    problem = path_problem(rel) if rel != "." else "is the repository itself"
    if problem:
        raise FsError(f"cannot add '{rel}': {problem}")
    if target.is_dir():
        raise FsError(f"cannot add '{rel}': is a directory")
    if rel in reg.files and not args.force:
        raise FsError(f"'{rel}' is already synced (use --force to replace its entry)")
    url, spec, named = add_source(reg, args)
    origin, release = ctx.release(url, spec)
    asset = match_asset(release, args.asset, origin.label)
    name = named or reg.source_name(url, spec)
    if args.dry_run:
        print(f"would add {rel} from {name} {release.tag} ({asset.name}, {spec_text(spec)})")
        return EXIT_OK
    digest, blob = install_asset(repo, origin, release, asset, rel, target, args.force)
    if rel in reg.files:
        reg.remove_file(rel, keep_source=named)
    name = named or reg.add_source(url, spec)
    entry = Entry(reg, rel)
    for k, v in (("source", name), ("asset", args.asset), ("synced", release.tag),
                 ("digest", digest), ("blob", blob)):
        if v:
            entry.set(k, v)
    reg.finish()
    large_binary_hint(repo, rel, target)
    repo.git(["add", "--", lit(rel)])
    print(f"{paint('added', 'green')} {rel} <- {name} {release.tag} ({asset.name})")
    if repo.git(["diff", "--cached", "--quiet", "HEAD", "--", lit(rel), REGISTRY],
                check=False).returncode == 0:
        print(f"{rel}: entry and file unchanged, nothing to commit")
        return EXIT_OK
    # staged only, like git add; the proposed message is prepared for the commit
    msg = "\n".join([f"Add {rel} from {name} {release.tag}", ""]
                    + release_lines(release, asset)) + "\n"
    report_staged(repo, rel, msg, paint("staged", "green"))
    return EXIT_OK


def cmd_unlink(ctx, repo, args):
    reg = Registry(repo)
    for entry in select_entries(repo, reg, args.paths):
        if args.dry_run:
            print(f"would unlink {entry.rel}")
            continue
        reg.remove_file(entry.rel)
        print(f"{paint('unlinked', 'green')} {entry.rel} (file kept)")
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
                          f"to it with 'git assetsync add --force <file> {other}'")
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
    return (f"# {HOOK_MARKER}: remind about new releases to pull (never blocks)\n"
            f"{cmd} </dev/null || true\n")


def is_our_hook_line(line):
    s = line.strip()
    return s.startswith(f"# {HOOK_MARKER}:") or s.startswith("git assetsync status --hook")


def cmd_install_hooks(repo, args):
    hookdir = hook_dir(repo, "installing into")
    hookdir.mkdir(parents=True, exist_ok=True)
    for name, cmd in HOOKS.items():
        f = hookdir / name
        snippet = hook_snippet(cmd)
        if f.exists():
            if HOOK_MARKER in f.read_text(encoding="utf-8", errors="replace"):
                print(f"{name}: already installed")
            else:
                print(f"{name}: {paint('hook exists', 'yellow')}, add these lines to {f}:\n{snippet}")
            continue
        f.write_bytes(("#!/bin/sh\n" + snippet + "exit 0\n").encode())
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
        if all(ln.strip() in ("", "#!/bin/sh", "exit 0") for ln in rest):
            f.unlink()
            print(f"{name}: {paint('removed', 'green')}")
        else:
            f.write_bytes("".join(rest).encode("utf-8"))
            print(f"{name}: {paint('git-assetsync lines removed', 'green')}, rest of hook kept")
    return EXIT_OK


# --------------------------------------------------------------------------

def main(argv=None):
    for stream in (sys.stdout, sys.stderr):
        try:
            # LF line ends like git's output, also on Windows (no CRLF translation)
            stream.reconfigure(errors="replace", newline="\n")
        except AttributeError:
            pass

    colorp = argparse.ArgumentParser(add_help=False)
    colorp.add_argument("--color", nargs="?", const="always", default="auto",
                        choices=["always", "never", "auto"], help="colored output (default: auto)")
    colorp.add_argument("--no-color", dest="color", action="store_const", const="never",
                        help="same as --color=never")

    ap = argparse.ArgumentParser(prog="git assetsync",
                                 description="Keep files in sync with release assets of "
                                             "other projects.",
                                 epilog="Without a command: status. "
                                        "'git assetsync <command> -h' lists the options of a "
                                        "command.")
    ap.add_argument("--version", action="version", version=f"git-assetsync {__version__}")
    sub = ap.add_subparsers(dest="cmd")

    p = sub.add_parser("status", parents=[colorp], help="show the state of the synced files")
    p.add_argument("paths", nargs="*", help="files or directories (default: all)")
    p.add_argument("-s", "--short", action="store_true",
                   help="short format: upstream / committed / working tree columns")
    p.add_argument("-v", "--verbose", action="store_true",
                   help="also list all files with their sources")
    p.add_argument("--exit-code", action="store_true",
                   help="exit with 1 if something is to pull or a file is modified")
    p.add_argument("--hook", action="store_true", help="terse output for git hooks")
    p.add_argument("--no-fetch", action="store_true",
                   help="don't ask the platform for new releases")

    p = sub.add_parser("pull", parents=[colorp], help="update files to the selected release")
    p.add_argument("paths", nargs="*", metavar="PATH", help="files or directories")
    p.add_argument("--all", action="store_true", help="all files with something to pull")
    p.add_argument("--force", action="store_true", help="discard local modifications")
    p.add_argument("--no-edit", action="store_true", help="commit without opening the editor")
    p.add_argument("--no-commit", action="store_true",
                   help="only stage; a plain 'git commit' offers the proposed message")
    p.add_argument("-n", "--dry-run", action="store_true",
                   help="only report what would happen")

    p = sub.add_parser("add", parents=[colorp], help="take a file from a release asset")
    p.add_argument("path", metavar="PATH", help="file in this repository")
    p.add_argument("source", metavar="SOURCE",
                   help=f"name of a [source] in {REGISTRY}, or URL (owner/repo: github.com)")
    p.add_argument("--asset", metavar="PATTERN",
                   help="asset of the release (glob pattern, must match exactly one; "
                        "default: the release's only asset)")
    p.add_argument("--release", metavar="TAG|PATTERN",
                   help="release to take: an exact tag (pinned) or the newest matching "
                        "(default: the latest release)")
    p.add_argument("--prerelease", action="store_true", help="prereleases count too")
    p.add_argument("--type", choices=sorted(PLATFORMS),
                   help="platform of the URL's host (default: derived from it)")
    p.add_argument("--force", action="store_true", help="replace an existing entry or file")
    p.add_argument("-n", "--dry-run", action="store_true", help="only show what would be done")

    p = sub.add_parser("unlink", parents=[colorp], help="remove entries (the files are kept)")
    p.add_argument("paths", nargs="+", metavar="PATH", help="files or directories")
    p.add_argument("-n", "--dry-run", action="store_true", help="only show what would be done")

    p = sub.add_parser("mv", parents=[colorp], help="move a file, keeping its entry")
    p.add_argument("src", metavar="OLD", help="synced file")
    p.add_argument("dst", metavar="NEW", help="new path or existing directory")
    p.add_argument("-n", "--dry-run", action="store_true", help="only show what would be done")

    p = sub.add_parser("source", parents=[colorp],
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

    sub.add_parser("install-hooks", parents=[colorp],
                   help="install pre-push/post-merge reminder hooks")
    sub.add_parser("uninstall-hooks", parents=[colorp], help="remove the reminder hooks again")

    argv = list(sys.argv[1:] if argv is None else argv)
    args = ap.parse_args(argv)
    if not args.cmd:
        args = ap.parse_args(["status"])
    try:
        try:
            repo = Repo()
        except FsError:
            repo = None
        setup_colors(args.color, repo.top if repo else None)
        if repo is None:
            raise FsError("not inside a Git working tree")
        if args.cmd == "install-hooks":
            return cmd_install_hooks(repo, args)
        if args.cmd == "uninstall-hooks":
            return cmd_uninstall_hooks(repo, args)
        ctx = Context(args)
        return {"status": cmd_status, "pull": cmd_pull, "add": cmd_add,
                "unlink": cmd_unlink, "mv": cmd_mv, "source": cmd_source}[args.cmd](ctx, repo, args)
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
