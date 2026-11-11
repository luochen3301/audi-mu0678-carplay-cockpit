"""Which ROM classes reference a given UTF8 (via any SRP inside the class)."""
import os, sys, bisect
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from romimg import RomImage
img = RomImage(sys.argv[1])
d = img.d
arr = np.frombuffer(d[:len(d) // 4 * 4], dtype="<i4").astype(np.int64)
pos = np.arange(arr.size, dtype=np.int64) * 4
tgt = arr + pos
starts = sorted((a, n) for n, a in img.classes.items())
keys = [a for a, _ in starts]
def owner(p):
    i = bisect.bisect_right(keys, p) - 1
    if i < 0: return None
    a, n = starts[i]
    return n if p < a + img.u32(a) else None
for word in sys.argv[2:]:
    b = word.encode()
    pat = len(b).to_bytes(2, "little") + b
    locs = []; i = d.find(pat)
    while i != -1:
        locs.append(i); i = d.find(pat, i + 1)
    users = {}
    for L in locs:
        for p in np.nonzero(tgt == L)[0]:
            o = owner(int(p) * 4)
            users[o] = users.get(o, 0) + 1
        o = owner(L)
        if o: users.setdefault(o + "  (string inside class)", 0)
    print("== %s  (%d copies)" % (word, len(locs)))
    for u in sorted(users, key=str): print("   ", u, users[u])
