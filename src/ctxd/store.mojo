"""S1: append-only per-session message store.

<dir>/log.bin    message JSON bytes and fold summaries, back to back
<dir>/idx.bin    flat (u32 off, u32 len) per message, into log.bin
<dir>/folds.bin  flat (u32 a, u32 b, u32 off, u32 len) per fold: messages [a, b) and the summary in log.bin

Memory is one List[UInt8] plus two List[UInt32]. Search is a byte scan of the log.
"""
from std.os import SEEK_END, SEEK_SET, getenv, makedirs
from std.os.path import exists


def session_dir(session: String) raises -> String:
    if session.byte_length() == 0 or "/" in session or ".." in session:
        raise Error("ctxd: bad session id '" + session + "'")
    return getenv("HOME") + "/.cache/ctxd/" + session


def _slurp(path: String) raises -> List[UInt8]:
    """The whole file in one exact allocation (`read_bytes` peaks near 3x the file size in RSS)."""
    var out = List[UInt8]()
    if exists(path):
        with open(path, "r") as f:
            out.resize(Int(f.seek(0, SEEK_END)), 0)
            _ = f.seek(0, SEEK_SET)
            var got = 0
            while got < len(out):
                var n = f.read(Span(out)[got:])
                if n <= 0:
                    raise Error("ctxd: short read of " + path)
                got += n
    return out^


def _words(path: String, stride: Int) raises -> List[UInt32]:
    var raw = _slurp(path)
    var out = List[UInt32](capacity=len(raw) // 4)
    for i in range(len(raw) // (4 * stride) * stride):
        var w = 0
        for k in range(4):
            w |= Int(raw[4 * i + k]) << (8 * k)
        out.append(UInt32(w))
    return out^


def _pack(v: List[UInt32], lo: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(lo, len(v)):
        for k in range(4):
            out.append(UInt8((Int(v[i]) >> (8 * k)) & 255))
    return out^


def _fold_ok(f: List[UInt32], k: Int, n: Int, size: Int) -> Bool:
    return f[4 * k] < f[4 * k + 1] and Int(f[4 * k + 1]) <= n and Int(f[4 * k + 2]) + Int(f[4 * k + 3]) <= size


struct Store(Movable):
    var log: List[UInt8]
    var idx: List[UInt32]
    var folds: List[UInt32]
    var flog: FileHandle
    var fidx: FileHandle
    var ffold: FileHandle

    def __init__(out self, dir: String) raises:
        makedirs(dir, exist_ok=True)
        self.log = _slurp(dir + "/log.bin")
        self.idx = _words(dir + "/idx.bin", 2)
        self.folds = _words(dir + "/folds.bin", 4)
        var size = len(self.log)
        var ni = 0
        while ni < len(self.idx) // 2 and Int(self.idx[2 * ni]) + Int(self.idx[2 * ni + 1]) <= size:
            ni += 1
        var nf = 0
        while nf < len(self.folds) // 4 and _fold_ok(self.folds, nf, ni, size):
            nf += 1
        var cut_i = ni * 2 < len(self.idx)
        var cut_f = nf * 4 < len(self.folds)
        self.idx.shrink(ni * 2)
        self.folds.shrink(nf * 4)
        self.flog = open(dir + "/log.bin", "a")
        self.fidx = open(dir + "/idx.bin", "w" if cut_i else "a")
        self.ffold = open(dir + "/folds.bin", "w" if cut_f else "a")
        if cut_i:
            self.fidx.write_bytes(Span(_pack(self.idx, 0)))
        if cut_f:
            self.ffold.write_bytes(Span(_pack(self.folds, 0)))

    def count(self) -> Int:
        return len(self.idx) // 2

    def fold_count(self) -> Int:
        return len(self.folds) // 4

    def _put(mut self, data: Span[UInt8, _]) raises -> Int:
        var off = len(self.log)
        if off + len(data) > Int(UInt32.MAX):
            raise Error("ctxd: log.bin would pass 4 GiB")
        self.flog.write_bytes(data)
        self.log.extend(data)
        return off

    def append(mut self, data: Span[UInt8, _]) raises -> Int:
        if len(data) == 0:
            raise Error("ctxd: empty message")
        var off = self._put(data)
        self.idx.append(UInt32(off))
        self.idx.append(UInt32(len(data)))
        self.fidx.write_bytes(Span(_pack(self.idx, len(self.idx) - 2)))
        return self.count() - 1

    def get(ref self, id: Int) raises -> Span[UInt8, origin_of(self.log)]:
        if id < 0 or id >= self.count():
            raise Error("ctxd: no message " + String(id))
        var off = Int(self.idx[2 * id])
        return Span(self.log)[off : off + Int(self.idx[2 * id + 1])]

    def range(self, a: Int, b: Int) raises -> List[UInt8]:
        if a < 0 or b > self.count() or a > b:
            raise Error("ctxd: bad range [" + String(a) + ", " + String(b) + ")")
        var out = List[UInt8]()
        for i in range(a, b):
            out.extend(self.get(i))
        return out^

    def fold(mut self, a: Int, b: Int, summary: Span[UInt8, _]) raises -> Int:
        if a < 0 or a >= b or b > self.count():
            raise Error("ctxd: bad fold [" + String(a) + ", " + String(b) + ")")
        var off = self._put(summary)
        for v in [a, b, off, len(summary)]:
            self.folds.append(UInt32(v))
        self.ffold.write_bytes(Span(_pack(self.folds, len(self.folds) - 4)))
        return self.fold_count() - 1

    def summary(ref self, fid: Int) raises -> Span[UInt8, origin_of(self.log)]:
        if fid < 0 or fid >= self.fold_count():
            raise Error("ctxd: no fold " + String(fid))
        var off = Int(self.folds[4 * fid + 2])
        return Span(self.log)[off : off + Int(self.folds[4 * fid + 3])]

    def expand(self, fid: Int) raises -> List[UInt8]:
        _ = self.summary(fid)
        return self.range(Int(self.folds[4 * fid]), Int(self.folds[4 * fid + 1]))

    def _owner(self, pos: Int) -> Int:
        """The last message starting at or before `pos`, or -1."""
        var lo = 0
        var hi = self.count()
        while lo < hi:
            var mid = (lo + hi) // 2
            if Int(self.idx[2 * mid]) <= pos:
                lo = mid + 1
            else:
                hi = mid
        return lo - 1

    def search(self, q: String) -> List[Int]:
        """Ids of the messages whose bytes contain `q`, ascending. Hits in summaries or across messages do not count."""
        var hits = List[Int]()
        var n = q.byte_length()
        var hay = StringSlice(unsafe_from_utf8=Span(self.log))
        var pos = 0
        while n > 0:
            var p = hay.find(q, pos)
            if p < 0:
                break
            var id = self._owner(p)
            var end = Int(self.idx[2 * id]) + Int(self.idx[2 * id + 1]) if id >= 0 else 0
            if p + n <= end:
                hits.append(id)
                pos = end
            else:
                pos = p + 1
        return hits^
