from std.sys import argv
from std.time import perf_counter_ns
from ctxd.store import Store
from gen import Rng, message

comptime DIR = ".work/s1-bench-data"
comptime N = 20000


def rss_kb() raises -> Int:
    with open("/proc/self/status", "r") as f:
        for line in f.read().split("\n"):
            if line.startswith("VmRSS:"):
                return Int(String(line.split()[1]))
    raise Error("no VmRSS")


def ms(t0: Int) -> Float64:
    return Float64(Int(perf_counter_ns()) - t0) / 1e6


def write() raises:
    var r = Rng(3)
    var pool = List[List[UInt8]]()
    for i in range(256):
        pool.append(message(r, 40 + r.below(250) if i % 8 else 300 + r.below(700), "pool" + String(i)))
    var s = Store(DIR)
    var t0 = Int(perf_counter_ns())
    for i in range(N):
        _ = s.append(pool[i % 256])
    var t = ms(t0)
    print("append:", N, "messages,", len(s.log), "bytes,", t, "ms,", Float64(N) / t * 1000, "msg/s")
    _ = s.append(List[UInt8](String('{"rare":"zzqq-unique-tail"}').as_bytes()))


def search(s: Store, q: String, name: String) raises:
    var t0 = Int(perf_counter_ns())
    var h = s.search(q)
    print("search", name, ":", len(h), "hits,", ms(t0), "ms")


def load() raises:
    var before = rss_kb()
    var s = Store(DIR)
    var after = rss_kb()
    var n = s.count()
    var logb = len(s.log)
    print("load:", n, "messages,", logb, "bytes of log (~", logb // 4, "tokens)")
    print("rss: before", before, "kB, after", after, "kB, delta", after - before, "kB")
    print("overhead:", Float64(1024 * (after - before) - logb) / Float64(n), "bytes/message beyond the raw bytes (index is 8 on disk, 8 in memory)")
    search(s, "zzqq-unique-tail", "rare (1 hit, last message)")
    search(s, "no-such-needle-anywhere", "miss (full scan)")
    search(s, "lorem", "common (many hits)")
    search(s, '"role":"user"', "every message")


def main() raises:
    if argv()[1] == "write":
        write()
    else:
        load()
