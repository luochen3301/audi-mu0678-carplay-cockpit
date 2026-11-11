#!/usr/bin/env python3
"""Make hook v1.1 from the published r60 hook: 3 bytes in the r25 autostart
shell script that the hook embeds as a string.

usage: python make_hook_v11.py <r60 libaltscreen111.so> <out .so>

  1. `if [ $i -eq 0 ]`  ->  `if [ $i -lt 0 ]`
     The "navigation already ready at session start" fast path (no phone UI
     re-acquire) is never taken any more, so that case also gets the author's
     single re-acquire. Without it, a first session that starts after the
     navigation is ready loses the phone's opening IDR (vc_render is still
     starting) and the cluster stays black for the whole session.
  2. `else sleep 3; P && touch`  ->  `else sleep 5; P && touch`
     That re-acquire waits 5 s instead of 3 s, so vc_render (1.6-2.4 s to
     start on the car) is listening before the phone sends the new IDR.

Every assumption is checked; the tool refuses to write anything otherwise.
"""
import hashlib
import struct
import sys

R60_SHA256 = "2ce451a472ea98e09971db34f75099dcfd20c0ce5d554df9f9f69755cc5f9ddb"
PATCHES = [
    # (unique context, offset of the changed bytes inside the context, old, new)
    (b"if [ $i -eq 0 ]; then for w in 1 2 3", 9, b"eq", b"lt"),
    (b"else sleep 3; P && touch /tmp/mibr-alt111-gen2-reacquire", 11, b"3", b"5"),
]


def sections(data):
    """(name, offset, size, flags) of every ELF32 little-endian section."""
    assert data[:4] == b"\x7fELF" and data[4] == 1 and data[5] == 1, "not ELF32 LE"
    shoff, = struct.unpack_from("<I", data, 0x20)
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x2E)
    hdrs = [struct.unpack_from("<IIIIIIIIII", data, shoff + i * shentsize) for i in range(shnum)]
    stroff = hdrs[shstrndx][4]
    out = []
    for h in hdrs:
        name = data[stroff + h[0]:data.index(b"\0", stroff + h[0])].decode()
        out.append((name, h[4], h[5], h[2]))
    return out


def main():
    src, dst = sys.argv[1], sys.argv[2]
    data = bytearray(open(src, "rb").read())
    if hashlib.sha256(data).hexdigest() != R60_SHA256:
        sys.exit("REFUSING: input is not the published r60 hook")
    secs = sections(bytes(data))
    changed = []
    for ctx, rel, old, new in PATCHES:
        hits = [i for i in range(len(data)) if data.startswith(ctx, i)]
        if len(hits) != 1:
            sys.exit(f"REFUSING: context found {len(hits)} times: {ctx!r}")
        off = hits[0] + rel
        if bytes(data[off:off + len(old)]) != old or len(old) != len(new):
            sys.exit(f"REFUSING: unexpected bytes at {off}")
        sec = [s for s in secs if s[1] <= off < s[1] + s[2]]
        if len(sec) != 1 or sec[0][0] != ".rodata" or sec[0][3] & 0x4:   # SHF_EXECINSTR
            sys.exit(f"REFUSING: offset {off} is in {sec} (expected non-executable .rodata)")
        data[off:off + len(new)] = new
        changed += list(range(off, off + len(new)))
        print(f"patched {ctx!r} at {off} in {sec[0][0]}: {old!r} -> {new!r}")
    orig = open(src, "rb").read()
    diff = [i for i in range(len(orig)) if orig[i] != data[i]]
    assert len(orig) == len(data) and diff == changed, "unexpected difference"
    open(dst, "wb").write(data)
    print(f"bytes changed: {len(diff)} at {diff}")
    print(f"sha256 {hashlib.sha256(data).hexdigest()}")


if __name__ == "__main__":
    main()
