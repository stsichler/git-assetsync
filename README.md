<img src="doc/logo.svg" alt="" width="128" align="right">

# git-assetsync

[![Tests](https://github.com/stsichler/git-assetsync/actions/workflows/test.yml/badge.svg)](https://github.com/stsichler/git-assetsync/actions/workflows/test.yml)
[![License: MIT-0](https://img.shields.io/badge/License-MIT--0-blue.svg)](LICENSE)
![Python 3.8+](https://img.shields.io/badge/python-3.8%2B-blue.svg)
![Platforms](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey.svg)

**Keep files in your repository in sync with release assets of other
projects.** Check in a binary, a firmware image, or headers and libraries
unpacked from a ZIP that another project publishes as release assets on
GitHub or GitLab, see when a new release is out, and update with one
command – with a proposed commit message that says where it came from.

```console
$ git assetsync status
Upstream changes to pull:
  (use "git assetsync diff --upstream <file>..." to see what pull would bring)
  (use "git assetsync pull <file>..." to update)
	pending:    bin/tool.bin  (v1.0 -> v1.1)

$ git assetsync pull bin/tool.bin
[main 4f1c2a9] Update bin/tool.bin to acme/tool v1.1 (was v1.0)
 2 files changed, 2 insertions(+), 2 deletions(-)
```

## Why?

Projects often need a file that another project builds and publishes: a
tool binary, a firmware image, a generated header, a data file. Downloading
it by hand works – until nobody knows which release the checked-in copy is
from or whether there is a newer one. git-assetsync records for each such
file the release and asset it comes from, tells you when a newer release
is out, and updates the file with a meaningful commit message.

Because each file is committed in your repository, the repository stays
**self-contained**: after a plain clone or checkout every file is there –
unlike with downloads at build time, nothing has to be fetched from other
projects, and neither git-assetsync nor access to GitHub or GitLab is
needed to build.

For single files kept in sync with files in **other Git repositories**
there is its sibling
[git-filesync](https://github.com/stsichler/git-filesync), built the same
way.

### Compared to downloading at build time

| | Downloading at build time (scripts, build systems) | git-assetsync |
|---|---|---|
| What your repository contains | a URL or version number of the asset | the file itself (or the files unpacked from it), committed like any other file |
| Cloning and building | needs network and access to the release, every time – and the release must still be there | a plain clone is complete and works on its own |
| Which version | whatever the URL or script says; newer releases go unnoticed | `status` shows new releases; you decide when to `pull` |
| Unpacking, selecting, converting | in each build script, its own way | once, in a named filter, and the result is committed |
| Updating | edit the URL or version; the log shows only that | `pull`; the commit contains the actual change and names the release, with its notes |
| For everyone else | the same downloads on every machine and CI run | nothing – only whoever updates needs git-assetsync |

Downloading at build time remains the better choice for big files that
change with every build, or when your repository must not contain them;
git-assetsync fits when the files belong to your project's sources – a
tool, a firmware image, a generated header – and should be versioned with
them.

### Compared to vendoring tools

| | git-assetsync | [vendir](https://carvel.dev/vendir/) | [git-vendor](https://github.com/thejoshwolfe/git-vendor) |
|---|---|---|---|
| Takes content from | release assets on GitHub and GitLab | Git, GitHub releases, HTTP, Helm charts, images, … | Git repositories |
| Which version | the latest release, the newest whose tag matches a pattern (by date), or a pinned one | a tag, the latest release, or semver constraints | a branch, a tag or a commit |
| Archives | unpacked safely (ZIP, tar, 7z with 7-Zip) | unpacked (one archive per release) | – |
| Selecting files | include / exclude, subdirectory, strip, move / copy into a new structure; named filters, reusable and per asset | include / exclude paths, new root | include / exclude |
| Converting with tools of your own | yes (e.g. bin2c), in filters you trust | – | – |
| What's new | `status` like `git status`: new releases, local modifications (those offline) | – (`sync` fetches and writes) | `st` |
| Updating | `pull` stages, with a proposed commit message naming the release and its notes | writes the files and a lock file | stages the changes |
| Local modifications | reported; `pull` refuses them, `--overwrite` discards | overwritten | discarded |
| Form | one Python script, standard library only | Go binary | Python script |

vendir is the closest: it vendors many kinds of sources declaratively into
directories, often for Kubernetes configuration. git-assetsync is narrower
– release assets only – but works the Git way: files, directories and their
state are part of the repository, `status` and `pull` behave like their Git
namesakes, and each update is a commit that says what it brings. git-vendor
copies content of other Git repositories, with filters – for single files
from other Git repositories see git-filesync.

## Features

- Takes files and directories from release assets on GitHub or GitLab,
  alike – also GitHub Enterprise and self-managed GitLab, and private
  projects; all entries of a repository are listed in one file,
  `.git-assetsync`, at its root (git-config format, like `.gitmodules`)
- Built-in filters, without running any code: unpack ZIP, tar and – with
  7-Zip installed – 7z archives safely, take a subdirectory, strip leading
  directories, include or exclude files by pattern, move and copy files
  into a new structure; filters are named, used by any number of entries
  and by each other (e.g. per asset); in a directory, files of your own
  can be next to those of the release, which an update replaces or deletes
- Converting files with commands of your own (bin2c, hex2c, …), per file
  or for all at once – run only if you trust the filter in your clone
- Follows the latest release, the newest release whose tag matches a
  pattern (e.g. `tool-*` for one of several tools released from one
  repository), or is pinned to one release; tags are taken as they are,
  without assuming a versioning scheme
- Proposed commit message names the release (and the one before), its page,
  the assets and the filter, and includes the release notes, shortened -
  also those of releases skipped by the update, and with a `changelog`
  filter step text from the assets (e.g. a `CHANGELOG.txt` in an archive)
- `status` works offline for local changes; only the check for new releases
  asks the platform
- Files must stay exactly what the release gives: local modifications are
  reported, `pull` refuses them, `restore` discards them
- Checks the download against the digest GitHub reports (GitLab reports
  none)
- Commands named like Git commands behave like them (`status`, `pull`,
  `diff`, `restore`, `mv`); dry runs for `pull`, `add`, `unlink`, `mv`
- `diff` / `difftool` show local modifications, or what `pull` would
  bring (with `--release`: another release, e.g. to go back to an older
  one once); `difftool -d` compares directories at once (e.g. in Meld)
- Git LFS and line-ending conversions: files are recorded as `git add`
  stores them; a hint for big binaries not in LFS
- A download cache, so another filter or a second repository needs no new
  download; cleaned up automatically (files unused for 90 days, optionally
  a size limit)
- Local folders as releases (`source map`, like git-filesync's): test a build in
  another repository before publishing it; several sources can share a
  folder (`--pattern`), the newest release by name instead of file date
  (`--sort name`); the pre-push hook warns about entries whose release
  isn't published yet
- Colored output, reminder hooks, CI-friendly exit codes
- One self-contained Python script, standard library only

## Installation

Requirements: Python ≥ 3.8, Git ≥ 2.28; for GitHub sources the
[GitHub CLI](https://cli.github.com) `gh`, for GitLab sources the
[GitLab CLI](https://gitlab.com/gitlab-org/cli) `glab` (logged in with
`gh auth login` / `glab auth login`, or a token in `GH_TOKEN` /
`GITLAB_TOKEN`); `git-lfs` for files stored in Git LFS; 7-Zip to unpack
7z archives. Linux, macOS and
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
it: `main` is the current development state, a tag like `v0.19.4` a
release. Or let git-assetsync keep a copy of itself in your project, so
everyone has the same version – see
[Shipping git-assetsync with your repository](MANUAL.md#shipping-git-assetsync-with-your-repository).

## Quick start

```sh
cd my-repo

# 1. Take a file from a release asset (once): fetched and staged like
#    git add, then committed - git commit offers the proposed message.
#    The source is the URL of the project on GitHub or GitLab; it is
#    recorded as source 'acme/tool'. --asset is a glob pattern that must
#    match exactly one asset (not needed if the release has only one).
git assetsync add bin/tool https://github.com/acme/tool --asset 'tool-*-linux-x64'
git commit

# 2. See whether a new release is out
git assetsync status

# 3. Update: staged like git merge --squash, then committed - git commit
#    offers the proposed message
git assetsync pull bin/tool
git commit
```

Proposed commit message:

```
[assetsync] Update bin/tool to acme/tool v1.1 (was v1.0)

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
release. `git assetsync set PATH --release …` changes that later.

A directory, unpacked from an archive by a filter – with a trailing `/`; files
of your own may be there too:

```sh
git assetsync filter add zlib-headers --extract --strip 1 --include '/*.h' LICENSE
git assetsync add third_party/zlib/ https://github.com/madler/zlib --asset 'zlib-*.tar.gz' \
    --filter zlib-headers
```

## Commands

Basic commands – what you need day to day:

| Command | Purpose |
|---|---|
| `status [PATH…]` | state of the entries, like `git status`: new releases, local modifications |
| `pull PATH…`, `pull --all` | update files and directories to the selected release (`--release`: once another one) and stage them, with a proposed commit message |
| `diff [PATH…]`, `difftool [PATH…]` | local modifications; `--upstream`: what `pull` would bring – in your difftool also as two directories (`-d`) |
| `restore PATH…` | discard local modifications: back to what the release gave, like `git restore` |
| `add PATH SOURCE` | take a file or directory from release assets |
| `rm PATH…`, `unlink PATH…`, `mv OLD NEW` | remove entries with their files (like `git rm`) or without, move them |

Advanced commands:

| Command | Purpose |
|---|---|
| `set PATH… OPTIONS` | change entries: source, release selection, asset, filter |
| `edit` | open `.git-assetsync` in the editor, then check and stage it |
| `source [ACTION …]` | list sources; rename them, change URL or type |
| `source map [URL\|SOURCE [DIR]]` | take releases from a local folder, to test a build before publishing it |
| `source releases SOURCE\|URL` | list the releases of a project, with their assets |
| `filter [ACTION …]` | list filters; show, test, add, set, rename or remove them |
| `filter trust [NAME…]` | list the filters that run commands; trust them in this repository |
| `verify [PATH…]` | filter the synced assets again: is the committed state reproducible? |
| `cache [ACTION]` | the download cache: show, list, prune, clear |
| `hooks [install\|uninstall]` | hooks for `push` and `merge`: reminders, check that pushed entries' releases are published |

`git assetsync <command> -h` describes a command and lists its options. The
**[manual](MANUAL.md)** describes all commands and options in detail,
along with the `.git-assetsync` file, files and directories, filters,
release selection, GitHub and GitLab access, the download cache,
Git LFS, line endings and CI.

## Development

The whole tool is the single file `git-assetsync.py`. Tests:

```sh
test/regress.sh            # Linux/macOS (bash); needs git, python3, git-lfs for the LFS part
```

The script builds throwaway repositories in a temp directory and plays
GitHub and GitLab with `test/fake_gh.py` and `test/fake_glab.py`, which
answer `gh api` / `glab api` calls from fixture files – no network or
account needed. It checks adding, status, pull, release selection
(latest, patterns, pinned, prereleases, drafts, paging), asset selection
and digests, local modifications, directories and filters, archive formats
(7z with a real 7-Zip where installed) and unsafe archive members, the download cache, the `.git-assetsync` file
(sources, set, unlink, mv, commit consistency), commit proposals, offline
status, line endings, Git LFS, unsafe registry entries, GitHub Enterprise,
GitLab (also self-managed, subgroups, the kinds of asset links), dry runs,
hooks and colors. It runs on every push via
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
