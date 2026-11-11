#!/bin/bash
# Simulated-unit tests for mod/custom.sh (altscreen-mu0678 installer).
# usage: bash tests/run_tests.sh <workdir for the simulation>
# Runs the real build/sd/mod tree against a fake unit filesystem built from the
# files collected on the car. The script under test runs in dash (strict POSIX).
set -u
W=$(cd "$(dirname "$0")/.." && pwd)
BUILD=${BUILD_DIR:-$W/build/sd/mod}
C=$W/car-data/altscreen_collect/001/files
# Private inputs (OEM files from your own car, build output): skip, do not fail, when absent.
need() { for f in "$@"; do [ -e "$f" ] || { echo "SKIP: $(basename "$0") needs $f (see car-data/README.md, inputs/README.md)"; exit 77; }; done; }
need "$BUILD/altscreen/FILES" "$C/mnt__app__eso__lib__libairplay.so" \
     "$C/mnt__system__etc__eso__production__smartphone_integrator.json" "$C/net__rcc__mnt__efs-persist__SWDL__CachedTrain.txt"
T=${1:?workdir}
PIN_STOCK=6e7968e0279a2548c50285923e5bbc66f8775ad490c2394e430318d570faeed9
PIN_PATCHED=67e05b2faa15c82dc3c48937aeb6120bb0db4408084815be2f1aff096ce46a95
PASS=0; FAIL=0

ok()   { echo "    PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "    FAIL  $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

R=; CARD=
make_env() {
    rm -rf "$T"; mkdir -p "$T"
    R=$T/root; CARD=$T/card
    mkdir -p "$R/testbin" "$R/mnt/app/eso/lib" "$R/mnt/app/root/bin-target" "$R/mnt/app/root/lib-target" \
             "$R/mnt/system/etc/eso/production" "$R/net/rcc/mnt/efs-persist/SWDL" "$R/tmp" "$R/mnt/ota/system/core"
    touch "$R/THIS_IS_A_TEST_ROOT"
    cp "$C/mnt__app__eso__lib__libairplay.so" "$R/mnt/app/eso/lib/libairplay.so"
    cp "$C/mnt__system__etc__eso__production__smartphone_integrator.json" "$R/mnt/system/etc/eso/production/smartphone_integrator.json"
    cp "$C/net__rcc__mnt__efs-persist__SWDL__CachedTrain.txt" "$R/net/rcc/mnt/efs-persist/SWDL/CachedTrain.txt"
    for c in mount pidin sloginfo netstat pfctl on; do
        printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\n' "$c" "$T" > "$R/testbin/$c"
        chmod +x "$R/testbin/$c"
    done
    mkdir -p "$CARD"; cp -r "$BUILD" "$CARD/mod"
}
set_action() { printf '%s' "$1" > "$CARD/mod/altscreen/ACTION"; }
RC=0
run() {   # run [sh]: run the installer (dash by default)
    sh_=${1:-dash}
    if [ "$sh_" = viacommand ]; then
        ALTSCREEN_TEST_ROOT="$R" sh "$CARD/mod/command.sh" > "$T/out.txt" 2>&1; RC=$?
    else
        ALTSCREEN_TEST_ROOT="$R" dash "$CARD/mod/custom.sh" > "$T/out.txt" 2>&1; RC=$?
    fi
}
snap() { (cd "$R" && find . -type f ! -path './tmp/*' ! -path './testbin/*' -print0 | sort -z | xargs -0 sha256sum); }
reboots() { grep -c 'on -f rcc /usr/apps/mib2_ioc_flash reboot' "$T/calls.log" 2>/dev/null || true; }
tgt() { sha256sum "$R/mnt/system/etc/eso/production/smartphone_integrator.json" | cut -d' ' -f1; }
installed_all() {
    while read -r h src dst mode; do
        case $h in ''|\#*) continue ;; esac
        [ "$(sha1sum "$R$dst" 2>/dev/null | cut -d' ' -f1)" = "$h" ] || return 1
    done < "$BUILD/altscreen/FILES"
}
none_installed() {
    while read -r h src dst mode; do
        case $h in ''|\#*) continue ;; esac
        [ -e "$R$dst" ] && return 1
    done < "$BUILD/altscreen/FILES"
    return 0
}
no_new_files() { [ -z "$(cd "$R" && find . -name '*.new')" ]; }
showfail() { [ $FAIL -gt $1 ] && { echo "    --- output ---"; sed 's/^/    | /' "$T/out.txt"; }; }

refused_unchanged() {  # common assertions for "must refuse and change nothing"
    check "refused (exit != 0)" '[ $RC -ne 0 ]'
    check "says nothing was changed" 'grep -q "Nothing on the unit was changed" "$T/out.txt"'
    check "unit files byte-identical" '[ "$(snap)" = "$BEFORE" ]'
    check "no reboot" '[ "$(reboots)" = 0 ]'
}

echo "== S1 fresh install"
make_env; set_action install; ORIG=$(snap); run; f=$FAIL
check "exit 0" '[ $RC -eq 0 ]'
check "INSTALL COMPLETE shown" 'grep -q "INSTALL COMPLETE" "$T/out.txt"'
check "config = author's patched file" '[ "$(tgt)" = $PIN_PATCHED ]'
check "all 10 files installed and verified" 'installed_all'
check "stock backup on unit = stock" '[ "$(sha256sum "$R/mnt/app/root/mibr-carplay111-backup/smartphone_integrator.json.stock" | cut -d" " -f1)" = $PIN_STOCK ]'
check "install record written" '[ -f "$R/mnt/app/root/altscreen-mu0678.installed" ]'
check "no .new leftovers" 'no_new_files'
check "reboot requested once" '[ "$(reboots)" = 1 ]'
check "log written to card" 'grep -q "INSTALL COMPLETE" "$CARD/altscreen_logs/001-install/log.txt"'
check "copy of old config kept on card" '[ "$(sha256sum "$CARD/altscreen_logs/001-install/smartphone_integrator.json.before" | cut -d" " -f1)" = $PIN_STOCK ]'
check "libairplay untouched" 'cmp -s "$R/mnt/app/eso/lib/libairplay.so" "$C/mnt__app__eso__lib__libairplay.so"'
showfail $f

echo "== S2 install again on an installed unit"
BEFORE=$(snap); run; f=$FAIL
check "exit 0" '[ $RC -eq 0 ]'
check "says already installed" 'grep -q "Already installed and verified" "$T/out.txt"'
check "unit files byte-identical" '[ "$(snap)" = "$BEFORE" ]'
check "no second reboot" '[ "$(reboots)" = 1 ]'
showfail $f

echo "== S3 logs on an installed unit"
printf 'x r25-autostart: spawn pid=1 h=542\nx NATIVE-B FORWARD MODE ON: frames\nx NATIVE-B rx 150 frames in 5000 ms = 30 fps; 900 KB\nx GEN2 TEARDOWN entry request=NULL reason=-6753\nx r25-autostart: spawn pid=2 h=542\n' > "$R/tmp/altscreen111.log"
printf '1.0 [vc_render] STATS 150 frames in 5000 ms = 30 fps; decode avg 900 us\n' > "$R/tmp/vc_render.log"
head -c 100000 /dev/urandom > "$R/tmp/mibr-nativeb.h264"
set_action logs; BEFORE=$(snap); run; f=$FAIL
check "exit 0" '[ $RC -eq 0 ]'
check "unit files byte-identical" '[ "$(snap)" = "$BEFORE" ]'
check "hook log copied" 'cmp -s "$R/tmp/altscreen111.log" "$CARD/altscreen_logs/003-logs/tmp/altscreen111.log"'
check "h264 capture skipped" '[ ! -e "$CARD/altscreen_logs/003-logs/tmp/mibr-nativeb.h264" ]'
check "config reported as ours" 'grep -q "CarPlay config:   ours" "$T/out.txt"'
check "sessions counted (2)" 'grep -q "sessions started: 2" "$T/out.txt"'
check "fps line shown" 'grep -q "last rx: rx 150 frames" "$T/out.txt"'
check "no reboot" '[ "$(reboots)" = 1 ]'
showfail $f

echo "== S4 uninstall"
set_action uninstall; run; f=$FAIL
check "exit 0" '[ $RC -eq 0 ]'
check "UNINSTALL COMPLETE shown" 'grep -q "UNINSTALL COMPLETE" "$T/out.txt"'
check "config byte-identical to the car's original" 'cmp -s "$R/mnt/system/etc/eso/production/smartphone_integrator.json" "$C/mnt__system__etc__eso__production__smartphone_integrator.json"'
check "all installed files removed" 'none_installed'
check "install record removed" '[ ! -e "$R/mnt/app/root/altscreen-mu0678.installed" ]'
check "stock backup kept" '[ -f "$R/mnt/app/root/mibr-carplay111-backup/smartphone_integrator.json.stock" ]'
check "reboot requested" '[ "$(reboots)" = 2 ]'
check "no .new leftovers" 'no_new_files'
showfail $f

echo "== S5 uninstall again"
BEFORE=$(snap); run; f=$FAIL
check "exit 0" '[ $RC -eq 0 ]'
check "says already stock" 'grep -q "already stock" "$T/out.txt"'
check "unit files byte-identical" '[ "$(snap)" = "$BEFORE" ]'
check "no reboot" '[ "$(reboots)" = 2 ]'
showfail $f

echo "== S6 refuse: different libairplay.so"
make_env; set_action install; printf 'X' | dd of="$R/mnt/app/eso/lib/libairplay.so" bs=1 seek=1000 conv=notrunc 2>/dev/null
BEFORE=$(snap); run; f=$FAIL; refused_unchanged
check "names libairplay" 'grep -q "libairplay.so is not the analysed build" "$T/out.txt"'; showfail $f

echo "== S7 refuse: different firmware train"
make_env; set_action install; printf 'MHI2_ER_AUG22_K3344\r\nabc\n' > "$R/net/rcc/mnt/efs-persist/SWDL/CachedTrain.txt"
BEFORE=$(snap); run; f=$FAIL; refused_unchanged
check "names the train" 'grep -q "MHI2_ER_AUG22_K3344" "$T/out.txt"'; showfail $f

echo "== S8 refuse: config modified by something else"
make_env; set_action install; echo '# other mod' >> "$R/mnt/system/etc/eso/production/smartphone_integrator.json"
BEFORE=$(snap); run; f=$FAIL; refused_unchanged
check "says another mod" 'grep -q "neither stock nor ours" "$T/out.txt"'; showfail $f

echo "== S9 refuse: damaged hook on the card"
make_env; set_action install; printf 'X' | dd of="$CARD/mod/altscreen/payload/libmibr_carplay111.so" bs=1 seek=5000 conv=notrunc 2>/dev/null
BEFORE=$(snap); run; f=$FAIL; refused_unchanged
check "says card damaged" 'grep -q "card BAD  libmibr_carplay111.so" "$T/out.txt"'; showfail $f

echo "== S10 refuse: damaged stock config on the card (sha1 self-test)"
make_env; set_action install; echo ' ' >> "$CARD/mod/altscreen/payload/smartphone_integrator.json.stock"
BEFORE=$(snap); run; f=$FAIL; refused_unchanged
check "says self-test failed" 'grep -q "sha1 self-test failed" "$T/out.txt"'; showfail $f

echo "== S11 refuse: unknown file already at /mnt/app/root/vc_render"
make_env; set_action install; echo "someone else" > "$R/mnt/app/root/vc_render"
BEFORE=$(snap); run; f=$FAIL; refused_unchanged
check "names the file" 'grep -q "unknown file is already at /mnt/app/root/vc_render" "$T/out.txt"'; showfail $f

echo "== S12 refuse: no working sha1sum at all"
make_env; set_action install
BEFORE=$(snap); ALTSCREEN_TEST_SHA1_LIST=/nonexistent/sha1sum ALTSCREEN_TEST_ROOT="$R" dash "$CARD/mod/custom.sh" > "$T/out.txt" 2>&1; RC=$?; f=$FAIL
refused_unchanged; showfail $f

echo "== S13 complete an earlier interrupted install (files there, config stock)"
make_env; set_action install
mkdir -p "$R/mnt/app/root/mibr-carplay111-backup"
cp "$CARD/mod/altscreen/payload/vc_render" "$R/mnt/app/root/vc_render"
cp "$CARD/mod/altscreen/payload/root/mibr-carplay111-size" "$R/mnt/app/root/"
echo partial > "$R/mnt/app/eso/lib/libmibr_carplay111.so.new"
run; f=$FAIL
check "exit 0" '[ $RC -eq 0 ]'
check "config = patched" '[ "$(tgt)" = $PIN_PATCHED ]'
check "all files installed" 'installed_all'
check "stale .new cleaned" 'no_new_files'
check "existing correct files reported" 'grep -q "ok, already there  /mnt/app/root/vc_render" "$T/out.txt"'
showfail $f

echo "== S14 uninstall when the unit backup is gone (uses the card copy)"
rm -f "$R/mnt/app/root/mibr-carplay111-backup/smartphone_integrator.json.stock"
set_action uninstall; run; f=$FAIL
check "exit 0" '[ $RC -eq 0 ]'
check "used card copy" 'grep -q "using the stock copy on the card" "$T/out.txt"'
check "config byte-identical to original" 'cmp -s "$R/mnt/system/etc/eso/production/smartphone_integrator.json" "$C/mnt__system__etc__eso__production__smartphone_integrator.json"'
check "files removed" 'none_installed'
showfail $f

echo "== S15 ACTION file with Windows line ending"
make_env; printf 'install\r\n' > "$CARD/mod/altscreen/ACTION"; run; f=$FAIL
check "installed" '[ $RC -eq 0 ] && [ "$(tgt)" = $PIN_PATCHED ]'; showfail $f

echo "== S16 no ACTION file -> logs only"
make_env; rm -f "$CARD/mod/altscreen/ACTION"; BEFORE=$(snap); run; f=$FAIL
check "exit 0" '[ $RC -eq 0 ]'
check "ran logs" 'grep -q "action: logs" "$T/out.txt"'
check "unit files byte-identical" '[ "$(snap)" = "$BEFORE" ]'
check "no reboot" '[ "$(reboots)" = 0 ]'; showfail $f

echo "== S17 uninstall refuses an unknown config"
make_env; set_action uninstall; echo '# other mod' >> "$R/mnt/system/etc/eso/production/smartphone_integrator.json"
BEFORE=$(snap); run; f=$FAIL; refused_unchanged; showfail $f

echo "== S18 config rename fails -> files added, config untouched, honest message"
make_env; set_action install
cat > "$R/testbin/mv" <<'EOF'
#!/bin/sh
for a in "$@"; do last=$a; done
case $last in *smartphone_integrator.json) exit 1 ;; esac
exec /usr/bin/mv "$@"
EOF
chmod +x "$R/testbin/mv"; run; f=$FAIL
check "refused" '[ $RC -ne 0 ]'
check "config still stock" '[ "$(tgt)" = $PIN_STOCK ]'
check "message: config untouched" 'grep -q "CarPlay config is now: stock" "$T/out.txt"'
check "no .new left" 'no_new_files'
check "no reboot" '[ "$(reboots)" = 0 ]'
rm -f "$R/testbin/mv"; set_action uninstall; run
check "uninstall then cleans up" '[ $RC -eq 0 ] && none_installed && [ "$(tgt)" = $PIN_STOCK ]'
showfail $f

echo "== S19 config corrupted during rename -> stock put back automatically"
make_env; set_action install
cat > "$R/testbin/mv" <<EOF
#!/bin/sh
for a in "\$@"; do last=\$a; done
if [ ! -f "$T/corrupted.flag" ]; then case \$last in *smartphone_integrator.json)
  touch "$T/corrupted.flag"; /usr/bin/mv "\$@" && echo junk >> "\$last"; exit 0 ;; esac; fi
exec /usr/bin/mv "\$@"
EOF
chmod +x "$R/testbin/mv"; run; f=$FAIL
check "refused" '[ $RC -ne 0 ]'
check "stock config restored" '[ "$(tgt)" = $PIN_STOCK ]'
check "message says config is stock" 'grep -q "CarPlay config is now: stock" "$T/out.txt"'
check "no reboot" '[ "$(reboots)" = 0 ]'
rm -f "$R/testbin/mv"; showfail $f

echo "== S20 install through command.sh (the path M.I.B. uses)"
make_env; set_action install; run viacommand; f=$FAIL
check "installed via command.sh" '[ $RC -eq 0 ] && [ "$(tgt)" = $PIN_PATCHED ] && installed_all'; showfail $f

# ---------------------------------------------------------------- v1 -> v1.1
BUILD_V1=${BUILD_V1_DIR:-$W/build/sd-v1/mod}
HOOK_DST=/mnt/app/eso/lib/libmibr_carplay111.so
use_card() { rm -rf "${CARD:?}/mod"; cp -r "$1" "$CARD/mod"; }
install_v1() {   # fresh unit with the real v1 package installed by the v1 installer
    make_env; use_card "$BUILD_V1"; set_action install; run
    [ $RC -eq 0 ] && grep -q "INSTALL COMPLETE" "$T/out.txt"
}
sys_mounts() { grep -c "mount -uw .*/mnt/system" "$T/calls.log" 2>/dev/null || true; }

if [ -d "$BUILD_V1" ]; then
echo "== S21 upgrade v1 -> v1.1 (the car's real situation)"
check "v1 installed first" 'install_v1'
V1HOOK=$(sha1sum "$R$HOOK_DST" | cut -d' ' -f1)
use_card "$BUILD"; set_action install
B_MOUNTS=$(sys_mounts); B_REBOOTS=$(reboots); run; f=$FAIL
check "exit 0" '[ $RC -eq 0 ]'
check "announced upgrade of the hook" 'grep -q "older version, will be upgraded  $HOOK_DST" "$T/out.txt"'
check "all v1.1 files installed" 'installed_all'
check "hook changed from v1" '[ "$(sha1sum "$R$HOOK_DST" | cut -d" " -f1)" != "$V1HOOK" ]'
check "CarPlay config still ours, not rewritten" '[ "$(tgt)" = $PIN_PATCHED ] && [ "$(sys_mounts)" = "$B_MOUNTS" ]'
check "stock backup unchanged" '[ "$(sha256sum "$R/mnt/app/root/mibr-carplay111-backup/smartphone_integrator.json.stock" | cut -d" " -f1)" = $PIN_STOCK ]'
check "one reboot requested" '[ "$(reboots)" = $((B_REBOOTS+1)) ]'
check "no .new leftovers" 'no_new_files'
showfail $f

echo "== S22 uninstall after the upgrade"
set_action uninstall; run; f=$FAIL
check "exit 0" '[ $RC -eq 0 ]'
check "config byte-identical to the car original" 'cmp -s "$R/mnt/system/etc/eso/production/smartphone_integrator.json" "$C/mnt__system__etc__eso__production__smartphone_integrator.json"'
check "all files removed" 'none_installed'
showfail $f

echo "== S23 uninstall straight from v1 with the v1.1 card"
check "v1 installed first" 'install_v1'
use_card "$BUILD"; set_action uninstall; run; f=$FAIL
check "exit 0" '[ $RC -eq 0 ]'
check "old hook removed as older version" 'grep -q "removed (older version)  $HOOK_DST" "$T/out.txt"'
check "config byte-identical to the car original" 'cmp -s "$R/mnt/system/etc/eso/production/smartphone_integrator.json" "$C/mnt__system__etc__eso__production__smartphone_integrator.json"'
check "all files removed" 'none_installed && [ ! -e "$R$HOOK_DST" ]'
showfail $f

echo "== S24 refuse: unknown hook (neither v1 nor v1.1) at the hook path"
make_env; set_action install; echo "someone else's library" > "$R$HOOK_DST"
BEFORE=$(snap); run; f=$FAIL; refused_unchanged
check "names the hook path" 'grep -q "unknown file is already at $HOOK_DST" "$T/out.txt"'; showfail $f

echo "== S25 uninstall leaves an unknown hook alone"
set_action uninstall; run; f=$FAIL
check "exit 0" '[ $RC -eq 0 ]'
check "unknown hook left in place" '[ -e "$R$HOOK_DST" ] && grep -q "left in place (not ours)  $HOOK_DST" "$T/out.txt"'
showfail $f
else
echo "!! $BUILD_V1 missing - v1 -> v1.1 upgrade tests SKIPPED (set REQUIRE_V1=1 to make this a failure)"
[ "${REQUIRE_V1:-0}" = 1 ] && FAIL=$((FAIL+1))
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
