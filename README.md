<img src="doc/logo.svg" alt="" width="128" align="right">

# git-assetsync

[![Tests](https://github.com/stsichler/git-assetsync/actions/workflows/test.yml/badge.svg)](https://github.com/stsichler/git-assetsync/actions/workflows/test.yml)
[![License: MIT-0](https://img.shields.io/badge/License-MIT--0-blue.svg)](LICENSE)
![Python 3.8+](https://img.shields.io/badge/python-3.8%2B-blue.svg)
![Platforms](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey.svg)

**Keep files in your repository in sync with release assets of other
projects.** Check in a binary, a firmware image, or headers unpacked from
a ZIP that another project publishes on GitHub or GitLab, see when a new
release is out, and update with one command – with a proposed commit
message that says where it came from.

> **Vibe-coded:** git-assetsync is entirely vibe-coded – all of its code, tests
> and documentation were written by [Claude](https://claude.ai) (Anthropic),
> directed by its author. The regression tests run on Linux, macOS and
> Windows on every push.

```console
$ git assetsync status
Upstream changes to pull:
  (use "git assetsync diff --upstream <file>..." to see what pull would bring)
  (use "git assetsync pull <file>..." to update)
	pending:    bin/tool.bin  (v1.0 -> v1.1)

$ git assetsync pull bin/tool.bin
bin/tool.bin: updated and staged. Commit with:
    git commit
(it offers the proposed commit message; a copy stays in .git/ASSETSYNC_MSG)

$ git commit
```

## Motivation

Projects often need a file that another project builds and publishes: a
tool, a firmware image, a generated header. Downloading it by hand works –
until nobody knows which release the checked-in copy is from, or whether
there is a newer one. git-assetsync records the release and asset of each
such file, tells you when a newer release is out, and updates the file
with a meaningful commit message.

The files are committed, so the repository stays **self-contained**: a
plain clone has everything, and building needs neither git-assetsync nor
access to GitHub or GitLab.

For files from **other Git repositories** there is its sibling
[git-filesync](https://github.com/stsichler/git-filesync), built the same
way.

### Compared to downloading at build time

| | Downloading at build time | git-assetsync |
|---|---|---|
| Your repository contains | a URL or version number | the files themselves |
| Cloning and building | needs network and the release, every time | a plain clone is complete |
| New releases | go unnoticed | `status` shows them; you decide when to `pull` |
| Unpacking, selecting, converting | in each build script | once, in a named filter; the result is committed |
| Updating | edit the URL; the log shows only that | `pull`; the commit names the release, with its notes |

Downloading at build time remains the better choice for big files that
change with every build, or files your repository must not contain.

### Compared to vendoring tools

| | git-assetsync | [vendir](https://carvel.dev/vendir/) | [git-vendor](https://github.com/thejoshwolfe/git-vendor) |
|---|---|---|---|
| Takes content from | release assets on GitHub and GitLab | Git, GitHub releases, HTTP, Helm charts, images, … | Git repositories |
| Which version | latest, newest matching a pattern (by date), or pinned | a tag, the latest release, or semver constraints | a branch, tag or commit |
| Archives | unpacked safely (ZIP, tar, 7z) | unpacked | – |
| Selecting files | include / exclude, subdirectory, strip, move / copy; named, reusable filters | include / exclude, new root | include / exclude |
| Converting with your own tools | yes (e.g. bin2c), in trusted filters | – | – |
| What's new | `status` like `git status` (local state offline) | – | `st` |
| Updating | `pull` stages, with a proposed commit message | writes files and a lock file | stages |
| Local modifications | reported; `pull` refuses them | overwritten | discarded |
| Form | one Python script, standard library only | Go binary | Python script |

vendir is the closest: it vendors many kinds of sources into directories.
git-assetsync is narrower – release assets only – but works the Git way:
`status` and `pull` behave like their Git namesakes, and each update is a
commit that says what it brings.

## Features

- Files and directories from release assets on GitHub and GitLab – also
  GitHub Enterprise, self-managed GitLab and private projects; all entries
  in one file, `.git-assetsync` (git-config format, like `.gitmodules`)
- Built-in filters that run no code: unpack ZIP, tar and 7z safely, take a
  subdirectory, strip directories, include or exclude files, move or copy
  them, make them executable, set line endings; named, and usable by
  entries and other filters
- Your own commands in filters (bin2c, hex2c, …) – run only if you trust
  the filter in your clone
- In a directory, files of your own can sit next to those of the release
- Follows the latest release, the newest whose tag matches a pattern
  (e.g. `tool-*`), or a pinned one; tags are taken as they are, without a
  versioning scheme
- Proposed commit messages name the release, its date and page, the assets
  and the filter, with the release notes shortened – also those of
  releases skipped, and text from the assets (`changelog` step)
- Files must stay what the release gives: local modifications are
  reported, `pull` refuses them, `restore` discards them
- `status` checks local changes offline; downloads are checked against
  GitHub's digests
- Commands named like Git commands behave like them; `-n` for dry runs
- `diff` / `difftool` show local modifications or what `pull` would bring;
  `difftool -d` compares directories (e.g. in Meld)
- Git LFS and line endings: files are stored as `git add` stores them
- A download cache, cleaned up automatically
- Local folders as releases (`source map`), to test a build before
  publishing it; the pre-push hook warns about releases not published yet
- Colored output, reminder hooks, CI-friendly exit codes
- One Python script, standard library only

## Installation

Requirements: Python ≥ 3.8 and Git ≥ 2.28; for GitHub sources the
[GitHub CLI](https://cli.github.com) `gh`, for GitLab sources the
[GitLab CLI](https://gitlab.com/gitlab-org/cli) `glab`, logged in (`gh auth
login`, `glab auth login`) or with a token in `GH_TOKEN` / `GITLAB_TOKEN`;
`git-lfs` for files in Git LFS; 7-Zip for 7z archives. Linux, macOS and
Windows (Git for Windows).

Download `git-assetsync.py` from the
[latest release](https://github.com/stsichler/git-assetsync/releases/latest)
and register a global Git alias:

```sh
# Linux / macOS
mkdir -p ~/tools
curl -fsSLo ~/tools/git-assetsync.py https://github.com/stsichler/git-assetsync/releases/latest/download/git-assetsync.py
git config --global alias.assetsync '!python3 ~/tools/git-assetsync.py'

# Windows (download in the browser or with curl.exe; use forward slashes;
# `py` or `python`, whatever is on PATH)
git config --global alias.assetsync "!py C:/tools/git-assetsync.py"
```

Alternatively (Linux/macOS) put an executable copy named `git-assetsync` on
your `PATH`. Either way it runs as `git assetsync …`; check with `git
assetsync --version`. To update, download the script again; the
[releases](https://github.com/stsichler/git-assetsync/releases) list the
changes.

You can also clone the repository and point the alias at the script:
`main` is the development state, a tag like `v0.23.2` a release. Or let
git-assetsync keep a copy of itself in your project – see [Shipping
git-assetsync with your
repository](MANUAL.md#shipping-git-assetsync-with-your-repository).

## Quick start

```sh
cd my-repo

# 1. Take a file from a release asset (once). It is staged like git add;
#    git commit offers the proposed message. --asset (a glob) must match
#    exactly one asset - not needed if the release has only one.
git assetsync add https://github.com/acme/tool bin/tool --asset 'tool-*-linux-x64'
git commit

# 2. See whether a new release is out
git assetsync status

# 3. Update: staged like git merge --squash, then committed
git assetsync pull bin/tool
git commit
```

Proposed commit message:

```
[assetsync] Update bin/tool to acme/tool v1.1 (2026-10-11, was v1.0 of 2026-10-01)

Release: https://github.com/acme/tool/releases/tag/v1.1
Title:   Tool 1.1
Asset:   tool-1.1-linux-x64

Release notes:
  ## What's Changed
  * Fix crash on empty input
  * Faster startup
```

`--release 'tool-*'` follows the newest release whose tag matches,
`--release v1.0` pins the file; `git assetsync set PATH --release …`
changes that later.

A directory (trailing `/`), unpacked from an archive by a filter; files
of your own may be there too:

```sh
git assetsync filter add zlib-headers --extract --strip 1 --include '/*.h' LICENSE
git assetsync add https://github.com/madler/zlib third_party/zlib/ --asset 'zlib-*.tar.gz' \
    --filter zlib-headers
```

## Commands

Basic commands – what you need day to day:

| Command | Purpose |
|---|---|
| `status [PATH…]` | state of the entries, like `git status`: new releases, local modifications |
| `pull PATH…`, `pull --all` | update to the selected release (`--release`: once another one) and stage, with a proposed commit message |
| `diff [PATH…]`, `difftool [PATH…]` | local modifications; `--upstream`: what `pull` would bring |
| `restore PATH…` | discard local modifications, like `git restore` |
| `add SOURCE PATH` | take a file or directory from release assets |
| `rm PATH…`, `unlink PATH…`, `mv OLD NEW` | remove entries with their files (like `git rm`) or without; move them |

Advanced commands:

| Command | Purpose |
|---|---|
| `set PATH… OPTIONS` | change entries: source, release selection, asset, filter |
| `edit` | open `.git-assetsync` in the editor, then check and stage it |
| `source [ACTION …]` | list sources; rename them, change URL or type |
| `source map [URL\|SOURCE [DIR]]` | take releases from a local folder, to test a build before publishing it |
| `source releases URL\|SOURCE` | list the releases of a project, with their assets |
| `filter [ACTION …]` | list filters; show, test, add, set, rename or remove them |
| `filter trust [NAME…]` | list the filters that run commands; trust them in this repository |
| `verify [PATH…]` | filter the synced assets again: is the committed state reproducible? |
| `cache [ACTION]` | the download cache: show, list, prune, clear |
| `hooks [install\|uninstall]` | reminders after merges and before pushes; check that pushed releases are published |

`git assetsync <command> -h` lists a command's options; the
**[manual](MANUAL.md)** describes everything in detail.

## Development

The whole tool is the single file `git-assetsync.py`. Tests:

```sh
test/regress.sh            # bash (on Windows: Git Bash); needs git, python3, git-lfs for the LFS part
```

The script builds throwaway repositories and plays GitHub and GitLab with
`test/fake_gh.py` and `test/fake_glab.py`, which answer `gh api` / `glab
api` calls from fixture files – no network or account needed. GitHub
Actions runs it on every push, on Linux (also with the oldest supported
Python and Git), macOS and Windows.

Issues and pull requests are welcome. Please add a test to `test/regress.sh`
for any change in behavior.

## License

[MIT No Attribution (MIT-0)](LICENSE) – free to use, also in commercial and
closed-source projects; no attribution required.

## Acknowledgements

This project – design, code, tests and documentation – is developed together
with [Claude](https://claude.ai) by Anthropic.
