#!/bin/sh
# navignore-mu0678 v1 - install / uninstall / log export for "dual navigation"
# (the M.I.B. NavActiveIgnore jar) on an Audi MHI2 MU0678 unit running
# MHI2_ER_AUG22_P3241. With it, starting route guidance in CarPlay no longer
# switches the Virtual Cockpit to the "navigation on phone" compass page, so
# the CarPlay map (altscreen) stays visible.
#
# Run from M.I.B.:  GEM -> m.i.b -> Advanced Settings -> Run individual script
# with the word "navignore" in mod/RUN (mod/command.sh hands over to this file).
#
# What it does is the first word of mod/navignore/ACTION:
#   install    check everything, add the jar, reboot
#   uninstall  remove the jar, reboot
#   logs       copy logs and status to the card, change nothing   [default]
# Every run writes its log to <card>/navignore_logs/NNN-<action>/.
#
# The whole change is ONE new file:
#     /mnt/app/eso/hmi/lsd/jars/NavActiveIgnore.jar
# The stock HMI start script lsd.sh already puts every *.jar in that folder on
# the HMI's boot class path, ahead of lsd.jxe. lsd.sh itself is NOT changed.
# (M.I.B.'s own "Remove dual navigation" button deletes the same file.)
#
# Safety rules:
#   - Nothing is written before every check has passed: firmware train, SHA-1
#     of lsd.sh (stock), SHA-1 of /ifs/lsd.jxe (the HMI image the jar's classes
#     were checked against, member by member), the jar on the card, and the
#     contents of the jars folder.
#   - The jar is copied to lsd/NavActiveIgnore.jar.new (outside jars/, so the
#     HMI never loads a half-written copy), verified, then renamed into jars/.
#   - The change takes effect only at the next HMI start (the reboot).
#   - QNX 6.5 /bin/sh is pdksh: no printf, find, dirname, awk or sed is used.
set -u

# PC test harness only. Active only when NAVIGNORE_TEST_ROOT names a directory
# that contains a file THIS_IS_A_TEST_ROOT; never the case on the unit.
R=
FAST=0
if [ -n "${NAVIGNORE_TEST_ROOT:-}" ] && [ -f "$NAVIGNORE_TEST_ROOT/THIS_IS_A_TEST_ROOT" ]; then
    R=$NAVIGNORE_TEST_ROOT
    PATH=$R/bin:$PATH
    FAST=1
else
    PATH=/proc/boot:/bin:/usr/bin:/usr/sbin:/sbin:/mnt/app/armle/bin:/mnt/app/armle/usr/bin:/mnt/app/armle/sbin:/mnt/app/armle/usr/sbin
fi
export PATH
unset LD_PRELOAD

VERSION=navignore-mu0678-v1

case $0 in */*) D=${0%/*} ;; *) D=. ;; esac
D=$(cd "$D" && pwd) || exit 1

# GEM runs on the MMX, where the HMI and /mnt/app live. Forward a launch on RCC.
if [ -z "$R" ] && [ ! -d /mnt/app/eso/hmi/lsd ] && [ -d /net/mmx/mnt/app/eso/hmi/lsd ]; then
    exec on -f mmx /bin/sh "$D/navignore.sh" "$@"
fi

echo "=== $VERSION ==="

case $D in
    */mod/navignore) CARD=${D%/mod/navignore} ;;
    *) echo "FAILED: navignore.sh must be in <card>/mod/navignore/ (it is in $D)"; exit 1 ;;
esac
PKG=$D
APP=$R/mnt/app
L=$APP/eso/hmi/lsd
JARS=$L/jars
JAR=$JARS/NavActiveIgnore.jar
TMPJAR=$L/NavActiveIgnore.jar.new
LSDSH=$L/lsd.sh
JXE=$R/ifs/lsd.jxe
TMPD=$R/tmp
PAYLOAD=$PKG/payload/NavActiveIgnore.jar

# ------------------------------------------------------------ the SD card
can_write() { ( : > "$1/.navignore_write_test" ) 2>/dev/null && rm -f "$1/.navignore_write_test"; }   # subshell: a failed redirection must not end the script
if ! can_write "$CARD"; then
    for m in "$CARD" /fs/sda0 /fs/sdb0 /net/mmx/fs/sda0 /net/mmx/fs/sdb0; do
        [ -f "$m/mod/navignore/navignore.sh" ] || continue
        mount -uw "$m" 2>/dev/null
        if can_write "$m"; then CARD=$m; break; fi
    done
fi
can_write "$CARD" || { echo "FAILED: SD card at $CARD is not writable"; exit 1; }

ACTION=logs
if [ -f "$PKG/ACTION" ]; then
    a=
    read -r a < "$PKG/ACTION" 2>/dev/null
    case $a in
        install*)   ACTION=install ;;
        uninstall*) ACTION=uninstall ;;
        logs*)      ACTION=logs ;;
    esac
fi

BASE=$CARD/navignore_logs
mkdir -p "$BASE" || { echo "FAILED: mkdir $BASE"; exit 1; }
last=0
for d in "$BASE"/*; do
    v=${d##*/}
    v=${v%%-*}
    case $v in ''|*[!0-9]*) continue ;; esac
    while :; do case $v in 0?*) v=${v#0} ;; *) break ;; esac; done   # 008 is octal to ksh
    if [ "$v" -gt "$last" ]; then last=$v; fi
done
n=$((last+1))
case $n in ?) NN=00$n ;; ??) NN=0$n ;; *) NN=$n ;; esac
OUT=$BASE/$NN-$ACTION
mkdir "$OUT" || { echo "FAILED: mkdir $OUT"; exit 1; }
mkdir "$OUT/cmd" "$OUT/tmp" 2>/dev/null
LOG=$OUT/log.txt
: > "$LOG"

# ------------------------------------------------------------ helpers
say() { echo "$@"; echo "$@" >> "$LOG" 2>/dev/null; }

CHANGED=0       # something under /mnt/app was written or removed

jar_state() {   # none | ours | UNKNOWN(<sha1>)
    if [ ! -e "$JAR" ]; then echo none; return; fi
    c=$(sha1_of "$JAR")
    if [ -n "$c" ] && [ "$c" = "$EXP_JAR" ]; then echo ours; else echo "UNKNOWN($c)"; fi
}

die() {
    say "!! $*"
    rm -f "$TMPJAR" 2>/dev/null
    if [ $CHANGED -eq 0 ]; then
        say "!! STOPPED. Nothing on the unit was changed."
    else
        case $(jar_state) in
            ours) say "!! STOPPED. NavActiveIgnore.jar IS in place (verified)."
                  say "!! It takes effect at the next restart. Run 'uninstall' to remove it." ;;
            none) say "!! STOPPED. NavActiveIgnore.jar is NOT in place: the HMI is as stock." ;;
            *)    say "!! STOPPED. $JAR is in an unexpected state: $(jar_state)"
                  say "!! Do not restart; send this log." ;;
        esac
    fi
    mount -ur "$APP" 2>/dev/null
    sync
    say "Log: $LOG"
    exit 1
}

# run_t <seconds> <name> <command...>: output to cmd/<name>.txt, stopped after <seconds>
run_t() {
    t=$1; f=$OUT/cmd/$2.txt; shift 2
    echo "# $*" > "$f"
    "$@" >> "$f" 2>&1 &
    p=$!; i=0
    while kill -0 $p 2>/dev/null; do
        if [ $i -ge $t ]; then
            kill $p 2>/dev/null
            echo "(stopped after ${t}s)" >> "$f"
            break
        fi
        sleep 1; i=$((i+1))
    done
    wait $p 2>/dev/null
    echo "(exit $?)" >> "$f"
}

# sha1_of <file>: the 40-hex-digit SHA-1 printed by the tool, or empty
SHA1=
sha1_of() {
    [ -n "$SHA1" ] && [ -f "$1" ] || { echo ""; return; }
    set -- $("$SHA1" "$1" 2>/dev/null)
    for t in "$@"; do
        case $t in
            *[!0-9a-f]*) ;;
            *) if [ ${#t} -eq 40 ]; then echo "$t"; return; fi ;;
        esac
    done
    echo ""
}

# Pick the first sha1sum that hashes the jar on the card correctly.
find_sha1() {
    [ -n "$EXP_JAR" ] && [ -f "$PAYLOAD" ] || return 1
    for t in /net/rcc/usr/bin/sha1sum /usr/bin/sha1sum /bin/sha1sum /proc/boot/sha1sum; do
        [ -f "$R$t" ] || continue
        SHA1=$R$t
        if [ "$(sha1_of "$PAYLOAD")" = "$EXP_JAR" ]; then return 0; fi
        SHA1=
    done
    return 1
}

EXP_TRAIN=; EXP_LSDSH=; EXP_JXE=; EXP_JAR=
load_expected() {
    [ -f "$PKG/EXPECTED" ] && [ -f "$PKG/STOCK_JARS" ] || return 1
    exec 4< "$PKG/EXPECTED"
    while read -r k v <&4; do
        v=${v%%[!A-Za-z0-9_]*}
        case $k in
            EXP_TRAIN) EXP_TRAIN=$v ;;
            EXP_LSDSH) EXP_LSDSH=$v ;;
            EXP_JXE)   EXP_JXE=$v ;;
            EXP_JAR)   EXP_JAR=$v ;;
        esac
    done
    exec 4<&-
    [ -n "$EXP_TRAIN" ] && [ -n "$EXP_LSDSH" ] && [ -n "$EXP_JXE" ] && [ -n "$EXP_JAR" ]
}

read_train() {
    TRAIN=
    for f in "$R/net/rcc/mnt/efs-persist/SWDL/CachedTrain.txt" "$R/mnt/efs-persist/SWDL/CachedTrain.txt"; do
        if [ -f "$f" ]; then read -r TRAIN < "$f"; break; fi
    done
    TRAIN=${TRAIN%%[!A-Za-z0-9_]*}
}

# is_stock_jar <name>: listed in STOCK_JARS (the jars folder as delivered)
is_stock_jar() {
    exec 5< "$PKG/STOCK_JARS"
    while read -r s _ <&5; do
        s=${s%%[!A-Za-z0-9_.-]*}
        case $s in ''|\#*) continue ;; esac
        if [ "$s" = "$1" ]; then exec 5<&-; return 0; fi
    done
    exec 5<&-
    return 1
}

# jars_ok: every entry in jars/ is a stock one or our NavActiveIgnore.jar
JARS_BAD=
jars_ok() {
    JARS_BAD=
    for f in "$JARS"/* "$JARS"/.[!.]*; do
        [ -e "$f" ] || continue
        b=${f##*/}
        [ "$b" = NavActiveIgnore.jar ] && continue
        is_stock_jar "$b" || JARS_BAD="$JARS_BAD $b"
    done
    [ -z "$JARS_BAD" ]
}

hmi_loaded() {   # yes | no | unknown : is the running HMI using the jar?
    f=$OUT/cmd/pidin_ar.txt
    [ -f "$f" ] || { echo unknown; return; }
    if grep 'lsd.jxe' "$f" > /dev/null 2>&1; then
        if grep 'jars/NavActiveIgnore.jar' "$f" > /dev/null 2>&1; then echo yes; else echo no; fi
    else
        echo unknown
    fi
}

reboot_countdown() {
    sync
    say ""
    say "The unit will REBOOT in 30 seconds to load the change."
    say "Take a photo of this screen now. Leave the SD card in."
    i=30
    while [ $i -gt 0 ]; do
        [ $FAST -eq 1 ] || sleep 5
        i=$((i-5))
        echo "  ... $i"
    done
    say "Rebooting now."
    sync
    on -f rcc /usr/apps/mib2_ioc_flash reboot >> "$LOG" 2>&1
    [ $FAST -eq 1 ] || sleep 20
    say "If the unit did not restart by itself, restart it by hand."
}

# ------------------------------------------------------------ logs (read-only)
grep_last() {   # grep_last <pattern> <file>: last matching line, or empty
    gl=
    grep "$1" "$2" > "$OUT/.grep" 2>/dev/null
    while read -r l; do gl=$l; done < "$OUT/.grep"
    rm -f "$OUT/.grep"
    echo "$gl"
}

do_logs() {
    say "Collecting logs (read-only)..."
    for f in "$TMPD/altscreen111.log" "$TMPD/vc_render.log" "$TMPD/r25-autostart.log" \
             "$TMPD/r44-watch.pid" "$TMPD"/mibr-*; do
        [ -f "$f" ] || continue
        case $f in *.h264) continue ;; esac
        cp "$f" "$OUT/tmp/" 2>/dev/null
    done
    run_t 10 pidin_ar pidin ar
    run_t 30 sloginfo sloginfo
    run_t 10 ls_lsd ls -la "$L" "$JARS"
    run_t 5  df df -k
    say "  NavActiveIgnore.jar:   $(jar_state)"
    if [ "$(sha1_of "$LSDSH")" = "$EXP_LSDSH" ]; then say "  lsd.sh:                stock (unchanged)"
    else say "  lsd.sh:                NOT the stock file"; fi
    say "  loaded by running HMI: $(hmi_loaded)"
    A=$TMPD/altscreen111.log
    if [ -f "$A" ]; then
        say "  CarPlay sessions:      $(grep -c 'r25-autostart: spawn' "$A" 2>/dev/null)"
        say "  route active seen:     $(grep -c 'MODES_CHANGED parsed.*turns=1' "$A" 2>/dev/null) time(s)"
        x=$(grep_last 'NATIVE-B rx' "$A"); [ -n "$x" ] && say "  last rx: ${x#*NATIVE-B }"
    else
        say "  no CarPlay map log yet (it appears once a phone is connected)"
    fi
    sync
}

# ------------------------------------------------------------ install
do_install() {
    say "Checking the file on the SD card..."
    say "  card ok   NavActiveIgnore.jar"      # find_sha1 verified it already

    say "Checking the unit..."
    read_train
    [ "$TRAIN" = "$EXP_TRAIN" ] || die "firmware train '$TRAIN' is not $EXP_TRAIN"
    say "  train      $TRAIN  ok"
    h=$(sha1_of "$LSDSH")
    [ "$h" = "$EXP_LSDSH" ] || die "lsd.sh is not the stock file (sha1 '$h'): another mod?"
    say "  lsd.sh     stock  ok"
    say "  checking the HMI image /ifs/lsd.jxe (58 MB, up to a minute)..."
    h=$(sha1_of "$JXE")
    [ "$h" = "$EXP_JXE" ] || die "/ifs/lsd.jxe is not the HMI image the jar was checked against (sha1 '$h')"
    say "  lsd.jxe    identical to the analysed image  ok"
    [ -d "$JARS" ] || die "${JARS#$R} does not exist"
    jars_ok || die "unknown file(s) in ${JARS#$R}:$JARS_BAD - another mod?"
    say "  jars/      only stock files  ok"
    STATE=$(jar_state)
    case $STATE in
        none) say "  NavActiveIgnore.jar  not installed yet" ;;
        ours)
            say "Already installed and verified - nothing to install."
            say "Exporting logs instead."
            do_logs
            return 0 ;;
        *) die "a different NavActiveIgnore.jar is already installed: $STATE" ;;
    esac

    say "All checks passed. Installing..."
    mount -uw "$APP" 2>/dev/null
    can_write "$L" || die "/mnt/app could not be made writable"
    CHANGED=1
    rm -f "$TMPJAR"
    cp "$PAYLOAD" "$TMPJAR" || die "could not write ${TMPJAR#$R}"
    chmod 644 "$TMPJAR" || die "chmod failed on ${TMPJAR#$R}"
    [ "$(sha1_of "$TMPJAR")" = "$EXP_JAR" ] || die "the copy on the unit did not verify"
    mv -f "$TMPJAR" "$JAR" || die "could not move the jar into ${JARS#$R}"
    sync
    [ "$(jar_state)" = ours ] || die "the jar did not verify after the move"
    mount -ur "$APP" 2>/dev/null
    say "  installed  ${JAR#$R}"

    say "Final check..."
    [ "$(jar_state)" = ours ] || die "final check: the jar is not ours"
    [ "$(sha1_of "$LSDSH")" = "$EXP_LSDSH" ] || die "final check: lsd.sh changed"
    [ ! -e "$TMPJAR" ] || die "final check: temporary file left behind"
    jars_ok || die "final check: unknown file(s) in jars/:$JARS_BAD"
    say "  everything verified  ok"
    say ""
    say "INSTALL COMPLETE."
    reboot_countdown
}

# ------------------------------------------------------------ uninstall
do_uninstall() {
    rm -f "$TMPJAR" 2>/dev/null
    STATE=$(jar_state)
    say "  NavActiveIgnore.jar  $STATE"
    case $STATE in
        ours)
            mount -uw "$APP" 2>/dev/null
            CHANGED=1
            rm -f "$JAR"
            sync
            [ ! -e "$JAR" ] || die "could not remove ${JAR#$R}"
            mount -ur "$APP" 2>/dev/null
            say "  removed  ${JAR#$R}"
            say ""
            say "UNINSTALL COMPLETE."
            reboot_countdown ;;
        none)
            say "  not installed - nothing to remove."
            say "No reboot needed." ;;
        *)
            say "  left in place (not ours): ${JAR#$R}"
            say "  It is not the file this installer puts there; remove it with the"
            say "  tool that installed it (M.I.B.: navigation -> Remove dual navigation)."
            say "No reboot needed." ;;
    esac
}

# ------------------------------------------------------------ main
say "action: $ACTION    log: $OUT"
if ! load_expected; then
    [ "$ACTION" = logs ] || die "mod/navignore/EXPECTED or STOCK_JARS missing on the card"
fi
if ! find_sha1; then
    [ "$ACTION" = logs ] || die "sha1 self-test failed: no working sha1sum, or the jar on the card is damaged"
    say "  (no working sha1sum - hashes skipped)"
else
    say "  sha1 tool: $SHA1"
fi
case $ACTION in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    *)         do_logs ;;
esac
sync
say "DONE: $OUT"
