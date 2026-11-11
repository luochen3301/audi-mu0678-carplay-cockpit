#!/usr/bin/env python3
"""Assemble the SD-card mod/ folder for the altscreen-mu0678 installer.

usage: python build_install_package.py --hook H --vcrender V --stock S --patched P
                                       --libairplay L --src-sd DIR --out DIR [--action install]

Every input is checked against the SHA-256 pinned below; the build stops on
any mismatch. Output: <out>/mod/{command.sh,custom.sh,altscreen/...} plus
<out>/SHA256SUMS listing every file written (for checking the card later).
"""
import argparse
import hashlib
import os
import shutil
import sys

PINS = {
    # r60 hook + tools/make_hook_v11.py (3 bytes in the embedded r25 script)
    "hook": "282d8722916785d3375b54327b60c7be179e5671800f704999384b0368b155f7",
    # joeyQuery/MHI2-altScreen artifacts/mu0678/SHA256SUMS (build r60) - installed by v1
    "upgrade_from": "2ce451a472ea98e09971db34f75099dcfd20c0ce5d554df9f9f69755cc5f9ddb",
    "vcrender": "a28ca6975e21105c721f673aa95926d7fb3c22789ac0d196bb8978afb1c35198",
    # mu0678/firmware.md; identical on the MU0678 test unit (collected 2026-11-10)
    "stock": "6e7968e0279a2548c50285923e5bbc66f8775ad490c2394e430318d570faeed9",
    "libairplay": "a3ab0fe0ac20a712f7f240c1abd852a38faf78f2673880342d0eb24a6d8c29be",
    # make_patched_carplay_json.py defaults; = EXP_NEWJSON of the author's installer
    "patched": "67e05b2faa15c82dc3c48937aeb6120bb0db4408084815be2f1aff096ce46a95",
}
TRAIN = "MHI2_ER_AUG22_P3241"

# Final values, docs/safe-areas.md (owner-confirmed 2026-10-02): x, y, w, h
SAFE_AREAS = {
    "mibr-carplay111-safearea-idle.conf": (360, 65, 720, 367),          # small dials, idle
    "mibr-carplay111-safearea.conf": (468, 85, 840, 332),               # small dials, route
    "mibr-carplay111-safearea-narrow-idle.conf": (550, 87, 340, 330),   # big dials, idle
    "mibr-carplay111-safearea-narrow-route.conf": (550, 87, 340, 330),  # big dials, route
    "mibr-carplay111-safearea-full-idle.conf": (114, 88, 350, 296),     # third layout (untested)
    "mibr-carplay111-safearea-full-route.conf": (114, 88, 350, 296),
}
STARTUP_CANVAS = (1440, 455)   # ALTSCREEN111_WIDTH/HEIGHT in the patched config


def sha256(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()


def sha1(p):
    return hashlib.sha1(open(p, "rb").read()).hexdigest()


def write_text(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="\n", encoding="ascii") as f:
        f.write(text)


def main():
    ap = argparse.ArgumentParser()
    for k in ("hook", "upgrade_from", "vcrender", "stock", "patched", "libairplay", "src_sd", "out"):
        ap.add_argument("--" + k.replace("_", "-"), dest=k, required=True)
    ap.add_argument("--action", default="install", choices=["install", "uninstall", "logs"])
    a = ap.parse_args()

    for k in ("hook", "upgrade_from", "vcrender", "stock", "patched", "libairplay"):
        got = sha256(getattr(a, k))
        if got != PINS[k]:
            sys.exit(f"REFUSING: {k} sha256 {got} != pinned {PINS[k]}")
        print(f"pin ok  {k:<10} {got[:16]}...")

    # the safe areas must pass the hook's own range check against the startup canvas
    W, H = STARTUP_CANVAS
    for name, (x, y, w, h) in SAFE_AREAS.items():
        if not (0 <= x < W and 0 <= y < H and w >= 1 and h >= 1 and x + w <= W and y + h <= H):
            sys.exit(f"REFUSING: {name} {x},{y},{w},{h} outside the {W}x{H} startup canvas")

    out_mod = os.path.join(a.out, "mod")
    if os.path.exists(a.out):
        shutil.rmtree(a.out)
    pkg = os.path.join(out_mod, "altscreen")
    pay = os.path.join(pkg, "payload")
    os.makedirs(os.path.join(pay, "root"))

    for name in ("custom.sh", "command.sh"):
        data = open(os.path.join(a.src_sd, name), "rb").read()
        if b"\r" in data:
            sys.exit(f"REFUSING: {name} has CR line endings")
        open(os.path.join(out_mod, name), "wb").write(data)

    shutil.copyfile(a.hook, os.path.join(pay, "libmibr_carplay111.so"))
    shutil.copyfile(a.vcrender, os.path.join(pay, "vc_render"))
    shutil.copyfile(a.stock, os.path.join(pay, "smartphone_integrator.json.stock"))
    shutil.copyfile(a.patched, os.path.join(pay, "smartphone_integrator.json.patched"))
    write_text(os.path.join(pay, "root", "mibr-carplay111-native-b"), "")
    write_text(os.path.join(pay, "root", "mibr-carplay111-size"), "1440 542\n")
    for name, (x, y, w, h) in SAFE_AREAS.items():
        write_text(os.path.join(pay, "root", name), f"x={x}\ny={y}\nw={w}\nh={h}\n")

    # payload path, unit path, mode - small config files first, the hook last
    entries = [("root/" + n, "/mnt/app/root/" + n, "644") for n in
               ["mibr-carplay111-size"] + list(SAFE_AREAS) + ["mibr-carplay111-native-b"]]
    entries += [("vc_render", "/mnt/app/root/vc_render", "755"),
                ("libmibr_carplay111.so", "/mnt/app/eso/lib/libmibr_carplay111.so", "755")]
    lines = ["# sha1 payload-path unit-path mode"]
    for src, dst, mode in entries:
        lines.append(f"{sha1(os.path.join(pay, src))} {src} {dst} {mode}")
    write_text(os.path.join(pkg, "FILES"), "\n".join(lines) + "\n")

    write_text(os.path.join(pkg, "EXPECTED"),
               f"EXP_TRAIN {TRAIN}\n"
               f"EXP_LIBAIRPLAY {sha1(a.libairplay)}\n"
               f"EXP_STOCK {sha1(a.stock)}\n"
               f"EXP_PATCHED {sha1(a.patched)}\n")
    # older versions of our files that install may upgrade and uninstall may remove
    write_text(os.path.join(pkg, "UPGRADE"),
               "# sha1 unit-path  (older versions of our files)\n"
               f"{sha1(a.upgrade_from)} /mnt/app/eso/lib/libmibr_carplay111.so\n")
    write_text(os.path.join(pkg, "ACTION"), a.action + "\n")
    write_text(os.path.join(pkg, "VERSION"), "altscreen-mu0678-v1.1 (hook r60 + r25 re-acquire fix)\n")

    sums = []
    for d, _, files in os.walk(out_mod):
        for f in files:
            p = os.path.join(d, f)
            sums.append(f"{sha256(p)}  {os.path.relpath(p, a.out).replace(os.sep, '/')}")
    write_text(os.path.join(a.out, "SHA256SUMS"), "\n".join(sorted(sums, key=lambda s: s[66:])) + "\n")
    print(f"built {len(sums)} files into {out_mod} (action={a.action})")


if __name__ == "__main__":
    main()
