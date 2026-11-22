#!/bin/sh
# The shell tests, in Docker: bats (bash 5, zsh, busybox sh, run mode) on Alpine, then the core
# cases under bash 3.2 (as macOS ships it), Debian (dash, mawk, GNU date) and plain busybox.
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
src=$root
command -v cygpath >/dev/null 2>&1 && src=$(cygpath -w "$root")
export MSYS_NO_PATHCONV=1
(cd "$root/tests/docker" && docker build -q -t zharp-shell-test -f shell.Dockerfile . >/dev/null)
docker run --rm -v "$src:/src" -w /src zharp-shell-test --print-output-on-failure tests/zharp.bats
for image in bash:3.2 debian:12-slim alpine:3.20; do
    echo "# $image"
    docker run --rm -v "$src:/src" -w /src "$image" sh tests/portability.sh
done
