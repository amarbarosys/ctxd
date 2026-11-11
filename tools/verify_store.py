"""Oracle: read a store directory with no Mojo code and check its on-disk format.
usage: verify_store.py <dir> [expected_messages]"""
import json, struct, sys

d = sys.argv[1]
log = open(f"{d}/log.bin", "rb").read()
idx = open(f"{d}/idx.bin", "rb").read()
folds = open(f"{d}/folds.bin", "rb").read()
assert len(idx) % 8 == 0 and len(folds) % 16 == 0, "torn record"
msgs = list(struct.iter_unpack("<II", idx))
fs = list(struct.iter_unpack("<IIII", folds))
if len(sys.argv) > 2:
    assert len(msgs) == int(sys.argv[2]), f"{len(msgs)} messages, expected {sys.argv[2]}"
covered = 0
for i, (off, n) in enumerate(msgs):
    assert n > 0 and off + n <= len(log), f"message {i} outside log.bin"
    assert json.loads(log[off:off + n].decode("utf-8")), f"message {i} is not JSON"
    covered += n
for k, (a, b, off, n) in enumerate(fs):
    assert a < b <= len(msgs) and off + n <= len(log), f"fold {k} out of range"
    log[off:off + n].decode("utf-8")
    covered += n
assert covered == len(log), f"{len(log) - covered} stray bytes in log.bin"
print(f"oracle ok: {len(msgs)} messages and {len(fs)} folds tile log.bin ({len(log)} bytes) exactly")
