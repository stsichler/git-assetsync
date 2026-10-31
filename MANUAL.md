# git-assetsync manual

The concepts, commands and options of git-assetsync in detail. For
motivation and installation see the [README](README.md).

## Contents

- [Concepts](#concepts)
  - [Sources, releases and assets](#sources-releases-and-assets)
  - [Files and directories](#files-and-directories)
  - [The `.git-assetsync` file](#the-git-assetsync-file)
  - [No local modifications](#no-local-modifications)
  - [Files of your own in a directory](#files-of-your-own-in-a-directory)
- [Commands](#commands)
  - [Common options](#common-options)
  - [`status`](#status) · [`pull`](#pull) · [`diff`](#diff) · [`difftool`](#difftool) · [`restore`](#restore) · [`add`](#add) · [`rm`](#rm) · [`unlink`](#unlink) · [`mv`](#mv)
- [Advanced commands](#advanced-commands)
  - [`set`](#set) · [`edit`](#edit) · [`source`](#source) · [`source map`](#source-map) · [`source releases`](#source-releases) · [`filter`](#filter) · [`filter trust`](#filter-trust) · [`verify`](#verify) · [`cache`](#cache) · [`hooks`](#hooks)
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
self-managed). A **release** is identified by its **tag** (e.g. `v1.3.1`
or `tool-20261016`); its title is only shown. Its **assets** are the files
attached to it.

git-assetsync takes a file or directory of your repository from assets:
it downloads them, optionally unpacks and selects files with a
[filter](#filters), writes the result and records in `.git-assetsync`
where it came from. Each entry selects its release – the latest, the
newest whose tag matches a pattern, or a fixed one (see [Selecting the
release](#selecting-the-release)) – and its assets by a glob pattern, which
stays valid when the asset names change with the version.

Nothing updates automatically: `status` shows that a new release is out,
`pull` updates and stages, you commit.

### Files and directories

[`add`](#add) decides the kind of an entry by the path:

- **A file** (`add … bin/tool`): exactly one file – an asset as it is, or
  the one file a filter leaves (e.g. one file from a ZIP).
- **A directory** (`add … third_party/zlib/`, with a trailing `/`, or an
  existing directory): any number of files – all assets (or those
  matching `--asset`), as they are or filtered. The entry has **the files
  its release gave**: `pull` replaces them and deletes those the new
  release no longer has. Files of your own there stay – see [Files of
  your own in a directory](#files-of-your-own-in-a-directory).

Entries must not overlap.

### The `.git-assetsync` file

Lives at the root of the repository and is committed like any other file.
Git-config format:

```ini
[source "acme/tool"]
	url = https://github.com/acme/tool
[file "bin/tool"]
	source = acme/tool
	asset = tool-*-linux-x64     # glob, exactly one match (without: the only asset)
	synced = v1.1                # tag of the release the file comes from
	digest = sha256:5b2c…        # SHA-256 of that asset
	blob = 8d01b7aa…             # the file as committed (git's blob id)
	mode = 100755                # 100644, or 100755 (executable)
[source "acme/multi"]
	url = https://github.com/acme/multi
[file "firmware/fw.bin"]
	source = acme/multi
	release = toolA-*            # newest release whose tag matches
	prerelease = true            # prereleases count too
	asset = fw-*.bin
	synced = toolA-20261016
	digest = sha256:…
	blob = …
[source "madler/zlib"]
	url = https://github.com/madler/zlib
[filter "zlib-headers"]          # a named filter: its steps, in order
	step = extract
	step = strip 1
	step = include '*.h' LICENSE
[dir "third_party/zlib"]
	source = madler/zlib
	asset = zlib-*.tar.gz        # without: all assets
	filter = zlib-headers
	synced = v1.3.2
	digest = sha256:…
	filterhash = 3f9a…           # of the filter it was synced with
	tree = …                     # the directory as committed (git's tree id)
```

- **`[source "NAME"]`** – a project, like a Git remote, one per URL. `type`
  (`github` or `gitlab`) is only needed for hosts other than github.com,
  gitlab.com and `gitlab.*`. `add` names new sources `owner/repo`, with a
  number appended if that name is taken.
- **`[file "PATH"]`** – a file (path relative to the root) and what to
  take: `source`, the release (`release`: a tag pins it, a pattern with
  `*`, `?` or `[…]` takes the newest match, none the latest;
  `prerelease = true` lets prereleases count) and `asset`. git-assetsync
  writes the rest, the **base** the file is compared with: `synced` (the
  tag), `digest` (the asset's SHA-256), `blob` (the file as `git add`
  stores it, after line endings and Git LFS) and `mode` (`100755` if the
  filter made it executable, see [Executables](#executables)). So
  `status` knows offline whether the file is still what the release gave.
  Where the platform reports no digests, `assetid` records the uploads
  (see [Integrity](#integrity)).
- **`[dir "PATH"]`** – like `[file]`, but `asset` may match several assets
  (without it: all), and the base is `tree`.
- **`[filter "NAME"]`** – a [named filter](#filters), one `step` per step.
  Entries use it with `filter = NAME`; `filterhash` records the filter an
  entry was synced with, so a changed filter shows up as pending.

Entries select their releases themselves, so entries of one project can
follow different releases – e.g. two tools released under different tag
prefixes.

The commands maintain the file; comments and your own layout stay. To
edit it by hand, use [`edit`](#edit), which checks and stages it. Leave
the base keys to git-assetsync: an entry without them counts as not
synced yet, and the next `pull` fetches it.

### No local modifications

A file taken from an asset must stay exactly what the release gives – a
binary or generated file can't be merged. A file that differs, committed
or not, is **NOT ALLOWED**: `status` reports it, `status --exit-code`
exits with 1, `pull` refuses to update it. [`diff`](#diff) shows the
modification, [`restore`](#restore) brings back what the release gave,
and `pull --overwrite` updates anyway (with a note in the commit message).

A file that is gone – deleted, committed or not – is **missing**, also
not allowed while it is an entry. `pull` refuses it, also with
`--overwrite`, and `pull --all` leaves it out; `restore` gets it back, or
`unlink`/`rm` remove the entry. An entry not synced yet is **new**
instead: `pull` takes its release.

In a directory, only the files of the release count: one changed or
deleted is a modification, all of them gone is missing.

Files an entry gets are staged even if `.gitignore` ignores them (e.g.
`*.lib`), and written as `git checkout` writes them. What counts is the
content: a file stored differently after `.gitattributes` changed (moved
to Git LFS, line endings normalized) is still unmodified.

### Files of your own in a directory

The files of a release can sit next to files of yours – a
`CMakeLists.txt`, patches, build output. `status` doesn't report them,
`pull` and `restore` leave them alone and stage only the release's files,
`rm` removes only those, and `mv` moves everything.

A new release with a file where one of yours is – the same name, also in
another case, or a file where the release has a directory – is refused by
`add` and `pull`, naming the files. With `--overwrite` the release's files
replace them. A file that is just what the release gives (same content
and mode) isn't in the way: it becomes the entry's.

Which files are the release's comes from the recorded `tree`. When files
of yours are committed in the directory, that tree isn't committed
itself, so a fresh clone lacks it: `status` says so and doesn't check
the directory. `verify` gets it again – filtering the synced assets, from
the download cache or the platform – and so do `pull`, `restore`, `rm`,
`diff` and `difftool` when they need it; it is then kept in the clone
(`refs/assetsync/base/<tree>`, never pushed). If that fails – the release
is gone, its assets were re-uploaded, or the filter changed – `pull`
refuses; with `--overwrite` it adds the new files and deletes none.

## Commands

Basic commands – what you need day to day:

| Command | Purpose |
|---|---|
| [`status [PATH…]`](#status) | state of the entries, like `git status` |
| [`pull PATH…`, `pull --all`](#pull) | update to the selected release (or once another one) and stage, with a proposed commit message |
| [`diff [PATH…]`](#diff) | local modifications; what `pull` would bring |
| [`difftool [PATH…]`](#difftool) | the same in your difftool, file by file or as two directories |
| [`restore PATH…`](#restore) | discard local modifications: back to what the release gave |
| [`add SOURCE PATH`](#add) | take a file or directory from release assets |
| [`rm PATH…`](#rm) | remove entries and their files, like `git rm` |
| [`unlink PATH…`](#unlink) | remove entries, keep the files |
| [`mv OLD NEW`](#mv) | move a file or directory with its entry |

[Advanced commands](#advanced-commands) – to change entries, sources and filters, and for setup:

| Command | Purpose |
|---|---|
| [`set PATH… OPTIONS`](#set) | change entries: source, release selection, asset, filter |
| [`edit`](#edit) | open `.git-assetsync` in the editor, then check and stage it |
| [`source [ACTION …]`](#source) | list sources; rename them, change URL or type |
| [`source map [URL\|SOURCE [DIR]]`](#source-map) | take the releases of a source from a local folder |
| [`source releases URL\|SOURCE`](#source-releases) | list the releases of a project, with their assets |
| [`filter [ACTION …]`](#filter) | list filters; show, test, add, set, rename or remove them |
| [`filter trust [NAME…]`](#filter-trust) | list the filters that run commands; trust them in this repository |
| [`verify [PATH…]`](#verify) | filter the synced assets again: is the committed state reproducible? |
| [`cache [ACTION]`](#cache) | the download cache: show, list, prune, clear |
| [`hooks [install\|uninstall]`](#hooks) | reminder hooks and the push check |

Commands named like a Git command behave like it (`status`, `pull`,
`diff`, `difftool`, `restore`, `add`, `rm`, `mv`; `source` like `git
remote`): the same kind of output and exit codes, the same caution with
uncommitted changes.

**No command commits.** They change the working tree or stage, like `git
add` – `pull` like `git merge --squash` – and you commit. `pull` and
`add` prepare a [proposed commit message](#proposed-commit-messages) that
a plain `git commit` offers. Whatever else is staged goes into the same
commit.

Without a command, `status` runs. `PATH` is a file or a directory (all
entries below it), relative to the current directory. A path inside a
directory entry (`third_party/zlib/zlib.h`) stands for that entry in
`status`, `pull`, `diff`, `difftool` and `verify`; `set`, `restore`, `rm`
and `unlink` refuse it – they act on whole entries. Options follow the
command; `git assetsync <command> -h` lists them.

Two options mean the same everywhere (also in git-filesync):
**`--overwrite`** replaces local content – files of yours, local
modifications – with what the release gives; **`--force`** does something
refused by default without losing local content (replace an entry, add
lines to the hooks of other tools).

**Discarded content can be got back.** Before `restore`, `rm -f` or
`--overwrite` replace or delete content that isn't committed, they keep
it as a Git object and say so:

```
discarded: lib/data.bin (git show 1a2b3c4d5e6f to get it back)
```

`git show 1a2b3c4d5e6f > lib/data.bin` writes it back exactly. Where the
index goes too (`rm -f`, `--overwrite`, `restore -S`), a staged version is
kept as well (`discarded: lib/data.bin, as staged …`). `git gc` removes
such objects after a while (normally two weeks).

### Common options

| Option | Meaning |
|---|---|
| `--color[=WHEN]`, `--no-color` | colored output: `always`, `never` or `auto` (default), see [Colors](#colors) |
| `--remote` | ignore [mappings](#source-map) this once and use the upstream URL (`status`, `pull`, `diff`, `difftool`, `add`, `verify`, `source releases`, `filter test`) |

### `status`

```
git assetsync status [PATH…] [-s] [-v] [--exit-code] [--no-fetch]
```

Shows the state of the entries (default: all) in sections like `git
status`; directories have a trailing `/`:

```
Upstream changes to pull:
  (use "git assetsync diff --upstream <file>..." to see what pull would bring)
  (use "git assetsync pull <file>..." to update)
	pending:    bin/tool  (v1.0 -> v1.1)
	new:        firmware/fw.bin  (not synced yet, release toolA-20261016)

Locally modified files:
  (use "git assetsync diff <file>..." to see the modifications)
  (use "git assetsync restore -SW <file>..." to restore the release asset)
	modified:   lib/data.bin  (NOT ALLOWED)

Missing files:
  (use "git assetsync restore <file>..." to get them back)
  (use "git assetsync unlink <file>..." to remove their entries)
	missing:    bin/tool  (NOT ALLOWED: still an entry)

Not committed yet:
  (use "git commit" to commit them)
	new file:   third_party/zlib/
```

- **Upstream changes to pull** – `pending`: the entry selects another
  release (`v1.0 -> v1.1`), its asset was re-uploaded with other content,
  or its filter changed. `new`: an entry not synced yet, e.g. written
  with [`edit`](#edit).
- **Locally modified files** – differs from what the release gave, in
  the working tree or committed; `restore -SW` and a commit bring it back.
- **Missing files** – the file, or all files of a directory's release,
  deleted (also committed).
- **Not committed yet** – added or pulled and staged.

With nothing to report it says `nothing to pull, all N files
unmodified`. Errors (no release found, no or several matching assets,
broken entries) go to stderr for the entry concerned; the others are shown
as usual. The hints follow `advice.statusHints`.

| Option | Meaning |
|---|---|
| `-s`, `--short` | one line per entry with something to report, two columns like `git status -s`: upstream (`P` pending, `N` new, `E` error) and local (`M` modified, `D` missing, `?` not committed yet) |
| `-v`, `--verbose` | also list all entries with asset, source, release selection and synced release |
| `--exit-code` | exit with 1 if something is to pull, modified or missing |
| `--no-fetch` | don't ask GitHub or GitLab for new releases, see [Offline operation](#offline-operation) |

It exits with 0 unless `--exit-code` is given, and with 2 on errors.

### `pull`

```
git assetsync pull (PATH… | --all) [--release TAG|PATTERN] [--overwrite] [-v] [-n]
```

Updates the entries to what their selected release gives (after the
filter) and stages them with their entries in `.git-assetsync`, like `git
merge --squash`. A plain `git commit` offers the [proposed
message](#proposed-commit-messages), one for all entries; `git commit
--no-edit` takes it as it is:

```sh
git assetsync pull --all
git commit --no-edit
```

In a directory, the release's files are replaced, added or removed;
files of yours stay. An entry whose filter changed is filtered again,
from the [download cache](#download-cache) if possible.

`pull` refuses an entry with local modifications or a missing one (see
[No local modifications](#no-local-modifications)); the others are pulled
anyway, and the exit code is 2. An entry not synced yet is taken as `add`
would.

| Option | Meaning |
|---|---|
| `--all` | all entries with something to pull (with `--overwrite` also modified ones; missing ones are left out); not with paths |
| `--release TAG\|PATTERN` | this release instead of the selected one, once – see below; prereleases count for a pattern only if the entry takes them |
| `--overwrite` | discard local modifications and files of yours in the way |
| `-v`, `--verbose` | first name where each entry comes from, as `status -v` does |
| `-n`, `--dry-run` | only report what would happen |

**Another release, once:** `pull --release TAG PATH…` takes that release
instead of the selected one – also an older one, to go back after a
broken update. The selection stays, so `status` then shows it as pending
and a plain `pull` goes back; `pull --release` says so:

```console
$ git assetsync pull --release v1.0 bin/tool
bin/tool: updated and staged. Commit with:
    git commit
(it offers the proposed commit message; a copy stays in .git/ASSETSYNC_MSG)
note: bin/tool: it still selects v1.1 - 'git assetsync pull bin/tool' goes back to it; to stay on v1.0: 'git assetsync set bin/tool --release v1.0'
```

To stay on a release, pin it with [`set --release`](#set). [`diff
--upstream --release TAG PATH…`](#diff) shows beforehand what `pull
--release` would bring.

### `diff`

```
git assetsync diff [PATH…] [--upstream [--release TAG|PATTERN]] [--exit-code | --quiet] [-- OPTS]
```

Shows the local modifications of the entries (default: all): what the
release gave (the recorded `blob` / `tree`) against the working tree. In
a directory only the release's files are compared. Works offline.

| Option | Shows |
|---|---|
| (none) | the local modifications: synced -> working tree |
| `--upstream` | what `pull` would bring: synced -> what the selected release gives now |
| `--upstream --release TAG\|PATTERN` | what `pull --release` would bring |
| `--exit-code` | exit with 1 if there are differences, like `git diff` |
| `--quiet` | the same, showing nothing |

```sh
git assetsync diff                      # local changes (synced/ -> local/)
git assetsync diff --upstream           # what pull would bring (synced/ -> upstream/)
git assetsync diff --upstream -- --stat # anything after -- goes to git diff
```

`diff` runs one `git diff` over all entries that differ: pager, colors,
diff drivers and options after `--` work as usual. Files in Git LFS are
compared by their content. With `--upstream`, the assets come from the
[download cache](#download-cache) if possible, and filters that run
commands must be [trusted](#filter-trust). To see what a `pull` command
line would do, replace `pull` by `diff --upstream`. Exit codes: 1 for
differences with `--exit-code` or `--quiet`, else 0; 2 on errors.

### `difftool`

```
git assetsync difftool [PATH…] [--upstream [--release TAG|PATTERN]]
                       [-d] [-y | --prompt] [-- OPTS]
```

The same as [`diff`](#diff), in your difftool (`diff.tool`, e.g. Meld);
`OPTS` go to `git difftool` (e.g. `-t meld`).

| Option | Effect |
|---|---|
| `--upstream`, `--release` | as for `diff` |
| `-d`, `--dir-diff` | all files at once, as two directories |
| `-y`, `--no-prompt` | don't ask before each file |
| `--prompt` | ask before each file (the default, unless `difftool.prompt = false`); the last of `-y` and `--prompt` counts |

**File by file** (the default), as `git difftool` does, asking before
each: the left side is a temporary copy of what the release gave
(`synced-v1.0/`), the right side the working file itself – so edits in the
tool are kept – or with `--upstream` a temporary copy (`upstream-v1.1/`).
A file missing on one side is compared with an empty file.

**As two directories** (`-d`): one call of the tool for all files – e.g.
to see which files a new release adds, removes or changes:

```sh
git assetsync difftool -d --upstream third_party/zlib
```

Files that are the same as in the working tree are linked to it, as `git
difftool -d` does, so edits are kept – except on Windows, where they are
copies (`-- --symlinks` to link anyway).

### `restore`

```
git assetsync restore PATH… [-S] [-W]
```

Like `git restore`, but brings back what the entries were synced with
instead of what is committed – without pulling a newer release (that does
`pull --overwrite`). It restores the working tree; `-S` (`--staged`) the
index instead, `-SW` both. `.git-assetsync` doesn't change. A committed
modification is gone with `restore -SW` and a commit:

```sh
git assetsync restore -SW lib/data.bin
git commit -m "Restore lib/data.bin"
```

Files get their executable bits as synced and are written as the current
`.gitattributes` say; files of yours in a directory stay. `restore` works
offline – except when a fresh clone has to get a directory's base again
(see [Files of your own in a
directory](#files-of-your-own-in-a-directory)).

| Option | Meaning |
|---|---|
| `-S`, `--staged` | restore the index instead of the working tree |
| `-W`, `--worktree` | restore the working tree (the default; with `-S`: both) |

### `add`

```
git assetsync add SOURCE PATH [--asset PATTERN] [--release TAG|PATTERN] [--prerelease]
                  [--type github|gitlab] [--filter NAME] [--force] [--overwrite] [-n]
```

Takes the file or directory `PATH` from assets of the release `SOURCE`
selects: downloads them, applies the filter, writes the result, records
the entry in `.git-assetsync` and stages both, like `git add`. A plain
`git commit` offers the proposed message. First the source, then the path
– as for `git submodule add URL PATH`.

- **`SOURCE`** is the name of a `[source]`, or a URL
  (`https://github.com/owner/repo`, `https://gitlab.com/group/project`,
  also with subgroups or of any page of the project); `owner/repo` is
  short for github.com. A URL takes the source with that URL, or creates
  one.
- **`PATH`**, relative to the current directory, becomes a [directory
  entry](#files-and-directories) with a trailing `/` (or if it is an
  existing directory), else a file. Its name needn't be the asset's. Like
  `cp`, `add` makes no directories: the one `PATH` goes into must exist.
- **`--asset PATTERN`** selects the assets by a glob (quote it), recorded
  for later releases too. A file needs exactly one match; without
  `--asset` the release must have exactly one asset. A directory takes all
  matching assets – without `--asset` all of them, listed first.

| Option | Meaning |
|---|---|
| `--asset PATTERN` | the assets to take, see above |
| `--release TAG\|PATTERN` | a tag pins the entry, a pattern takes the newest matching release (default: the latest) |
| `--prerelease` | prereleases count too |
| `--type github\|gitlab` | platform of the URL's host; needed for hosts other than github.com, gitlab.com and `gitlab.*` |
| `--filter NAME` | apply the named [filter](#filters) (define it first with [`filter add`](#filter)) |
| `--force` | replace an existing entry, with its file or directory; a file stays a file, a directory a directory |
| `--overwrite` | replace files in the way that differ from the release's; with `--force` also local modifications of the entry |
| `-n`, `--dry-run` | only show which release, assets and filter would be taken |

An existing file at `PATH`, or a file of yours in a directory, is only
replaced with `--overwrite` – unless it already is what the release
gives. An existing entry is only replaced with `--force`, like `unlink`
then `add`: the new entry has only the options given now. For big binary
files (1 MiB or more) not in Git LFS, `add` suggests `git lfs track`,
since each update adds another copy to the history.

```sh
git assetsync add acme/tool bin/tool --asset 'tool-*-linux-x64'

git assetsync filter add glab-binary --extract --include bin/glab
git assetsync add https://gitlab.com/gitlab-org/cli tools/glab \
    --asset '*_linux_amd64.tar.gz' --filter glab-binary

git assetsync filter add zlib-headers --extract --strip 1 --include '/*.h' LICENSE
git assetsync add madler/zlib third_party/zlib/ --asset 'zlib-*.tar.gz' --filter zlib-headers
```

### `rm`

```
git assetsync rm PATH… [-f] [-n]
```

Like `git rm`: removes the entries and their files and stages that – of a
directory only the release's files (`rm` says how many of yours stay). It
refuses all paths if one of those files has uncommitted changes; `-f`
removes them anyway (the content can be [got back](#commands)). Committed
modifications and files already deleted don't count. To keep the files,
use [`unlink`](#unlink).

| Option | Meaning |
|---|---|
| `-f`, `--force` | also with uncommitted changes |
| `-n`, `--dry-run` | only show what would be removed |

### `unlink`

```
git assetsync unlink PATH… [-n]
```

Removes the entries, and sources no longer used, from `.git-assetsync` and
stages it; the files stay as ordinary files. A broken entry (e.g. a path
outside the working tree) is removed by its name as written in the file.

### `mv`

```
git assetsync mv OLD NEW [-n]
```

Moves a file or directory with `git mv`, with its entry, and stages both.
`NEW` may be an existing directory – with a trailing `/` it must be one;
like `git mv`, `mv` makes no directories. A directory moves with
everything in it. `OLD` may also be an ordinary directory with entries in
it (e.g. `bin/`): all of them follow.

## Advanced commands

### `set`

```
git assetsync set PATH… [--source URL|SOURCE [--type github|gitlab]] [--release TAG|PATTERN | --latest]
                        [--prerelease | --no-prerelease]
                        [--asset PATTERN | --no-asset] [--filter NAME | --no-filter] [-n]
```

Changes entries – source, release selection, asset or filter – where `add`
would need `--force`. Only `.git-assetsync` changes (staged); `status`
then shows what changes, and `pull` updates the files, for one commit
with the change.

| Option | Effect |
|---|---|
| `--source URL\|SOURCE` | another project – a fork, a moved project – or another `[source]`; a source left unused is removed |
| `--release TAG\|PATTERN`, `--latest` | another release selection: a tag pins, a pattern takes the newest match, `--latest` the latest |
| `--prerelease`, `--no-prerelease` | let prereleases count, or not |
| `--type github\|gitlab` | with `--source` a new URL: the platform of its host |
| `--asset PATTERN`, `--no-asset` | another asset; `--no-asset`: the only one (a directory: all) |
| `--filter NAME`, `--no-filter` | another named [filter](#filters), or none |
| `-n`, `--dry-run` | only show what would change |

The base (`blob`, `digest`) stays, so local modifications stay
modifications. After another source or asset, `status` shows the entry as
pending (`entry changed`); if `pull` gets the same file, the commit only
records that (`Record … (…, file unchanged)`). A file can't become a
directory or the other way round: `unlink` it and `add` it again.

```sh
git assetsync set bin/tool --release 'v2.*'           # newest 2.x
git assetsync set firmware/ --source https://gitlab.com/me/fw-fork
git assetsync set bin/tool --asset 'tool-*-linux-arm64'
git assetsync set third_party/zlib --filter zlib-all
```

### `edit`

```
git assetsync edit
```

Opens `.git-assetsync` in the editor Git uses (`GIT_EDITOR`,
`core.editor`, `VISUAL`, `EDITOR`), like `git config --edit`, then checks
and stages it. A file that can't be parsed is not staged; gaps that
`status` would report are shown as warnings:

```
warning: .git-assetsync: [source "acme/old"] is not used by any file
warning: .git-assetsync: [file "bin/tool"]: no [source "acme/tol"]
warning: .git-assetsync: [file "lib/x.bin"] has synced but no blob (what it was synced with) - pull takes the release again
```

An entry with only source, asset, release selection and filter is not a
gap but not synced yet – handy to write many at once; `pull --all` takes
their releases. An emptied file is removed. For the usual changes,
[`set`](#set), [`source`](#source), [`filter`](#filter),
[`unlink`](#unlink) and [`mv`](#mv) are safer: `edit` keeps whatever you
write, also a changed base.

### `source`

```
git assetsync source [-v]
git assetsync source rename OLD NEW
git assetsync source set-url NAME URL
git assetsync source set-type NAME (github|gitlab | --unset)
```

Lists and changes the `[source]` sections, like `git remote`. The changes
are staged; `status` then shows what changes for the entries, and `pull`
updates them, for one commit.

| Action | Meaning |
|---|---|
| (none) | list the sources; `-v`: with URL, type and number of entries |
| `rename OLD NEW` | rename a source and all references to it |
| `set-url NAME URL` | change the URL, e.g. after the project moved |
| `set-type NAME github\|gitlab` | the platform of the host; `--unset`: derived from the host again |

There is one source per URL: `set-url` to the URL of another source is
refused, with a hint to move the entries there (`set <file>... --source
<source>`). The release selection is the entries' own: change it with
[`set`](#set).

### `source map`

```
git assetsync source map [URL|SOURCE [DIR]] [--flat] [--pattern PATTERN] [--sort date|name]
                         [--global] [--unset]
```

Takes the releases of a source from the local folder `DIR` instead of
GitHub or GitLab – to try a new build in another repository before
publishing it. The mapping applies to every source with that URL and is
kept in `.git/config` (`assetsync.<url>.localpath`), with `--global` in
your global Git config – never in `.git-assetsync`, which keeps the real
URL.

```
~/build/tool-releases/
  v1.2/       tool-linux.bin  tool-win.exe
  v1.3-rc1/   tool-linux.bin  tool-win.exe
```

```sh
git assetsync source map acme/tool ~/build/tool-releases  # by [source] name or URL
git assetsync status                                      # pending: bin/tool (v1.2 -> v1.3-rc1, local folder)
git assetsync pull bin/tool                               # takes v1.3-rc1 from the folder
git assetsync source map                                  # list the mappings
git assetsync source map acme/tool --unset                # remove it again
```

- Each **subdirectory** is a release named like its tag; its files are the
  assets (hidden files are ignored).
- With **`--flat`**, the folder itself holds the assets of all releases –
  e.g. a build's output folder. A file belongs to the release named like
  the file without its extension (`.tar.gz` and the like count as one);
  subdirectories are ignored.

  ```
  ~/build/fw-out/
    rel20260213.7z  rel20260213.xml     -> release rel20260213 (2 assets)
    rel20260410.7z  rel20260410.xml     -> release rel20260410 (2 assets)
  ```
- With **`--pattern PATTERN`**, only the matching subdirectories (with
  `--flat`: files) count, so several sources can share a folder:
  `source map acme/tool ~/build/out --pattern 'tool-*'`. The pattern
  matches the whole name, case-sensitively; other releases aren't seen at
  all.
- A release is dated by its **newest file**, so the latest is the one
  built last. With **`--sort name`** the greatest name is the newest
  instead – for names like `rel20261022`; they are compared character by
  character (`v1.10` comes before `v1.9`).
- `--flat`, `--pattern` and `--sort` are kept with the mapping; `source
  map` without them goes back to the defaults.
- There are no prereleases, drafts or release notes; the commit message
  says `Release: v1.3-rc1 (from a local folder, not published)`.
- Everything works offline; the assets are read from the folder. Their
  SHA-256 is remembered in the [download cache](#download-cache), so
  `status` doesn't read big files on every call.
- `--remote` asks the platform once (e.g. `status --remote`), `--unset`
  for good.
- An entry synced from a release the folder doesn't have – e.g. synced
  later from the server – is left as it is: `status` warns, and `pull`
  doesn't go back to a release of the folder (`pull --release` does).
- The [push check](#hooks) warns about entries whose release isn't
  published yet.

### `source releases`

```
git assetsync source releases URL|SOURCE [--assets] [-n N | --all] [--type github|gitlab]
```

Lists the releases of a project, newest first: tag, date and title,
marked `latest`, `prerelease` (GitLab: `upcoming`), `draft`, and `selected
by …` with the entries that select it – a help for choosing `--release`
and `--asset`. With a URL it also works outside a repository.

```console
$ git assetsync source releases acme/tool --assets -n 2
v1.1      2026-10-11  Tool 1.1  (latest, selected by bin/tool)
    tool-1.1-linux-x64     14.6 MiB
    tool-1.1-windows.zip   15.2 MiB
v1.1-rc1  2026-10-04  Tool 1.1 RC  (prerelease)
    tool-1.1-rc1-linux-x64  14.5 MiB
```

| Option | Meaning |
|---|---|
| `--assets` | also list the assets, with their sizes (GitLab reports none) |
| `-n`, `--max-count N` | the newest N releases (default: 10) |
| `--all` | all releases |
| `--type github\|gitlab` | platform of the URL's host |

### `filter`

```
git assetsync filter
git assetsync filter show NAME
git assetsync filter test NAME (FILE… | --source SOURCE [--release …] [--prerelease] [--type …] [--asset PATTERN]) [-o DIR]
git assetsync filter add NAME STEP-OPTIONS…
git assetsync filter set NAME STEP-OPTIONS…
git assetsync filter rename OLD NEW
git assetsync filter remove NAME
```

Lists and changes the [filters](#filters). Changes are staged; entries
using a changed filter show as pending.

| Action | Meaning |
|---|---|
| (none) | list the filters, with their steps and users |
| `show NAME` | the steps of a filter, and who uses it |
| `test NAME FILE…` | apply a filter to local files as if they were the assets (a directory: its files) and list the result, or write it to an empty directory with `-o DIR` |
| `test NAME --source SOURCE` | the same with the assets of a release (`--release`, `--prerelease`, `--type` as for [`add`](#add); `--asset`: only the matching ones) |
| `add NAME STEP-OPTIONS…` | define a filter with the [step options](#filters), in the order given; names consist of letters, digits, `.`, `+`, `-` and `_` |
| `set NAME STEP-OPTIONS…` | replace the steps of a filter |
| `rename OLD NEW` | rename a filter and its references |
| `remove NAME` | remove a filter nothing uses |

`filter test` changes nothing; it shows what each step did (on stderr),
then the result:

```console
$ git assetsync filter test zlib-headers --source madler/zlib --asset 'zlib-*.tar.gz'
input: madler/zlib v1.3.2: zlib-1.3.2.tar.gz
extract                 1 archive -> 287 files
strip 1                 287 files
include '/*.h' LICENSE  287 -> 16 files
1002 bytes  LICENSE
 577.9 KiB  crc32.h
  13.9 KiB  deflate.h
…
```

### `filter trust`

```
git assetsync filter trust
git assetsync filter trust NAME… | --all
git assetsync filter trust --revoke NAME…
```

Filters that run [commands](#commands-in-filters) run only if trusted in
this repository. Without arguments, `filter trust` lists them – `trusted`,
`not trusted` or `changed since trusted` – with their commands and the
scripts of the repository they run; on a terminal it asks for each one
not trusted. `NAME…` trusts filters as they are now, `--all` all of them,
`--revoke` takes the trust back. Trusts are kept in `.git/config`
(`assetsync.trusted`), never committed: each clone decides.

```console
$ git assetsync filter trust
filter firmware: not trusted (used by src/fw/)
  convert '*.bin' 'src/{stem}.c' 'xxd -i {in} > {out}'
  convert '*.hex' 'src/{stem}_hex.c' 'python3 {root}/tools/hex2c.py {in} {out}'
    (runs tools/hex2c.py of this repository)
  (use "git assetsync filter trust <name>..." or "git assetsync filter trust --all" to trust them in this repository)
```

### `verify`

```
git assetsync verify [PATH…] [-v]
```

Checks that the committed state is reproducible: for each entry (default:
all) it filters the assets of the release it was synced with again – from
the [download cache](#download-cache) or the platform – and compares the
result with the recorded base, as `git add` would store it. Nothing
changes, except that a directory's base missing in a clone is kept once
verified.

```console
$ git assetsync verify
third_party/zlib/: verified (v1.3.2)
src/fw/: differs from what v2.1 gives now:
	M	gen/fw.c
```

It also reports re-uploaded assets, a release that no longer exists and a
filter changed since the sync. Filters that run commands must be
[trusted](#filter-trust). Exit code 0 if all is verified, 1 if something
differs, 2 on errors – so CI can check that nobody changed a file by hand
and that filters are deterministic. `-v` first names where each entry
comes from, as `status -v` does.

### `cache`

```
git assetsync cache [list | prune [--older-than DAYS] [--max-size SIZE] [-n] | clear [-n] | dir]
```

The [download cache](#download-cache), shared by all your repositories:

```console
$ git assetsync cache
/home/me/.cache/git-assetsync: 37 files, 1.2 GiB
cleaned up automatically: files unused for 90 days (assetsync.cacheMaxAge, assetsync.cacheMaxSize)
$ git assetsync cache list
  12.3 MiB  2026-10-19  github.com/madler/zlib  v1.3.2  zlib-1.3.2.tar.gz
 340.0 MiB  2026-08-02  gitlab.com/acme/fw  fw-2026.07  fw.zip
```

| Action | Effect |
|---|---|
| (none) | where the cache is, how big, and its limits |
| `list` | its files, most recently used first |
| `prune` | remove what is beyond the limits; `--older-than DAYS` and `--max-size SIZE` (e.g. `500M`) set others for this run (`0` or `off`: none); `-n` only shows |
| `clear` | remove everything (`-n`: only show) |
| `dir` | print the directory, e.g. to cache it between CI runs |

What counts is when a file was last used. Files used in the last ten
minutes are never pruned, for another git-assetsync running at the same
time. A removed file is simply downloaded again when needed.

After a download, at most once a day, the cache is cleaned up by these
settings:

| Setting | Default | Meaning |
|---|---|---|
| `assetsync.cacheMaxAge` | `90` | remove files unused for that many days; `0` or `off`: never |
| `assetsync.cacheMaxSize` | (none) | then the least recently used, down to this size, e.g. `2G`; `0` or `off`: no limit |

```sh
git config --global assetsync.cacheMaxSize 5G
```

### `hooks`

```
git assetsync hooks
git assetsync hooks install [--force]
git assetsync hooks uninstall
```

`hooks` shows the state of the two hooks – `installed`, `outdated`
(update with `hooks install`), `not installed`, or a hook of another tool
without our lines:

```console
$ git assetsync hooks
pre-push: installed
post-merge: hook of another tool, without our lines (add them with 'git assetsync hooks install --force')
```

`hooks install` installs or updates two hooks that report on stderr:

- `pre-push` – reminds of new releases, local modifications, missing
  files and errors before pushing
- `post-merge` – reminds of local modifications and missing files after
  `git pull` / `git merge`, offline

```
assetsync: bin/tool: upstream pending (v1.0 -> v1.1)
assetsync: run 'git assetsync pull <file>' to update
```

**Push check:** `pre-push` also reports pushed entries synced from a
release that isn't on GitHub or GitLab – typically pulled from a [local
folder](#source-map) – or whose assets differ from the release there:

```
assetsync: bin/tool: synced from release v1.3-rc1, which is not on the server (https://github.com/acme/tool) - publish it there first
assetsync: bin/tool: synced from assets of release v1.3 that differ from those on the server (https://github.com/acme/tool) - publish them there first
```

Others couldn't pull or verify that state. The check ignores mappings and
only asks for entries the remote doesn't have yet, so usually no request
is needed. GitLab reports no digests; there only the tag is checked. Like
Git with submodules, it only warns by default; `assetsync.pushCheck` sets
what happens:

| `assetsync.pushCheck` | Effect |
|---|---|
| `warn` (default) | report, push anyway |
| `error` | report and refuse the push (`git push --no-verify` skips it) |
| `off` | no check |

Apart from `error`, the hooks never block – not even if git-assetsync
fails or is missing, or the platform can't be asked. The hooks run `git
assetsync hook pre-push` / `hook post-merge` (like `git lfs pre-push`), so
new versions change what they do without reinstalling.

Hooks of other tools aren't changed: `hooks install` prints the lines to
add, or with `--force` adds them right after the `#!` line. In a
`pre-push` hook they must come first, since the push check reads the
pushed refs from stdin; they pass them on to the commands after them
(such as `git lfs pre-push`). `hooks uninstall` removes the hooks, or only
our lines. With `core.hooksPath` set, the hooks go there (with a warning:
other repositories may use it).

## Further topics

### Selecting the release

The `release` key of an entry (`add --release`, `set --release`) decides
which release it takes:

| `release` | Release taken |
|---|---|
| (none) | the **latest**, as the platform defines it – GitHub: the one marked latest, else the newest that is no prerelease or draft; GitLab: the newest by release date |
| a tag, e.g. `v1.0` | exactly that release (**pinned**), also a prerelease |
| a pattern, e.g. `tool-*` | the **newest by date** whose tag matches |

Tags are opaque strings: no versioning scheme, never sorted by name.
"Newest" is the date the platform reports – so a pattern works for
`v1.2.3`, date tags like `tool-20261016`, and several tools released from
one repository under different prefixes. There is no reserved value like
`latest`.

Drafts never count; prereleases only with `prerelease = true` (`add
--prerelease`).

If the selected release has no asset matching the entry's pattern, or
several, that is an error – also when an older release would match, so a
renamed asset doesn't go unnoticed: `git assetsync set PATH --asset
'NEW-*'`, then `pull`.

To change the selection, use [`set --release`](#set) (e.g. `set lib/ bin/
--latest`) and `pull`; to take another release once, [`pull
--release`](#pull).

### Filters

A filter turns the downloaded assets into the files of an entry, without
running any code. Filters are **named**: defined with [`filter
add`](#filter) and used by any number of entries (`add --filter`, `set
--filter`).

A filter is a list of steps, applied in order; files a step doesn't
concern pass unchanged. At the start, the files are the assets. `filter
add` and `filter set` build the steps from their options, **in the order
given**; each option is one step:

| Option (step) | Effect |
|---|---|
| `--extract [PATTERN…]` | unpack the matching files (default: all), which must be archives: ZIP, tar (also .gz, .bz2, .xz), single `.gz`/`.bz2`/`.xz` files, and 7z with an external 7-Zip; recognized by content. All go into one root; with other files among the assets, choose the archives: `--extract '*.zip'` |
| `--subdir PATH` | only the files below `PATH`, which becomes the root |
| `--strip N` | remove `N` leading directories, like `tar --strip-components`; files with fewer are left out |
| `--include PATTERN…` | only the files matching any of the patterns |
| `--exclude PATTERN…` | not the files matching any of the patterns |
| `--move PATTERN TARGET` | move what matches – files, or directories with all below them – see below |
| `--copy PATTERN TARGET` | the same, keeping the originals |
| `--apply PATTERN NAME` | apply the filter `NAME` to the matching files only, see [Filters using filters](#filters-using-filters) |
| `--executable PATTERN…` | make the matching files executable, see [Executables](#executables) |
| `--eol PATTERN lf\|crlf\|native` | line endings of the matching text files, see [Line endings in filters](#line-endings-in-filters) |
| `--changelog PATTERN…` | put the text of the matching files into the commit message of `pull`, see [Changelogs from the assets](#changelogs-from-the-assets) |
| `--convert PATTERN TARGET COMMAND` | convert each matching file with a command of your own (e.g. bin2c), see [Commands in filters](#commands-in-filters) |
| `--run PATTERN COMMAND` | run a command on all matching files at once, see [Commands in filters](#commands-in-filters) |

**The patterns of one option** count together: `--include '/*.h' LICENSE`
keeps the headers *and* the license. Two options are two steps: `--include
'/*.h' --include LICENSE` keeps the headers, then of those only `LICENSE`
– nothing.

```sh
git assetsync filter add zlib-headers --extract --strip 1 --include '/*.h' LICENSE
```

```ini
[filter "zlib-headers"]
	step = extract
	step = strip 1
	step = include '/*.h' LICENSE
```

Patterns work like in `.gitignore`, relative to the root after the
previous steps: without a `/` a pattern matches a name at any depth
(`*.h`), a leading or inner `/` anchors it (`/*.h`, `include/*.h`), a
trailing `/` matches a directory with everything below it, and `**/`
matches any number of directories.

**`TARGET` of `move` and `copy`**: what matches moves – a file, or a
directory with everything below it. With a trailing `/`, `TARGET` is the
directory it goes into, under its name (`--move '*.h' include/`; `./` is
the root). Else `TARGET` is its new path, with placeholders for parts of
the old one – for `images/boardA/app.bin`:

| Placeholder | Value |
|---|---|
| `{path}` | `images/boardA/app.bin` |
| `{dir}` | `images/boardA` |
| `{parent}` | `boardA` |
| `{name}` | `app.bin` |
| `{stem}` | `app` |
| `{ext}` | `.bin` |

So `--move 'images/*/app.bin' 'firmware/{parent}.bin'` makes
`firmware/boardA.bin`, `firmware/boardB.bin`, …, and `--move include/ api`
renames the directory `include` to `api`.

A step whose pattern matches nothing changes nothing, so a filter stays
valid for a release that lacks some files. Errors are only: a file
`extract` can't unpack, results that would replace each other, and no
files left at all (a file entry needs exactly one). In `pull` and
`verify` filters are silent; [`filter test`](#filter) shows what each
step did.

#### Executables

A downloaded asset is never executable. A file is executable when an
archive marks it so or a [command](#commands-in-filters) makes it, or by
**`--executable PATTERN…`** – e.g. a program that is an asset as it is:

```sh
git assetsync filter add exe --executable '*'
git assetsync add acme/tool bin/tool --asset 'tool-*-linux-x64' --filter exe
```

The executable bit is part of what an entry gets: `status` counts a lost
or added bit as a local modification, `pull` and `restore` set it. So
make such a file executable with the filter, not by hand. On Windows
(`core.filemode = false`) the bit is still kept in the repository.

#### Line endings in filters

**`--eol PATTERN lf|crlf|native`** sets the line endings of the matching
files – for a command step that expects certain ones, or a repository
whose `.gitattributes` say nothing about them:

```sh
git assetsync filter add sdk --extract --eol '*.h' lf --eol '*.bat' crlf
```

- Binary files stay as they are, decided as git does for `text=auto`
  (a NUL byte, a lone CR, many control characters).
- `native` is CRLF on Windows, LF elsewhere – so the result depends on
  the platform: `verify` on another one may find it differs.
- The repository's `.gitattributes` still decide how files are stored and
  checked out (see [Line endings](#line-endings)).

#### Filters using filters

Some steps act on all files – `strip`, `subdir`, `include` – and `extract`
unpacks all archives into one root. When that must not touch the other
files, **`apply PATTERN NAME`** lets another named filter treat some files
on their own: the matching files are set aside, `NAME` runs on them alone,
and its result joins the others again (a path that collides is an error).

For example, a release of `acme/sdk` with two ZIPs of the same layout and
a firmware image:

```
sdk-2.1-headers.zip    sdk-2.1/include/sdk.h, sdk-2.1/README.md
sdk-2.1-libs.zip       sdk-2.1/lib/libsdk.a,  sdk-2.1/README.md
fw-boardA.bin
```

`--extract 'sdk-*.zip' --strip 1` fails: both ZIPs have
`sdk-2.1/README.md`, and `--strip 1` would drop `fw-boardA.bin`. With a
filter `unpack` applied to each ZIP on its own:

```sh
git assetsync filter add unpack --extract --strip 1 --exclude README.md
git assetsync filter add sdk --apply 'sdk-*-headers.zip' unpack \
    --apply 'sdk-*-libs.zip' unpack --move 'fw-*.bin' firmware/
git assetsync add acme/sdk vendor/sdk/ --filter sdk
```

```
vendor/sdk/
  include/sdk.h            <- sdk-2.1-headers.zip, via unpack
  lib/libsdk.a             <- sdk-2.1-libs.zip, via unpack
  firmware/fw-boardA.bin   <- moved by the last step
```

`unpack` is a filter like any other: entries can use it directly, and
`filter test unpack sdk-2.1-libs.zip` tries it. A filter may use other
filters, but not itself. A changed filter makes all entries using it
pending, also through other filters.

#### Archives

Archives are unpacked safely: members outside the target (`..`, absolute
paths, drive letters), in a `.git` directory, links and special files are
refused, as are names that aren't valid on every platform (e.g. `con.txt`
on Windows), duplicate paths and paths that differ only in case. At most
2 GiB and 100 000 files are unpacked per entry.

**7z archives** need 7-Zip: `7zz`, `7z`, `7za` or `7zr` on the `PATH`, on
Windows also in `Program Files\7-Zip`; `ASSETSYNC_7Z` sets another
command. git-assetsync checks the listing first (encrypted members are
refused), lets 7-Zip unpack into an empty directory and checks the result
again. A `.7z` asset taken as it is needs no 7-Zip.

#### Changelogs from the assets

**`--changelog PATTERN…`** adds the text of the matching files to the
[release notes](#proposed-commit-messages) in the commit message of
`pull`; the files themselves stay (remove them with a later `--exclude`).
This helps where the release page says little – above all with a [local
folder](#source-map), which has no notes at all:

```sh
git assetsync filter add fw --extract --changelog CHANGELOG.txt --exclude CHANGELOG.txt
```

```
[assetsync] Update firmware/ to acme/fw rel20260410 (2026-04-10, was rel20260213 of 2026-02-13)

Release: rel20260410 (from a local folder, not published)
Asset:   rel20260410.7z
Filter:  fw

Changelog (CHANGELOG.txt):
  2026-04-10: faster boot
  2026-02-13: first release
```

- The text is shortened like the notes (by default its first 20 lines –
  the new entries, in a changelog with the newest on top).
- It is read as UTF-8, else as Windows-1252; UTF-16 with a BOM. Other
  files with a NUL byte are skipped.
- It comes with an update to another release, and when the assets of the
  same release were replaced (a local build made again) – not for a new
  entry or going back.

#### Commands in filters

Two steps run commands of your own:

- **`convert PATTERN TARGET COMMAND`** runs `COMMAND` for each matching
  file: `{in}` is the file, `{out}` the result, which replaces it at
  `TARGET` – with the placeholders of `move`, e.g. `'gen/{stem}.c'`. A
  `TARGET/` with a trailing `/` is a directory: `{out}` is then an empty
  directory, and all files the command writes there go into it (e.g. a
  `.c` and a `.h`). To keep the original, `--copy` it first.
- **`run PATTERN COMMAND`** runs `COMMAND` once for all matching files
  (`'*'`: all): `{in}` is a directory with them, `{out}` an empty
  directory; what the command writes there replaces them.

```sh
git assetsync filter add firmware --extract --include '*.bin' '*.hex' \
    --convert '*.bin' 'src/{stem}.c' 'xxd -i {in} > {out}' \
    --convert '*.hex' 'src/{stem}_hex.c' 'python3 {root}/tools/hex2c.py {in} {out}'
```

The commands run with `sh -c` (on Windows the `sh` of Git for Windows;
`ASSETSYNC_SH` sets another), in a temporary directory where `{in}` and
`{out}` are **short relative names** – for `convert` the file names
(`fw.bin`, `fw.c`), for `run` `in` and `out` – so tools that derive names
from them (like `xxd -i`) give the same result everywhere. `{root}` is
the repository's root, for its scripts. The placeholders are filled in
quoted, and are in the environment too (`ASSETSYNC_IN`, `ASSETSYNC_OUT`,
`ASSETSYNC_ROOT`, …), with `ASSETSYNC_RELEASE`, `ASSETSYNC_SOURCE` and
`ASSETSYNC_ENTRY`. A command that fails, writes no result or writes links
is an error.

Commands run only when assets are filtered – on `pull`, `add`, `filter
test`, `diff --upstream`, `verify`, and when a directory's base is got
again – never on `status`, and a clone gets the committed files without
running anything. They should be deterministic; [`verify`](#verify)
checks it.

**Trust.** The commands come from `.git-assetsync`, a committed file:
whoever can change it could run commands on every machine that pulls. So
a filter with commands runs only if it is **trusted in your clone**, with
[`filter trust`](#filter-trust). A changed filter, or a changed script of
the repository it runs (`{root}/tools/hex2c.py`), needs a new trust and
makes the entries pending. On a terminal, `pull` and `add` ask; otherwise
they refuse with a hint. In CI, set `ASSETSYNC_TRUST=all`.

### Proposed commit messages

```
[assetsync] Update bin/tool to acme/tool v1.1 (2026-10-11, was v1.0 of 2026-10-01)

Release: https://github.com/acme/tool/releases/tag/v1.1
Title:   Tool 1.1
Asset:   tool-1.1-linux-x64

Release notes:
  ## What's Changed
  * Fix crash on empty input by @someone in https://github.com/acme/tool/pull/42
  * Faster startup

  **Full Changelog**: https://github.com/acme/tool/compare/v1.0...v1.1
```

The subject starts with `[assetsync] ` (`git log --grep='^\[assetsync\]'`;
git-filesync's with `[filesync] `) and names the entry, the source and the
release: `Add …`, `Update … to … (…, was …)`, `Update … (…, asset
replaced)`, `Update … (…, filter changed)`, or `Restore …` when `pull
--overwrite` only brought back what the release gives. The body links the
release page and names its title, the assets and the filter, for a
directory also what changes. Each release named has its date
(`YYYY-MM-DD`, UTC, as `source releases` shows it):

```
[assetsync] Update third_party/zlib/ to madler/zlib v1.3.2 (2026-02-17, was v1.3.1 of 2025-01-22)

Release: https://github.com/madler/zlib/releases/tag/v1.3.2
Title:   zlib 1.3.2
Asset:   zlib-1.3.2.tar.gz
Filter:  zlib-headers
Files:   1 added, 0 removed, 9 changed (12 in total)
```

Updated to another release, the **release notes** follow – and text from
a [`changelog` step](#changelogs-from-the-assets) – so the log tells what
changed: at most 20 lines of 200 characters, without HTML comments,
indented so that `git commit` doesn't take `## headings` for comments.

**Skipped releases** – between the synced and the new one, selected by
the entry's rule – are listed in `Since:`, and their notes follow, newest
first; at most 60 lines of notes in all, older ones only referred to.
Going back to an older release, `Reverted:` lists the releases undone.

```
[assetsync] Update bin/tool to acme/tool v1.3 (2026-10-25, was v1.0 of 2026-10-01)

Release: https://github.com/acme/tool/releases/tag/v1.3
Asset:   tool-1.3-linux-x64
Since:   v1.2 (2026-10-18), v1.1 (2026-10-11)

Release notes v1.3 (2026-10-25):
  ...
Release notes v1.2 (2026-10-18):
  ...
Release notes v1.1 (2026-10-11):
  ...
```

| Setting | Default | Meaning |
|---|---|---|
| `assetsync.notesLines` | `20` | lines of notes per release; `0`: none (the link and `Since:` stay) |
| `assetsync.notesTotalLines` | `60` | lines of notes in all |

`add` and `pull` add the proposal to `.git/SQUASH_MSG`, which a plain
`git commit` offers (as do IDEs like VS Code). Proposals of several
commands are collected; git removes the file after the commit. A copy
stays in `.git/ASSETSYNC_MSG`, overwritten with each proposal – to get it
back after `git commit -m` or `git reset`: `git commit -e -F
.git/ASSETSYNC_MSG`.

### GitHub and GitLab access

git-assetsync asks the platforms through their command-line tools, used
only as authenticated HTTP clients: `gh api` ([GitHub
CLI](https://cli.github.com)) and `glab api` ([GitLab
CLI](https://gitlab.com/gitlab-org/cli)). So it works with whatever they
are logged in to – `gh auth login` / `glab auth login`, or `GH_TOKEN` /
`GITLAB_TOKEN` (e.g. in CI); public GitLab projects need no login. For
GitHub Enterprise or a self-managed GitLab, log in to that host
(`--hostname HOST`); the host is always passed on, so `GH_HOST` doesn't
redirect requests. Only the tool for the platforms you use is needed.

On GitHub, assets are downloaded through their API URL. On GitLab, the
assets of a release are its **links** (not the generated source
archives). Links on the project's host – the generic package registry,
job artifacts, uploads – are downloaded through `glab api`, with your
login; links to other servers plainly, so they must be public (`http://`
works, with a warning). GitLab releases with a future release date
("upcoming") count as prereleases; there are no drafts.

`ASSETSYNC_GH` / `ASSETSYNC_GLAB` set other commands instead of `gh` /
`glab` (on Windows with forward slashes).

### Integrity

GitHub reports a SHA-256 digest for assets uploaded since June 2025; the
download is checked against it. For older assets the digest is computed
from the download. Either way it is recorded, so a re-upload with other
content shows up as pending.

Where the platform reports no digests – GitLab, older GitHub assets – the
entry also records `assetid`: name, id, URL and size of the assets. A
re-upload changes it, so `status` notices without a download. Only other
content behind the same URL goes unnoticed (e.g. an overwritten generic
package) – not even `verify` sees it while the cache has the old file
(`cache clear`, then `verify`).

### Download cache

Downloaded assets are cached, so another filter, `pull --overwrite` or a
second repository needs no new download: in `~/.cache/git-assetsync` (or
`$XDG_CACHE_HOME/git-assetsync`), on Windows
`%LOCALAPPDATA%\git-assetsync`; `ASSETSYNC_CACHE` sets another directory.
It also remembers the SHA-256 of assets in [local folders](#source-map).
Files unused for 90 days are removed automatically; see [`cache`](#cache).
Deleting it by hand does no harm.

### Git LFS

Files are stored as `git add` would: if `.gitattributes` puts one into Git
LFS, it is committed as an LFS pointer. Run `git lfs track PATTERN` before
`add` (it suggests that for big binaries). Files moved to LFS later stay
unmodified. Needs `git-lfs`.

### Line endings

Files are stored as `git add` stores them, so `text=auto`, `eol` and
`core.autocrlf` apply as for any other file, and written as `git checkout`
writes them. Changing these settings later doesn't make entries count as
modified. To keep an asset byte for byte, mark it `-text` in
`.gitattributes`; to set line endings in the filter, see
[`--eol`](#line-endings-in-filters).

### Offline operation

`status` decides offline whether the files are still what their release
gave; only the check for new releases needs GitHub or GitLab (`--no-fetch`
skips it). `diff` works offline too, and everything with a source
[mapped to a local folder](#source-map). `add`, `pull` and `diff
--upstream` always ask which release to take; cached assets aren't
downloaded again.

Commands that only look – `status`, `diff`, `difftool`, `verify`, the
hooks – change nothing in the repository (except that a directory's base
got again is kept).

### Colors

Output is colored like `git status`: pending updates yellow, local
modifications red, entries not committed yet green. Colors follow
`color.assetsync`, else `color.ui`; `--color` / `--no-color` override
that, and `NO_COLOR` turns them off. With Python 3.14 or later the help
(`-h`) is colored too.

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

To pin a version, download
`https://github.com/stsichler/git-assetsync/releases/download/v0.23.2/git-assetsync.py`
instead. `gh` is preinstalled on GitHub's runners; for sources in other
private repositories use a token with read access. For GitLab sources,
install `glab` (and give `GITLAB_TOKEN` for private projects).

### Exit codes

| Code | Meaning |
|---|---|
| `0` | ok |
| `1` | something to do: `status --exit-code` found something to pull, modified or missing; `verify` or `diff --exit-code` found a difference |
| `2` | error, also an entry `pull` refused |
| `141` | output into a pipe closed early (e.g. `\| head`), as with git: a command that only looks stops there, one that changes something finishes first |

`-n` (`--dry-run`) exits with 0, or 2 on errors.

### Windows

git-assetsync runs with Git for Windows and a Python from python.org or
the Microsoft Store; set the alias with `py` or `python` (see the
[README](README.md)). Output has LF line ends, like git's.

Git for Windows runs the alias through its MSYS shell, also from cmd or
PowerShell. That shell changes two kinds of arguments:

- **Wildcards** (`*`, `?`, `[…]`) are expanded if a file in the current
  directory matches, quoted or not: `--asset 'tool-*.zip'` turns into
  `tool-1.0.zip` when that file is there.
- **Arguments starting with `/`** become Windows paths: `unlink /tmp/x`
  turns into `C:/Users/…/Temp/x`.

For such arguments, run the script directly (`py
C:/tools/git-assetsync.py …` in cmd or PowerShell), or put
`MSYS_NO_PATHCONV=1` in front in Git Bash. Don't set it (or
`MSYS=noglob`) for git itself: that breaks how git passes arguments to the
alias.

### Shipping git-assetsync with your repository

git-assetsync can keep a copy of itself in your repository, so everyone
has the same version:

```sh
git assetsync add stsichler/git-assetsync tools/git-assetsync.py --asset git-assetsync.py
git commit
git config alias.assetsync '!python3 tools/git-assetsync.py'     # each clone, once (Windows: !py …)
```

The alias in `.git/config` takes precedence over a global one; git runs
it in the top-level directory, so the relative path works everywhere.
`status` then shows new releases of git-assetsync too. The same works for
[git-filesync](https://github.com/stsichler/git-filesync).
