#!/usr/bin/env python3
"""Check an altscreen-collect folder against the joeyQuery/MHI2-altScreen reference unit.

usage: python check_collect.py <card>/altscreen_collect/NNN
       python check_collect.py <card>/altscreen_collect      (picks the highest NNN)

Standard library only. Prints one line per check:
  PASS  matches the reference unit, nothing to port
  WARN  differs in a way that needs a look before installing
  FAIL  blocks the r60 build as published
  INFO  recorded for later steps
"""
import hashlib
import os
import re
import sys

REF = {
    "train": "MHI2_ER_AUG22_P3241",
    # mu0678/firmware.md and the deployment scripts of the reference repo
    "libairplay.so": ("a3ab0fe0ac20a712f7f240c1abd852a38faf78f2673880342d0eb24a6d8c29be", 857727),
    "smartphone_integrator.json": "6e7968e0279a2548c50285923e5bbc66f8775ad490c2394e430318d570faeed9",
    "displaymanager.json": "c2263eb38ff03dbd23d1c95ddf47e04762df97e40da1825f8677801cec24d644",
    "dio_manager.json": "99a11a14efa4a02bc5811b5d29d0b336695089c06774ca4568bb7844f4688528",
}

results = []


def rep(status, name, detail=""):
    results.append((status, name, detail))


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except OSError:
        return None


def pick_run(arg):
    if os.path.isdir(os.path.join(arg, "files")):
        return arg
    runs = [d for d in os.listdir(arg) if d.isdigit() and os.path.isdir(os.path.join(arg, d))]
    if not runs:
        sys.exit(f"no NNN run folder under {arg}")
    return os.path.join(arg, max(runs, key=int))


def find_file(files_dir, *suffixes):
    """First collected file whose flattened name ends with one of the suffixes."""
    names = sorted(os.listdir(files_dir)) if os.path.isdir(files_dir) else []
    for suf in suffixes:
        for n in names:
            if n.endswith(suf):
                return os.path.join(files_dir, n)
    return None


def e2p_train(text):
    """modifyE2P prints '0x<addr> <hex bytes>'; decode the ASCII train."""
    if not text:
        return ""
    hexbytes = []
    for line in text.splitlines():
        parts = line.split()
        if not parts or not parts[0].lower().startswith("0x"):
            continue
        for tok in parts[1:]:
            for i in range(0, len(tok) - 1, 2):
                b = tok[i:i + 2]
                if re.fullmatch(r"[0-9a-fA-F]{2}", b):
                    hexbytes.append(int(b, 16))
    s = ""
    for b in hexbytes:
        c = chr(b)
        if c.isalnum() or c == "_":
            s += c
        else:
            break
    return s


def parse_contexts(text):
    """dmdt gc -> {context_id: [displayable ids]}"""
    ctx, cur = {}, None
    for line in text.splitlines():
        m = re.match(r"^\s*(-?\d+)\s*\|\s*\d+\s*\|", line)
        if m:
            cur = int(m.group(1))
            ctx[cur] = []
            continue
        m = re.match(r"^\s+(-?\d+)\s+\(", line)
        if m and cur is not None:
            ctx[cur].append(int(m.group(1)))
    return ctx


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    run = pick_run(sys.argv[1])
    files = os.path.join(run, "files")
    cmd = os.path.join(run, "cmd")
    print(f"run folder: {run}\n")

    # 1. firmware train
    train = ""
    p = find_file(files, "CachedTrain.txt")
    if p:
        lines = (read(p) or "").strip().splitlines()
        train = lines[0].strip() if lines else ""   # 2nd line is a checksum
    if not train:
        train = e2p_train(read(os.path.join(cmd, "e2p_train.txt")))
    if train.startswith(REF["train"]):
        rep("PASS", "firmware train", train)
    elif train:
        rep("FAIL", "firmware train", f"{train} (reference {REF['train']})")
    else:
        rep("WARN", "firmware train", "not readable; see cmd/e2p_train.txt")

    # 2. libairplay.so - every hook offset in the r60 build is tied to this exact file
    p = find_file(files, "eso__lib__libairplay.so")
    if not p:
        rep("FAIL", "libairplay.so", "not collected")
    else:
        h, size = sha256(p), os.path.getsize(p)
        if h == REF["libairplay.so"][0]:
            rep("PASS", "libairplay.so", f"sha256 {h[:16]}... identical to reference; hook offsets apply as-is")
        else:
            rep("FAIL", "libairplay.so",
                f"sha256 {h[:16]}... size {size} differs (reference {REF['libairplay.so'][0][:16]}... "
                f"size {REF['libairplay.so'][1]}); offsets must be re-derived before any install")

    # 3. configs
    for name in ("smartphone_integrator.json", "displaymanager.json", "dio_manager.json"):
        p = find_file(files, "mnt__system__etc__eso__production__" + name, "etc__eso__production__" + name)
        if not p:
            rep("WARN", name, "not collected")
            continue
        h = sha256(p)
        if h == REF[name]:
            rep("PASS", name, f"sha256 {h[:16]}... identical to reference")
        else:
            text = read(p) or ""
            hint = ""
            if name == "smartphone_integrator.json" and "LD_PRELOAD" in text:
                hint = "; contains LD_PRELOAD - something already preloads into a child process"
            rep("WARN", name, f"sha256 {h[:16]}... differs from reference{hint}")

    # 4. cluster display as displaymanager sees it
    gs = read(os.path.join(cmd, "dmdt_gs.txt")) or ""
    gs_body = [l for l in gs.splitlines() if l.strip() and not l.startswith("#") and not l.startswith("(exit")]
    if not gs_body:
        # dmdt writes stdout in 1 KB blocks and drops the last partial block when
        # it exits, so a short answer like gs is lost when captured to a file.
        rep("WARN", "cluster display", "dmdt gs printed nothing (output lost when not run on a terminal); "
            "displaymanager.json and contexts 72/77 are the evidence instead")
    elif "2nd_lvds" in gs and re.search(r"1440\s*x\s*542", gs):
        rep("PASS", "cluster display", "2nd_lvds 1440 x 542 present")
    elif "2nd_lvds" in gs:
        m = re.search(r"terminal:\s*2nd_lvds\s*\n\s*size:\s*([0-9]+\s*x\s*[0-9]+)", gs)
        rep("WARN", "cluster display", f"2nd_lvds present but size {m.group(1) if m else '?'} (reference 1440 x 542)")
    else:
        rep("FAIL", "cluster display", "no 2nd_lvds display in dmdt gs output")

    ctx = parse_contexts(read(os.path.join(cmd, "dmdt_gc.txt")) or "")
    c72, c77 = ctx.get(72), ctx.get(77)
    if c72 is not None and 33 in c72:
        rep("PASS", "context 72 (native map)", str(c72))
    else:
        rep("FAIL", "context 72 (native map)", f"{c72} (reference [33])")
    if c77 is not None and 58 in c77:
        rep("PASS", "context 77 (altscreen)", str(c77))
    else:
        rep("FAIL", "context 77 (altscreen)", f"{c77} (reference [20, 102, 101, 58])")

    # 5. packet filter must let stream 111 in on port 6000 (pfctl prints it as 'xserver')
    pf = read(os.path.join(cmd, "pf_rules.txt")) or ""
    ok = re.search(r"pass in quick on carplay0 proto tcp .*port = (6000|xserver)\b", pf)
    if ok:
        rep("PASS", "pf: carplay0 tcp 6000", "allowed")
    elif "carplay0" in pf:
        rep("FAIL", "pf: carplay0 tcp 6000", "carplay0 rules present but 6000 not allowed")
    else:
        rep("WARN", "pf: carplay0 tcp 6000", "no carplay0 rules in output (pfctl missing or interface down?)")

    # 6. other mods
    mods = read(os.path.join(run, "mods.txt")) or ""
    present = [l for l in mods.splitlines() if l.startswith("PRESENT")]
    rep("PASS" if not present else "WARN", "earlier mods", "none" if not present else "; ".join(present))
    env = read(os.path.join(cmd, "dio_env.txt")) or ""
    if "LD_PRELOAD=" in env:
        line = next(l for l in env.splitlines() if "LD_PRELOAD=" in l)
        rep("WARN", "dio_manager LD_PRELOAD", line.strip())
    elif not any(re.match(r"^\s*\d+\s", l) for l in env.splitlines()):
        rep("INFO", "dio_manager LD_PRELOAD", "dio_manager was not running (no phone connected); "
            "smartphone_integrator.json is the evidence instead")
    else:
        rep("PASS", "dio_manager LD_PRELOAD", "not set")

    # 7. later steps
    p = find_file(files, "traceConfig.properties")
    rep("INFO" if p else "WARN", "traceConfig.properties",
        "collected (needed for wheel zoom / dial layout later)" if p else "not found")
    df = read(os.path.join(cmd, "df.txt")) or ""
    line = next((l for l in df.splitlines() if "/mnt/app" in l), "")
    rep("INFO", "free space /mnt/app", line.strip() or "see cmd/df.txt")
    nav = read(os.path.join(cmd, "slog_nav.txt")) or ""
    rep("INFO", "NavStateOfOperation to 5", f"{nav.count('NavStateOfOperation to 5')} line(s) in sloginfo")

    width = max(len(n) for _, n, _ in results)
    for status, name, detail in results:
        print(f"{status:5} {name:<{width}}  {detail}")
    fails = sum(1 for s, _, _ in results if s == "FAIL")
    warns = sum(1 for s, _, _ in results if s == "WARN")
    print(f"\n{fails} FAIL, {warns} WARN")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
