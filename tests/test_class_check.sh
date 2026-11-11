#!/bin/bash
# Proves tools/jxe/check_override.py catches incompatible classes.
# usage: bash tests/test_class_check.sh <workdir>
# Needs the collected lsd.jxe (car-data/navignore_collect/001) and a JDK (javac).
set -u
W=$(cd "$(dirname "$0")/.." && pwd)
T=${1:?workdir}
JXE=$W/car-data/navignore_collect/001/files/ifs__lsd.jxe
JAR=$W/inputs/navignore/navignore_audi.jar
CHK=$W/tools/jxe/check_override.py
if [ -z "${JAVAC:-}" ]; then JAVAC=$(command -v javac 2>/dev/null || true); fi
[ -n "$JAVAC" ] || JAVAC="/c/Program Files/Java/jdk-17/bin/javac.exe"
# Private inputs (OEM files from your own car, build output): skip, do not fail, when absent.
need() { for f in "$@"; do [ -e "$f" ] || { echo "SKIP: $(basename "$0") needs $f (see car-data/README.md, inputs/README.md)"; exit 77; }; done; }
need "$JXE" "$JAR" "$JAVAC"
winpath() { if command -v cygpath > /dev/null 2>&1; then cygpath -w "$1"; else echo "$1"; fi; }
PASS=0; FAIL=0
ok()  { echo "    PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "    FAIL  $1"; FAIL=$((FAIL+1)); }

rm -rf "$T"; mkdir -p "$T"
( cd "$T" && unzip -q -o "$JXE" rom.classes )
ROM=$T/rom.classes

run_chk() { python -I "$CHK" "$ROM" "$1" > "$T/report.txt" 2>&1; }

# control: the real M.I.B. jar must pass
mkdir -p "$T/real" && ( cd "$T/real" && unzip -q -o "$JAR" )
rm -rf "$T/real/META-INF"
if run_chk "$T/real"; then ok "real M.I.B. jar passes"; else bad "real M.I.B. jar passes"; cat "$T/report.txt"; fi

# mutants of org.dsi.ifc.carplay.AppState; each must FAIL with the given reason
mutant() {   # mutant <name> <expected text in report> <java body of class AppState>
    d=$T/m_$1; mkdir -p "$d/src/org/dsi/ifc/carplay" "$d/out"
    { echo "package org.dsi.ifc.carplay;"; echo "$3"; } > "$d/src/org/dsi/ifc/carplay/AppState.java"
    "$JAVAC" -nowarn --release 8 -d "$(winpath "$d/out")" "$(winpath "$d/src/org/dsi/ifc/carplay/AppState.java")" > "$d/javac.txt" 2>&1 \
        || { bad "$1 (javac failed)"; cat "$d/javac.txt"; return; }
    if run_chk "$d/out"; then bad "$1 must be rejected"; return; fi
    if grep -q -- "$2" "$T/report.txt"; then ok "$1 rejected: $2"; else bad "$1 rejected for the wrong reason"; cat "$T/report.txt"; fi
}

BASE_FIELDS='public int appStateID; public int owner; public int speechMode;'
CTORS='public AppState(){} public AppState(int a,int b,int c){appStateID=a;owner=b;speechMode=c;}'
GETS='public int getAppStateID(){return 0;} public int getOwner(){return 0;} public int getSpeechMode(){return speechMode;}'
TOS='public String toString(){return "AppState";}'

mutant missing_method   "getSpeechMode ()I missing" \
  "public class AppState { $BASE_FIELDS $CTORS public int getAppStateID(){return 0;} public int getOwner(){return 0;} $TOS }"
mutant renamed_field    "field owner I missing" \
  "public class AppState { public int appStateID; public int ownerX; public int speechMode; public AppState(){} public AppState(int a,int b,int c){} $GETS $TOS }"
mutant changed_sig      "getOwner ()I missing" \
  "public class AppState { $BASE_FIELDS $CTORS public int getAppStateID(){return 0;} public long getOwner(){return 0;} public int getSpeechMode(){return 0;} $TOS }"
mutant static_field     "static-ness differs" \
  "public class AppState { public int appStateID; public int owner; public static int speechMode; $CTORS $GETS $TOS }"
mutant narrowed_access  "access narrowed" \
  "public class AppState { $BASE_FIELDS $CTORS private int getAppStateID(){return 0;} public int getOwner(){return 0;} public int getSpeechMode(){return 0;} $TOS }"
mutant wrong_super      "superclass stock java/lang/Object" \
  "public class AppState extends java.util.Vector { $BASE_FIELDS $CTORS $GETS $TOS }"
mutant missing_ctor     "<init> (III)V missing" \
  "public class AppState { $BASE_FIELDS public AppState(){} $GETS $TOS }"
mutant bad_reference    "does not resolve" \
  "public class AppState { $BASE_FIELDS $CTORS $GETS public String toString(){ return String.valueOf(new StringBuffer().reverse().codePointAt(0)); } }"

# a class that does not exist in the HMI at all
d=$T/m_unknown; mkdir -p "$d/src/org/dsi/ifc/carplay" "$d/out"
echo 'package org.dsi.ifc.carplay; public class AppStateZZ { }' > "$d/src/org/dsi/ifc/carplay/AppStateZZ.java"
"$JAVAC" -nowarn --release 8 -d "$(winpath "$d/out")" "$(winpath "$d/src/org/dsi/ifc/carplay/AppStateZZ.java")" > /dev/null 2>&1
if run_chk "$d/out"; then bad "unknown class must be rejected"
elif grep -q "no stock class" "$T/report.txt"; then ok "unknown class rejected"; else bad "unknown class: wrong reason"; fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
