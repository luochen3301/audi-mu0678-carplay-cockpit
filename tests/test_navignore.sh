#!/bin/bash
# Simulated-unit tests for mod/navignore/navignore.sh (dual navigation installer).
# usage: bash tests/test_navignore.sh <workdir>
# Uses the real build tree (build/sd-navignore/mod) and the real lsd.sh and
# lsd.jxe collected from the car. The script under test runs in dash.
set -u
W=$(cd "$(dirname "$0")/.." && pwd)
BUILD=${BUILD_DIR:-$W/build/sd-navignore/mod}
C=$W/car-data/navignore_collect/001/files
# Private inputs (OEM files from your own car, build output): skip, do not fail, when absent.
need() { for f in "$@"; do [ -e "$f" ] || { echo "SKIP: $(basename "$0") needs $f (see car-data/README.md, inputs/README.md)"; exit 77; }; done; }
need "$BUILD/navignore/navignore.sh" "$C/ifs__lsd.jxe" "$C/mnt__app__eso__hmi__lsd__lsd.sh" \
     "$C/net__rcc__mnt__efs-persist__SWDL__CachedTrain.txt" "$W/inputs/navignore/navignore_audi.jar"
T=${1:?workdir}
PASS=0; FAIL=0
ok()   { echo "    PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "    FAIL  $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

L=mnt/app/eso/hmi/lsd
STOCK_JARS="AppDevelopment.jar DevelopmentStubEvo.jar RemoteHMI-Libs-Ext.jar diag.jar lang_data.zip locale.zip xEventRecorder.jar xEventRecorderEvo.jar xTcpKeyPanel.jar xTcpLog.jar"
mkdir -p "$T"
CACHE=$T/jxe-cache.jxe        # the 58 MB image is moved between roots, not copied
[ -f "$CACHE" ] || cp "$C/ifs__lsd.jxe" "$CACHE"
chmod u+w "$CACHE"
R=; CARD=

park_jxe() { if [ -n "$R" ] && [ -f "$R/ifs/lsd.jxe" ] && [ ! -f "$CACHE" ]; then mv "$R/ifs/lsd.jxe" "$CACHE"; fi; }
make_env() {
    park_jxe
    rm -rf "$T/root" "$T/card" "$T/calls.log"
    R=$T/root; CARD=$T/card
    mkdir -p "$R/bin" "$R/$L/jars" "$R/ifs/jre/bin" "$R/net/rcc/usr/bin" "$R/net/rcc/mnt/efs-persist/SWDL" "$R/tmp"
    touch "$R/THIS_IS_A_TEST_ROOT"
    cp "$C/net__rcc__mnt__efs-persist__SWDL__CachedTrain.txt" "$R/net/rcc/mnt/efs-persist/SWDL/CachedTrain.txt"
    cp "$C/mnt__app__eso__hmi__lsd__lsd.sh" "$R/$L/lsd.sh"
    mv "$CACHE" "$R/ifs/lsd.jxe"
    for j in $STOCK_JARS; do echo "stock $j" > "$R/$L/jars/$j"; done
    printf '#!/bin/sh\nexec sha1sum "$@"\n' > "$R/net/rcc/usr/bin/sha1sum"; chmod +x "$R/net/rcc/usr/bin/sha1sum"
    for c in mount on sloginfo df; do
        printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\n' "$c" "$T" > "$R/bin/$c"; chmod +x "$R/bin/$c"
    done
    # pidin ar: the HMI command line, with the jar on it if PIDIN_HAS_JAR exists
    cat > "$R/bin/pidin" <<EOF
#!/bin/sh
echo "pidin \$*" >> "$T/calls.log"
if [ -f "$T/PIDIN_HAS_JAR" ]; then X=:/mnt/app/eso/hmi/lsd/jars/NavActiveIgnore.jar; else X=; fi
echo " 1323061 /ifs/jre/bin/j9 -Xbootclasspath::/mnt/app/eso/hmi/lsd/jars/diag.jar\$X:/ifs/lsd.jxe -jxe:/ifs/lsd.jxe"
EOF
    chmod +x "$R/bin/pidin"
    rm -f "$T/PIDIN_HAS_JAR"
    mkdir -p "$CARD"; cp -r "$BUILD" "$CARD/mod"
}
set_action() { printf '%s\n' "$1" > "$CARD/mod/navignore/ACTION"; }
RC=0
SUT_SHELL=${SUT_SHELL:-dash}     # shell for command.sh and everything it execs as "sh"
mkdir -p "$T/shim"; printf '#!/bin/sh
exec %s "$@"
' "$SUT_SHELL" > "$T/shim/sh"; chmod +x "$T/shim/sh"
run() { PATH="$T/shim:$PATH" NAVIGNORE_TEST_ROOT="$R" "$SUT_SHELL" "$CARD/mod/command.sh" > "$T/out.txt" 2>&1; RC=$?; }
out() { grep -q -- "$1" "$T/out.txt"; }
snap() { (cd "$R" && find . -type f ! -path './bin/*' ! -path './tmp/*' -print0 | sort -z | xargs -0 sha256sum); }
reboots() { [ -f "$T/calls.log" ] || { echo 0; return; }; grep -c 'on -f rcc /usr/apps/mib2_ioc_flash reboot' "$T/calls.log"; }
JARSHA=$(sha256sum "$BUILD/navignore/payload/NavActiveIgnore.jar" | cut -d' ' -f1)
jar_ours() { [ -f "$R/$L/jars/NavActiveIgnore.jar" ] && [ "$(sha256sum "$R/$L/jars/NavActiveIgnore.jar" | cut -d' ' -f1)" = "$JARSHA" ]; }
no_jar() { [ ! -e "$R/$L/jars/NavActiveIgnore.jar" ]; }
no_tmp() { [ ! -e "$R/$L/NavActiveIgnore.jar.new" ]; }
lsd_stock() { cmp -s "$R/$L/lsd.sh" "$C/mnt__app__eso__hmi__lsd__lsd.sh"; }
showfail() { [ $FAIL -gt $1 ] && sed 's/^/        | /' "$T/out.txt" | tail -25; }

# boot_cp: run a copy of the unit's lsd.sh (paths moved into the fake root) and
# print the -Xbootclasspath it would hand to j9.
boot_cp() {
    S=$T/lsd-sim.sh
    { echo 'info() { :; }'
      cat "$R/$L/lsd.sh"; } \
      | sed -e "s|^export MOUNT_DIR=.*|export MOUNT_DIR=$R|" \
            -e "s|^export MOUNT_APP_DIR=.*|export MOUNT_APP_DIR=$R/mnt/app|" > "$S"
    printf '#!/bin/sh\nfor a in "$@"; do case $a in -Xbootclasspath:*) echo "$a" ;; esac; done > "%s/j9args.txt"\n' "$T" > "$R/bin/on"
    chmod +x "$R/bin/on"
    : > "$T/j9args.txt"
    ( cd "$T" && PATH="$R/bin:$PATH" RUN_MODE=normal bash "$S" > "$T/lsd-sim.out" 2>&1; wait )
    sleep 1
    cat "$T/j9args.txt"
    printf '#!/bin/sh\necho "on $*" >> "%s/calls.log"\n' "$T" > "$R/bin/on"; chmod +x "$R/bin/on"
}

echo "== static checks"
for f in navignore/navignore.sh navignore/collect.sh command.sh; do
    check "no CR in $f" '[ "$(tr -cd "\r" < "$BUILD/$f" | wc -c)" -eq 0 ]'
    check "dash -n $f" 'dash -n "$BUILD/$f"'
done
check "card RUN is navignore" '[ "$(cat "$BUILD/RUN")" = navignore ]'
check "card ACTION is install" '[ "$(cat "$BUILD/navignore/ACTION")" = install ]'
check "stock lsd.sh has the jar loop M.I.B. checks for" 'grep -q "## Find and append jar files" "$C/mnt__app__eso__hmi__lsd__lsd.sh"'
check "jar on card = M.I.B. 3.6.0 navignore_audi.jar" 'cmp -s "$BUILD/navignore/payload/NavActiveIgnore.jar" "$W/inputs/navignore/navignore_audi.jar"'

echo "== N1 install on the stock unit"
make_env; set_action install
BEFORE=$(snap); BOOT_BEFORE=$(boot_cp); run; AFTER=$(snap); BOOT_AFTER=$(boot_cp)
check "exit 0" '[ $RC -eq 0 ]'; showfail 0
check "INSTALL COMPLETE" 'out "INSTALL COMPLETE."'
check "jar in place, byte-identical" 'jar_ours'
check "no temporary file left" 'no_tmp'
check "lsd.sh unchanged" 'lsd_stock'
check "exactly one file added, nothing else changed" '[ "$(diff <(echo "$BEFORE") <(echo "$AFTER") | grep -c "^[<>]")" -eq 1 ] && diff <(echo "$BEFORE") <(echo "$AFTER") | grep -q "^> .*jars/NavActiveIgnore.jar$"'
check "one reboot requested" '[ "$(reboots)" -eq 1 ]'
check "/mnt/app remounted rw then ro" 'grep -q "^mount -uw $R/mnt/app" "$T/calls.log" && grep -q "^mount -ur $R/mnt/app" "$T/calls.log"'
check "checked the HMI image" 'out "lsd.jxe    identical to the analysed image  ok"'
check "boot sim (before): jar not on the class path" '[ -n "$BOOT_BEFORE" ] && ! echo "$BOOT_BEFORE" | grep -q NavActiveIgnore'
check "boot sim (after): jar on the class path" 'echo "$BOOT_AFTER" | grep -q "jars/NavActiveIgnore.jar"'
check "boot sim (after): jar comes before lsd.jxe" 'case $BOOT_AFTER in *NavActiveIgnore.jar*:$R/ifs/lsd.jxe) true ;; *) false ;; esac'
check "boot sim: nothing else on the class path changed" '[ "$(echo "$BOOT_AFTER" | tr ":" "\n" | grep -v NavActiveIgnore | sort)" = "$(echo "$BOOT_BEFORE" | tr ":" "\n" | sort)" ]'
check "log folder 001-install" '[ -f "$CARD/navignore_logs/001-install/log.txt" ]'

echo "== N2 run again with ACTION=install: already installed -> logs only"
BEFORE=$(snap); : > "$T/calls.log"; touch "$T/PIDIN_HAS_JAR"; run; AFTER=$(snap)
check "exit 0" '[ $RC -eq 0 ]'
check "says already installed" 'out "Already installed and verified"'
check "unit unchanged" '[ "$BEFORE" = "$AFTER" ]'
check "no reboot" '[ "$(reboots)" -eq 0 ]'
check "never remounted /mnt/app rw" '! grep -q "^mount -uw $R/mnt/app" "$T/calls.log"'
check "reports jar ours" 'out "NavActiveIgnore.jar:   ours"'
check "reports HMI has it loaded" 'out "loaded by running HMI: yes"'
check "log folder 002-install" '[ -d "$CARD/navignore_logs/002-install" ]'

echo "== N3 uninstall after install: back to exactly stock"
make_env; STOCK=$(snap); set_action install; run
set_action uninstall; : > "$T/calls.log"; run; AFTER=$(snap)
check "exit 0" '[ $RC -eq 0 ]'; showfail 0
check "UNINSTALL COMPLETE" 'out "UNINSTALL COMPLETE."'
check "unit byte-identical to stock" '[ "$STOCK" = "$AFTER" ]'
check "one reboot" '[ "$(reboots)" -eq 1 ]'
check "boot sim: jar no longer on the class path" '! boot_cp | grep -q NavActiveIgnore'

echo "== N4 uninstall when not installed"
make_env; set_action uninstall; BEFORE=$(snap); run; AFTER=$(snap)
check "exit 0, nothing to remove" '[ $RC -eq 0 ] && out "nothing to remove"'
check "unit unchanged, no reboot" '[ "$BEFORE" = "$AFTER" ] && [ "$(reboots)" -eq 0 ]'

refuse() {   # refuse <title> <text expected on screen>
    WHY=$2
    check "$1: exit != 0" '[ $RC -ne 0 ]'
    check "$1: says why" 'out "$WHY"'
    check "$1: says nothing was changed" 'out "Nothing on the unit was changed."'
    check "$1: unit unchanged" '[ "$BEFORE" = "$AFTER" ]'
    check "$1: no reboot, never remounted" '[ "$(reboots)" -eq 0 ] && ! grep -q "^mount -uw $R/mnt/app" "$T/calls.log"'
}

echo "== N5 refuses: other firmware train"
make_env; set_action install; echo MHI2_ER_AUG22_P4000 > "$R/net/rcc/mnt/efs-persist/SWDL/CachedTrain.txt"
BEFORE=$(snap); run; AFTER=$(snap); refuse "train" "is not MHI2_ER_AUG22_P3241"

echo "== N6 refuses: lsd.sh changed (e.g. a line appended by another tool)"
make_env; set_action install
echo 'BOOTCLASSPATH="$BOOTCLASSPATH -Xbootclasspath/p:$BASE_DIR/lsd/jars/NavActiveIgnore.jar"' >> "$R/$L/lsd.sh"
BEFORE=$(snap); run; AFTER=$(snap); refuse "lsd.sh" "lsd.sh is not the stock file"

echo "== N7 refuses: HMI image differs by one byte"
make_env; set_action install
printf 'X' | dd of="$R/ifs/lsd.jxe" bs=1 seek=30000000 conv=notrunc 2>/dev/null
BEFORE=$(snap); run; AFTER=$(snap); refuse "lsd.jxe" "is not the HMI image the jar was checked against"
cp "$C/ifs__lsd.jxe" "$R/ifs/lsd.jxe"     # repair the cached image

echo "== N8 refuses: a different NavActiveIgnore.jar already installed; uninstall leaves it"
make_env; set_action install; echo "someone else's jar" > "$R/$L/jars/NavActiveIgnore.jar"
BEFORE=$(snap); run; AFTER=$(snap); refuse "foreign jar" "a different NavActiveIgnore.jar is already installed"
set_action uninstall; run; AFTER=$(snap)
check "uninstall leaves the foreign jar" '[ "$BEFORE" = "$AFTER" ] && out "left in place (not ours)" && [ "$(reboots)" -eq 0 ]'

echo "== N9 refuses: unknown extra jar in jars/"
make_env; set_action install; echo x > "$R/$L/jars/g24fullscreen.jar"
BEFORE=$(snap); run; AFTER=$(snap); refuse "extra jar" "g24fullscreen.jar"
make_env; set_action install; echo x > "$R/$L/jars/.hidden.jar"
BEFORE=$(snap); run; AFTER=$(snap); refuse "hidden jar" ".hidden.jar"

echo "== N10 refuses: jar on the card damaged"
make_env; set_action install; printf 'Z' >> "$CARD/mod/navignore/payload/NavActiveIgnore.jar"
BEFORE=$(snap); run; AFTER=$(snap); refuse "card jar" "sha1 self-test failed"

echo "== N11 refuses: EXPECTED missing on the card"
make_env; set_action install; rm "$CARD/mod/navignore/EXPECTED"
BEFORE=$(snap); run; AFTER=$(snap); refuse "EXPECTED" "EXPECTED or STOCK_JARS missing"

echo "== N12 no sha1 tool: install refuses, logs still work"
make_env; set_action install; rm "$R/net/rcc/usr/bin/sha1sum"
BEFORE=$(snap); run; AFTER=$(snap); refuse "no sha1" "sha1 self-test failed"
set_action logs; run
check "logs run without sha1" '[ $RC -eq 0 ] && out "hashes skipped"'

echo "== N13 failure: copy to the unit fails"
make_env; set_action install
printf '#!/bin/sh\ncase "$2" in *NavActiveIgnore.jar.new) exit 1 ;; esac\nexec /usr/bin/cp "$@"\n' > "$R/bin/cp"; chmod +x "$R/bin/cp"
BEFORE=$(snap); run; AFTER=$(snap)
check "exit != 0" '[ $RC -ne 0 ]'
check "says the HMI is as stock" 'out "is NOT in place: the HMI is as stock"'
check "no jar, no temp file, unit unchanged" 'no_jar && no_tmp && [ "$BEFORE" = "$AFTER" ]'
check "no reboot" '[ "$(reboots)" -eq 0 ]'

echo "== N14 failure: the copy on the unit is corrupt"
make_env; set_action install
printf '#!/bin/sh\ncase "$2" in *NavActiveIgnore.jar.new) head -c 100 "$1" > "$2"; exit 0 ;; esac\nexec /usr/bin/cp "$@"\n' > "$R/bin/cp"; chmod +x "$R/bin/cp"
BEFORE=$(snap); run; AFTER=$(snap)
check "exit != 0 and says it did not verify" '[ $RC -ne 0 ] && out "did not verify"'
check "corrupt copy never reached jars/" 'no_jar && no_tmp && [ "$BEFORE" = "$AFTER" ]'
check "no reboot" '[ "$(reboots)" -eq 0 ]'

echo "== N15 failure: the move into jars/ fails"
make_env; set_action install
printf '#!/bin/sh\nexit 1\n' > "$R/bin/mv"; chmod +x "$R/bin/mv"
BEFORE=$(snap); run; AFTER=$(snap)
check "exit != 0" '[ $RC -ne 0 ] && out "could not move the jar"'
check "no jar, temp cleaned, unit unchanged" 'no_jar && no_tmp && [ "$BEFORE" = "$AFTER" ]'
check "no reboot" '[ "$(reboots)" -eq 0 ]'

echo "== N16 a temp file left by an earlier failed run is cleaned up"
make_env; set_action install; echo junk > "$R/$L/NavActiveIgnore.jar.new"
run
check "install completes" '[ $RC -eq 0 ] && jar_ours && no_tmp'

echo "== N17 /mnt/app cannot be made writable"
make_env; set_action install; mkdir "$R/$L/.navignore_write_test"
BEFORE=$(snap); run; AFTER=$(snap); F0=$FAIL
check "exit != 0" '[ $RC -ne 0 ] && out "could not be made writable"'
check "says nothing was changed" 'out "Nothing on the unit was changed."'
check "unit unchanged, no reboot" 'no_jar && [ "$BEFORE" = "$AFTER" ] && [ "$(reboots)" -eq 0 ]'; showfail $F0

echo "== N18 logs: read-only, copies the CarPlay map logs"
make_env; set_action install; run; set_action logs
echo "1.0 [altscreen111] r25-autostart: spawn pid=1" > "$R/tmp/altscreen111.log"
echo "2.0 [altscreen111] GEN2 FLIGHT MODES_CHANGED parsed rc=0 seq=1 screen=1 turns=1" >> "$R/tmp/altscreen111.log"
echo "3.0 [altscreen111] NATIVE-B rx 150 frames in 5000 ms = 30 fps" >> "$R/tmp/altscreen111.log"
echo "STATS" > "$R/tmp/vc_render.log"
BEFORE=$(snap); : > "$T/calls.log"; run; AFTER=$(snap)
O=$(ls -d "$CARD"/navignore_logs/*-logs | tail -1)
check "exit 0" '[ $RC -eq 0 ]'
check "unit unchanged, no reboot, no remount" '[ "$BEFORE" = "$AFTER" ] && [ "$(reboots)" -eq 0 ] && ! grep -q "^mount -uw $R/mnt/app" "$T/calls.log"'
check "CarPlay map logs copied" '[ -f "$O/tmp/altscreen111.log" ] && [ -f "$O/tmp/vc_render.log" ]'
check "route seen counted" 'out "route active seen:     1 time(s)"'
check "fps shown" 'out "30 fps"'
check "HMI not yet restarted -> loaded: no" 'out "loaded by running HMI: no"'

echo "== N19 ACTION missing or garbage -> logs; CRLF in RUN and ACTION"
make_env; rm "$CARD/mod/navignore/ACTION"; BEFORE=$(snap); run; AFTER=$(snap)
check "missing ACTION -> logs, unit unchanged" '[ $RC -eq 0 ] && out "action: logs" && [ "$BEFORE" = "$AFTER" ]'
make_env; set_action "format-everything"; BEFORE=$(snap); run; AFTER=$(snap)
check "garbage ACTION -> logs, unit unchanged" '[ $RC -eq 0 ] && out "action: logs" && [ "$BEFORE" = "$AFTER" ]'
make_env; printf 'navignore\r\n' > "$CARD/mod/RUN"; printf 'install\r\n' > "$CARD/mod/navignore/ACTION"; run
check "CRLF RUN + ACTION still install" '[ $RC -eq 0 ] && jar_ours'

echo "== N20 M.I.B.'s own 'Remove dual navigation' undoes our install"
make_env; STOCK=$(snap); set_action install; run
rm -rf "$R/$L/jars/NavActiveIgnore.jar"    # what installjava -navignoreoff does on Audi
check "unit back to stock after M.I.B. remove" '[ "$STOCK" = "$(snap)" ]'
set_action install; run
check "and our installer can install again" '[ $RC -eq 0 ] && jar_ours'

echo "== N21 the altscreen package on the same card is untouched by RUN"
make_env; rm "$CARD/mod/RUN"; printf '#!/bin/sh\necho ALTSCREEN-RAN\n' > "$CARD/mod/custom.sh"; run
check "no RUN -> altscreen custom.sh" 'out ALTSCREEN-RAN && no_jar'

park_jxe
echo
echo "RESULT: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
