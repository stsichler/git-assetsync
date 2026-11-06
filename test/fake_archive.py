"""Source code archives for fake_gh.py and fake_glab.py: made on request
from the files of a release's tag, like the platforms do - the same bytes
each time (fixed dates), a top directory named by the platform."""

import bz2
import gzip
import hashlib
import io
import tarfile
import zipfile


def commit_of(project, meta):
    """The commit of a release's tag: given ("commit"), else derived."""
    return meta.get("commit") or \
        hashlib.sha1(f"{project}\n{meta['tag_name']}".encode()).hexdigest()


def source_archive(src, top, fmt):
    """Bytes of an archive (zip, tar.gz, tar.bz2, tar) of the files below
    src, in the directory top."""
    files = sorted(p for p in src.rglob("*") if p.is_file()) if src.is_dir() else []
    names = [(f"{top}/{p.relative_to(src).as_posix()}", p.read_bytes()) for p in files]
    buf = io.BytesIO()
    if fmt == "zip":
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
            for name, data in names:
                info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
                info.create_system, info.external_attr = 3, 0o100644 << 16   # as git archive
                z.writestr(info, data)
        return buf.getvalue()
    with tarfile.open(fileobj=buf, mode="w") as t:
        for name, data in names:
            info = tarfile.TarInfo(name)
            info.size, info.mode = len(data), 0o644
            t.addfile(info, io.BytesIO(data))
    raw = buf.getvalue()
    if fmt == "tar.gz":
        return gzip.compress(raw, mtime=0)
    if fmt == "tar.bz2":
        return bz2.compress(raw)
    return raw
