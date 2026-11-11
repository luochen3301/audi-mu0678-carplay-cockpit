#!/bin/bash
# Simulated-unit tests for mod/zoom/collect.sh (read-only) via mod/command.sh.
# usage: bash tests/test_zoom_collect.sh <workdir>
set -u
W=$(cd "$(dirname "$0")/.." && pwd)
SRC=${SRC_DIR:-$W/src-sd}
T=${1:?workdir}
PASS=0; FAIL=0
ok()   { echo "    PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "    FAIL  $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

L=mnt/app/eso/hmi/lsd
FILES="$L/DSITracer.jar $L/bundles_dsitracer_enabled.properties $L/bundles_dsitracer_disabled.properties $L/bundles.properties $L/bundles_headless.properties $L/traceConfig.properties $L/lsd.sh mnt/app/eso/bin/runHMI.sh"
SUT_SHELL=${SUT_SHELL:-dash}
mkdir -p "$T/shim"; printf '#!/bin/sh\nexec %s "$@"\n' "$SUT_SHELL" > "$T/shim/sh"; chmod +x "$T/shim/sh"
make_env() {
    rm -rf "$T/root" "$T/card" "$T/calls.log"
    R=$T/root; CARD=$T/card
    mkdir -p "$R/bin" "$R/$L/jars" "$R/mnt/app/eso/bin" "$R/net/rcc/usr/bin" "$R/net/rcc/mnt/efs-persist/SWDL"
    touch "$R/THIS_IS_A_TEST_ROOT"
    echo MHI2_ER_AUG22_P3241 > "$R/net/rcc/mnt/efs-persist/SWDL/CachedTrain.txt"
    for f in $FILES; do head -c $((1000 + RANDOM)) /dev/urandom > "$R/$f"; done
    head -c 1161684 /dev/urandom > "$R/$L/DSITracer.jar"
    printf '#!/bin/sh\nexec sha1sum "$@"\n' > "$R/net/rcc/usr/bin/sha1sum"; chmod +x "$R/net/rcc/usr/bin/sha1sum"
    for c in mount pidin sloginfo on netstat; do
        printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\necho "%s output"\n' "$c" "$T" "$c" > "$R/bin/$c"; chmod +x "$R/bin/$c"
    done
    mkdir -p "$CARD/mod/zoom" "$CARD/mod/navignore"
    cp "$SRC/command.sh" "$CARD/mod/command.sh"
    cp "$SRC/zoom/collect.sh" "$CARD/mod/zoom/collect.sh"
    printf 'zoom-collect\r\n' > "$CARD/mod/RUN"
}
snap() { (cd "$R" && find . -type f ! -path './bin/*' -print0 | sort -z | xargs -0 sha256sum); }
RC=0
run() { PATH="$T/shim:$PATH" ZOOM_TEST_ROOT="$R" "$SUT_SHELL" "$CARD/mod/command.sh" > "$T/out.txt" 2>&1; RC=$?; }
out() { grep -q -- "$1" "$T/out.txt"; }
O1() { echo "$CARD/zoom_logs/001-collect"; }
flat() { echo "$1" | sed 's|/|__|g'; }

for f in "$SRC/command.sh" "$SRC/zoom/collect.sh"; do
    check "no CR in ${f##*/}" '[ "$(tr -cd "\r" < "$f" | wc -c)" -eq 0 ]'
    check "dash -n ${f##*/}" 'dash -n "$f"'
    check "bash -n ${f##*/}" 'bash -n "$f"'
done

echo "== Z1 collect (RUN with CRLF)"
make_env; BEFORE=$(snap); run; AFTER=$(snap)
check "exit 0" '[ $RC -eq 0 ]'
check "unit files byte-identical" '[ "$BEFORE" = "$AFTER" ]'
allcopied=1
for f in $FILES; do cmp -s "$R/$f" "$(O1)/files/$(flat "$f")" || allcopied=0; done
check "all 8 files copied exactly" '[ $allcopied -eq 1 ]'
check "every copy hashed on unit and card" '[ "$(grep -c " unit " "$(O1)/sha1.txt")" -eq 8 ] && [ "$(grep -c " card " "$(O1)/sha1.txt")" -eq 8 ]'
check "missing .orig recorded as absent" 'grep -q "^absent /$L/traceConfig.properties.orig" "$(O1)/sha1.txt"'
check "says all verified" 'out "copies:         all verified"'
check "markers reported absent" 'out "dsitracer_activated: not present" && out "development_activated: not present"'
check "DSITracer.jar size shown" 'out "DSITracer.jar:  1161684 bytes"'
check "says nothing changed" 'out "Nothing on the unit was changed."'
check "never remounted" '! grep -q "^mount -uw" "$T/calls.log"'
check "netstat, pidin, sloginfo ran" 'grep -q "^netstat -an" "$T/calls.log" && grep -q "^pidin ar" "$T/calls.log" && grep -q "^sloginfo" "$T/calls.log"'

echo "== Z2 next run numbering"
run
check "002-collect" '[ -d "$CARD/zoom_logs/002-collect" ]'

echo "== Z3 a bad copy is reported"
make_env
printf '#!/bin/sh\ncase "$1" in *DSITracer.jar) head -c 10 "$1" > "$2" ;; *) exec /usr/bin/cp "$@" ;; esac\n' > "$R/bin/cp"; chmod +x "$R/bin/cp"
run
check "1 NOT verified" 'out "copies:         1 NOT verified"'

echo "== Z4 markers present are reported, unit untouched"
make_env; : > "$R/$L/dsitracer_activated"; : > "$R/$L/development_activated"; echo orig > "$R/$L/traceConfig.properties.orig"
BEFORE=$(snap); run; AFTER=$(snap)
check "both PRESENT" 'out "dsitracer_activated: PRESENT" && out "development_activated: PRESENT"'
check ".orig collected" 'cmp -s "$R/$L/traceConfig.properties.orig" "$(O1)/files/$(flat $L/traceConfig.properties.orig)"'
check "unit unchanged" '[ "$BEFORE" = "$AFTER" ]'

echo "== Z5 dispatcher: zoom selected but zoom.sh missing"
make_env; echo zoom > "$CARD/mod/RUN"; run
check "exit != 0, nothing run" '[ $RC -ne 0 ] && out "not found" && [ ! -d "$CARD/zoom_logs" ]'

echo "== Z6 no sha1 tool"
make_env; rm "$R/net/rcc/usr/bin/sha1sum"; run
check "exit 0, all NOT verified, files still copied" '[ $RC -eq 0 ] && out "8 NOT verified" && cmp -s "$R/$L/DSITracer.jar" "$(O1)/files/$(flat $L/DSITracer.jar)"'

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
