# git-assetsync manual

Detailed description of the concepts, commands and options of
git-assetsync. For motivation and installation see the [README](README.md).

## Contents

- [Concepts](#concepts)
  - [Sources, releases and assets](#sources-releases-and-assets)
  - [Files and directories](#files-and-directories)
  - [The `.git-assetsync` file](#the-git-assetsync-file)
  - [No local modifications](#no-local-modifications)
- [Commands](#commands)
  - [Common options](#common-options)
  - [`status`](#status) · [`pull`](#pull) · [`add`](#add) · [`set`](#set) · [`unlink`](#unlink) · [`mv`](#mv) · [`source`](#source) · [`filter`](#filter) · [`releases`](#releases)
  - [`install-hooks`, `uninstall-hooks`](#install-hooks-uninstall-hooks)
- [Further topics](#further-topics)
  - [Selecting the release](#selecting-the-release) · [Filters](#filters) · [Proposed commit messages](#proposed-commit-messages)
  - [GitHub and GitLab access](#github-and-gitlab-access) · [Integrity](#integrity) · [Download cache](#download-cache)
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

git-assetsync takes a file or a directory of your repository from assets:
it downloads them, optionally unpacks and selects files from them with a
[filter](#filters), writes the result to the path and records in
`.git-assetsync` which release and assets it comes from. Which release
that is, is decided by the source: the latest release, the newest one
whose tag matches a pattern, or one fixed release (see
[Selecting the release](#selecting-the-release)). Which assets of it, is
decided by the entry: a glob pattern for the asset names – they usually
contain the version, so the pattern stays the same across releases while
the path in your repository doesn't change.

Updates are never applied automatically: `status` shows that a new release
is out, `pull` updates the file (directory) and commits it with a message
naming the release. All commands run inside your repository.

### Files and directories

An entry is one of two kinds; [`add`](#add) decides by the form of the
path:

- **A file** (`add bin/tool …`): exactly one file – one asset as it is, or
  the one file a filter leaves of it (e.g. one file from a ZIP). Files
  next to it are not concerned.
- **A directory** (`add third_party/zlib/ …`, with a trailing `/`, or an
  existing directory): any number of files – all assets of the release (or
  those matching `--asset`), as they are or after the filter. The
  directory **belongs to the entry completely**: `pull` makes it exactly
  what the release gives, so files that a new release no longer has
  disappear, and files of your own in it count as modifications (files
  your `.gitignore` ignores don't count and stay).

Entries must not overlap: no entry inside a directory entry, no directory
entry around another entry.

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
[source "madler/zlib"]
	url = https://github.com/madler/zlib
[filter "zlib-headers"]          # a named filter: steps, in this order
	step = extract
	step = strip 1
	step = include '*.h' LICENSE
[dir "third_party/zlib"]
	source = madler/zlib
	asset = zlib-*.tar.gz        # optional: without, all assets of the release
	filter = zlib-headers        # optional: the filter applied to the assets
	synced = v1.3.2
	digest = sha256:…
	filterhash = 3f9a…           # of the filter it was synced with
	tree = …                     # the directory as committed (git's tree id)
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
- **`[dir "PATH"]`** – a directory and the assets it comes from: like
  `[file]`, but `asset` may match several assets (without it: all), and
  the base is `tree`, the id of the directory as committed.
- **`[filter "NAME"]`** – a [named filter](#filters): its steps, one
  `step` key per step, in order. An entry uses it with `filter = NAME` (in
  `[file]` and `[dir]`); `filterhash` records the filter the entry was
  synced with, so a changed filter shows up as pending. Like sources,
  filters are referred to by name – but they are never created or removed
  automatically.

All files of a source take the same release, e.g. a header and a library
published together. To follow a different release of the same project,
use a second source with the same URL (`add` does that when `--release`
differs).

The commands maintain the file: `add`, `set`, `unlink` and `mv` for the
`[file]` and `[dir]` entries, [`source`](#source) for the `[source]`
sections. It can also be edited by hand (or with `git config -f
.git-assetsync …`), but that is never needed; `synced`, `digest`,
`filterhash`, `blob` and `tree` should be left to git-assetsync. An entry
written by hand without them is fetched by the next `pull` (an existing
file at its path is only replaced if it is the same, a directory with
files only with `--force`). Changes to
the file are committed along with the next `pull` – or, if they concern
other files' entries, that `pull` refuses until they are committed (see
[`pull`](#pull)).

### No local modifications

A file taken from an asset must stay exactly what the release gives – a
binary or a generated file can't be merged with local changes. A file that
differs – committed or not, also deleted – is reported by `status` as
**NOT ALLOWED**, `status --exit-code` exits with 1, and `pull` refuses to
update it. `pull --force` discards the modification and restores what the
selected release gives (with a warning, and a note in the commit message).

In a directory entry, every file git sees counts: a changed, deleted or
added file – also an untracked one – is a modification. Files that your
`.gitignore` ignores (e.g. build output) don't count; `pull` and `pull
--force` leave them alone. Files the entry itself gets are always
committed, also if `.gitignore` would ignore them (e.g. `*.lib`).

What counts is the content, not how it is stored: a file that is
re-stored differently after `.gitattributes` changed (moved to Git LFS,
line endings normalized) is still unmodified.

## Commands

| Command | Purpose |
|---|---|
| `status [PATH…]` | state of the entries, like `git status` |
| `pull PATH…`, `pull --all` | update files and directories to the selected release and commit |
| `add PATH SOURCE` | take a file or directory from release assets |
| `set PATH… OPTIONS` | change entries: source, release selection, asset, filter |
| `unlink PATH…` | remove entries (the files are kept) |
| `mv OLD NEW` | move a file or directory, keeping its entry |
| `source [ACTION …]` | list sources; rename them, change URL, release selection or type |
| `filter [ACTION …]` | list filters; show, add, set, rename or remove them |
| `releases SOURCE\|URL` | list the releases of a project, with their assets |
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

Shows the state of the files and directories (default: all) in sections
like `git status`; directories are shown with a trailing `/`:

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
  release than the one the entry comes from (`v1.0 -> v1.1`), the asset of
  that release was replaced (re-uploaded with other content), or the
  filter was changed (`filter changed`). `new`: an entry without a synced
  release yet, or one not in the working tree yet.
- **Locally modified files** – the committed file (directory) differs from
  what the release gives.
- **Uncommitted changes** – the working tree file (directory) differs from
  the committed one (`modified`, `deleted`, `new file`); marked NOT
  ALLOWED if it differs from what the release gives, too.

With nothing to report: `nothing to pull, all N files unmodified` (or
directories). Errors
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

Updates each given file or directory to what the release its source
selects gives (after the filter), and commits it together with its entry
in `.git-assetsync` – one commit per entry. A directory is replaced as a
whole: files the new release no longer has are removed, new ones added.
The editor opens with the [proposed message](#proposed-commit-messages)
unless `--no-edit` is given. An entry that is up to date is reported as
such; one whose filter was changed (with [`set`](#set)) is filtered again,
from the [download cache](#download-cache) if possible.

`pull` refuses a file with local modifications, committed or not (see
[No local modifications](#no-local-modifications)); the other files are
pulled anyway, and the exit code is 2.

`pull` commits only the file (directory) and `.git-assetsync`. If `.git-assetsync`
has uncommitted changes to entries of other files, it refuses, since the
commit would take them along without their files; commit them first, or
use `--no-commit`. Uncommitted changes to `[source]` sections are fine:
they go into the commit – e.g. change `release` of a source and pull, in
one commit.

| Option | Meaning |
|---|---|
| `--all` | all entries with something to pull (with `--force` also modified ones) |
| `--force` | discard local modifications: restore or update the file (directory) anyway; in a directory also untracked files are deleted (ignored ones stay) |
| `--no-edit` | commit with the proposed message, without opening the editor |
| `--no-commit` | update and stage only; a plain `git commit` then offers the proposed message (via `.git/SQUASH_MSG`) |
| `-n`, `--dry-run` | only report what would happen; nothing is downloaded or changed |

If the commit is not done (e.g. the editor is closed with an empty
message, or a hook rejects it), the changes stay staged and `pull` tells
how to commit them with the proposed message; the exit code is then 1.

### `add`

```
git assetsync add PATH SOURCE [--asset PATTERN] [--release TAG|PATTERN] [--prerelease]
                  [--type github|gitlab] [--filter NAME] [--force] [-n]
```

The arguments are in the same order as for `git filesync add`. Takes the
file or directory `PATH` from assets of the release `SOURCE` selects:
downloads them, applies the filter, writes the result to `PATH`, records
the entry in `.git-assetsync` and stages both – like `git add`, without
committing. A plain `git commit` then offers the proposed message (`git
commit --no-edit` takes it as it is).

- **`PATH`** is the file or directory in your repository, relative to the
  current directory. With a trailing `/` (or if it is an existing
  directory) it becomes a [directory entry](#files-and-directories), else
  a file. The name doesn't have to be the asset's, and stays the same when
  later assets are named differently.
- **`SOURCE`** is the name of a `[source]` in `.git-assetsync`, or a URL
  (`https://github.com/owner/repo`, `https://gitlab.com/group/project`,
  also with subgroups; the URL of any page of the project works as well);
  `owner/repo` is short for a repository on github.com. A URL takes the source with that URL and the
  same release selection, or creates one. A source name takes that source
  with its release selection – unless `--release`/`--prerelease` ask for
  another one, then its URL with that selection.
- **`--asset PATTERN`** selects the assets: a glob pattern (`*`, `?`,
  `[…]`), e.g. `--asset 'tool-*-linux-x64.tar.gz'`. Quote it, so the
  shell doesn't expand it. The pattern is recorded and used for later
  releases, too. For a file it must match exactly one asset; without
  `--asset` the release must have exactly one asset, which is taken – no
  pattern is recorded, and a later release with more than one asset is an
  error until you choose one (`git assetsync set PATH --asset PATTERN`).
  For a directory, all matching assets are taken; without `--asset` all
  assets of the release – they are listed first, and more than 10 assets
  or 100 MiB need `--force`.
- **`--filter NAME`** applies the named [filter](#filters) `NAME` to the
  assets – to unpack them, select and move files. Define it first with
  [`filter add`](#filter).

| Option | Meaning |
|---|---|
| `--asset PATTERN` | the assets to take (glob; a file: exactly one match, default the release's only asset; a directory: all matching, default all) |
| `--release TAG\|PATTERN` | release to take: a tag pins the source to that release, a pattern takes the newest release whose tag matches (default: the latest release) |
| `--prerelease` | prereleases count too (with a pattern, or instead of the latest release) |
| `--type github\|gitlab` | platform of the URL's host; needed for hosts other than github.com, gitlab.com and `gitlab.*` |
| `--filter NAME` | the named [filter](#filters) to apply to the assets |
| `--force` | replace an existing entry for `PATH`; overwrite an existing file that differs; take over a directory that isn't empty; take more than 10 assets or 100 MiB |
| `-n`, `--dry-run` | only show which release, assets and filter would be taken; nothing is downloaded |

An existing file at `PATH` is only overwritten with `--force`, unless it is
already what the release gives. An existing directory with files in it
becomes the entry's only with `--force` – then files there that the
release doesn't give are deleted (ignored ones stay). For big binary files
(1 MiB or more) that are not stored in Git LFS, `add` warns and suggests
`git lfs track`: each update adds another copy to the repository's
history.

```sh
git assetsync add bin/tool acme/tool --asset 'tool-*-linux-x64'

git assetsync filter add glab-binary --extract --include bin/glab
git assetsync add tools/glab https://gitlab.com/gitlab-org/cli \
    --asset '*_linux_amd64.tar.gz' --filter glab-binary

git assetsync filter add zlib-headers --extract --strip 1 --include '/*.h' --include LICENSE
git assetsync add third_party/zlib/ madler/zlib --asset 'zlib-*.tar.gz' --filter zlib-headers
```

### `set`

```
git assetsync set PATH… [--source URL|SOURCE] [--release TAG|PATTERN | --latest]
                        [--prerelease | --no-prerelease] [--type github|gitlab]
                        [--asset PATTERN | --no-asset] [--filter NAME | --no-filter] [-n]
```

Changes the entries of files and directories – their source, release
selection, asset or filter –
where `add` would need `--force`. It does for files what
[`source`](#source) does for sources: only `.git-assetsync` is changed (and
staged); `status` then shows what changes, and `pull` updates the files and
commits the change with them.

| Option | Effect |
|---|---|
| `--source URL\|SOURCE` | take the files from another project – a fork, a moved project – or another `[source]`. URL, name and `--release` / `--prerelease` / `--type` are taken as for [`add`](#add) |
| `--release TAG\|PATTERN`, `--latest` | (without `--source`) another release selection for these files: a tag pins them, a pattern takes the newest matching release, `--latest` follows the latest release |
| `--prerelease`, `--no-prerelease` | (without `--source`) let prereleases count for these files, or not |
| `--type github\|gitlab` | (without `--source`) the platform of the host |
| `--asset PATTERN`, `--no-asset` | another asset of the release; `--no-asset`: the release's only asset (a directory: all) |
| `--filter NAME`, `--no-filter` | use another named [filter](#filters), or none |
| `-n`, `--dry-run` | only show what would change |

If the files are all files of their source and no source with that URL and
selection exists yet, the source itself is changed; otherwise they move to
that source (created if necessary), and a source left without files is
removed.

The base the files are compared with (`blob`, `digest`) is kept, so local
modifications stay modifications. With another URL or asset, which release
asset a file comes from is unknown until the next `pull`: `status` shows it
as pending (`entry changed`), and `pull` fetches it – if it is the same file,
the commit only records that (`Record … (file unchanged)`). Another filter
(or a changed one) shows as pending (`filter changed`); `pull` filters
the assets again, from the [download cache](#download-cache). A
file can't become a directory or the other way round: `unlink` it and
`add` it again.

```sh
git assetsync set bin/tool --release 'v2.*'           # this file only: newest 2.x
git assetsync set firmware/ --source https://gitlab.com/me/fw-fork
git assetsync set bin/tool --asset 'tool-*-linux-arm64'
git assetsync set third_party/zlib --filter zlib-all       # another named filter
```

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

Moves a file or directory (with `git mv`) and its entry, and stages both.
`NEW` may be an existing directory.

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
to move the files to the other one (`set <file>... --source <source>`).

To give only some files of a source another release selection, use
[`set`](#set), e.g. `git assetsync set lib/x.h --release v2.0` – they get a
source of their own.

### `releases`

```
git assetsync releases SOURCE|URL [--assets] [-n N | --all] [--type github|gitlab]
```

Lists the releases of a project, newest first: tag, date and title (if it
differs from the tag), marked `latest` (as the platform defines it),
`prerelease` (GitLab: `upcoming`), `draft`, and `selected by …` with the
sources of this repository that select it now. A help for choosing
`--release` and `--asset` for [`add`](#add) and [`set`](#set):

```console
$ git assetsync releases acme/tool --assets -n 2
v1.1      2026-10-11  Tool 1.1  (latest, selected by acme/tool)
    tool-1.1-linux-x64     14.6 MiB
    tool-1.1-windows.zip   15.2 MiB
v1.1-rc1  2026-10-04  Tool 1.1 RC  (prerelease)
    tool-1.1-rc1-linux-x64  14.5 MiB
```

`SOURCE` is the name of a `[source]` or a URL (`owner/repo`: github.com),
as for `add`; with a URL it also works outside a repository.

| Option | Meaning |
|---|---|
| `--assets` | also list the assets of each release, with their sizes (GitLab reports none) |
| `-n`, `--max-count N` | the newest N releases (default: 10) |
| `--all` | all releases |
| `--type github\|gitlab` | platform of the URL's host, as for `add` |

### `filter`

```
git assetsync filter
git assetsync filter show NAME
git assetsync filter add NAME STEP-OPTIONS…
git assetsync filter set NAME STEP-OPTIONS…
git assetsync filter rename OLD NEW
git assetsync filter remove NAME
```

Lists and changes the [filters](#filters). The changing actions only
change `.git-assetsync` and stage it; entries using a changed filter show
as pending in `status`, and `pull` updates them.

| Action | Meaning |
|---|---|
| (none) | list the filters, with their number of steps and the entries and filters using them |
| `show NAME` | the steps of a filter, and who uses it |
| `add NAME STEP-OPTIONS…` | define a new filter with the [step options](#filters) (`--extract`, `--include`, `--move`, `--apply`, …), in the order given. Names consist of letters, digits, `.`, `+`, `-` and `_` |
| `set NAME STEP-OPTIONS…` | replace the steps of an existing filter |
| `rename OLD NEW` | rename a filter, and the entries and `apply` steps that use it |
| `remove NAME` | remove a filter that nothing uses |

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
`git assetsync set PATH --asset 'NEW-*'` and pull.

To switch a source to another release selection, use
[`source set-release`](#source) (e.g.
`git assetsync source set-release acme/tool v2.0`) and pull its files; the
change is committed with them. For some of its files only, use
[`set --release`](#set).

### Filters

A filter turns the downloaded assets into the files of an entry, without
running any code. Filters are **named**: defined once with
[`filter add`](#filter) – in `.git-assetsync` as `[filter "NAME"]` – and
used by any number of entries (`add --filter NAME`, `set --filter NAME`),
also of different sources. Like sources, they are never created or
removed automatically.

A filter is a list of steps, applied in order to the files so far; files a
step doesn't concern pass unchanged. At the start, the files are the
assets, named as they are. `filter add` and `filter set` build the steps
from their options, **in the order the options are given**; each option
has the name of its step:

| Option (step) | Effect |
|---|---|
| `--extract` | unpack the archives among the files: ZIP, tar, tar.gz/.tgz, tar.bz2, tar.xz, single `.gz`/`.bz2`/`.xz` files (named without the suffix), and 7z with an external 7-Zip (see below). The type is recognized by the content, not the name. All archives go into one root; files that are no archives stay as they are |
| `--subdir PATH` | only the files below `PATH`, which becomes the root |
| `--strip N` | remove `N` leading directories from all paths, like `tar --strip-components` (e.g. the `zlib-1.3.2/` of an archive) |
| `--include PATTERN` | only the files matching the pattern |
| `--exclude PATTERN` | not the files matching the pattern |
| `--move PATTERN TARGET` | move the matching files to `TARGET`, see below |
| `--copy PATTERN TARGET` | the same, but the files also stay where they are |
| `--apply PATTERN NAME` | apply the filter `NAME` to the matching files only, see [Filters using filters](#filters-using-filters) |

**Several `--include` options in a row make one step** that keeps the
files matching *any* of their patterns – they don't filter one after the
other (which would leave nothing). The same for `--exclude`: one step that
removes the files matching any of the patterns. So

```sh
git assetsync filter add zlib-headers --extract --strip 1 --include '/*.h' --include LICENSE
```

keeps the headers *and* the license:

```ini
[filter "zlib-headers"]
	step = extract
	step = strip 1
	step = include '/*.h' LICENSE
```

Only options in between separate them: `--include '*.h' --exclude 'x*'
--include 'a*'` makes three steps, applied one after the other (headers,
not starting with `x`, starting with `a`). `filter show` lists the steps.

Patterns are like in `.gitignore` (and `git filesync add --include`),
relative to the root after the previous steps: without a `/` a pattern
matches a name at any depth (`*.h`; `*` matches every file), a leading or
inner `/` anchors it to the root (`/*.h`, `include/*.h` – but not
`x/include/a.h`), a trailing `/` matches a directory and everything below
it; `**/` matches any number of directories (`**/include/*.h`).

**`TARGET` of `move` and `copy`**: with a trailing `/` the files go into
that directory under their names – e.g. to gather files spread over
several directories (`--move '*.h' include/`; `./` is the root). Else
`TARGET` is the new path of each file, with placeholders for parts of its
old path – for `images/boardA/app.bin`:

| Placeholder | Value |
|---|---|
| `{path}` | `images/boardA/app.bin` |
| `{dir}` | `images/boardA` |
| `{parent}` | `boardA` |
| `{name}` | `app.bin` |
| `{stem}` | `app` |
| `{ext}` | `.bin` |

So `--move 'images/*/app.bin' 'firmware/{parent}.bin'` makes
`firmware/boardA.bin`, `firmware/boardB.bin`, …; `--move include/
'api/{path}'` moves a whole directory with its structure. Two files with
the same target, or a target that is another file, are an error.

It is an error if `extract` finds no archive, `subdir`, `move`, `copy` or
`apply` no files, `strip` a file with too few directories, or if nothing
is left. A file entry must end up with exactly one file.

#### Filters using filters

The step `apply PATTERN NAME` applies the filter `NAME` to the files
matching `PATTERN` only; they keep their paths, and the result joins the
other files again (a path that collides with one of them is an error).
Since the files are the assets before `extract`, one directory entry can
treat the assets of a release differently:

```sh
git assetsync filter add headers --extract --strip 1 --include '*.h' --move '*.h' include/
git assetsync filter add firmware --move '*' firmware/
git assetsync filter add sdk --apply 'sdk-*-headers.zip' headers --apply 'fw-*.bin' firmware
git assetsync add vendor/sdk/ acme/sdk --filter sdk
```

```ini
[filter "headers"]
	step = extract
	step = strip 1
	step = include '*.h'
	step = move '*.h' include/
[filter "firmware"]
	step = move '*' firmware/
[filter "sdk"]
	step = apply 'sdk-*-headers.zip' headers
	step = apply 'fw-*.bin' firmware
[dir "vendor/sdk"]
	source = acme/sdk
	filter = sdk
	...
```

A filter may use other filters, but not itself (also not through others).
A changed filter changes all entries that use it, directly or through
other filters: `status` shows them as pending (`filter changed`), `pull`
applies it. Renaming one changes nothing else.

Archives are unpacked safely: members with paths outside the target
(`..`, absolute, drive letters), in a `.git` directory, symbolic or hard
links and special files are refused, as are names that are no valid file
names on every platform (on Windows: `con.txt`, `a:b`, trailing dots or
blanks), two members with the same path, and paths that differ only in
case. At most 2 GiB and 100 000 files are unpacked per entry. The
executable bit of archive members is kept (git knows only executable or
not).

**7z archives** are unpacked with 7-Zip, which is only needed for them:
`7zz` (7-Zip for Linux and macOS), `7z` (7-Zip for Windows, or p7zip),
`7za` or `7zr` on the `PATH`, on Windows also in `Program Files\7-Zip`;
`ASSETSYNC_7Z` sets another command. Without it, `extract` on a 7z
archive is an error that says so; taking a `.7z` asset as it is needs no
7-Zip. The same safety rules apply: git-assetsync checks the archive's
listing first (encrypted members are refused, too), lets 7-Zip unpack it
into an empty temporary directory and checks the result again before
using it. All methods 7-Zip knows work (LZMA, LZMA2, PPMd, BCJ2, …).

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

The subject names the file (directory), the source and the release –
`Add …` for a new entry, `Update … to … (was …)` for another release,
`Update … (asset replaced)` when the asset of the same release changed,
`Update … (filter changed)` after another filter, `Restore …` when `pull
--force` brought back what the release gives after local modifications.
The body links the release page and names its title (if it differs from
the tag), the assets and the filter; for a directory it adds what changes
in it:

```
Update third_party/zlib/ to madler/zlib v1.3.2 (was v1.3.1)

Release: https://github.com/madler/zlib/releases/tag/v1.3.2
Title:   zlib 1.3.2
Asset:   zlib-1.3.2.tar.gz
Filter:  zlib-headers
Files:   1 added, 0 removed, 9 changed (12 in total)
```

When an entry is updated to another release, its **release notes** (the
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

### Download cache

Downloaded assets are kept in a cache, so another filter, `pull --force`
or a second repository with the same asset need no new download:
`~/.cache/git-assetsync` (or `$XDG_CACHE_HOME/git-assetsync`), on Windows
`%LOCALAPPDATA%\git-assetsync`; `ASSETSYNC_CACHE` sets another directory.
Contents are kept by their SHA-256 (`sha256/`), with an index for
platforms that report no digests (`index/`, GitLab). The cache is never
cleaned up by git-assetsync; delete it (or parts of it) whenever you like.

### Git LFS

git-assetsync stores files exactly as `git add` would: if `.gitattributes`
puts one into Git LFS, it is committed as an LFS pointer, and the recorded
`blob` (for a directory: the `tree`) contains the pointer's id. To put
files into LFS from the start, run `git lfs track PATTERN` before `add`
(`add` suggests it for big binaries).

Files moved to LFS later (`git lfs track` + `git add --renormalize`) stay
unmodified. Requires `git-lfs` for files stored in LFS.

### Line endings

Files – also those of a directory – are stored as `git add` stores them, so
`text=auto`, `eol` attributes and `core.autocrlf` apply as for any other
file: an asset with CRLF line ends is committed normalized in a
`text=auto` repository. A file entry is written to the working tree as
`git checkout` would write it (with `core.autocrlf=true`, a text asset gets
CRLF); the files of a directory are written as the release has them, which
`git status` sees as unchanged – the next checkout converts them. Changing
these settings afterwards doesn't make entries count as modified. To keep
an asset byte for byte, mark it `-text` (or `binary`) in `.gitattributes`.

### Offline operation

`status` works without network for everything local: whether the committed
and working tree files (directories) are still what their release gives is
decided from the recorded `blob` (`tree`). Only the check for new releases
needs GitHub or GitLab; `--no-fetch` skips it (`new releases not
checked`). `add` and `pull` always ask the platform which release to take;
assets already in the [download cache](#download-cache) are not
downloaded again.

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
`https://github.com/stsichler/git-assetsync/releases/download/v0.5.0/git-assetsync.py`
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
