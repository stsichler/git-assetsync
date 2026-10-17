# git-assetsync

Keep files in your repository in sync with **release assets** of other
projects (GitHub, GitLab) – check in a binary, the unpacked contents of a
ZIP, or a file generated from it, and update it with one command, with a
commit message that says where it came from.

**Status: in preparation.** Nothing to use yet.

A sibling of [git-filesync](https://github.com/stsichler/git-filesync),
which keeps single files in sync with files in other Git repositories, and
built the same way: a single Python script (standard library only), a
`.git-assetsync` registry in your repository (git-config format, like
`.gitmodules`), `status` / `pull` that behave like their Git namesakes,
Linux, macOS and Windows.

## License

[MIT No Attribution](LICENSE)
