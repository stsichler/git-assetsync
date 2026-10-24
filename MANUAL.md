# git-assetsync manual

Detailed description of the concepts, commands and options of
git-assetsync. For motivation and installation see the [README](README.md).

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
self-managed), alike. A **release** is identified by its **tag**
(e.g. `v1.3.1` or `tool-20261016`); its title is only shown. Each release
has **assets**: the files attached to it.

git-assetsync takes a file or a directory of your repository from assets:
it downloads them, optionally unpacks and selects files from them with a
[filter](#filters), writes the result to the path and records in
`.git-assetsync` which release and assets it comes from. Both are the
entry's: which release – the latest, the newest one whose tag matches a
pattern, or one fixed release (see [Selecting the
release](#selecting-the-release)) – and which assets of it: a glob pattern
for the asset names – they usually contain the version, so the pattern
stays the same across releases while the path in your repository doesn't
change.

Updates are never applied automatically: `status` shows that a new release
is out, `pull` updates the file (directory) and stages it with a proposed
commit message naming the release; you commit. All commands run inside your repository.

### Files and directories

An entry is one of two kinds; [`add`](#add) decides by the form of the
path:

- **A file** (`add bin/tool …`): exactly one file – one asset as it is, or
  the one file a filter leaves of it (e.g. one file from a ZIP). Files
  next to it are not concerned.
- **A directory** (`add third_party/zlib/ …`, with a trailing `/`, or an
  existing directory): any number of files – all assets of the release (or
  those matching `--asset`), as they are or after the filter. The entry
  has **the files its release gave**: `pull` replaces them with those of
  the new release, and deletes those it no longer has. Files of your own
  in the directory are left alone – see [Files of your own in a
  directory](#files-of-your-own-in-a-directory).

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
	mode = 100755                # its mode: 100644, or 100755 (executable)
[source "acme/multi"]
	url = https://github.com/acme/multi
[file "firmware/fw.bin"]
	source = acme/multi
	release = toolA-*            # newest release whose tag matches
	prerelease = true            # optional: prereleases count too
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

- **`[source "NAME"]`** – a project, like a Git remote: `url` is its web
  address, one source per URL. `type` (`github` or `gitlab`) names the
  platform; it is only needed for hosts other than github.com, gitlab.com
  and those whose name starts with `gitlab` (like `gitlab.example.com`).
  `add` names new sources `owner/repo` after the URL, with a number
  appended if that name belongs to another URL.
- **`[file "PATH"]`** – a file of the repository (path relative to the
  root) and the asset it comes from: `source` (name of its `[source]`),
  which release – without `release`, the latest; `release` is a tag (the
  file is pinned to that release) or a pattern with `*`, `?` or `[…]`
  (the newest release whose tag matches); `prerelease = true` lets
  prereleases count – and `asset` (glob pattern; without it, the
  release's only asset) say what to take. `synced`, `digest`, `blob` and
  `mode` are written by git-assetsync and record what the committed file
  is based on: the release tag, the asset's SHA-256, the id of the file
  as `git add` stores it (after line-ending conversion and Git LFS), and
  its mode as the filter gave it – `100755` for an executable (taken out
  of an archive, or made one with [`--executable`](#executables)), else
  `100644`. With `blob` and `mode`,
  `status` knows offline whether the committed file and the working tree
  file are still the asset – a lost executable bit too (where the system
  has one; with `core.filemode = false`, as on Windows, git takes modes
  from the index); `restore` brings it back. Entries synced before 0.21.0
  have no `mode`: there it doesn't count until their next `pull`. Where the platform reports no
  digests, `assetid` records which uploads they were (see
  [Integrity](#integrity)).
- **`[dir "PATH"]`** – a directory and the assets it comes from: like
  `[file]`, but `asset` may match several assets (without it: all), and
  the base is `tree`, the id of the directory as committed.
- **`[filter "NAME"]`** – a [named filter](#filters): its steps, one
  `step` key per step, in order. An entry uses it with `filter = NAME` (in
  `[file]` and `[dir]`); `filterhash` records the filter the entry was
  synced with, so a changed filter shows up as pending. Like sources,
  filters are referred to by name – but they are never created or removed
  automatically.

There is one `[source]` per URL; each entry selects its release itself
(`release`, `prerelease`), so the entries of one project can follow
different releases – e.g. two tools released from one repository under
different tag prefixes.

The commands maintain the file: `add`, `set`, `unlink` and `mv` for the
`[file]` and `[dir]` entries, [`source`](#source) for the `[source]`
sections. It can also be edited by hand – with [`edit`](#edit), which
checks and stages it afterwards, or with `git config -f .git-assetsync
…` – but that is never needed; `synced`, `digest`,
`filterhash`, `blob`, `mode` and `tree` should be left to git-assetsync.
An entry written by hand without them is fetched by the next `pull`
(files already at its paths only go with `--overwrite`, unless they are
what the release gives). Changes to
the file are committed along with what the next `pull` stages, or on
their own.

### No local modifications

A file taken from an asset must stay exactly what the release gives – a
binary or a generated file can't be merged with local changes. A file that
differs – committed or not, also deleted – is reported by `status` as
**NOT ALLOWED**, `status --exit-code` exits with 1, and `pull` refuses to
update it. [`diff`](#diff) shows the modification; [`restore`](#restore)
discards it and brings back what the release gave, `pull --overwrite`
discards it and updates to what the selected release gives (with a
warning, and a note in the commit message).

In a directory entry, only the files of the release count: one of them
changed or deleted is a modification; other files there are not the
entry's (see below). Files an entry gets – the file of a file entry, the
files of a directory entry – are always staged and committed, also if
`.gitignore` would ignore them (e.g. `*.lib`), and written as `git
checkout` writes them (line endings, filters of `.gitattributes`).

What counts is the content, not how it is stored: a file that is
re-stored differently after `.gitattributes` changed (moved to Git LFS,
line endings normalized) is still unmodified.

### Files of your own in a directory

A directory entry doesn't need a directory of its own: the files of the
release can be next to files of yours – a `CMakeLists.txt`, a `README`,
patches, build output. They are yours, tracked or not: `status`
doesn't report them, `pull` and `restore` leave them alone, `pull`
commits only the files of the release (other changes you staged there
stay staged), `rm` removes only the release's files, and `mv` moves the
directory with everything in it.

A new release with a file where one of yours is – the same name, also in
another case (`README.md` and `README.MD` are one file on Windows and
macOS), or a file of yours where the release has a directory – is
refused, by `add` and by `pull`, naming the files in the way. With
`--overwrite` the release's files replace them and become the entry's. A
file of yours that is just what the release gives (the same path,
content and mode) is not in the way: it becomes the entry's without `--overwrite`,
as for a file entry (`add` onto an existing file of the same content).

Which files are the release's comes from the recorded `tree`: what the
release gave, after the filter. When files of yours are committed in the
directory, that tree isn't committed itself, so a fresh clone doesn't
have it. There, `status` says so and doesn't check the directory for
local modifications; `verify` gets the tree again – filtering the assets
of the release it was synced with, from the download cache or the
platform – and so do `pull`, `restore`, `rm`, `diff` and `difftool`
when they need it. It is then kept in the clone (as
`refs/assetsync/base/<tree>`, never pushed). If that is no longer
possible – the release is gone or its assets were re-uploaded, or the
filter was changed without a `pull` – `pull` refuses; with `--overwrite`
it adds the files of the new release and deletes none.

## Commands

Basic commands – what you need day to day:

| Command | Purpose |
|---|---|
| [`status [PATH…]`](#status) | state of the entries, like `git status` |
| [`pull PATH…`, `pull --all`](#pull) | update files and directories to the selected release (or once another one) and stage them, with a proposed commit message |
| [`diff [PATH…]`](#diff) | local modifications against what the release gave; what `pull` would bring |
| [`difftool [PATH…]`](#difftool) | the same in your difftool, file by file or (`-d`) as two directories |
| [`restore PATH…`](#restore) | discard local modifications: back to what the release gave, without pulling |
| [`add SOURCE PATH`](#add) | take a file or directory from release assets |
| [`rm PATH…`](#rm) | remove entries and their files, like `git rm` |
| [`unlink PATH…`](#unlink) | remove entries (the files are kept) |
| [`mv OLD NEW`](#mv) | move a file or directory, keeping its entry |

[Advanced commands](#advanced-commands) – to change entries, sources and filters, and for setup:

| Command | Purpose |
|---|---|
| [`set PATH… OPTIONS`](#set) | change entries: source, release selection, asset, filter |
| [`edit`](#edit) | open `.git-assetsync` in the editor, then check and stage it |
| [`source [ACTION …]`](#source) | list sources; rename them, change URL or type |
| [`source map [URL\|SOURCE [DIR]]`](#source-map) | take the releases of a source from a local folder (local development, tests) |
| [`source releases SOURCE\|URL`](#source-releases) | list the releases of a project, with their assets |
| [`filter [ACTION …]`](#filter) | list filters; show, test, add, set, rename or remove them |
| [`filter trust [NAME…]`](#filter-trust) | list the filters that run commands; trust them in this repository |
| [`verify [PATH…]`](#verify) | filter the synced assets again: is the committed state reproducible? |
| [`cache [ACTION]`](#cache) | the download cache: show, list, prune, clear |
| [`hooks [install\|uninstall]`](#hooks) | hooks: reminders, push check – their state, install, remove |

Commands named like a Git command behave like it (`status`, `pull`, `diff`,
`difftool`, `restore`, `add`, `rm`, `mv`; `source` like `git remote`): same
kind of output, same exit codes, same caution with uncommitted changes.

**No command commits.** Like `git add`, `git rm`, `git mv`, `git restore`
– and `pull` like `git merge --squash` – they only change the working tree
or stage, and you commit, when and with what you like: `pull`, `add`, `rm`,
`mv`, `set`, `unlink`, `edit`, `source` and `filter` stage, `restore`
(without `-S`) leaves the index alone. `pull` and `add` prepare a proposed
commit message that a plain `git commit` offers (see [Proposed commit
messages](#proposed-commit-messages)) – for `pull` it names the release,
its notes and those of releases skipped. What else is staged then goes
into the same commit; that's up to you.

Without a command, `status` runs. `PATH` may be a file or a directory (all
entries below it) and is relative to the current directory. A path inside
a directory entry (`third_party/zlib/zlib.h`) stands for that entry in
`status`, `diff`, `difftool`, `verify` and `pull`; commands that change
entries (`set`, `restore`, `rm`, `unlink`) refuse it – an entry is only
changed as a whole. Options follow the command; `git assetsync <command>
-h` lists them.

Two options mean the same in all commands (and in git-filesync):
**`--overwrite`** lets a command replace local content – a file of yours,
local modifications – with what the release gives; **`--force`** lets it
do something it refuses by default, without losing local content (replace
an entry, add the lines to hooks of other tools).

**Discarded content can be got back.** When `restore`, `rm -f` or
`--overwrite` replace or delete a file whose content isn't committed –
nor staged, where the index stays as it is (`restore` without `-S`) –
they keep that content as a Git object first and say how to get it back:

```
discarded: lib/data.bin (git show 1a2b3c4d5e6f to get it back)
```

`git show 1a2b3c4d5e6f > lib/data.bin` writes it back exactly as it was.
Where the index goes too (`rm -f`, `--overwrite`, `restore -S`), a staged
version that is neither committed nor what the working tree has is named
as well: `discarded: lib/data.bin, as staged (git show … to get it
back)` – as git stores it (e.g. line endings normalized).
Nothing refers to the object, so `git gc` removes it after a while
(normally two weeks).

### Common options

| Option | Meaning |
|---|---|
| `--color[=WHEN]`, `--no-color` | colored output: `always`, `never` or `auto` (default), see [Colors](#colors) |

### `status`

```
git assetsync status [PATH…] [-s] [-v] [--exit-code] [--no-fetch]
```

Shows the state of the files and directories (default: all) in sections
like `git status`; directories are shown with a trailing `/`:

```
Upstream changes to pull:
  (use "git assetsync diff --upstream <file>..." to see what pull would bring)
  (use "git assetsync pull <file>..." to update)
	pending:    bin/tool  (v1.0 -> v1.1)
	new:        firmware/fw.bin  (release toolA-20261016)

Locally modified files:
  (use "git assetsync diff <file>..." to see the modifications)
  (use "git assetsync restore -SW <file>..." to restore the release asset)
	modified:   lib/data.bin  (NOT ALLOWED)
	deleted:    bin/tool  (NOT ALLOWED)

Not committed yet:
  (use "git commit" to commit them)
	new file:   third_party/zlib/
```

- **Upstream changes to pull** – `pending`: the entry selects another
  release than the one it comes from (`v1.0 -> v1.1`), the asset of
  that release was replaced (re-uploaded with other content), or the
  filter was changed (`filter changed`). `new`: an entry without a synced
  release yet, or one not in the working tree yet.
- **Locally modified files** – the file (directory) differs from what the
  release gave: in the working tree or committed – both are not allowed,
  and `restore -SW` (then a commit) brings it back either way.
- **Not committed yet** – an entry added or pulled and staged, not
  committed yet.

With nothing to report: `nothing to pull, all N files unmodified` (or
directories). Errors
(no release found, the asset pattern matches no or several assets, broken
entries) are printed on stderr for the file concerned; the other files are
shown as usual. The hints in parentheses follow `advice.statusHints`.

| Option | Meaning |
|---|---|
| `-s`, `--short` | one line per file with something to report, two columns like `git status -s`: upstream (`P` pending, `N` new, `E` error) and local (`M` modified, committed or not; `D` deleted; `?` not committed yet) |
| `-v`, `--verbose` | also list all files with asset, source, release selection and synced release |
| `--exit-code` | exit with 1 if something is to pull or a file is modified |
| `--no-fetch` | don't ask GitHub or GitLab for new releases: only local modifications are shown, see [Offline operation](#offline-operation) |

Like `git status`, it exits with 0 unless `--exit-code` is given; errors
exit with 2.

### `pull`

```
git assetsync pull (PATH… | --all) [--release TAG|PATTERN] [--overwrite] [-v] [-n]
```

Updates each given file or directory to what the release its entry
selects gives (after the filter) and stages them together with their
entries in `.git-assetsync` – like `git merge --squash`, without
committing. A plain `git commit` then offers the [proposed
message](#proposed-commit-messages), one for all entries, with a part for
each (with one entry, just that); `git commit --no-edit` takes it as it
is:

```sh
git assetsync pull --all
git commit --no-edit
```

In a directory, the files of the release are replaced: those the new
release no longer has are removed, new ones added; files of others there
stay as they are. An entry that is up to date is reported as such; one
whose filter was changed (with [`set`](#set)) is filtered again, from the
[download cache](#download-cache) if possible. If `pull --overwrite` only
brought back what is committed, there is nothing to commit, and it says
so.

`pull` refuses a file with local modifications, committed or not (see
[No local modifications](#no-local-modifications)); the other files are
pulled anyway, and the exit code is 2.


| Option | Meaning |
|---|---|
| `--all` | all entries with something to pull (with `--overwrite` also modified ones) |
| `--release TAG\|PATTERN` | this release instead of the one the entry selects, once – see below; a pattern takes the newest matching release; not with `--all` |
| `--overwrite` | discard local modifications: restore or update the file (directory) anyway; in a directory also replace files of yours in the way of the release's |
| `-v`, `--verbose` | first name where each entry comes from, as `status -v` shows it (assets, source, release selection, filter, the release synced) |
| `-n`, `--dry-run` | only report what would happen; nothing is downloaded or changed |

**Another release, once:** `pull --release TAG PATH…` updates the files to
that release instead of the selected one – also an older one, e.g. to go
back after a broken update. The release selection of the entries stays
as it is, so `status` then shows the selected release as pending, and a plain
`pull` (or `pull --all`) goes back to it; `pull --release` says so:

```console
$ git assetsync pull --release v1.0 bin/tool
bin/tool: updated and staged. Commit with:
    git commit
(it offers the proposed commit message; a copy stays in .git/ASSETSYNC_MSG)
note: bin/tool: it still selects v1.1 - 'git assetsync pull bin/tool' goes back to it; to stay on v1.0: 'git assetsync set bin/tool --release v1.0'
```

To keep the files on that release, pin them instead with [`set
--release`](#set). [`diff --upstream --release TAG PATH…`](#diff)
shows beforehand what `pull --release` would bring.

### `diff`

```
git assetsync diff [PATH…] [--upstream [--release TAG|PATTERN]] [-- OPTS]
```

Shows the local modifications of the entries (default: all) – the
difference between what their release gave when they were synced (the
recorded `blob` / `tree`) and the working tree, which [should be
none](#no-local-modifications). In a directory only the files of the
release are compared – files of yours there aren't shown. Like `status`,
it works offline.

| Option | Shows |
|---|---|
| (none) | the local modifications: synced -> working tree |
| `--upstream` | what `pull` would bring: synced -> what the selected release gives now, after the filter (also after the filter was changed) |
| `--upstream --release TAG\|PATTERN` | what `pull --release` would bring; `--release` requires `--upstream` |

```sh
git assetsync diff                      # local changes: synced -> working tree (local/)
git assetsync diff --upstream           # what `pull` would bring (upstream/)
git assetsync diff --upstream --release v1.0 bin/  # what `pull --release v1.0 bin/` would bring
git assetsync diff --upstream -- --stat # anything after `--` goes to `git diff`
```

`diff` runs a single `git diff` over all entries that differ, with their
paths in the repository: pager, colors, diff drivers and options (after
`--`, e.g. `--stat`, `--name-status`, `--word-diff`) work as usual. The
old side is named `synced/`, the new one `local/` or `upstream/`. Files in Git LFS are compared by their content, not their
pointers. With `--upstream`, the assets come from the [download
cache](#download-cache) if possible – and `pull` then needs no new
download; filters that run commands must be [trusted](#filter-trust). To see
what a `pull` command line would do, replace `pull` by `diff --upstream`
(with the same `--release` and paths), as in git-filesync. With
`--exit-code` or `--quiet` after `--`, the exit code is 1 if there are
differences, like `git diff`; otherwise 0, or 2 on errors.

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

**File by file** (the default), like `git difftool`: the left side is a
temporary copy of what the release gave, in a directory named after it
(`synced-v1.0/`); the right side is the working file itself – so edits
made in the tool are kept – or with `--upstream` a temporary copy
(`upstream-v1.1/`). A file that is
missing on one side is compared with an empty file. Like `git
difftool`, it asks before each file – also with paths given (`Viewing
(1/3): 'third_party/zlib/zlib.h'` / `Launch 'meld' [Y/n/q]?`; Enter =
yes, `q` = stop); `-y` / `--no-prompt` or `difftool.prompt = false` skip
the questions, `--prompt` asks anyway; of `-y` and `--prompt`, the last
one given counts.

**As two directories** (`-d`), with `git difftool --dir-diff`: one call of
the tool for all files that differ – useful for directory entries, e.g.
to see in Meld which files a new release adds, removes or changes before
pulling it:

```sh
git assetsync difftool -d --upstream third_party/zlib
```

The directories are temporary copies; files that are the same as in the
working tree are linked to it (as `git difftool -d` does), so edits to
them are kept – except on Windows, where they are copies (symbolic links
need a privilege there; `-- --symlinks` to use them anyway). Binary files can only be shown as
different by most tools.

### `restore`

```
git assetsync restore PATH… [-S] [-W]
```

Like `git restore`, but brings back what the entries were synced with –
what the release gave, after the filter – instead of what is committed:
it discards local modifications without pulling a newer release (that
does `pull --overwrite`). Without options it restores the working tree;
`-S` (`--staged`) restores the index instead, `-S -W` (short `-SW`) both.
Nothing is committed and `.git-assetsync` doesn't change. A committed
modification is gone with `restore -SW` and a commit:

```sh
git assetsync restore -SW lib/data.bin
git commit -m "Restore lib/data.bin"
```

The files are written back with their executable bits as synced (a file
entry's recorded `mode`, a directory entry's `tree`); in a directory, files
of yours stay. Files are written
as the current `.gitattributes` say (line endings, Git LFS). `restore`
works offline: what an entry was synced with is in the repository
(`blob`/`tree`) – for a directory that may have to be got again in a
fresh clone (see [Files of your own in a
directory](#files-of-your-own-in-a-directory)); if that isn't possible,
`restore` says so, and `pull --overwrite` gets the release again.

| Option | Meaning |
|---|---|
| `-S`, `--staged` | restore the index instead of the working tree |
| `-W`, `--worktree` | restore the working tree (the default; with `-S`: both) |

### `add`

```
git assetsync add SOURCE PATH [--asset PATTERN] [--release TAG|PATTERN] [--prerelease]
                  [--type github|gitlab] [--filter NAME] [--force] [--overwrite] [-n]
```

First the source, then the path – as for `git submodule add URL PATH`,
[`source map`](#source-map) and `git filesync add`. Takes the
file or directory `PATH` from assets of the release `SOURCE` selects:
downloads them, applies the filter, writes the result to `PATH`, records
the entry in `.git-assetsync` and stages both – like `git add`, without
committing. A plain `git commit` then offers the proposed message (`git
commit --no-edit` takes it as it is).

- **`SOURCE`** is the name of a `[source]` in `.git-assetsync`, or a URL
  (`https://github.com/owner/repo`, `https://gitlab.com/group/project`,
  also with subgroups; the URL of any page of the project works as well);
  `owner/repo` is short for a repository on github.com. A URL takes the
  source with that URL, or creates one (with `--type`, if given). The
  release selection – `--release`, `--prerelease` – is the entry's.
- **`PATH`** is the file or directory in your repository, relative to the
  current directory. With a trailing `/` (or if it is an existing
  directory) it becomes a [directory entry](#files-and-directories), else
  a file. The name doesn't have to be the asset's, and stays the same when
  later assets are named differently. Like `cp`, `add` makes no
  directories: the directory a file goes into must exist (else `error:
  directory 'src/new' does not exist`); a directory entry's own directory
  may be new, the one above it must exist. `pull` and `restore` make
  directories that are missing again, as `git checkout` does.
- **`--asset PATTERN`** selects the assets: a glob pattern (`*`, `?`,
  `[…]`), e.g. `--asset 'tool-*-linux-x64.tar.gz'`. Quote it, so the
  shell doesn't expand it. The pattern is recorded and used for later
  releases, too. For a file it must match exactly one asset; without
  `--asset` the release must have exactly one asset, which is taken – no
  pattern is recorded, and a later release with more than one asset is an
  error until you choose one (`git assetsync set PATH --asset PATTERN`).
  For a directory, all matching assets are taken; without `--asset` all
  assets of the release – they are listed first.
- **`--filter NAME`** applies the named [filter](#filters) `NAME` to the
  assets – to unpack them, select and move files. Define it first with
  [`filter add`](#filter).

| Option | Meaning |
|---|---|
| `--asset PATTERN` | the assets to take (glob; a file: exactly one match, default the release's only asset; a directory: all matching, default all) |
| `--release TAG\|PATTERN` | release to take: a tag pins the entry to that release, a pattern takes the newest release whose tag matches (default: the latest release) |
| `--prerelease` | prereleases count too (with a pattern, or instead of the latest release) |
| `--type github\|gitlab` | platform of the URL's host; needed for hosts other than github.com, gitlab.com and `gitlab.*` |
| `--filter NAME` | the named [filter](#filters) to apply to the assets |
| `--force` | replace an existing entry for `PATH` (its file or directory too, unless it has local modifications) |
| `--overwrite` | replace files in the way of the release's that differ from them (an existing file; in a directory, files of yours); with `--force` also local modifications of the entry replaced |
| `-n`, `--dry-run` | only show which release, assets and filter would be taken; nothing is downloaded |

An existing file at `PATH` is only replaced with `--overwrite`, unless it
is already what the release gives. In an existing directory, the files of
the release go next to those there; files of yours in their way are only
replaced with `--overwrite` (see [Files of your own in a
directory](#files-of-your-own-in-a-directory)). An entry that exists
already is replaced only with `--force`; its file (directory) as well, as
long as it is what its release gave – local modifications need
`--overwrite` too. For big binary files
(1 MiB or more) that are not stored in Git LFS, `add` warns and suggests
`git lfs track`: each update adds another copy to the repository's
history.

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

Like `git rm`: removes the entries from `.git-assetsync` together with
their files and stages both (commit when you like) – of a directory, the
files its release gave; files of yours there stay (`rm` says how many).
It refuses – for all paths given – if one of those files has uncommitted
changes; `-f` removes them anyway (their content can be [got
back](#commands) for a while). A committed
modification doesn't count, and a file already deleted is fine. To keep the files and only
remove the entries, use [`unlink`](#unlink).

| Option | Meaning |
|---|---|
| `-f`, `--force` | remove them anyway, also with uncommitted changes |
| `-n`, `--dry-run` | only show what would be removed |

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
`NEW` may be an existing directory; like `git mv`, `mv` makes no
directories – the one `NEW` goes into must exist. A directory moves with everything in
it, files of yours too (`mv` says how many). `OLD` may also be an ordinary
directory with entries in it (e.g. `bin/` with several synced tools): it
moves like with `git mv`, and all entries in it follow.

## Advanced commands

### `set`

```
git assetsync set PATH… [--source URL|SOURCE [--type github|gitlab]] [--release TAG|PATTERN | --latest]
                        [--prerelease | --no-prerelease]
                        [--asset PATTERN | --no-asset] [--filter NAME | --no-filter] [-n]
```

Changes the entries of files and directories – their source, release
selection, asset or filter – where `add` would need `--force`. Only
`.git-assetsync` is changed (and staged); `status` then shows what
changes, and `pull` updates the files and stages them, for one commit with the change.

| Option | Effect |
|---|---|
| `--source URL\|SOURCE` | take the files from another project – a fork, a moved project – or another `[source]`, as for [`add`](#add); a source left without files is removed |
| `--release TAG\|PATTERN`, `--latest` | another release selection for these files: a tag pins them, a pattern takes the newest matching release, `--latest` follows the latest release |
| `--prerelease`, `--no-prerelease` | let prereleases count for these files, or not |
| `--type github\|gitlab` | with `--source` a URL of a new source: the platform of its host |
| `--asset PATTERN`, `--no-asset` | another asset of the release; `--no-asset`: the release's only asset (a directory: all) |
| `--filter NAME`, `--no-filter` | use another named [filter](#filters), or none |
| `-n`, `--dry-run` | only show what would change |

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

### `edit`

```
git assetsync edit
```

Opens `.git-assetsync` in your editor – the one Git uses (`GIT_EDITOR`,
`core.editor`, `VISUAL`, `EDITOR`), like `git config --edit` – and
afterwards checks and stages it. A file that can't be parsed is not
staged (`… - not staged; fix it with 'git assetsync edit'`); gaps that
`status` would report are shown as warnings, e.g.:

```
warning: .git-assetsync: [source "acme/old"] is not used by any file
warning: .git-assetsync: [file "bin/tool"]: no [source "acme/tol"]
warning: .git-assetsync: [file "lib/x.bin"] lacks synced or blob (what it was synced with) - pull takes the release
```

Unchanged, nothing happens; if the editor fails, nothing is staged; an
emptied file is removed (and that staged). For the usual changes the
dedicated commands are safer – [`set`](#set), [`source`](#source),
[`filter`](#filter), [`unlink`](#unlink), [`mv`](#mv) – since `edit` keeps
whatever you write: a changed `blob` or `tree` changes what counts as a
local modification, a removed `synced` makes `pull` take the release
again.

### `source`

```
git assetsync source [-v]
git assetsync source rename OLD NEW
git assetsync source set-url NAME URL
git assetsync source set-type NAME (github|gitlab | --unset)
```

Lists and changes the `[source]` sections, like `git remote` does for
remotes. The changing actions only change `.git-assetsync` and stage it;
`status` then shows what changes for the files of the source, and `pull`
updates and stages them, for one commit with the change of the source.

| Action | Meaning |
|---|---|
| (none) | list the sources; `-v`: with URL, type and file count |
| `rename OLD NEW` | rename a source and all references to it |
| `set-url NAME URL` | change the URL, e.g. after the project moved |
| `set-type NAME github\|gitlab` | the platform of the host; `--unset`: derived from the host again |

There is one source per URL: `set-url` to the URL of another source is
refused, with a hint to move the files to that one (`set <file>...
--source <source>`). Which release a file takes is its own (see
[Selecting the release](#selecting-the-release)): to change it, use
[`set`](#set), e.g. `git assetsync set lib/x.h --release v2.0`.

### `source map`

```
git assetsync source map [URL|SOURCE [DIR]] [--flat] [--pattern PATTERN] [--sort date|name]
                         [--global] [--unset]
```

Takes the releases of a source from the local folder `DIR` instead of
GitHub or GitLab – to try a new build "the proper way" in another local
repository before publishing it. The source is given by its URL or the
name of a `[source]`; the mapping applies to every source with that URL.
It is kept in this repository's `.git/config`
(`assetsync.<url>.localpath`), with `--global` in your global Git config
for all repositories without a mapping of their own – never in
`.git-assetsync`, which keeps the real URL.

```
~/build/tool-releases/
  v1.2/       tool-linux.bin  tool-win.exe
  v1.3-rc1/   tool-linux.bin  tool-win.exe
```

```sh
git assetsync source map acme/tool ~/build/tool-releases  # by the name of the [source] (or its URL)
git assetsync status                                      # pending: bin/tool (v1.2 -> v1.3-rc1, local folder)
git assetsync pull bin/tool                               # takes v1.3-rc1 from the folder
git assetsync source map                                  # list the mappings (scope, overridden ones marked)
git assetsync source map acme/tool --unset                # remove it again
```

- Each **subdirectory** is a release, named like its tag; its files are
  the assets (hidden files are ignored).
- With **`--flat`**, the folder itself holds the assets of all releases
  as files – e.g. a build's output folder. A file belongs to the release
  named like the file without its extension (`.tar.gz`, `.tar.xz` and
  the like count as one); the asset keeps the full file name, so
  `--asset '*.xml'` chooses as usual. Subdirectories are ignored.

  ```
  ~/build/fw-out/
    rel20260213.7z  rel20260213.xml     -> release rel20260213 (2 assets)
    rel20260410.7z  rel20260410.xml     -> release rel20260410 (2 assets)
  ```

  ```sh
  git assetsync source map --flat acme/fw ~/build/fw-out
  ```

  The layout is kept with the mapping (`assetsync.<url>.layout = flat`);
  `source map` without `--flat` switches back to subdirectories.
- With **`--pattern PATTERN`**, only the subdirectories – with `--flat`,
  the files – whose names match it count, so several sources can share
  one folder, e.g. the output folder of a build that makes the releases of
  several projects:

  ```
  ~/build/out/
    tool-1.2/  tool-1.3/      <- acme/tool
    lib-0.9/                  <- acme/lib
  ```

  ```sh
  git assetsync source map acme/tool ~/build/out --pattern 'tool-*'
  git assetsync source map acme/lib  ~/build/out --pattern 'lib-*'
  ```

  The pattern is matched case-sensitively against the whole name (`*`,
  `?`, `[…]`). Releases of other sources aren't seen at all, not even as
  a pinned tag, so their names must differ. It is kept with the mapping
  (`assetsync.<url>.pattern`); `source map` without `--pattern` takes all
  again.
- A release is dated by its **newest file**: the latest release is the one
  built last, also when a build overwrites the files of an existing
  folder (then `status` shows its assets as replaced).
- With **`--sort name`**, the release with the greatest name is the
  newest instead – for names that tell the order, like `rel20261022`.
  File dates don't matter then, so building an older release again (or
  copying the folder, which may change the dates) doesn't make it the
  latest. Names are compared character by character, not as versions:
  `v1.10` comes before `v1.9`, so they need a fixed width (dates, leading
  zeros). It decides everything that asks which release is newer: the
  latest, the newest matching a pattern, the releases skipped by an
  update, the order of `source releases`. Kept as `assetsync.<url>.sort
  = name`; `source map` without it sorts by date again. The [release
  selection](#selecting-the-release) applies as usual – a pattern takes
  the newest matching folder, a pinned tag that folder; prereleases and
  drafts don't exist here, and there are no release notes.
- The commit message says where it came from: `Release: v1.3-rc1 (from a
  local folder, not published)`.
- Everything works offline; the assets are read from the folder, not
  copied into the [download cache](#download-cache). Only their SHA-256
  is remembered there, with each file's size and modification time, so
  that `status` doesn't read big assets again on every call (e.g. from a
  network share); a file that changes is read again, and `pull` and
  `verify` always read what they take. `status` names the folder, `source
  releases` lists the folders; `source map … --unset` takes the releases
  from the platform again.
- Before pushing, the [push check](#hooks) warns
  about entries whose release isn't published yet.

### `source releases`

```
git assetsync source releases SOURCE|URL [--assets] [-n N | --all] [--type github|gitlab]
```

Lists the releases of a project, newest first: tag, date and title (if it
differs from the tag), marked `latest` (as the platform defines it),
`prerelease` (GitLab: `upcoming`), `draft`, and `selected by …` with the
entries of this repository that select it now. A help for choosing
`--release` and `--asset` for [`add`](#add) and [`set`](#set):

```console
$ git assetsync source releases acme/tool --assets -n 2
v1.1      2026-10-11  Tool 1.1  (latest, selected by bin/tool)
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
git assetsync filter test NAME (FILE… | --source SOURCE [--release …] [--prerelease] [--asset PATTERN]) [-o DIR]
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
| `test NAME FILE…` | apply a filter to local files, as if they were the assets (a directory: its files, with their paths below it), and list the result – or write it to a new or empty directory with `-o DIR` |
| `test NAME --source SOURCE` | the same with the assets of the release `SOURCE` selects (`--release`, `--prerelease`, `--type` as for [`add`](#add); `--asset PATTERN`: only the matching ones) – to try a filter on the real thing before an entry uses it |
| `add NAME STEP-OPTIONS…` | define a new filter with the [step options](#filters) (`--extract`, `--include`, `--move`, `--apply`, …), in the order given. Names consist of letters, digits, `.`, `+`, `-` and `_` |
| `set NAME STEP-OPTIONS…` | replace the steps of an existing filter |
| `rename OLD NEW` | rename a filter, and the entries and `apply` steps that use it |
| `remove NAME` | remove a filter that nothing uses |

`filter test` changes nothing in the repository; errors are the ones
`pull` would report. It shows what each step did (on stderr), then the
result:

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
this repository. Without arguments, `filter trust` lists them with their state –
`trusted`, `not trusted`, or `changed since trusted` – and their commands,
naming the scripts of the repository they run; on a terminal it asks for
each one that isn't trusted. `filter trust NAME…` trusts the filters as they are
now, `--all` all filters that run commands, `--revoke` takes the trust
back. Trusts are kept in the repository's own config (`.git/config`,
`assetsync.trusted`), never committed – each clone decides for itself.

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
all), `verify` takes the assets of the release it was synced with (not
the newest one) from the [download cache](#download-cache) or the
platform, applies its filter again, and compares the result with the
recorded base (`blob` / `tree`) – as `git add` would store it, so files
stored differently since (moved to Git LFS, line endings normalized) still
count as the same. The working tree, the index and the branches are not
touched; only in a clone that lacks the base of a directory entry is it
kept, once verified (see [Files of your own in a
directory](#files-of-your-own-in-a-directory)).

```console
$ git assetsync verify
third_party/zlib/: verified (v1.3.2)
src/fw/: differs from what v2.1 gives now:
	M	gen/fw.c
```

It also reports when the assets of the release differ from those the entry
was synced with (re-uploaded), when the release no longer exists, and when
the filter changed since the sync (`pull` first). Filters that run
commands must be [trusted](#filter-trust). The exit code is 0 if everything is
verified, 1 if something differs, 2 on errors – so a CI job can check that
nobody changed a file by hand and that the filters are deterministic.
With `-v` (`--verbose`), each entry is first named with where it comes
from, as `status -v` shows it: its assets, source, release selection,
filter and the release it was synced with.

### `cache`

```
git assetsync cache [list | prune [--older-than DAYS] [--max-size SIZE] [-n] | clear [-n] | dir]
```

The [download cache](#download-cache), shared by all repositories of your
user account:

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
| `list` | its files, most recently used first: size, last used, where it came from (`+N more` if several assets have the same content) |
| `prune` | remove what wasn't used for `assetsync.cacheMaxAge` days, then the least recently used beyond `assetsync.cacheMaxSize`; `--older-than DAYS` and `--max-size SIZE` (e.g. `500M`, `2G`) set other limits for this run; `-n` only shows what would be removed |
| `clear` | remove everything (`-n`: only show) |
| `dir` | print the directory, e.g. for caching it between CI runs |

What counts is when a file was **last used**, not when it was
downloaded. Files used in the last ten minutes are never removed by
`prune`, so that another git-assetsync running at the same time keeps
them; leftovers of interrupted downloads go too. Nothing is lost by
removing: a file needed again is downloaded again.

**Automatically**, after a download and at most once a day, the cache is
cleaned up by the limits:

| Setting | Default | Meaning |
|---|---|---|
| `assetsync.cacheMaxAge` | `90` | remove files unused for that many days; `0` or `off`: never |
| `assetsync.cacheMaxSize` | (none) | then remove the least recently used files until the cache is at most this big, e.g. `2G`; `0` or `off`: no limit |

```sh
git config --global assetsync.cacheMaxSize 5G
git config --global assetsync.cacheMaxAge off
```

Commands that download nothing (like `status`) never remove anything.

### `hooks`

```
git assetsync hooks
git assetsync hooks install [--force]
git assetsync hooks uninstall
```

`hooks` shows the state of the two hooks – `installed`, `outdated` (from an
older version: update with `hooks install`), `not installed`, or a hook of
another tool without our lines – and the directory, if `core.hooksPath`
sets it:

```console
$ git assetsync hooks
pre-push: installed
post-merge: hook of another tool, without our lines (add them with 'git assetsync hooks install --force')
```

`hooks install` installs (or updates) two hooks that report on stderr:

- `pre-push` – reminds of new releases, local modifications and errors
  before pushing
- `post-merge` – reminds of local modifications after `git pull`/`git
  merge`, without asking GitHub or GitLab

```
assetsync: bin/tool: upstream pending (v1.0 -> v1.1)
assetsync: run 'git assetsync pull <file>' to update
```

**Push check:** the `pre-push` hook also looks at the commits being pushed:
an entry synced from a release that isn't on GitHub or GitLab – typically
pulled from a [local folder](#source-map) – or whose assets differ from those of
the release there is reported:

```
assetsync: bin/tool: synced from release v1.3-rc1, which is not on the server (https://github.com/acme/tool) - publish it there first
assetsync: bin/tool: synced from assets of release v1.3 that differ from those on the server (https://github.com/acme/tool) - publish them there first
```

Others couldn't pull or verify that state. The check always asks the
platform (mappings don't count), only for entries the remote doesn't have
yet (in the pushed-over commit or its remote-tracking branches), so usually
no request at all is needed. Once the tested build is published as that
release, the warning is gone – no new `pull` needed. GitLab reports no
digests: there, only the tag is checked. Like Git with submodules, it only
warns by default; `assetsync.pushCheck` sets what happens:

| `assetsync.pushCheck` | Effect |
|---|---|
| `warn` (default) | report, push anyway |
| `error` | report and refuse the push (`git push --no-verify` skips it) |
| `off` | no check |

```sh
git config assetsync.pushCheck error            # this repository
git config --global assetsync.pushCheck error   # all repositories
```

A platform that can't be asked is reported, but never refuses the push.
Apart from `error`, the hooks never block – not even if git-assetsync
itself fails or is missing. The hooks run `git assetsync hook pre-push` /
`hook post-merge` (like `git lfs pre-push`), so later versions can change
what the hooks do without reinstalling them; only exit code 3 of `hook
pre-push` refuses a push, as in git-filesync. They are not meant to be run
by hand (from a terminal, `hook pre-push` checks `HEAD`).

Existing hooks of others are not changed; `hooks install` prints the lines
to add instead – or, with `--force`, adds them right after the `#!` line,
before the hook's own commands (also before an `exec` or `exit` at its
end). In a `pre-push` hook, they must come first: git passes the
pushed refs on stdin, which the push check reads – the lines keep them for
the commands after them (such as `git lfs pre-push`), but a command before
them that reads stdin leaves nothing for the check. Hooks installed by an
older version are updated in place (`updated`). `hooks uninstall` removes the hooks, or only its lines from
hooks that contain other commands as well. Until 0.15, the commands were
`install-hooks` and `uninstall-hooks`; hooks installed by them keep
working. With `core.hooksPath` set, the
hooks go there (with a warning, since other repositories may use it).

## Further topics

### Selecting the release

The `release` key of an entry (`add --release`, `set --release`) decides
which release its file or directory takes:

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

To switch entries to another release selection, use [`set
--release`](#set) (e.g. `git assetsync set bin/tool --release v2.0`, or
for several, `set lib/ bin/ --latest`) and pull them; the change is
committed with them. To take another release only once (the selection
stays), use [`pull --release`](#pull).

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
| `--extract [PATTERN…]` | unpack the matching files (without a pattern: all), which must be archives – a file that is none is an error, like a broken archive: ZIP, tar, tar.gz/.tgz, tar.bz2, tar.xz, single `.gz`/`.bz2`/`.xz` files (named without the suffix), and 7z with an external 7-Zip (see below). The type is recognized by the content, not the name. All archives go into one root; the files not matching stay as they are. With archives and other files among the assets, choose the archives: `--extract '*.zip'` |
| `--subdir PATH` | only the files below `PATH`, which becomes the root |
| `--strip N` | remove `N` leading directories from all paths, like `tar --strip-components` (e.g. the `zlib-1.3.2/` of an archive); files with no more than `N` directories are left out, as `tar` does |
| `--include PATTERN…` | only the files matching any of the patterns |
| `--exclude PATTERN…` | not the files matching any of the patterns |
| `--move PATTERN TARGET` | move what matches – files, or directories with all below them – to `TARGET`, see below |
| `--copy PATTERN TARGET` | the same, but the files also stay where they are |
| `--apply PATTERN NAME` | apply the filter `NAME` to the matching files only, see [Filters using filters](#filters-using-filters) |
| `--executable PATTERN…` | make the matching files executable – an asset itself never is, see [Executables](#executables) |
| `--changelog PATTERN…` | reads only: the text of the matching files goes with the release notes into the commit message of `pull`, see [Changelogs from the assets](#changelogs-from-the-assets) |
| `--convert PATTERN TARGET COMMAND` | convert each matching file with a command of your own (e.g. bin2c), see [Commands in filters](#commands-in-filters) |
| `--run PATTERN COMMAND` | run a command on the matching files at once (`'*'`: all), see [Commands in filters](#commands-in-filters) |

Each option is one step. **The patterns of one option** count together:
`--include` keeps the files matching *any* of them, `--exclude` removes
the files matching any of them. So

```sh
git assetsync filter add zlib-headers --extract --strip 1 --include '/*.h' LICENSE
```

keeps the headers *and* the license:

```ini
[filter "zlib-headers"]
	step = extract
	step = strip 1
	step = include '/*.h' LICENSE
```

Two options are two steps, applied one after the other: `--include
'/*.h' --include LICENSE` would keep the headers first and then, of
those, only `LICENSE` – nothing. `filter show` lists the steps.

Patterns are like in `.gitignore` (and `git filesync add --include`),
relative to the root after the previous steps: without a `/` a pattern
matches a name at any depth (`*.h`; `*` matches every file), a leading or
inner `/` anchors it to the root (`/*.h`, `include/*.h` – but not
`x/include/a.h`), a trailing `/` matches a directory and everything below
it; `**/` matches any number of directories (`**/include/*.h`).

**`TARGET` of `move` and `copy`**: what the pattern matches moves – a
file, or a directory with everything below it (where a pattern matches
directories inside each other, the outermost). With a trailing `/`,
`TARGET` is the directory it goes into, under its name – e.g. to gather
files spread over several directories (`--move '*.h' include/`; `./` is
the root), or `--move include/ api/`, which gives `api/include/…`. Else
`TARGET` is its new path, with placeholders for parts of its old path –
for `images/boardA/app.bin`:

| Placeholder | Value |
|---|---|
| `{path}` | `images/boardA/app.bin` |
| `{dir}` | `images/boardA` |
| `{parent}` | `boardA` |
| `{name}` | `app.bin` |
| `{stem}` | `app` |
| `{ext}` | `.bin` |

So `--move 'images/*/app.bin' 'firmware/{parent}.bin'` makes
`firmware/boardA.bin`, `firmware/boardB.bin`, …; `--move include/ api`
renames the directory `include` to `api`, with everything below it
(`include/sub/a.h` → `api/sub/a.h`); for a directory the placeholders are
its own (`{name}` = `include`). Two files with the same target, or a
target that is another file, are an error.

A step whose pattern matches no files changes no file – a filter stays
valid for a release that happens to have none of them (e.g. no headers).
Only `include` and `subdir` then leave nothing, which is what they are
for: they keep the matching files only.
Only grave problems are errors: a file that `extract` can't unpack,
results that would replace each other (two files with the same target,
a target that is another file), and a filter that leaves no files at all
for an entry – a filter applied with `apply` may leave nothing of its
part. A file entry must end up with exactly one file. In `pull` and
`verify` filters are silent; [`filter test`](#filter) shows what each
step did.

#### Executables

An asset itself is never executable: a downloaded file is just data. A
file is executable when an archive marks it so (tar, ZIP and 7z made on
Unix keep the executable bit) or a [command](#commands-in-filters) makes
it. **`--executable PATTERN…`** makes the matching files executable –
e.g. a program that is an asset as it is:

```sh
git assetsync filter add exe --executable '*'
git assetsync add acme/tool bin/tool --asset 'tool-*-linux-x64' --filter exe
```

In a directory, a pattern chooses them (`--extract --executable 'bin/*'`).
The executable bit is part of what an entry gets, like its content: a
file entry records it in `mode`, a directory entry in its `tree`;
`status` counts a lost (or added) bit as a local modification, `pull` and
`restore` set it – so don't make such a file executable by hand, but
with the filter (`git assetsync set bin/tool --filter exe`). On Windows
(`core.filemode = false`) the bit is kept in the repository for the
other platforms.

#### Filters using filters

Most steps take a pattern and leave the other files alone, so files of
different kinds can usually be treated in one filter. Some steps act on
all files, though – `strip`, `subdir`, and `include`, which keeps only
the matching ones – and `extract` unpacks all archives into one root. When
that must not touch the other files, the step **`apply PATTERN NAME`**
lets another, named filter treat some of them on their own:

1. The files matching `PATTERN` are set aside – at the first step of the
   filter, these are the assets, named as they are.
2. The filter `NAME` runs on those files alone, as if they were all the
   files there are; the other files don't take part.
3. What it gives joins the other files again (a path that collides with
   one of them is an error). If nothing matches, `apply` does nothing.

For example, a release of `acme/sdk` with three assets – two ZIPs of the
same layout, and a firmware image:

```
sdk-2.1-headers.zip    sdk-2.1/include/sdk.h, sdk-2.1/README.md
sdk-2.1-libs.zip       sdk-2.1/lib/libsdk.a,  sdk-2.1/README.md
fw-boardA.bin
```

In one go, `--extract 'sdk-*.zip' --strip 1` fails: both ZIPs have
`sdk-2.1/README.md`, and `--strip 1` would also drop `fw-boardA.bin`,
which is in no directory. With a filter `unpack` applied to each ZIP on
its own:

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

```ini
[filter "unpack"]
	step = extract
	step = strip 1
	step = exclude README.md
[filter "sdk"]
	step = apply 'sdk-*-headers.zip' unpack
	step = apply 'sdk-*-libs.zip' unpack
	step = move 'fw-*.bin' firmware/
[dir "vendor/sdk"]
	source = acme/sdk
	filter = sdk
	...
```

The two `apply` steps are two runs of `unpack`, one per ZIP. That is also
the second use of `apply`: a filter written once serves several
filters and assets. `unpack` is a filter like any other – other entries
can use it directly, and `filter test unpack sdk-2.1-libs.zip` tries it on
its own.

A filter may use other filters, but not itself (also not through others).
A changed filter changes all entries that use it, directly or through
other filters: `status` shows them as pending (`filter changed`), `pull`
applies it. Renaming one changes nothing else.

#### Changelogs from the assets

The step `changelog PATTERN…` reads the files matching any of the
patterns and adds their text to the [release
notes](#proposed-commit-messages) in the commit message of `pull`; the
files themselves stay (remove them with a later `--exclude` if they
shouldn't be in the repository). This helps where the release page tells
little or nothing – above all with a [local folder](#source-map), which
has no release notes at all:

```sh
git assetsync filter add fw --extract --changelog CHANGELOG.txt --exclude CHANGELOG.txt
```

```
[assetsync] Update firmware/ to acme/fw rel20260410 (was rel20260213)

Release: rel20260410 (from a local folder, not published)
Asset:   rel20260410.7z
Filter:  fw

Changelog (CHANGELOG.txt):
  2026-04-10: faster boot
  2026-02-13: first release
```

- The text is that of the release pulled, shortened like the notes (by
  default its first 20 lines – for a changelog with the newest entries
  on top, those are the new ones), within the limit of all notes; a cut
  text ends with `[... more in CHANGELOG.txt]`. The text is read as
  UTF-8 (with or without a BOM); what isn't valid UTF-8 as Windows-1252,
  as older Windows tools write it; UTF-16 if it starts with a BOM. Other
  files with a NUL byte aren't text and are skipped – `filter test` says
  so.
- It comes with an update to another release, like the release notes,
  and also when the assets of the same release were replaced (e.g. a
  local build made again): then it is read anew from them – not for a new
  entry or going back to an older one.
- No matching file (e.g. a later release has none) means no text, as
  with any step.

#### Commands in filters

Two steps run commands, to convert files with tools of your own:

- **`convert PATTERN TARGET COMMAND`** runs `COMMAND` once for each file
  matching `PATTERN` (also each one below a matching directory): `{in}` is
  the file, `{out}` where the command writes the result. The result
  replaces the file, under
  the path `TARGET` – with the placeholders of `move` (`{path}`, `{dir}`,
  `{parent}`, `{name}`, `{stem}`, `{ext}`) of that file, e.g.
  `'gen/{stem}.c'`. Unlike for `move`, a trailing `/` doesn't mean "into,
  under its name" here (a converted file named like its input would be of
  little use): `TARGET` is a directory and `{out}` an empty directory: all
  files the command writes there go into it (e.g. a `.c` and a `.h`). To
  keep the original as well, `--copy` it first.
- **`run PATTERN COMMAND`** runs `COMMAND` once for all files matching
  `PATTERN` (`'*'`: all files so far): `{in}` is a directory with them, at
  their paths, `{out}` an empty directory; the files the command writes
  there replace them, the other files stay. A result at the path of one
  of the other files is an error. Until 0.18, `run` had no pattern and
  took all files: write `run '*' COMMAND` for that now.

```sh
git assetsync filter add firmware --extract --include '*.bin' '*.hex' \
    --convert '*.bin' 'src/{stem}.c' 'xxd -i {in} > {out}' \
    --convert '*.hex' 'src/{stem}_hex.c' 'python3 {root}/tools/hex2c.py {in} {out}'
```

The commands run with `sh -c` (on Windows the `sh` of Git for Windows;
`ASSETSYNC_SH` sets another one), so redirections like `> {out}` work. They
run in a temporary working directory where `{in}` and `{out}` are **short
relative names**: for `convert`, `{in}` is the file's name (`fw.bin`) and
`{out}` the name of `TARGET` (`fw.c`; if both are the same – also when
they differ only in case, as disks on Windows and macOS don't – `out/fw.c`; for
a `TARGET/`, the directory `out`); for `run`, `in` and `out`. So tools that
derive names from them – like `xxd -i`, which makes `fw_bin` of `fw.bin` –
give the same result everywhere. `{root}` is the root of the repository,
for its scripts: `python3 {root}/tools/hex2c.py {in} {out}`.

The placeholders are filled in quoted; other `{…}` in a command (like
`${VAR}`) stay as they are. In the environment, the placeholders are
`ASSETSYNC_IN`, `ASSETSYNC_OUT`, `ASSETSYNC_ROOT`, `ASSETSYNC_NAME`, … too,
and `ASSETSYNC_RELEASE` (the tag), `ASSETSYNC_SOURCE` and `ASSETSYNC_ENTRY`
(the path of the entry). A command that fails (exit code not 0), writes
no result, or writes links is an error; nothing is changed then. On Linux
and macOS, the executable bit of what a command writes is kept.

The result is recorded like any other (`blob` / `tree`), so commands only
run on `pull`, `add` and `filter test` – never on `status`, and never on
a clone: everyone else gets the committed files. Commands should be
deterministic, so that the same release gives the same result –
[`verify`](#verify) checks it.

**Trust.** The commands come from `.git-assetsync`, a committed file:
whoever can change it could run commands on every machine that pulls. So
a filter with commands runs only if it is **trusted in your repository**
– recorded in its own config (`.git/config`, never committed), with
[`filter trust`](#filter-trust). A trust is for the filter as it is: a changed filter,
or a changed script of the repository its commands run (named as
`{root}/tools/hex2c.py` or `$ASSETSYNC_ROOT/tools/hex2c.py`), needs a new one – and makes the entries using it
pending, so they are converted again. On a terminal, `pull` and `add` ask;
otherwise they refuse with a hint. In CI, set `ASSETSYNC_TRUST=all`.

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
[assetsync] Update bin/tool to acme/tool v1.1 (was v1.0)

Release: https://github.com/acme/tool/releases/tag/v1.1
Title:   Tool 1.1
Asset:   tool-1.1-linux-x64

Release notes:
  ## What's Changed
  * Fix crash on empty input by @someone in https://github.com/acme/tool/pull/42
  * Faster startup

  **Full Changelog**: https://github.com/acme/tool/compare/v1.0...v1.1
```

The subject starts with `[assetsync] `, so the commits git-assetsync
proposed are easy to tell apart (`git log --grep='^\[assetsync\]'`;
git-filesync's start with `[filesync] `). It names the file (directory),
the source and the release –
`Add …` for a new entry, `Update … to … (was …)` for another release,
`Update … (asset replaced)` when the asset of the same release changed,
`Update … (filter changed)` after another filter, `Restore …` when `pull
--overwrite` brought back what the release gives after local modifications.
The body links the release page and names its title (if it differs from
the tag), the assets and the filter; for a directory it adds what changes
in it:

```
[assetsync] Update third_party/zlib/ to madler/zlib v1.3.2 (was v1.3.1)

Release: https://github.com/madler/zlib/releases/tag/v1.3.2
Title:   zlib 1.3.2
Asset:   zlib-1.3.2.tar.gz
Filter:  zlib-headers
Files:   1 added, 0 removed, 9 changed (12 in total)
```

When an entry is updated to another release, its **release notes** (the
description on the release page; also text from the assets with a
[`changelog` step](#changelogs-from-the-assets)) follow, shortened, so the log tells what
changed without following the link: at most 20 lines of at most 200
characters (cut lines end in `[...]`, a cut text with a hint at the
release page), HTML comments (left over from templates) and repeated blank
lines dropped. They are indented by two spaces – otherwise `git commit`
would take Markdown headings like `## What's Changed` for comment lines and
remove them when the editor opens.

**Skipped releases:** when the update skips releases – newer than the
synced one, older than the new one, selected by the same rule as the
entry (its tag pattern; prereleases only if it takes them; no drafts) –
`Since:` lists them, and their notes follow those of the new release,
newest first:

```
[assetsync] Update bin/tool to acme/tool v1.3 (was v1.0)

Release: https://github.com/acme/tool/releases/tag/v1.3
Asset:   tool-1.3-linux-x64
Since:   v1.2, v1.1

Release notes v1.3:
  ...
Release notes v1.2:
  ...
Release notes v1.1:
  ...
```

At most 60 lines of notes in all; the notes of older releases beyond that
are only referred to (`[... notes of v1.1 and older: see the release
pages]`). Going back to an older release (e.g. with `pull --release`),
`Reverted:` lists the releases undone, without notes.

| Setting | Default | Meaning |
|---|---|---|
| `assetsync.notesLines` | `20` | lines of notes per release; `0`: no notes at all (the link and `Since:` stay) |
| `assetsync.notesTotalLines` | `60` | lines of notes in all |

```sh
git config assetsync.notesLines 40
git config --global assetsync.notesTotalLines 200
```

`add` and `pull` stage only and add the proposal to `.git/SQUASH_MSG`,
which a plain `git commit` offers (as do IDEs like VS Code). Proposals are
collected – of several commands, also with one git wrote itself (after
`git merge --squash`); the same proposal again changes nothing. Git
removes the file after the commit, so the next proposal starts afresh.

A copy of it all goes to `.git/ASSETSYNC_MSG` – always that file,
overwritten with each proposal (the path is printed along with the hint
to commit). It brings the message back if `SQUASH_MSG` is gone – after a
commit that was aborted with an empty message and then made with another
one, after `git reset`, or after `git commit -m`: `git commit -e -F
.git/ASSETSYNC_MSG`.

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
releases") count as prereleases: they are skipped unless the entry has
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
shows up as pending.

Where the platform reports no digests – GitLab, and GitHub for older
assets – the entry also records `assetid`, a fingerprint of what the
platform says about the assets: name, id, URL and size. A re-upload gets
a new id on GitHub; on GitLab, a replaced asset is a link with a new id or
a new URL. Either way `status` shows the entry as pending, without a
download. Not noticed is only other content behind the same URL (e.g. a
generic package overwritten, or a link to a server elsewhere) – there,
not even `verify` sees it while the download cache has the old file
(`git assetsync cache clear`, then `verify`). Entries synced before 0.19.0
get `assetid` with their next `pull`.

### Download cache

Downloaded assets are kept in a cache, so another filter, `pull --overwrite`
or a second repository with the same asset need no new download:
`~/.cache/git-assetsync` (or `$XDG_CACHE_HOME/git-assetsync`), on Windows
`%LOCALAPPDATA%\git-assetsync`; `ASSETSYNC_CACHE` sets another directory.
Contents are kept by their SHA-256 (`sha256/`), with an index for
platforms that report no digests (`index/`, GitLab), which also says
where each file came from; `local/` remembers the SHA-256 of assets in
[local folders](#source-map) (`clear` removes them, `prune` those of
files no longer there). Files unused for 90 days are removed
automatically; [`cache`](#cache) shows, lists and cleans it up, and sets
other limits. Deleting it (or parts of it) by hand does no harm either.

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
`text=auto` repository. Files are written to the working tree as `git
checkout` would write them (with `core.autocrlf=true`, a text asset gets
CRLF) – those of a directory too. Changing
these settings afterwards doesn't make entries count as modified. To keep
an asset byte for byte, mark it `-text` (or `binary`) in `.gitattributes`.

### Offline operation

`status` works without network for everything local: whether the committed
and working tree files (directories) are still what their release gives is
decided from the recorded `blob` (`tree`). Only the check for new releases
needs GitHub or GitLab; `--no-fetch` skips it (`new releases not
checked`). `diff` works offline, too, and so does
everything with a source [mapped to a local folder](#source-map). `add`, `pull`
and `diff --upstream` always ask the platform which release to take;
assets already in the [download cache](#download-cache) are not
downloaded again.

Commands that only look – `status`, `diff`, `difftool`, `verify` and the
hooks – change nothing in the repository: the objects they need for
comparing go to a temporary object directory, removed afterwards (only
`verify` keeps a directory's base it got again). They read only the files
of the entries, not those of others in a directory, and only the ones
that differ from what the release gave are looked at more closely.

### Colors

Output is colored like `git status`: pending updates yellow, local
modifications red (NOT ALLOWED and errors bold red), entries not committed
yet green.

Colors follow `color.assetsync`, falling back to `color.ui` (default: on
for terminals); `--color[=always|never|auto]` and `--no-color` override
that, and `NO_COLOR` turns colors off. Hook output on stderr is colored the
same way, and so is the help (`-h`) – with Python 3.14 or later, which
colors it; the list of commands in the colors of the rest.

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
`https://github.com/stsichler/git-assetsync/releases/download/v0.21.1/git-assetsync.py`
instead. `gh` is preinstalled on GitHub's runners; `GH_TOKEN` logs it in. For
sources in other private repositories, use a token with read access to
them. For GitLab sources, install `glab` in the job (and give
`GITLAB_TOKEN` for private projects).

### Exit codes

| Code | Meaning |
|---|---|
| `0` | ok |
| `1` | something to do: `status --exit-code` with something to pull or a modified file; `verify` or `diff --exit-code` found a difference |
| `2` | error (also: `pull` refused a modified file) |
| `141` | the output went into a pipe that was closed early (e.g. `\| head`), as with git: a command that only looks (`status`, `diff`, `difftool`, `verify`, and those that list or show, like `source releases`, `filter show` or `cache list`) stops there; one that changes something finishes its work first – never only half of it |

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
  `git assetsync add acme/tool lib/tool.zip --asset 'tool-*.zip'` turns
  into `tool-1.0.zip` when that file is there.
- **Arguments starting with `/`** become Windows paths: `unlink /tmp/x` (of
  a broken entry) turns into `C:/Users/…/Temp/x`.

For such arguments, run the script directly instead of through the alias,
e.g. `py C:/tools/git-assetsync.py add acme/tool lib/tool.zip --asset
tool-*.zip` in cmd or PowerShell; in Git Bash, put `MSYS_NO_PATHCONV=1` in
front of it. Don't set `MSYS_NO_PATHCONV` (or `MSYS=noglob`) for git
itself: it breaks how git passes the arguments to the alias.

### Shipping git-assetsync with your repository

git-assetsync can keep a copy of itself in your repository, so everyone
has the same version without installing it:

```sh
git assetsync add stsichler/git-assetsync tools/git-assetsync.py --asset git-assetsync.py
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
