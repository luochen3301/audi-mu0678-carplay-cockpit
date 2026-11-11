"""Minimal reader for an IBM J9 ROM image (rom.classes inside a .jxe).

Layout used (J9 2.x, little endian, SRP = int32 relative to its own address):
  header: idTag 'J99J', flagsAndVersion, romSize, classCount,
          SRP jxePointer, SRP tableOfContents, SRP firstClass, SRP aot, 16-byte id
  TOC entry: SRP className (J9UTF8), SRP romClass
  J9UTF8: u16 length + bytes
Only what the checks need is decoded; everything else is located empirically
and cross-checked (see probe()).
"""
import struct
import sys


class RomImage:
    def __init__(self, path):
        self.d = open(path, "rb").read()
        d = self.d
        if d[:4] != b"J99J":
            raise ValueError("not a J9 ROM image")
        self.version, self.romSize, self.classCount = struct.unpack_from("<III", d, 4)
        self.toc = self.srp(0x14)
        self.first = self.srp(0x18)
        self.classes = {}
        for i in range(self.classCount):
            e = self.toc + 8 * i
            name = self.utf8(self.srp(e))
            self.classes[name] = self.srp(e + 4)

    def u32(self, a):
        return struct.unpack_from("<I", self.d, a)[0]

    def i32(self, a):
        return struct.unpack_from("<i", self.d, a)[0]

    def u16(self, a):
        return struct.unpack_from("<H", self.d, a)[0]

    def srp(self, a):
        v = self.i32(a)
        return a + v if v else 0

    def utf8(self, a):
        n = self.u16(a)
        return self.d[a + 2:a + 2 + n].decode("utf-8", "replace")

    def is_utf8(self, a, maxlen=8000):
        if a <= 0 or a + 2 > len(self.d) or a & 1:
            return False
        n = self.u16(a)
        if n == 0 or n > maxlen or a + 2 + n > len(self.d):
            return False
        s = self.d[a + 2:a + 2 + n]
        return all(32 <= c < 127 for c in s)

    def srp_utf8(self, a):
        t = self.srp(a)
        return self.utf8(t) if t and self.is_utf8(t) else None


if __name__ == "__main__":
    img = RomImage(sys.argv[1])
    print("version %08x romSize %d classes %d toc %#x first %#x"
          % (img.version, img.romSize, img.classCount, img.toc, img.first))
    for n in sys.argv[2:]:
        a = img.classes.get(n)
        print(n, hex(a) if a else None)
        if a:
            for k in range(0, 0x60, 4):
                v = img.u32(a + k)
                s = img.srp_utf8(a + k)
                print("  +%02x %08x %10d %s" % (k, v, v if v < 0x80000000 else v - 2**32, s or ""))
