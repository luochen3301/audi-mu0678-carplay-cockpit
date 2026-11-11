"""Check that the classes in an override jar are safe drop-ins for the stock
classes of the same name in this unit's HMI image (rom.classes from lsd.jxe).

usage: python check_override.py <rom.classes> <dir with the jar's .class files>

For every class in the jar:
  1. the stock class exists; same superclass, interfaces and class access;
  2. every stock field/method exists in the override with the same signature
     and the same static-ness (so no stock caller can hit a missing member);
  3. every field/method the override's code references resolves, with the
     same signature, in the override itself, its stock superclasses, or the
     referenced stock class (walking superclasses and interfaces);
  4. every method of the stock interfaces is implemented;
  5. bytecode sizes per method, stock vs override, to show what changed.
Exit status 0 only if 1-4 pass for every class.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from romimg import RomImage  # noqa: E402
from members import RomClass, class_members, ACC_STATIC  # noqa: E402

ACC_PUBLIC, ACC_PRIVATE, ACC_PROTECTED = 0x1, 0x2, 0x4


def code_sizes(path):
    """{(name, desc): code length} of a .class file."""
    d = open(path, "rb").read()
    n = struct.unpack_from(">H", d, 8)[0]
    off = 10
    cp = [None] * n
    i = 1
    while i < n:
        t = d[off]
        if t == 1:
            ln = struct.unpack_from(">H", d, off + 1)[0]
            cp[i] = d[off + 3:off + 3 + ln].decode(); off += 3 + ln
        elif t in (3, 4): off += 5
        elif t in (5, 6): off += 9; i += 1
        elif t in (7, 8): off += 3
        else: off += 5
        i += 1
    off += 6
    nif = struct.unpack_from(">H", d, off)[0]; off += 2 + 2 * nif
    out = {}
    for kind in ("f", "m"):
        cnt = struct.unpack_from(">H", d, off)[0]; off += 2
        for _ in range(cnt):
            a, nm, ds, ac = struct.unpack_from(">HHHH", d, off); off += 8
            for _ in range(ac):
                an = struct.unpack_from(">H", d, off)[0]
                ln = struct.unpack_from(">I", d, off + 2)[0]
                if kind == "m" and cp[an] == "Code":
                    out[(cp[nm], cp[ds])] = struct.unpack_from(">I", d, off + 10)[0]
                off += 6 + ln
    return out


def rom_code_sizes(img, rc):
    out = {}
    p = img.srp(rc.a + 0x20)
    for name, sig, mods in rc.methods:
        # re-walk exactly like RomClass._walk to find each method header
        while not (img.srp_utf8(p) == name and img.srp_utf8(p + 4) == sig):
            p += 4
        bc = img.u16(p + 14) | (img.d[p + 16] << 16)
        out[(name, sig)] = (4 * bc, img.d[p + 20:p + 20 + 4 * bc])   # stored in 4-byte words
        p += 20 + 4 * bc
    return out


def access(m):
    return "private" if m & ACC_PRIVATE else "protected" if m & ACC_PROTECTED else \
        "public" if m & ACC_PUBLIC else "package"


RANK = {"private": 0, "package": 1, "protected": 2, "public": 3}


def main():
    img = RomImage(sys.argv[1])
    cache = {}

    def rom(name):
        if name not in cache:
            cache[name] = RomClass(img, name) if name in img.classes else None
        return cache[name]

    def find_member(cls_name, kind, name, sig, seen=None):
        """Search cls_name, its superclasses and interfaces in the ROM image."""
        seen = seen or set()
        if cls_name is None or cls_name in seen:
            return None
        seen.add(cls_name)
        rc = rom(cls_name)
        if rc is None:
            return "absent:" + cls_name
        lst = rc.methods if kind != "field" else rc.fields
        for n, s, m in lst:
            if n == name and s == sig:
                return (cls_name, m)
        for nxt in [rc.super] + rc.interfaces:
            r = find_member(nxt, kind, name, sig, seen)
            if isinstance(r, tuple):
                return r
        return None

    root = sys.argv[2]
    failures = 0
    for dp, _, fs in os.walk(root):
        for f in sorted(fs):
            if not f.endswith(".class"):
                continue
            path = os.path.join(dp, f)
            ov = class_members(path)
            name = ov["name"]
            print("=" * 78)
            print(name)
            st = rom(name)
            if st is None:
                print("  FAIL  no stock class of this name in the HMI image")
                failures += 1
                continue
            ok = True

            def fail(msg):
                nonlocal ok
                ok = False
                print("  FAIL  " + msg)

            # 1. shape
            if st.super != ov["super"]:
                fail("superclass stock %s, override %s" % (st.super, ov["super"]))
            if sorted(st.interfaces) != sorted(ov["interfaces"]):
                fail("interfaces stock %s, override %s" % (st.interfaces, ov["interfaces"]))
            if (st.modifiers & 0x7FF) & ~0x20 != ov["access"] & 0x7FF & ~0x20:
                fail("class access stock %#x, override %#x" % (st.modifiers, ov["access"]))
            print("  shape: extends %s, implements %s, access %#x" % (st.super, st.interfaces, ov["access"]))

            # 2. stock members all present, same static-ness, access not narrower
            for kind, slist, olist in (("field", st.fields, ov["fields"]), ("method", st.methods, ov["methods"])):
                omap = {(n, s): m for n, s, m in olist}
                for n, s, m in slist:
                    om = omap.get((n, s))
                    if om is None:
                        fail("stock %s %s %s missing in override" % (kind, n, s))
                        continue
                    if (m & ACC_STATIC) != (om & ACC_STATIC):
                        fail("%s %s %s static-ness differs" % (kind, n, s))
                    if RANK[access(om)] < RANK[access(m)]:
                        fail("%s %s %s access narrowed %s -> %s" % (kind, n, s, access(m), access(om)))
                    print("  same  %-6s %-28s %s  (%s%s)" % (kind, n, s, access(m), " static" if m & ACC_STATIC else ""))
                smap = {(n, s) for n, s, _ in slist}
                for n, s, m in olist:
                    if (n, s) not in smap:
                        print("  extra %-6s %-28s %s  (%s) - not in stock" % (kind, n, s, access(m)))

            # 3. every reference resolves
            for kind, cls, n, s in ov["refs"]:
                k = "field" if kind == "field" else "method"
                if cls == name:
                    own = {(a, b) for a, b, _ in (ov["fields"] if k == "field" else ov["methods"])}
                    if (n, s) in own:
                        continue
                    r = find_member(st.super, k, n, s)
                else:
                    r = find_member(cls, k, n, s)
                if isinstance(r, tuple):
                    print("  ref ok  %-6s %s.%s %s  (found in %s)" % (k, cls, n, s, r[0]))
                elif isinstance(r, str) and cls.startswith("java/"):
                    print("  ref JRE %-6s %s.%s %s  (%s - JRE class, not in lsd.jxe)" % (k, cls, n, s, r))
                else:
                    fail("reference %s %s.%s %s does not resolve (%s)" % (k, cls, n, s, r))

            # 4. interface methods implemented
            for itf in st.interfaces:
                ir = rom(itf)
                if ir is None:
                    fail("interface %s not in image" % itf)
                    continue
                for n, s, m in ir.methods:
                    if n == "<clinit>":
                        continue
                    have = any(a == n and b == s for a, b, _ in ov["methods"]) or \
                        isinstance(find_member(st.super, "method", n, s), tuple)
                    if not have:
                        fail("interface method %s.%s %s not implemented" % (itf, n, s))
                    else:
                        print("  impl  %s.%s %s" % (itf.rsplit("/", 1)[-1], n, s))

            # 5. bytecode sizes
            ocs = code_sizes(path)
            for (n, s), (bc, code) in rom_code_sizes(img, st).items():
                o = ocs.get((n, s))
                mark = "" if o is not None and (o + 3) & ~3 == bc else "   <-- differs"
                print("  code  %-28s %-50s stock %4d  override %4s%s" % (n, s[:50], bc, o, mark))
                if mark or os.environ.get("SHOWCODE"):
                    print("        stock bytes: " + code.hex(" "))
            print("  RESULT: %s" % ("PASS" if ok else "FAIL"))
            failures += 0 if ok else 1
    print("=" * 78)
    print("ALL PASS" if failures == 0 else "%d CLASS(ES) FAILED" % failures)
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
