#!/usr/bin/env bash
# S3 gate: ctx_expand / ctx_search / compress run inside ctxd, JSON and SSE replies, both API shapes. Local only.
set -euo pipefail
cd "$(dirname "$0")/.."
w=.work/s3
rm -rf "$w" && mkdir -p "$w/fake" "$w/run" "$w/home"
up="" ct=""
trap 'kill $up $ct 2>/dev/null || true' EXIT
fail() { echo "FAIL $1: $2"; exit 1; }
for t in "src/ctxd/main.mojo ctxd" "tests/fake_upstream.mojo fake_upstream"; do
  set -- $t
  mojo build -I src -I "${MOJO_BENTO:-$HOME/Projects/mojo/mojo-bento}/src" -I "${MOJO_BENTO:-$HOME/Projects/mojo/mojo-bento}/lib" "$1" -o ".work/$2" 2> ".work/$2.err" || { cat ".work/$2.err"; fail build "$1"; }
done
listen() { for _ in $(seq 100); do grep -q '^LISTEN ' "$1" 2>/dev/null && { cut -d' ' -f2 "$1"; return; }; sleep 0.05; done; fail start "$1 never listened"; }
FAKE_DIR="$PWD/$w/fake" .work/fake_upstream > $w/fake.out 2>&1 & up=$!
uport=$(listen $w/fake.out)
printf 'messages = "http://127.0.0.1:%s"\nchat = "http://127.0.0.1:%s"\n[window]\nmessages = 8000\nchat = 8000\n[summarizer]\nurl = "http://127.0.0.1:%s/sum"\nmodel = "sum-model"\nmax_tokens = 200\n' "$uport" "$uport" "$uport" > $w/run/ctxd.toml
(cd $w/run && HOME="$PWD/../home" CTXD_PORT=0 exec ../../ctxd > ctxd.out 2>&1) & ct=$!
cport=$(listen $w/run/ctxd.out)
python3 -I tools/s3_oracle.py "$cport" "$PWD/$w/fake" "$PWD/$w/run/ctxd.out" || fail oracle "see above"
grep -c '^CTX-TOOL' $w/run/ctxd.out | sed 's/^/ctx tool rounds run inside ctxd: /'
echo "PASS s3"
