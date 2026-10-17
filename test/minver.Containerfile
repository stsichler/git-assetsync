# The oldest supported versions: Python 3.8 and Git 2.28 (built from source),
# with git-lfs, and p7zip 16.02 as an older 7-Zip. Used by the CI; locally,
# from the repository root:
#   podman build -t assetsync-minver -f test/minver.Containerfile test
#   podman run --rm -v "$PWD":/src:ro,Z -w /src assetsync-minver test/regress.sh </dev/null
FROM docker.io/library/python:3.8-slim-bullseye
ARG GIT_VERSION=2.28.0
# Debian 11 has moved to the archive
RUN printf 'deb http://archive.debian.org/debian bullseye main\ndeb http://archive.debian.org/debian-security bullseye-security main\n' \
      > /etc/apt/sources.list \
 && apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends build-essential curl ca-certificates \
      libcurl4-gnutls-dev libexpat1-dev zlib1g-dev libssl-dev git-lfs p7zip-full >/dev/null \
 && curl -sSfL https://mirrors.edge.kernel.org/pub/software/scm/git/git-$GIT_VERSION.tar.xz \
      | tar xJ --no-same-owner -C /tmp \
 && make -C /tmp/git-$GIT_VERSION -j"$(nproc)" prefix=/usr/local NO_TCLTK=1 NO_GETTEXT=1 install >/dev/null \
 && rm -rf /tmp/git-$GIT_VERSION /var/lib/apt/lists/*
RUN git --version && python3 --version && git lfs version && 7z | head -2
