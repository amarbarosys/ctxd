#!/usr/bin/env bash
# S4 gate: the docker image passes the S0 oracle (bytes, streaming, headers, latency), bound to 127.0.0.1 only.
set -euo pipefail
cd "$(dirname "$0")/.."
w=.work/s4
rm -rf "$w" && mkdir -p "$w/home/.cache/ctxd"
up="" name=ctxd-gate-$$
trap 'kill $up 2>/dev/null || true; docker rm -f $name >/dev/null 2>&1 || true' EXIT
fail() { echo "FAIL $1: $2"; exit 1; }
docker/build.sh ctxd:gate > $w/build.txt 2>&1 || { tail $w/build.txt; fail image "docker/build.sh"; }
tail -1 $w/build.txt
mojo build -I src -I "${MOJO_BENTO:-$HOME/Projects/mojo/mojo-bento}/src" -I "${MOJO_BENTO:-$HOME/Projects/mojo/mojo-bento}/lib" tests/fake_upstream.mojo -o .work/fake_upstream 2> .work/fake_upstream.err || fail build fake_upstream
listen() { for _ in $(seq 100); do grep -q '^LISTEN ' "$1" 2>/dev/null && { cut -d' ' -f2 "$1"; return; }; sleep 0.1; done; fail start "$1 never listened"; }
.work/fake_upstream > $w/fake.out 2>&1 & up=$!
uport=$(listen $w/fake.out)
cport=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
printf 'chat = "http://127.0.0.1:%s/chatbase"\n' "$uport" > $w/ctxd.toml
docker run -d --name $name --network host --user "$(id -u):$(id -g)" \
  -v "$PWD/$w/home/.cache/ctxd:/data/.cache/ctxd" -v "$PWD/$w/ctxd.toml:/etc/ctxd/ctxd.toml:ro" \
  -e CTXD_PORT=$cport -e CTXD_UPSTREAM_MESSAGES="http://127.0.0.1:$uport" ctxd:gate > /dev/null
for _ in $(seq 100); do docker logs $name 2>&1 | grep -q '^LISTEN ' && break; sleep 0.1; done
docker logs $name 2>&1 | grep -q "^LISTEN $cport" || { docker logs $name; fail start "container never listened on $cport"; }
ss -ltnH "sport = :$cport" | grep -q '127.0.0.1:' || fail bind "ctxd in the container is not bound to 127.0.0.1 only"
python3 -I tools/s0_oracle.py "$cport" "$uport" "$(docker inspect -f '{{.State.Pid}}' $name)" || fail oracle "see above"
echo "PASS s4"
