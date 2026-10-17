# git-assetsync manual

Detailed description of the concepts, commands and options of
git-assetsync. For motivation and installation see the [README](README.md).

## Contents

- [Concepts](#concepts)
  - [Sources, releases and assets](#sources-releases-and-assets)
  - [The `.git-assetsync` file](#the-git-assetsync-file)
  - [No local modifications](#no-local-modifications)
- [Commands](#commands)
  - [Common options](#common-options)
  - [`status`](#status) · [`pull`](#pull) · [`add`](#add) · [`unlink`](#unlink) · [`mv`](#mv) · [`source`](#source)
  - [`install-hooks`, `uninstall-hooks`](#install-hooks-uninstall-hooks)
- [Further topics](#further-topics)
  - [Selecting the release](#selecting-the-release) · [Proposed commit messages](#proposed-commit-messages)
  - [GitHub and GitLab access](#github-and-gitlab-access) · [Integrity](#integrity)
  - [Git LFS](#git-lfs) · [Line endings](#line-endings) · [Offline operation](#offline-operation)
  - [Colors](#colors) · [CI](#ci) · [Exit codes](#exit-codes) · [Windows](#windows)
  - [Shipping git-assetsync with your repository](#shipping-git-assetsync-with-your-repository)

## Concepts

### Sources, releases and assets

A **source** is a project that publishes releases: a repository on GitHub
(also GitHub Enterprise) or a project on GitLab (gitlab.com or
self-managed), alike. A **release** is identified by its **tag**
(e.g. `v1.3.1` or `tool-20261016`); its title is only shown. Each release
has **assets**: the files attached to it.

git-assetsync takes a file of your repository from an asset: it downloads
the asset, writes it to the file's path and records in `.git-assetsync`
which release and asset the file comes from. Which release that is, is
decided by the source: the latest release, the newest one whose tag
matches a pattern, or one fixed release (see
[Selecting the release](#selecting-the-release)). Which asset of it, is
decided by the file's entry: a glob pattern that must match exactly one
asset name – asset names usually contain the version, so the pattern stays
the same across releases while the file's path in your repository doesn't
change.

Updates are never applied automatically: `status` shows that a new release
is out, `pull` updates the file and commits it with a message naming the
release. All commands run inside your repository.

### The `.git-assetsync` file

Lives at the root of the repository and is committed like any other file.
Git-config format:

```ini
[source "acme/tool"]
	url = https://github.com/acme/tool
[file "bin/tool"]
	source = acme/tool
	asset = tool-*-linux-x64     # asset of the release: glob, exactly one match
	                             # (optional: without, the release's only asset)
	synced = v1.1                # tag of the release the file comes from
	digest = sha256:5b2c…        # SHA-256 of that asset
	blob = 8d01b7aa…             # the file as committed (git's blob id)
[source "acme/multi"]
	url = https://github.com/acme/multi
	release = toolA-*            # newest release whose tag matches
	prerelease = true            # optional: prereleases count too
[file "firmware/fw.bin"]
	source = acme/multi
	asset = fw-*.bin
	synced = toolA-20261016
	digest = sha256:…
	blob = …
```

- **`[source "NAME"]`** – a project and which of its releases to take.
  `url` is its web address. Without `release`, the source follows the
  latest release; `release` is a tag (the source is pinned to that
  release) or a pattern with `*`, `?` or `[…]` (the newest release whose
  tag matches). `prerelease = true` lets prereleases count. `type`
  (`github` or `gitlab`) names the platform; it is only needed for hosts
  other than github.com, gitlab.com and those whose name starts with
  `gitlab` (like `gitlab.example.com`). `add` names new sources
  `owner/repo` after the URL, with a number appended if that name is
  taken (`acme/tool-2`: same project, other release selection).
- **`[file "PATH"]`** – a file of the repository (path relative to the
  root) and the asset it comes from: `source` (name of its `[source]`) and
  `asset` (glob pattern; without it, the release's only asset) say what
  to take. `synced`, `digest` and `blob`
  are written by git-assetsync and record what the committed file is
  based on: the release tag, the asset's SHA-256 and the id of the file
  as `git add` stores it (after line-ending conversion and Git LFS). With
  `blob`, `status` knows offline whether the committed file and the
  working tree file are still the asset.

All files of a source take the same release, e.g. a header and a library
published together. To follow a different release of the same project,
use a second source with the same URL (`add` does that when `--release`
differs).

The commands maintain the file: `add`, `unlink` and `mv` for the
`[file]` entries, [`source`](#source) for the `[source]` sections. It can
also be edited by hand (or with `git config -f .git-assetsync …`), but that
is never needed; `synced`/`digest`/`blob` should be left to git-assetsync.
An entry written by hand without them is fetched by the next `pull` (an existing file at its
path is only replaced if it is the same, or with `--force`). Changes to
the file are committed along with the next `pull` – or, if they concern
other files' entries, that `pull` refuses until they are committed (see
[`pull`](#pull)).

### No local modifications

A file taken from an asset must stay an exact copy of it – a binary or a
generated file can't be merged with local changes. A file that differs
from its asset – committed or not, also deleted – is reported by `status`
as **NOT ALLOWED**, `status --exit-code` exits with 1, and `pull` refuses
to update it. `pull --force` discards the modification and restores the
asset of the selected release (with a warning, and a note in the commit
message).

What counts is the content, not how it is stored: a file that is
re-stored differently after `.gitattributes` changed (moved to Git LFS,
line endings normalized) is still unmodified.

## Commands

| Command | Purpose |
|---|---|
| `status [PATH…]` | state of the files, like `git status` |
| `pull PATH…`, `pull --all` | update files to the selected release and commit |
| `add PATH SOURCE` | take a file from a release asset |
| `unlink PATH…` | remove entries (the files are kept) |
| `mv OLD NEW` | move a file, keeping its entry |
| `source [ACTION …]` | list sources; rename them, change URL, release selection or type |
| `install-hooks`, `uninstall-hooks` | reminder hooks for `push` and `merge` |

Without a command, `status` runs. `PATH` may be a file or a directory (all
entries below it) and is relative to the current directory. Options follow
the command; `git assetsync <command> -h` lists them.

### Common options

| Option | Meaning |
|---|---|
| `--color[=WHEN]`, `--no-color` | colored output: `always`, `never` or `auto` (default), see [Colors](#colors) |

### `status`

```
git assetsync status [PATH…] [-s] [-v] [--exit-code] [--hook] [--no-fetch]
```

Shows the state of the files (default: all) in sections like `git status`:

```
Upstream changes to pull:
  (use "git assetsync pull <file>..." to update)
	pending:    bin/tool  (v1.0 -> v1.1)
	new:        firmware/fw.bin  (release toolA-20261016)

Locally modified files:
  (use "git assetsync pull --force <file>..." to restore the release asset)
	modified:   lib/data.bin  (NOT ALLOWED)

Uncommitted changes:
  (use "git restore <file>..." to discard uncommitted changes)
	modified:   bin/tool  (NOT ALLOWED)
```

- **Upstream changes to pull** – `pending`: the source selects another
  release than the one the file comes from (`v1.0 -> v1.1`), or the asset
  of that release was replaced (re-uploaded with other content). `new`:
  an entry without a synced release yet, or a file not in the working tree
  yet.
- **Locally modified files** – the committed file differs from its asset.
- **Uncommitted changes** – the working tree file differs from the
  committed one (`modified`, `deleted`, `new file`); marked NOT ALLOWED
  if it differs from the asset, too.

With nothing to report: `nothing to pull, all N files unmodified`. Errors
(no release found, the asset pattern matches no or several assets, broken
entries) are printed on stderr for the file concerned; the other files are
shown as usual. The hints in parentheses follow `advice.statusHints`.

| Option | Meaning |
|---|---|
| `-s`, `--short` | one line per file with something to report, three columns like `git status -s`: upstream (`P` pending, `N` new, `E` error), committed (`A` modified), working tree (`M` modified, `D` deleted, `?` not committed yet) |
| `-v`, `--verbose` | also list all files with asset, source, release selection and synced release |
| `--exit-code` | exit with 1 if something is to pull or a file is modified |
| `--hook` | terse output on stderr, for hooks (see [`install-hooks`](#install-hooks-uninstall-hooks)) |
| `--no-fetch` | don't ask GitHub or GitLab for new releases: only local modifications are shown, see [Offline operation](#offline-operation) |

Like `git status`, it exits with 0 unless `--exit-code` is given; errors
exit with 2.

### `pull`

```
git assetsync pull (PATH… | --all) [--force] [--no-edit] [--no-commit] [-n]
```

Updates each given file to the asset of the release its source selects,
and commits it together with its entry in `.git-assetsync` – one commit
per file. The editor opens with the [proposed message](#proposed-commit-messages)
unless `--no-edit` is given. A file that is up to date is reported as such.

`pull` refuses a file with local modifications, committed or not (see
[No local modifications](#no-local-modifications)); the other files are
pulled anyway, and the exit code is 2.

`pull` commits only the file and `.git-assetsync`. If `.git-assetsync`
has uncommitted changes to entries of other files, it refuses, since the
commit would take them along without their files; commit them first, or
use `--no-commit`. Uncommitted changes to `[source]` sections are fine:
they go into the commit – e.g. change `release` of a source and pull, in
one commit.

| Option | Meaning |
|---|---|
| `--all` | all files with something to pull (with `--force` also modified ones) |
| `--force` | discard local modifications: restore or update the file anyway |
| `--no-edit` | commit with the proposed message, without opening the editor |
| `--no-commit` | update and stage only; a plain `git commit` then offers the proposed message (via `.git/SQUASH_MSG`) |
| `-n`, `--dry-run` | only report what would happen; nothing is downloaded or changed |

If the commit is not done (e.g. the editor is closed with an empty
message, or a hook rejects it), the changes stay staged and `pull` tells
how to commit them with the proposed message; the exit code is then 1.

### `add`

```
git assetsync add PATH SOURCE [--asset PATTERN] [--release TAG|PATTERN] [--prerelease] [--type github|gitlab] [--force] [-n]
```

The arguments are in the same order as for `git filesync add`. Takes the
file `PATH` from an asset of the release `SOURCE` selects: downloads it, writes it to `PATH`, records the entry in
`.git-assetsync` and stages both – like `git add`, without committing. A
plain `git commit` then offers the proposed message (`git commit --no-edit`
takes it as it is).

- **`PATH`** is the file in your repository, relative to the current
  directory. Its name doesn't have to be the asset's, and stays the same
  when later assets are named differently.
- **`SOURCE`** is the name of a `[source]` in `.git-assetsync`, or a URL
  (`https://github.com/owner/repo`, `https://gitlab.com/group/project`,
  also with subgroups; the URL of any page of the project works as well);
  `owner/repo` is short for a repository on github.com. A URL takes the source with that URL and the
  same release selection, or creates one. A source name takes that source
  with its release selection – unless `--release`/`--prerelease` ask for
  another one, then its URL with that selection.
- **`--asset PATTERN`** selects the asset: a glob pattern (`*`, `?`,
  `[…]`) that must match exactly one asset of the release, e.g.
  `--asset 'tool-*-linux-x64.tar.gz'`. Quote it, so the shell doesn't
  expand it. The pattern is recorded and used for later releases, too.
  Without `--asset`, the release must have exactly one asset, which is
  taken; no pattern is recorded, and a later release with more than one
  asset is an error until you choose one
  (`git assetsync add --force PATH SOURCE --asset PATTERN`).

| Option | Meaning |
|---|---|
| `--asset PATTERN` | the asset to take (glob, must match exactly one; default: the release's only asset) |
| `--release TAG\|PATTERN` | release to take: a tag pins the source to that release, a pattern takes the newest release whose tag matches (default: the latest release) |
| `--prerelease` | prereleases count too (with a pattern, or instead of the latest release) |
| `--type github\|gitlab` | platform of the URL's host; needed for hosts other than github.com, gitlab.com and `gitlab.*` |
| `--force` | replace an existing entry for `PATH`, or overwrite an existing file that differs from the asset |
| `-n`, `--dry-run` | only show which release and asset would be taken; nothing is downloaded |

An existing file at `PATH` is only overwritten with `--force`, unless it is
already the asset. For a big binary file (1 MiB or more) that is not stored
in Git LFS, `add` warns and suggests `git lfs track`: each update adds
another copy to the repository's history.

### `unlink`

```
git assetsync unlink PATH… [-n]
```

Removes the entries (and sources no longer used) from `.git-assetsync`
and stages it; the files themselves are kept as ordinary files. Commit
when you like. A broken entry that `status` reports as unsafe (e.g. a path
outside the working tree) is removed by giving its name as it is in the
file.

### `mv`

```
git assetsync mv OLD NEW [-n]
```

Moves a file (with `git mv`) and its entry, and stages both. `NEW` may be
an existing directory.

### `source`

```
git assetsync source [-v [--no-fetch]]
git assetsync source rename OLD NEW
git assetsync source set-url NAME URL
git assetsync source set-release NAME (TAG|PATTERN | --unset) [--prerelease | --no-prerelease]
git assetsync source set-type NAME (github|gitlab | --unset)
```

Lists and changes the `[source]` sections, like `git remote` does for
remotes. The changing actions only change `.git-assetsync` and stage it;
`status` then shows what changes for the files of the source, and `pull`
updates them and commits the change of the source along with them.

| Action | Meaning |
|---|---|
| (none) | list the sources; `-v`: with URL, release selection, file count and the release the source selects now (asked from the platform; `--no-fetch`: not) |
| `rename OLD NEW` | rename a source and all references to it |
| `set-url NAME URL` | change the URL, e.g. after the project moved |
| `set-release NAME TAG\|PATTERN` | select another release: a tag pins the source to it, a pattern takes the newest matching release (see [Selecting the release](#selecting-the-release)) |
| `set-release NAME --unset` | follow the latest release again |
| `--prerelease`, `--no-prerelease` | (with `set-release`, also alone) let prereleases count, or not |
| `set-type NAME github\|gitlab` | the platform of the host; `--unset`: derived from the host again |

Two sources with the same URL and release selection are not allowed: a
change that would make one the same as another is refused, with a hint
to move the files to the other one (`add --force <file> <source>`).

To give only some files of a source another release selection, add them
again with the URL and the new selection, e.g.
`git assetsync add --force lib/x.h https://github.com/acme/lib --release v2.0`
– they get a source of their own.

### `install-hooks`, `uninstall-hooks`

`install-hooks` installs two hooks that never block:

- `pre-push`: `git assetsync status --hook` – reminds of new releases and
  local modifications before pushing
- `post-merge`: `git assetsync status --hook --no-fetch` – reminds of local
  modifications after `git pull`/`git merge`, without asking GitHub or GitLab

Existing hooks are not changed; `install-hooks` prints the lines to add
instead. `uninstall-hooks` removes the hooks, or only its lines from hooks
that contain other commands as well. With `core.hooksPath` set, the hooks
go there (with a warning, since other repositories may use it).

## Further topics

### Selecting the release

The `release` key of a source (or `add --release`) decides which release
its files take:

| `release` | Release taken |
|---|---|
| (none) | the **latest** release, as the platform defines it – GitHub: the one marked as latest, otherwise the newest that is neither a prerelease nor a draft; GitLab: the newest by release date |
| a tag, e.g. `v1.0` | exactly that release (**pinned**); also if it is a prerelease |
| a pattern, e.g. `tool-*` | the **newest release by publication date** whose tag matches |

Tags are taken as opaque strings: there is no versioning scheme, and they
are never compared or sorted by name. "Newest" always means the date the
platform reports (GitLab: the release date) – so a pattern works for tags like `v1.2.3`, date tags like
`tool-20261016`, and repositories that release several tools under
different tag prefixes. A pattern without wildcard characters is an exact
tag. There is no reserved value like `latest`: a tag could be called that.

Drafts never count. Prereleases count only with `prerelease = true`
(`add --prerelease`): with a pattern, the newest matching release including
prereleases; without one, the newest release including prereleases.

If the selected release has no asset matching the entry's pattern, or more
than one, that is an error – also when an older release would have one, so
a renamed asset doesn't go unnoticed. Change the pattern with
`git assetsync add --force PATH SOURCE --asset 'NEW-*'`, which fetches the
file again and stages it with its entry.

To switch a source to another release selection, use
[`source set-release`](#source) (e.g.
`git assetsync source set-release acme/tool v2.0`) and pull its files; the
change is committed with them.

### Proposed commit messages

```
Update bin/tool to acme/tool v1.1 (was v1.0)

Release: https://github.com/acme/tool/releases/tag/v1.1
Title:   Tool 1.1
Asset:   tool-1.1-linux-x64

Release notes:
  ## What's Changed
  * Fix crash on empty input by @someone in https://github.com/acme/tool/pull/42
  * Faster startup

  **Full Changelog**: https://github.com/acme/tool/compare/v1.0...v1.1
```

The subject names the file, the source and the release – `Add …` for a new
file, `Update … to … (was …)` for another release, `Update … (asset
replaced)` when the asset of the same release changed, `Restore …` when
`pull --force` brought back the asset after local modifications. The body
links the release page and names its title (if it differs from the tag)
and the asset.

When the file is updated to another release, its **release notes** (the
description on the release page) follow, shortened, so the log tells what
changed without following the link: at most 20 lines of at most 200
characters (cut lines end in `[...]`, a cut text with a hint at the
release page), HTML comments (left over from templates) and repeated blank
lines dropped. They are indented by two spaces – otherwise `git commit`
would take Markdown headings like `## What's Changed` for comment lines and
remove them when the editor opens. Only the notes of the new release are
included, not those of releases in between.

`add` and `pull --no-commit` stage only and put the proposal into
`.git/SQUASH_MSG`, which a plain `git commit` offers (as do IDEs like VS
Code); proposals of several commands are collected, and git removes the
file after the commit. If `.git/SQUASH_MSG` is in use by git itself (after
`git merge --squash`), it is left alone, and the command prints a
`git commit -F` command with a message file instead.

### GitHub and GitLab access

git-assetsync asks the platforms through their command-line tools, used
only as authenticated HTTP clients: `gh api` for GitHub
([GitHub CLI](https://cli.github.com)), `glab api` for GitLab
([GitLab CLI](https://gitlab.com/gitlab-org/cli)). So it works with
whatever they are logged in to – `gh auth login` / `glab auth login`, or a
token in `GH_TOKEN` / `GITLAB_TOKEN` (e.g. in CI); for public GitLab
projects `glab` works without login, too. Private projects need read
access. For GitHub Enterprise or a self-managed GitLab, log in to the
host (`gh auth login --hostname HOST`, `glab auth login --hostname HOST`).
The host is always passed on, so `GH_HOST` or the repository you run in
doesn't redirect the requests. Only the tool for the platforms you use is
needed.

`status` asks once per source (the latest release, or the release of the
tag); a pattern lists all releases (100 per request).

Downloads: on GitHub through the asset's API URL. On GitLab, the assets of
a release are its **links** (the release's automatically generated source
archives are not assets). A link to an API URL on the project's host – as
for files in the generic package registry, the usual way to attach build
results – is downloaded through `glab api`, with your login; so are links
to job artifacts (`…/-/jobs/ID/artifacts/raw/…`) and project uploads
(`…/uploads/…`) on that host, via their API counterparts. Links to other
servers are downloaded plainly, without login – they have to be public
(`http://` links work, with a warning).

On GitLab, releases with a release date in the future ("upcoming
releases") count as prereleases: they are skipped unless the source has
`prerelease = true`. There are no drafts there.

`ASSETSYNC_GH` / `ASSETSYNC_GLAB` set other commands instead of `gh` /
`glab`, split like a shell would (e.g. `ASSETSYNC_GH="/opt/gh/bin/gh"`; on
Windows use forward slashes). The tests use them to play GitHub and GitLab
without network.

### Integrity

GitHub reports a SHA-256 digest for each asset (for assets uploaded since
June 2025); the download is checked against it and refused if it differs.
For older assets, the digest is computed from the download; their size is
checked. Either way the digest is recorded in the entry, and a later
change of the asset in the same release (a re-upload with other content)
shows up as pending – if GitHub reports digests for it.

GitLab reports no digests: the digest is computed from the download, and
a re-uploaded asset of the same release is not noticed.

### Git LFS

git-assetsync stores a file exactly as `git add` would: if `.gitattributes`
puts it into Git LFS, it is committed as an LFS pointer, and the recorded
`blob` is the pointer's id. To put a file into LFS from the start, run
`git lfs track PATH` before `add` (`add` suggests it for big binaries).

A file moved to LFS later (`git lfs track` + `git add --renormalize`) stays
unmodified: the pointer's hash is the asset's digest. Requires `git-lfs`
for files stored in LFS.

### Line endings

Files are stored as `git add` stores them and written as `git checkout`
writes them, so `text=auto`, `eol` attributes and `core.autocrlf` apply as
for any other file: an asset with CRLF line ends is committed normalized in
a `text=auto` repository; with `core.autocrlf=true`, a text asset gets
CRLF in the working tree. Changing these settings afterwards doesn't make
files count as modified. To keep an asset byte for byte, mark it `-text`
(or `binary`) in `.gitattributes`.

### Offline operation

`status` works without network for everything local: whether the committed
and working tree files are still their assets is decided from the recorded
`blob`. Only the check for new releases needs GitHub or GitLab;
`--no-fetch` skips it (`new releases not checked`). `add` and `pull`
always need them.

### Colors

Output is colored like `git status`: pending updates yellow, committed
modifications cyan, uncommitted changes red, NOT ALLOWED and errors bold
red.

Colors follow `color.assetsync`, falling back to `color.ui` (default: on
for terminals); `--color[=always|never|auto]` and `--no-color` override
that, and `NO_COLOR` turns colors off. Hook output on stderr is colored the
same way.

### CI

A scheduled job fails when a new release is out or a file was modified
(`status --exit-code`), so e.g. GitHub notifies you:

```yaml
name: assetsync
on:
  schedule: [{ cron: "23 6 * * 1" }]
  workflow_dispatch:
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: curl -fsSLo /tmp/git-assetsync.py https://github.com/stsichler/git-assetsync/releases/latest/download/git-assetsync.py
      - run: python3 /tmp/git-assetsync.py status --exit-code
        env:
          GH_TOKEN: ${{ github.token }}
```

This uses the latest release. To pin a version, download
`https://github.com/stsichler/git-assetsync/releases/download/v0.2.0/git-assetsync.py`
instead. `gh` is preinstalled on GitHub's runners; `GH_TOKEN` logs it in. For
sources in other private repositories, use a token with read access to
them. For GitLab sources, install `glab` in the job (and give
`GITLAB_TOKEN` for private projects).

### Exit codes

| Code | Meaning |
|---|---|
| `0` | ok |
| `1` | unfinished: `pull` without the commit done; `status --exit-code` with something to pull or a modified file |
| `2` | error (also: `pull` refused a modified file) |

`--dry-run` / `-n` exit with 0, or 2 on errors.

### Windows

git-assetsync runs with Git for Windows and a Python from python.org (or
the Microsoft Store); set the alias with `py` or `python`, see the
[README](README.md). Output has LF line ends, like git's.

Git for Windows runs the alias through its own (MSYS) shell, also when you
call `git assetsync` from cmd or PowerShell. That shell changes two kinds of
arguments before git-assetsync sees them:

- **Wildcard characters** (`*`, `?`, `[…]`) are expanded if a file in the
  current directory matches, quoted or not:
  `git assetsync add lib/tool.zip acme/tool --asset 'tool-*.zip'` turns
  into `tool-1.0.zip` when that file is there.
- **Arguments starting with `/`** become Windows paths: `unlink /tmp/x` (of
  a broken entry) turns into `C:/Users/…/Temp/x`.

For such arguments, run the script directly instead of through the alias,
e.g. `py C:/tools/git-assetsync.py add lib/tool.zip acme/tool --asset
tool-*.zip` in cmd or PowerShell; in Git Bash, put `MSYS_NO_PATHCONV=1` in
front of it. Don't set `MSYS_NO_PATHCONV` (or `MSYS=noglob`) for git
itself: it breaks how git passes the arguments to the alias.

### Shipping git-assetsync with your repository

git-assetsync can keep a copy of itself in your repository, so everyone
has the same version without installing it:

```sh
git assetsync add tools/git-assetsync.py stsichler/git-assetsync --asset git-assetsync.py
git commit
git config alias.assetsync '!python3 tools/git-assetsync.py'     # each clone, once (Windows: !py …)
```

The alias goes into the repository's own config (`.git/config`), so it has
to be set in each clone; it takes precedence over a global alias. Git runs
shell aliases in the top-level directory, so the relative path works from
any subdirectory. `git assetsync status` then shows new releases of
git-assetsync, too. The same works for
[git-filesync](https://github.com/stsichler/git-filesync), which publishes
its script as a release asset as well.
