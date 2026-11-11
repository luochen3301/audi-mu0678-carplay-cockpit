import os, sys, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from romimg import RomImage
from members import RomClass
img = RomImage(sys.argv[1])
for n in sys.argv[2:]:
    c = RomClass(img, n)
    print("==", n, "extends", c.super, c.interfaces)
    for f in c.fields: print("   F %-40s %-30s %#x" % f)
    for m in c.methods: print("   M %-40s %s" % (m[0], m[1]))
    # constant values of static final int fields: 4 bytes after modifiers
    p = img.srp(c.a + 0x28)
    for name, sig, mods in c.fields:
        while not (img.srp_utf8(p) == name and img.srp_utf8(p + 4) == sig): p += 4
        if mods & 0x8 and sig == "I" and (mods & 0x400000):
            print("   const %s = %d" % (name, img.i32(p + 12)))
        p += 12
    # strings inside the class body
    seen = []
    a = c.a
    for q in range(a, c.end - 2, 2):
        if img.is_utf8(q, 200) and img.u16(q) >= 6:
            s = img.utf8(q)
            if " " in s or "[" in s: seen.append(s)
    for s in seen[:40]: print("   S", s)
