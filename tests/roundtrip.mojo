from std.sys import argv
from ctxd.store import Store
from gen import Rng, message

comptime DIR = ".work/s1-rt"


def check(ok: Bool, what: String) raises:
    if not ok:
        raise Error(what)


def same(a: Span[UInt8, _], b: Span[UInt8, _]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def write(mut want: List[List[UInt8]], mut sums: List[List[UInt8]], mut folds: List[Tuple[Int, Int]]) raises:
    var s = Store(DIR)
    var r = Rng(7)
    for i in range(2000):
        var size = 20 + r.below(3000)
        if i == 500:
            size = 1_500_000
        if i == 1500:
            size = 3_000_000
        want.append(message(r, size, "needle#" + String(i) + "#"))
        check(s.append(want[i]) == i, "append id")
    for k in range(6):
        var a = r.below(1900)
        var b = a + 1 + r.below(100)
        sums.append(List[UInt8](String("SUMONLY é日本 fold " + String(k)).as_bytes()))
        folds.append((a, b))
        check(s.fold(a, b, sums[k]) == k, "fold id")
    _ = s.append(List[UInt8](String('{"tail":"x"}').as_bytes()))


def verify(want: List[List[UInt8]], sums: List[List[UInt8]], folds: List[Tuple[Int, Int]]) raises:
    var s = Store(DIR)
    check(s.count() == len(want) + 1 and s.fold_count() == len(folds), "counts after reopen")
    for i in range(len(want)):
        check(same(s.get(i), want[i]), "get " + String(i) + " not byte-equal")
    for k in range(len(folds)):
        var cat = List[UInt8]()
        for i in range(folds[k][0], folds[k][1]):
            cat.extend(Span(want[i]))
        check(same(s.expand(k), cat), "expand " + String(k) + " not the concatenated range")
        check(same(s.summary(k), sums[k]), "summary " + String(k))
    print("ok roundtrip:", len(want), "messages,", len(folds), "folds, byte-equal after reopen")
    for i in range(0, len(want), 97):
        var h = s.search("needle#" + String(i) + "#")
        check(len(h) == 1 and h[0] == i, "search needle " + String(i))
    check(len(s.search("SUMONLY")) == 0, "search must not hit summaries")
    check(len(s.search('"}{"role"')) == 0, "search must not cross messages")
    check(len(s.search("")) == 0 and len(s.search('{"tail"')) == 1 and len(s.search("lorem ")) > 1000, "search counts")
    print("ok search: needles found once, summaries and boundaries not matched")
    var bad = 0
    try:
        _ = s.get(len(want) + 1)
    except:
        bad += 1
    try:
        _ = s.get(-1)
    except:
        bad += 1
    try:
        _ = s.fold(3, 3, sums[0])
    except:
        bad += 1
    try:
        _ = s.expand(99)
    except:
        bad += 1
    try:
        _ = s.append(List[UInt8]())
    except:
        bad += 1
    check(bad == 5, "bad input must raise, " + String(bad) + " of 5 did")
    print("ok bad input raises")


def torn() raises:
    with open(DIR + "/idx.bin", "a") as f:
        f.write_bytes(List[UInt8](length=11, fill=255))
    with open(DIR + "/folds.bin", "a") as f:
        f.write_bytes(List[UInt8](length=16, fill=255))
    with open(DIR + "/log.bin", "a") as f:
        f.write_bytes(List[UInt8](length=5, fill=65))
    var s = Store(DIR)
    check(s.count() == 2001 and s.fold_count() == 6, "torn tail not dropped")
    check(s.append(List[UInt8](String("{}").as_bytes())) == 2001, "append after torn tail")
    s = Store(DIR)
    check(s.count() == 2002 and s.get(2001)[0] == 123, "reopen after torn recovery")
    print("ok torn tail dropped, appends continue")


def main() raises:
    if argv()[1] == "torn":
        torn()
        return
    var want = List[List[UInt8]]()
    var sums = List[List[UInt8]]()
    var folds = List[Tuple[Int, Int]]()
    write(want, sums, folds)
    verify(want, sums, folds)
