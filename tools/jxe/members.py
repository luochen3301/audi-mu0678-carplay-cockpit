"""Member lists of ROM classes (from rom.classes) and of .class files.

ROM class header offsets (checked on this image against classes whose
members are known):
  +00 romSize  +08 SRP className  +0c SRP superclassName  +10 modifiers
  +14 interfaceCount  +18 SRP interfaces  +1c romMethodCount  +20 SRP romMethods
  +24 romFieldCount  +28 SRP romFields
ROM field:  SRP name, SRP signature, u32 modifiers, then optional extras
ROM method: SRP name, SRP signature, u32 modifiers, u16 maxStack,
            u16 bytecodeSizeLow, u8 bytecodeSizeHigh, u8 argCount, u16 tempCount,
            bytecodes, then optional extras
Members are walked by finding the next 4-aligned (name, signature) SRP pair
after the previous member; the walk must find exactly the declared count
inside the class, otherwise the class is reported as not decodable.
"""
import struct
import sys

sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.abspath(__file__)))
from romimg import RomImage

ACC_STATIC = 0x0008


def _is_field_sig(s):
    return s is not None and len(s) > 0 and s[0] in "BCDFIJSZL["


def _is_method_sig(s):
    return s is not None and s.startswith("(") and ")" in s


def _is_name(s):
    return s is not None and len(s) > 0 and all(c.isalnum() or c in "_$<>" for c in s)


class RomClass:
    def __init__(self, img, name):
        self.img = img
        self.name = name
        a = img.classes[name]
        self.a = a
        self.size = img.u32(a)
        self.end = a + self.size
        assert img.srp_utf8(a + 8) == name, "className mismatch"
        self.super = img.srp_utf8(a + 0x0C)
        self.modifiers = img.u32(a + 0x10)
        n_if = img.u32(a + 0x14)
        ia = img.srp(a + 0x18)
        self.interfaces = [img.srp_utf8(ia + 4 * i) for i in range(n_if)] if n_if else []
        self.methods = self._walk(img.srp(a + 0x20), img.u32(a + 0x1C), True)
        self.fields = self._walk(img.srp(a + 0x28), img.u32(a + 0x24), False)

    def _pair(self, p, method):
        n = self.img.srp_utf8(p)
        s = self.img.srp_utf8(p + 4)
        if not _is_name(n):
            return None
        if method and not _is_method_sig(s):
            return None
        if not method and not _is_field_sig(s):
            return None
        return n, s

    def _walk(self, start, count, method):
        out = []
        p = start
        while len(out) < count:
            if p + 12 > self.end:
                raise ValueError("%s: walk ran past the class (%d of %d %s)"
                                 % (self.name, len(out), count, "methods" if method else "fields"))
            pr = self._pair(p, method)
            if pr is None:
                p += 4
                continue
            mods = self.img.u32(p + 8)
            out.append((pr[0], pr[1], mods))
            if method:
                bc = self.img.u16(p + 14) | (self.img.d[p + 16] << 16)
                p += 20 + 4 * bc   # size is stored in 4-byte words
            else:
                p += 12
                if mods & 0x400000:            # static constant: value follows
                    p += 8 if pr[1] in ("J", "D") else 4
        return out


def class_members(path):
    """Members and references of a .class file."""
    d = open(path, "rb").read()
    assert d[:4] == b"\xca\xfe\xba\xbe"
    off = 10
    n = struct.unpack_from(">H", d, 8)[0]
    cp = [None] * n
    i = 1
    while i < n:
        tag = d[off]
        if tag == 1:
            ln = struct.unpack_from(">H", d, off + 1)[0]
            cp[i] = ("utf8", d[off + 3:off + 3 + ln].decode("utf-8"))
            off += 3 + ln
        elif tag in (3, 4):
            cp[i] = ("num",); off += 5
        elif tag in (5, 6):
            cp[i] = ("num",); off += 9; i += 1
        elif tag in (7, 8):
            cp[i] = ("class" if tag == 7 else "string", struct.unpack_from(">H", d, off + 1)[0]); off += 3
        elif tag in (9, 10, 11, 12):
            a, b = struct.unpack_from(">HH", d, off + 1)
            cp[i] = ({9: "field", 10: "method", 11: "imethod", 12: "nat"}[tag], a, b); off += 5
        else:
            raise ValueError("cp tag %d" % tag)
        i += 1

    def u(k):
        return cp[k][1]

    def cls(k):
        return u(cp[k][1])

    acc, this_, super_ = struct.unpack_from(">HHH", d, off); off += 6
    nif = struct.unpack_from(">H", d, off)[0]; off += 2
    ifs = [cls(struct.unpack_from(">H", d, off + 2 * j)[0]) for j in range(nif)]; off += 2 * nif

    def members(off):
        cnt = struct.unpack_from(">H", d, off)[0]; off += 2
        out = []
        for _ in range(cnt):
            a, nm, ds, ac = struct.unpack_from(">HHHH", d, off); off += 8
            for _ in range(ac):
                ln = struct.unpack_from(">I", d, off + 2)[0]
                off += 6 + ln
            out.append((u(nm), u(ds), a))
        return out, off

    fields, off = members(off)
    methods, off = members(off)
    refs = []
    for e in cp:
        if e and e[0] in ("field", "method", "imethod"):
            nat = cp[e[2]]
            refs.append((e[0], cls(e[1]), u(nat[1]), u(nat[2])))
    return {"name": cls(this_), "super": cls(super_), "interfaces": ifs,
            "fields": fields, "methods": methods, "refs": refs, "access": acc}


if __name__ == "__main__":
    img = RomImage(sys.argv[1])
    for n in sys.argv[2:]:
        c = RomClass(img, n)
        print("%s extends %s implements %s mods=%#x" % (n, c.super, c.interfaces, c.modifiers))
        for f in c.fields:
            print("  field  %-28s %-40s %#x" % f)
        for m in c.methods:
            print("  method %-28s %-60s %#x" % m)
