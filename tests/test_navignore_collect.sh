#!/bin/bash
# Simulated-unit tests for mod/command.sh (dispatcher) and
# mod/navignore/collect.sh (read-only collector).
# usage: bash tests/test_navignore_collect.sh <workdir>
# The scripts under test run in dash (strict POSIX), like the other tests.
set -u
W=$(cd "$(dirname "$0")/.." && pwd)
SRC=${SRC_DIR:-$W/src-sd}
T=${1:?workdir}
PASS=0; FAIL=0
ok()   { echo "    PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "    FAIL  $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

L=mnt/app/eso/hmi/lsd
make_env() {
    rm -rf "$T"; mkdir -p "$T"
    R=$T/root; CARD=$T/card
    mkdir -p "$R/bin" "$R/$L/jars" "$R/ifs" "$R/net/rcc/usr/bin" "$R/net/rcc/mnt/efs-persist/SWDL" \
             "$R/etc/boot" "$R/etc/eso/production"
    touch "$R/THIS_IS_A_TEST_ROOT"
    echo MHI2_ER_AUG22_P3241 > "$R/net/rcc/mnt/efs-persist/SWDL/CachedTrain.txt"
    echo '"MIB2_AUDI_HIGH EUROPE"' > "$R/$L/version.txt"
    printf '#!/bin/ksh\nBASE_DIR=/mnt/app/eso/hmi\nJ9=/ifs/jre/bin/j9\n$J9 $BOOTCLASSPATH -jxe:/ifs/lsd.jxe\n' > "$R/$L/lsd.sh"
    head -c 3000000 /dev/urandom > "$R/ifs/lsd.jxe"
    echo jar > "$R/$L/jars/diag.jar"
    echo 'sh /mnt/app/eso/hmi/lsd/lsd.sh' > "$R/etc/boot/startup.sh"
    printf '#!/bin/sh\nexec sha1sum "$@"\n' > "$R/net/rcc/usr/bin/sha1sum"; chmod +x "$R/net/rcc/usr/bin/sha1sum"
    for c in mount pidin sloginfo on df; do
        printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\necho "%s output"\n' "$c" "$T" "$c" > "$R/bin/$c"
        chmod +x "$R/bin/$c"
    done
    mkdir -p "$CARD/mod/navignore"
    cp "$SRC/command.sh" "$CARD/mod/command.sh"
    printf '#!/bin/sh\necho ALTSCREEN-INSTALLER-RAN\n' > "$CARD/mod/custom.sh"
    cp "$SRC/navignore/collect.sh" "$CARD/mod/navignore/collect.sh"
}
snap() { (cd "$R" && find . -type f ! -path './bin/*' -print0 | sort -z | xargs -0 sha256sum); }
RC=0
SUT_SHELL=${SUT_SHELL:-dash}     # shell for command.sh and everything it execs as "sh"
mkdir -p "$T/shim"; printf '#!/bin/sh
exec %s "$@"
' "$SUT_SHELL" > "$T/shim/sh"; chmod +x "$T/shim/sh"
run() { PATH="$T/shim:$PATH" NAVIGNORE_TEST_ROOT="$R" "$SUT_SHELL" "$CARD/mod/command.sh" > "$T/out.txt" 2>&1; RC=$?; }
out() { grep -q -- "$1" "$T/out.txt"; }
O1() { echo "$CARD/navignore_logs/001-collect"; }

for f in "$SRC/command.sh" "$SRC/navignore/collect.sh"; do
    check "no CR in ${f##*/}" '[ "$(tr -cd "\r" < "$f" | wc -c)" -eq 0 ]'
    check "dash -n ${f##*/}" 'dash -n "$f"'
    check "bash -n ${f##*/}" 'bash -n "$f"'
done

echo "== C1 dispatcher: no RUN file runs the altscreen installer (unchanged behaviour)"
make_env; run
check "custom.sh ran" 'out ALTSCREEN-INSTALLER-RAN'
check "collector did not run" '[ ! -d "$CARD/navignore_logs" ]'

echo "== C2 dispatcher: RUN=altscreen / empty RUN"
make_env; echo altscreen > "$CARD/mod/RUN"; run
check "altscreen -> custom.sh" 'out ALTSCREEN-INSTALLER-RAN'
make_env; : > "$CARD/mod/RUN"; run
check "empty -> custom.sh" 'out ALTSCREEN-INSTALLER-RAN'

echo "== C3 dispatcher: unknown word runs nothing"
make_env; echo navignorex > "$CARD/mod/RUN"; run
check "exit != 0" '[ $RC -ne 0 ]'
check "says nothing was run" 'out "Nothing was run"'
check "custom.sh not run" '! out ALTSCREEN-INSTALLER-RAN'
check "collector not run" '[ ! -d "$CARD/navignore_logs" ]'
make_env; echo 'rm -rf /' > "$CARD/mod/RUN"; run
check "word 'rm' refused" '[ $RC -ne 0 ] && out "Nothing was run"'

echo "== C4 dispatcher: navignore selected but its script missing"
make_env; echo navignore > "$CARD/mod/RUN"; run
check "exit != 0 and nothing run" '[ $RC -ne 0 ] && out "not found" && ! out ALTSCREEN-INSTALLER-RAN'

echo "== C5 collect on a stock unit (RUN written with CRLF, as Windows Notepad would)"
make_env; printf 'navignore-collect\r\n' > "$CARD/mod/RUN"
BEFORE=$(snap); run; AFTER=$(snap)
check "exit 0" '[ $RC -eq 0 ]'
check "unit files byte-identical" '[ "$BEFORE" = "$AFTER" ]'
check "lsd.sh copied exactly" 'cmp -s "$R/$L/lsd.sh" "$(O1)/files/mnt__app__eso__hmi__lsd__lsd.sh"'
check "lsd.jxe copied exactly" 'cmp -s "$R/ifs/lsd.jxe" "$(O1)/files/ifs__lsd.jxe"'
check "startup.sh copied" '[ -f "$(O1)/files/etc__boot__startup.sh" ]'
check "train recorded" 'out "MHI2_ER_AUG22_P3241"'
H=$(sha1sum "$R/$L/lsd.sh" | cut -d" " -f1)
check "lsd.sh sha1 on screen" 'out "sha1 $H"'
check "lsd.sh copy verified" 'out "lsd.sh copy:    verified"'
check "lsd.jxe copy verified" 'out "lsd.jxe copy:   verified"'
HJ=$(sha1sum "$R/ifs/lsd.jxe" | cut -d" " -f1)
check "sha1.txt has the unit jxe sum" 'grep -q "^$HJ unit /ifs/lsd.jxe" "$(O1)/sha1.txt"'
check "says stock lsd.sh" 'out "no bootclasspath/p line (stock)"'
check "says jar not present" 'out "NavActiveIgnore.jar: not present"'
check "says nothing changed" 'out "Nothing on the unit was changed."'
check "never remounted anything" '! grep -q "^mount -uw" "$T/calls.log"'
check "listings recorded" 'grep -q "diag.jar" "$(O1)/cmd/ls_lsd.txt"'
check "who starts lsd.sh recorded" 'grep -q "startup.sh" "$(O1)/cmd/who_starts_lsd.txt"'
check "pidin/sloginfo ran" 'grep -q "pidin ar" "$T/calls.log" && grep -q "^sloginfo" "$T/calls.log"'

echo "== C6 second run gets the next folder number"
run
check "002-collect created" '[ -d "$CARD/navignore_logs/002-collect" ] && [ $RC -eq 0 ]'
mkdir "$CARD/navignore_logs/009-collect"; run
check "after 009 comes 010 (no octal trap)" '[ -d "$CARD/navignore_logs/010-collect" ]'

echo "== C7 earlier patch present (M.I.B. jar + patched lsd.sh + backup)"
make_env; echo navignore-collect > "$CARD/mod/RUN"
cp "$R/$L/lsd.sh" "$R/$L/lsd.sh.bu"
printf 'BOOTCLASSPATH="$BOOTCLASSPATH -Xbootclasspath/p:$BASE_DIR/lsd/jars/NavActiveIgnore.jar"\n' >> "$R/$L/lsd.sh"
echo jar > "$R/$L/jars/NavActiveIgnore.jar"
BEFORE=$(snap); run; AFTER=$(snap)
check "unit files byte-identical" '[ "$BEFORE" = "$AFTER" ]'
check "reports jar present" 'out "NavActiveIgnore.jar: ALREADY PRESENT"'
check "reports bootclasspath/p line" 'out "already has a bootclasspath/p line"'
check "backup copy collected" 'cmp -s "$R/$L/lsd.sh.bu" "$(O1)/files/mnt__app__eso__hmi__lsd__lsd.sh.bu"'

echo "== C8 a bad copy of lsd.jxe is reported, not hidden"
make_env; echo navignore-collect > "$CARD/mod/RUN"
printf '#!/bin/sh\ncase "$1" in *lsd.jxe) head -c 1000 "$1" > "$2" ;; *) exec /usr/bin/cp "$@" ;; esac\n' > "$R/bin/cp"; chmod +x "$R/bin/cp"
run
check "lsd.jxe NOT verified" 'out "lsd.jxe copy:   NOT verified"'
check "lsd.sh still verified" 'out "lsd.sh copy:    verified"'

echo "== C9 no sha1 tool on the unit"
make_env; echo navignore-collect > "$CARD/mod/RUN"; rm "$R/net/rcc/usr/bin/sha1sum"
run
check "exit 0" '[ $RC -eq 0 ]'
check "both NOT verified" 'out "lsd.sh copy:    NOT verified" && out "lsd.jxe copy:   NOT verified"'
check "files still copied" 'cmp -s "$R/ifs/lsd.jxe" "$(O1)/files/ifs__lsd.jxe"'

echo "== C10 collector placed in the wrong folder refuses"
make_env; mkdir -p "$CARD/other"; cp "$SRC/navignore/collect.sh" "$CARD/other/collect.sh"
NAVIGNORE_TEST_ROOT="$R" dash "$CARD/other/collect.sh" > "$T/out.txt" 2>&1; RC=$?
check "exit != 0" '[ $RC -ne 0 ] && out "must be in"'

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
