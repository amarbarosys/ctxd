#!/usr/bin/env bash
# Run ctxd in docker on the host network (it binds 127.0.0.1 only). Store: ~/.cache/ctxd. Config: ./ctxd.toml if present.
# Keys pass through from env (CTXD_SUMMARIZER_KEY); client keys travel in request headers, never in the image.
set -euo pipefail
mkdir -p "$HOME/.cache/ctxd"
conf=()
[ -f ctxd.toml ] && conf=(-v "$PWD/ctxd.toml:/etc/ctxd/ctxd.toml:ro")
exec docker run --rm --name "${CTXD_NAME:-ctxd}" --network host --user "$(id -u):$(id -g)" \
  -v "$HOME/.cache/ctxd:/data/.cache/ctxd" "${conf[@]}" \
  $(env | grep -o '^CTXD_[A-Z_]*' | sed 's/^/-e /') "${CTXD_IMAGE:-ctxd:latest}"
