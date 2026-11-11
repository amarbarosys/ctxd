#!/usr/bin/env bash
# Build the ctxd image from a host build: binary + the Mojo runtime libs it links. Usage: docker/build.sh [tag]
set -euo pipefail
cd "$(dirname "$0")/.."
tag=${1:-ctxd:latest}
ctx=.work/image
rm -rf "$ctx" && mkdir -p "$ctx/lib"
mojo build -I src -I "${MOJO_BENTO:-$HOME/Projects/mojo/mojo-bento}/src" -I "${MOJO_BENTO:-$HOME/Projects/mojo/mojo-bento}/lib" src/ctxd/main.mojo -o "$ctx/ctxd" || { echo "FAIL build: mojo build"; exit 1; }
for so in $(ldd "$ctx/ctxd" | awk '/modular\/lib/ {print $3}'); do cp -L "$so" "$ctx/lib/"; done
[ "$(ls "$ctx/lib" | wc -l)" -ge 1 ] || { echo "FAIL libs: no Mojo runtime libs found by ldd"; exit 1; }
cp docker/Dockerfile "$ctx/"
docker build -q -t "$tag" "$ctx" >/dev/null || { echo "FAIL docker: build"; exit 1; }
echo "built $tag ($(docker image inspect "$tag" --format '{{.Size}}') bytes)"
