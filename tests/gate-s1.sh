#!/usr/bin/env bash
# S1 gate: round trip, torn-tail recovery, independent format oracle, 1M-token measurements.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .work
step() { echo "== $1"; }
fail() { echo "FAIL $1: $2"; exit 1; }

step build
for t in roundtrip bench; do
  mojo build -I src -I "${MOJO_BENTO:-$HOME/Projects/mojo/mojo-bento}/src" -I "${MOJO_BENTO:-$HOME/Projects/mojo/mojo-bento}/lib" -I tests "tests/$t.mojo" -o ".work/s1-$t" 2>.work/s1-build-$t.log \
    || { cat .work/s1-build-$t.log; fail build "tests/$t.mojo does not compile"; }
done

step "round trip (2000 messages incl. 1.5 MB and 3 MB, unicode, folds, reopen)"
rm -rf .work/s1-rt
.work/s1-roundtrip main || fail roundtrip "see output above"
python3 -I tools/verify_store.py .work/s1-rt 2001 || fail oracle "on-disk format check on .work/s1-rt"
step "torn tail"
.work/s1-roundtrip torn || fail torn "see output above"

step "1M-token session"
rm -rf .work/s1-bench-data
.work/s1-bench write || fail bench-write "see output above"
python3 -I tools/verify_store.py .work/s1-bench-data 20001 || fail oracle "on-disk format check on .work/s1-bench-data"
.work/s1-bench load || fail bench-load "see output above"

step loc
cat src/ctxd/store.mojo | grep -cvE '^\s*(#.*)?$' | xargs echo "store.mojo non-blank lines (docstrings included):"
echo "PASS gate-s1"
