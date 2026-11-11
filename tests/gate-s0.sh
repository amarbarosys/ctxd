#!/usr/bin/env bash
# S0 gate: ctxd passthrough against a local fake upstream. No network, no paid API. Output: .work/s0-gate.txt
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .work
up="" ct=""
trap 'kill $up $ct 2>/dev/null || true' EXIT
fail() { echo "FAIL $1: $2"; exit 1; }
for t in "src/ctxd/main.mojo ctxd" "tests/fake_upstream.mojo fake_upstream"; do
  set -- $t
  mojo build -I src -I "${MOJO_BENTO:-$HOME/Projects/mojo/mojo-bento}/src" -I "${MOJO_BENTO:-$HOME/Projects/mojo/mojo-bento}/lib" "$1" -o ".work/$2" 2> ".work/$2.err" || { cat ".work/$2.err"; fail build "$1"; }
done
listen() { for _ in $(seq 100); do grep -q '^LISTEN ' "$1" 2>/dev/null && { cut -d' ' -f2 "$1"; return; }; sleep 0.05; done; fail start "$1 never listened"; }
.work/fake_upstream > .work/fake.out 2>&1 & up=$!
uport=$(listen .work/fake.out)
mkdir -p .work/run
printf 'chat = "http://127.0.0.1:%s/chatbase"\n' "$uport" > .work/run/ctxd.toml
(cd .work/run && CTXD_PORT=0 CTXD_UPSTREAM_MESSAGES="http://127.0.0.1:$uport" exec ../ctxd > ctxd.out 2>&1) & ct=$!
cport=$(listen .work/run/ctxd.out)
python3 -I tools/s0_oracle.py "$cport" "$uport" "$ct"
