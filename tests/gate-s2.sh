#!/usr/bin/env bash
# S2 gate: header relay, error frame, fold policy over 40 turns, summarizer failure. Local only, 127.0.0.1, no paid API.
# Output: .work/s2-gate.txt (stdout of this script)
set -euo pipefail
cd "$(dirname "$0")/.."
w=.work/s2
rm -rf "$w" && mkdir -p "$w/fake" "$w/run" "$w/bad" "$w/slow" "$w/home"
up="" ct="" bt="" st=""
trap 'kill $up $ct $bt $st 2>/dev/null || true' EXIT
fail() { echo "FAIL $1: $2"; exit 1; }
for t in "src/ctxd/main.mojo ctxd" "tests/fake_upstream.mojo fake_upstream"; do
  set -- $t
  mojo build -I src -I "${MOJO_BENTO:-$HOME/Projects/mojo/mojo-bento}/src" -I "${MOJO_BENTO:-$HOME/Projects/mojo/mojo-bento}/lib" "$1" -o ".work/$2" 2> ".work/$2.err" || { cat ".work/$2.err"; fail build "$1"; }
done
listen() { for _ in $(seq 100); do grep -q '^LISTEN ' "$1" 2>/dev/null && { cut -d' ' -f2 "$1"; return; }; sleep 0.05; done; fail start "$1 never listened"; }
FAKE_DIR="$PWD/$w/fake" .work/fake_upstream > $w/fake.out 2>&1 & up=$!
uport=$(listen $w/fake.out)
conf() { # dir summarizer-url
  printf 'messages = "http://127.0.0.1:%s"\nchat = "http://127.0.0.1:%s/chatbase"\n[window]\nmessages = 8000\nchat = 8000\n[summarizer]\nurl = "%s"\nmodel = "sum-model"\nmax_tokens = 200\n' "$uport" "$uport" "$2" > "$1/ctxd.toml"
}
conf $w/run "http://127.0.0.1:$uport/sum"
conf $w/bad "http://127.0.0.1:1/sum"
conf $w/slow "http://127.0.0.1:$uport/slow/sum"
(cd $w/run && HOME="$PWD/../home" CTXD_PORT=0 exec ../../ctxd > ctxd.out 2>&1) & ct=$!
(cd $w/bad && HOME="$PWD/../home" CTXD_PORT=0 exec ../../ctxd > ctxd.out 2>&1) & bt=$!
(cd $w/slow && HOME="$PWD/../home" CTXD_PORT=0 exec ../../ctxd > ctxd.out 2>&1) & st=$!
cport=$(listen $w/run/ctxd.out)
sport=$(listen $w/slow/ctxd.out)
bport=$(listen $w/bad/ctxd.out)
python3 -I tools/s2_oracle.py "$cport" "$bport" "$PWD/$w/fake" "$PWD/$w/run/ctxd.out" "$PWD/$w/bad/ctxd.out" "$ct" "$uport" "$sport"
echo "PASS s2"
