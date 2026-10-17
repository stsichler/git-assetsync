# git-assetsync

[![Tests](https://github.com/stsichler/git-assetsync/actions/workflows/test.yml/badge.svg)](https://github.com/stsichler/git-assetsync/actions/workflows/test.yml)
[![License: MIT-0](https://img.shields.io/badge/License-MIT--0-blue.svg)](LICENSE)
![Python 3.8+](https://img.shields.io/badge/python-3.8%2B-blue.svg)
![Platforms](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey.svg)

**Keep files in your repository in sync with release assets of other
projects.** Check in a binary, firmware image or generated file that another
project publishes as a release asset on GitHub or GitLab, see when a new
release is out,
and update it with one command, in a commit that says where it came from.

> git-assetsync is developed together with [Claude](https://claude.ai) by
> Anthropic: design, code, tests and documentation.

```console
$ git assetsync status
Upstream changes to pull:
  (use "git assetsync pull <file>..." to update)
	pending:    bin/tool.bin  (v1.0 -> v1.1)

$ git assetsync pull bin/tool.bin
[main 4f1c2a9] Update bin/tool.bin to acme/tool v1.1 (was v1.0)
 2 files changed, 2 insertions(+), 2 deletions(-)
```

**Status: early development.** The first version covers single files from
releases on GitHub and GitLab. Unpacking archives (all or some of their
files) and converting assets with filters (e.g. binary → C source) are
planned next.

## Why?

Projects often need a file that another project builds and publishes: a
tool binary, a firmware image, a generated header, a data file. Downloading
it by hand works – until nobody knows which release the checked-in copy is
from or whether there is a newer one. git-assetsync records for each such
file the release and asset it comes from, tells you when a newer release
is out, and updates the file with a meaningful commit.

It is a sibling of [git-filesync](https://github.com/stsichler/git-filesync),
which keeps single files in sync with files in other Git repositories, and
built the same way.

## Features

- Takes a file from a release asset on GitHub or GitLab, alike – also
  GitHub Enterprise and self-managed GitLab, and private projects; all files of a repository are listed in one file, `.git-assetsync`, at
  its root (git-config format, like `.gitmodules`)
- Follows the latest release, the newest release whose tag matches a
  pattern (e.g. `tool-*` for one of several tools released from one
  repository), or is pinned to one release; tags are taken as they are,
  without assuming a versioning scheme
- Proposed commit message names the release (and the one before), its page
  and the asset, and includes the release notes, shortened
- `status` works offline for local changes; only the check for new releases
  asks the platform
- Files must stay exact copies of the asset: local modifications are
  reported, `pull` refuses them, `--force` restores the asset
- Checks the download against the digest GitHub reports (GitLab reports
  none)
- Commands named like Git commands behave like them (`status`, `pull`,
  `mv`); dry runs for `pull`, `add`, `unlink`, `mv`
- Git LFS and line-ending conversions: files are recorded as `git add`
  stores them; a hint for big binaries not in LFS
- Colored output, reminder hooks, CI-friendly exit codes
- One self-contained Python script, standard library only

## Installation

Requirements: Python ≥ 3.8, Git ≥ 2.28; for GitHub sources the
[GitHub CLI](https://cli.github.com) `gh`, for GitLab sources the
[GitLab CLI](https://gitlab.com/gitlab-org/cli) `glab` (logged in with
`gh auth login` / `glab auth login`, or a token in `GH_TOKEN` /
`GITLAB_TOKEN`); `git-lfs` for files stored in Git LFS. Linux, macOS and
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
your `PATH`. Either way the tool is invoked as `git assetsync …`; check
with `git assetsync --version`. To update, download the script again; the
[releases](https://github.com/stsichler/git-assetsync/releases) list the
changes of each version.

You can also clone the repository and point the alias at the script in
it: `main` is the current development state, a tag like `v0.2.0` a
release. Or let git-assetsync keep a copy of itself in your project, so
everyone has the same version – see
[Shipping git-assetsync with your repository](MANUAL.md#shipping-git-assetsync-with-your-repository).

## Quick start

```sh
cd my-repo

# 1. Take a file from a release asset (once): fetched and staged like
#    git add, then committed - git commit offers the proposed message.
#    --asset is a glob pattern that must match exactly one asset (not
#    needed if the release has only one).
git assetsync add bin/tool acme/tool --asset 'tool-*-linux-x64'
git commit

# 2. See whether a new release is out
git assetsync status

# 3. Update – the editor opens with the proposed commit message
git assetsync pull bin/tool
```

Proposed commit message:

```
Update bin/tool to acme/tool v1.1 (was v1.0)

Release: https://github.com/acme/tool/releases/tag/v1.1
Title:   Tool 1.1
Asset:   tool-1.1-linux-x64

Release notes:
  ## What's Changed
  * Fix crash on empty input
  * Faster startup
```

Each commit contains the file and its updated entry in `.git-assetsync`.
`--release` selects other releases: `--release 'tool-*'` follows the
newest release whose tag matches, `--release v1.0` pins the file to that
release. `git assetsync source set-release` changes that later.

## Commands

| Command | Purpose |
|---|---|
| `status [PATH…]` | state of the files, like `git status`: new releases, local modifications |
| `pull PATH…`, `pull --all` | update files to the selected release and commit |
| `add PATH SOURCE` | take a file from a release asset |
| `set PATH… OPTIONS` | change entries: source, release selection, asset |
| `unlink PATH…`, `mv OLD NEW` | remove or move entries |
| `source [ACTION …]` | list sources; rename them, change URL, release selection or type |
| `install-hooks`, `uninstall-hooks` | reminder hooks for `push` and `merge` |

`git assetsync <command> -h` lists the options of a command. The
**[manual](MANUAL.md)** describes all commands and options in detail,
along with the `.git-assetsync` file, release selection, GitHub and GitLab access,
Git LFS, line endings and CI.

## Development

The whole tool is the single file `git-assetsync.py`. Tests:

```sh
test/regress.sh            # Linux/macOS (bash); needs git, python3, git-lfs for the LFS part
```

The script builds throwaway repositories in a temp directory and plays
GitHub and GitLab with `test/fake_gh.py` and `test/fake_glab.py`, which
answer `gh api` / `glab api` calls from fixture files – no network or
account needed. It checks adding, status,
pull, release selection (latest, patterns, pinned, prereleases, drafts,
paging), asset selection and digests, local modifications, the
`.git-assetsync` file (sources, unlink, mv, commit consistency), commit
proposals, offline status, line endings, Git LFS, unsafe registry entries,
GitHub Enterprise, GitLab (also self-managed, subgroups, the kinds of asset
links), dry runs, hooks and colors. It runs on every push via
GitHub Actions, on Linux (also with the oldest supported Python and Git),
macOS and Windows.

Issues and pull requests are welcome. Please add a test to `test/regress.sh`
for any change in behavior.

## License

[MIT No Attribution (MIT-0)](LICENSE) – free to use, also in commercial and
closed-source projects; no attribution required.

## Acknowledgements

This project – design, code, tests and documentation – is developed together
with [Claude](https://claude.ai) by Anthropic.
