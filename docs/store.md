# S1 fold store (src/ctxd/store.mojo)

Per session dir (`session_dir(id)` = `~/.cache/ctxd/<id>`), three flat files:

| file | record | meaning |
|---|---|---|
| log.bin | raw bytes | message JSON and fold summaries, back to back |
| idx.bin | u32 off, u32 len (LE) | message i = log[off:off+len] |
| folds.bin | u32 a, u32 b, u32 off, u32 len | fold covers messages [a, b), summary = log[off:off+len] |

Memory: one `List[UInt8]` (log), two `List[UInt32]` (idx, folds). `get` and `summary` return Spans into the log
(an `append` may move the log: do not hold a Span across it). Ids are positions, stable forever.

- Opening drops a torn tail: idx or fold records that point past the log, or a partial record, are cut and the file rewritten.
- `search(q)` is a byte scan of the whole log; hits inside summaries or across a message boundary do not count.
- Limits: log.bin under 4 GiB (u32 offsets, raises past it); empty messages are rejected.
- Check: `tests/gate-s1.sh`. The gate prints the measured numbers.
