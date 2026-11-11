#!/usr/bin/env python3
"""Assemble the SD-card files for the dual-navigation (NavActiveIgnore) step.

usage: python build_navignore_package.py --jar J --lsdsh S --jxe X --listing LS
                                         --src-sd DIR --out DIR [--action install]

Inputs are checked against the SHA-256 pinned below and the build stops on any
mismatch. Before anything is written the jar's classes are checked, member by
member, against this unit's stock classes in lsd.jxe (tools/jxe/check_override.py);
the build stops if that check fails.

Output: <out>/mod/{command.sh,RUN,navignore/...} and <out>/SHA256SUMS.
"""
import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile

PINS = {
    # M.I.B. V3.6.0 mod/java/navignore_audi.jar (installed as NavActiveIgnore.jar)
    "jar": "c962834de249459209f7c1aa4210f6b4179e563bad84e39e1312e4848278fd46",
    # stock files of MHI2_ER_AUG22_P3241 / MU0678, collected read-only (navignore_collect/001, 2026-11-11)
    "lsdsh": "a21649b32c615366fe36a193fb9a9d82637f8deb346a853c0cefd9fdcec32f2d",
    "jxe": "12c4102c11a051732e142000d0a2a84dc1c908b82d2ea87f96d3236ec1426151",
}
TRAIN = "MHI2_ER_AUG22_P3241"
# /mnt/app/eso/hmi/lsd/jars as delivered (navignore_collect/001/cmd/ls_lsd.txt)
STOCK_JARS = ["AppDevelopment.jar", "DevelopmentStubEvo.jar", "RemoteHMI-Libs-Ext.jar",
              "diag.jar", "lang_data.zip", "locale.zip", "xEventRecorder.jar",
              "xEventRecorderEvo.jar", "xTcpKeyPanel.jar", "xTcpLog.jar"]
JAR_LOOP = b"## Find and append jar files"
HERE = os.path.dirname(os.path.abspath(__file__))


def sha256(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()


def sha1(p):
    return hashlib.sha1(open(p, "rb").read()).hexdigest()


def write_text(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="\n", encoding="ascii") as f:
        f.write(text)


def listed_jars(listing):
    """File names under the '/mnt/app/eso/hmi/lsd/jars:' block of ls -la output."""
    names, inside = [], False
    for line in open(listing, encoding="latin-1"):
        line = line.rstrip("\n")
        if line.endswith("/jars:"):
            inside = True
            continue
        if inside:
            if not line.strip() or line.endswith(":") or line.startswith("("):
                break
            parts = line.split()
            if len(parts) >= 9 and parts[0].startswith("-"):
                names.append(parts[-1])
    return sorted(names)


def main():
    ap = argparse.ArgumentParser()
    for k in ("jar", "lsdsh", "jxe", "listing", "src_sd", "out"):
        ap.add_argument("--" + k.replace("_", "-"), dest=k, required=True)
    ap.add_argument("--action", default="install", choices=["install", "uninstall", "logs"])
    a = ap.parse_args()

    for k in ("jar", "lsdsh", "jxe"):
        got = sha256(getattr(a, k))
        if got != PINS[k]:
            sys.exit(f"REFUSING: {k} sha256 {got} != pinned {PINS[k]}")
        print(f"pin ok  {k:<6} {got[:16]}...")

    if JAR_LOOP not in open(a.lsdsh, "rb").read():
        sys.exit("REFUSING: lsd.sh has no jar loop - the jar would never be loaded")
    if listed_jars(a.listing) != sorted(STOCK_JARS):
        sys.exit(f"REFUSING: jars listing {listed_jars(a.listing)} != STOCK_JARS")
    print("lsd.sh  has the stock jar loop; jars folder matches STOCK_JARS")

    # member-by-member check of the jar's classes against this unit's lsd.jxe
    with tempfile.TemporaryDirectory() as td:
        with zipfile.ZipFile(a.jxe) as z:
            z.extract("rom.classes", td)
        cls = os.path.join(td, "classes")
        with zipfile.ZipFile(a.jar) as z:
            for n in z.namelist():
                if n.endswith(".class"):
                    z.extract(n, cls)
        r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "jxe", "check_override.py"),
                            os.path.join(td, "rom.classes"), cls], capture_output=True, text=True)
        report = r.stdout
    if r.returncode != 0 or "ALL PASS" not in report:
        print(report)
        sys.exit("REFUSING: the jar's classes do not match this unit's HMI classes")
    print("class check: ALL PASS (" + str(report.count("RESULT: PASS")) + " classes)")

    for name in ("command.sh", "navignore/navignore.sh", "navignore/collect.sh"):
        if b"\r" in open(os.path.join(a.src_sd, name), "rb").read():
            sys.exit(f"REFUSING: {name} has CR line endings")

    out_mod = os.path.join(a.out, "mod")
    if os.path.exists(a.out):
        shutil.rmtree(a.out)
    pkg = os.path.join(out_mod, "navignore")
    os.makedirs(os.path.join(pkg, "payload"))
    for name in ("command.sh", "navignore/navignore.sh", "navignore/collect.sh"):
        shutil.copyfile(os.path.join(a.src_sd, name), os.path.join(out_mod, name))
    shutil.copyfile(a.jar, os.path.join(pkg, "payload", "NavActiveIgnore.jar"))
    write_text(os.path.join(out_mod, "RUN"), "navignore\n")
    write_text(os.path.join(pkg, "ACTION"), a.action + "\n")
    write_text(os.path.join(pkg, "EXPECTED"),
               f"EXP_TRAIN {TRAIN}\n"
               f"EXP_LSDSH {sha1(a.lsdsh)}\n"
               f"EXP_JXE {sha1(a.jxe)}\n"
               f"EXP_JAR {sha1(a.jar)}\n")
    write_text(os.path.join(pkg, "STOCK_JARS"),
               "# /mnt/app/eso/hmi/lsd/jars as delivered\n" + "\n".join(STOCK_JARS) + "\n")
    write_text(os.path.join(pkg, "VERSION"), "navignore-mu0678-v1 (M.I.B. 3.6.0 navignore_audi.jar)\n")
    write_text(os.path.join(pkg, "CLASS_CHECK.txt"), report)

    sums = []
    for d, _, files in os.walk(out_mod):
        for f in files:
            p = os.path.join(d, f)
            sums.append(f"{sha256(p)}  {os.path.relpath(p, a.out).replace(os.sep, '/')}")
    write_text(os.path.join(a.out, "SHA256SUMS"), "\n".join(sorted(sums, key=lambda s: s[66:])) + "\n")
    print(f"built {len(sums)} files into {out_mod} (action={a.action})")


if __name__ == "__main__":
    main()
