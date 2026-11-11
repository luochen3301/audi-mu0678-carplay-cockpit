#!/bin/sh
# altscreen-mu0678 v1 - install / uninstall / log export for the CarPlay map
# in the Audi Virtual Cockpit (joeyQuery/MHI2-altScreen, hook build r60) on an
# Audi MHI2 MU0678 unit running MHI2_ER_AUG22_P3241.
#
# Run from M.I.B.:  GEM -> m.i.b -> Advanced Settings -> Run individual script
# (M.I.B. runs mod/command.sh, which hands over to this file.)
#
# What it does is the first word of mod/altscreen/ACTION:
#   install    check everything, install, reboot
#   uninstall  put the stock CarPlay config back, remove the files, reboot
#   logs       copy logs and status to the card, change nothing   [default]
# Every run writes its log to <card>/altscreen_logs/NNN-<action>/.
#
# Safety rules:
#   - Nothing is written before every check has passed: firmware train, the
#     SHA-1 of libairplay.so, the state of smartphone_integrator.json, every
#     payload file on the card, and anything already at a target path.
#   - Every file is copied to <name>.new, verified, then renamed into place.
#   - The CarPlay config is switched last; until then the hook is never loaded.
#   - Uninstall restores the config first, then removes the files.
#   - QNX 6.5 /bin/sh is pdksh: no printf, find, dirname, awk or sed is used.
set -u
PATH=/proc/boot:/bin:/usr/bin:/usr/sbin:/sbin:/mnt/app/armle/bin:/mnt/app/armle/usr/bin:/mnt/app/armle/sbin:/mnt/app/armle/usr/sbin
export PATH
unset LD_PRELOAD

VERSION=altscreen-mu0678-v1.1

case $0 in */*) D=${0%/*} ;; *) D=. ;; esac
D=$(cd "$D" && pwd) || exit 1

# PC test harness only. Active only when ALTSCREEN_TEST_ROOT names a directory
# that contains a file THIS_IS_A_TEST_ROOT; never the case on the unit.
R=
FAST=0
SHA1_LIST="/net/rcc/usr/bin/sha1sum /usr/bin/sha1sum /bin/sha1sum /proc/boot/sha1sum"
if [ -n "${ALTSCREEN_TEST_ROOT:-}" ] && [ -f "${ALTSCREEN_TEST_ROOT}/THIS_IS_A_TEST_ROOT" ]; then
    R=$ALTSCREEN_TEST_ROOT
    PATH=$R/testbin:$PATH
    FAST=1
    [ -n "${ALTSCREEN_TEST_SHA1_LIST:-}" ] && SHA1_LIST=$ALTSCREEN_TEST_SHA1_LIST
fi

# GEM runs on the MMX, where CarPlay and /mnt/app live. Forward a launch on RCC.
if [ -z "$R" ] && [ ! -d /mnt/app/eso/hmi/lsd ] && [ -d /net/mmx/mnt/app/eso/hmi/lsd ]; then
    exec on -f mmx /bin/sh "$D/custom.sh" "$@"
fi

PKG=$D/altscreen
CARD=${D%/mod}
APP=$R/mnt/app
SYS=$R/mnt/system
TARGET=$SYS/etc/eso/production/smartphone_integrator.json
LIBAIRPLAY=$APP/eso/lib/libairplay.so
BACKDIR=$APP/root/mibr-carplay111-backup
BACKUP=$BACKDIR/smartphone_integrator.json.stock
RECORD=$APP/root/altscreen-mu0678.installed
TMPD=$R/tmp
STOCK_SRC=$PKG/payload/smartphone_integrator.json.stock
PATCHED_SRC=$PKG/payload/smartphone_integrator.json.patched

echo "=== $VERSION ==="

# ------------------------------------------------------------ the SD card
can_write() { : > "$1/.altscreen_write_test" 2>/dev/null && rm -f "$1/.altscreen_write_test"; }
if ! can_write "$CARD"; then
    for m in "$CARD" /fs/sda0 /fs/sdb0 /net/mmx/fs/sda0 /net/mmx/fs/sdb0; do
        [ -f "$m/mod/custom.sh" ] || continue
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

BASE=$CARD/altscreen_logs
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

CHANGED=0       # something under /mnt/app was written
CFG_TOUCHED=0   # the CarPlay config was rewritten

cfg_state() {
    c=$(sha1_of "$TARGET")
    if [ "$c" = "$EXP_STOCK" ]; then echo stock
    elif [ "$c" = "$EXP_PATCHED" ]; then echo ours
    else echo "UNKNOWN($c)"; fi
}

die() {
    say "!! $*"
    if [ $CFG_TOUCHED -eq 1 ]; then
        say "!! STOPPED. CarPlay config is now: $(cfg_state)"
    elif [ $CHANGED -eq 1 ]; then
        say "!! STOPPED. Some files were added under /mnt/app, but the"
        say "!! CarPlay config is untouched: CarPlay works as stock."
        say "!! Run 'uninstall' to clean up, or 'install' again."
    else
        say "!! STOPPED. Nothing on the unit was changed."
    fi
    mount -ur "$APP" 2>/dev/null
    mount -ur "$SYS" 2>/dev/null
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

# Pick the first sha1sum that hashes the stock config on the card correctly.
find_sha1() {
    [ -n "$EXP_STOCK" ] && [ -f "$STOCK_SRC" ] || return 1
    for t in $SHA1_LIST "$CARD/apps/sbin/sha1sum"; do
        [ -f "$t" ] || continue
        SHA1=$t
        if [ "$(sha1_of "$STOCK_SRC")" = "$EXP_STOCK" ]; then return 0; fi
        SHA1=
    done
    return 1
}

EXP_TRAIN=; EXP_LIBAIRPLAY=; EXP_STOCK=; EXP_PATCHED=
load_expected() {
    [ -f "$PKG/EXPECTED" ] && [ -f "$PKG/FILES" ] || return 1
    exec 4< "$PKG/EXPECTED"
    while read -r k v <&4; do
        v=${v%%[!A-Za-z0-9_]*}
        case $k in
            EXP_TRAIN)      EXP_TRAIN=$v ;;
            EXP_LIBAIRPLAY) EXP_LIBAIRPLAY=$v ;;
            EXP_STOCK)      EXP_STOCK=$v ;;
            EXP_PATCHED)    EXP_PATCHED=$v ;;
        esac
    done
    exec 4<&-
    [ -n "$EXP_TRAIN" ] && [ -n "$EXP_LIBAIRPLAY" ] && [ -n "$EXP_STOCK" ] && [ -n "$EXP_PATCHED" ]
}

# FILES lines: <sha1> <payload path> <unit path> <mode>
open_files() { exec 3< "$PKG/FILES"; }
close_files() { exec 3<&-; }
next_file() {
    while read -r F_SHA F_SRC F_DST F_MODE <&3; do
        case $F_SHA in ''|\#*) continue ;; esac
        F_MODE=${F_MODE%%[!0-7]*}
        return 0
    done
    return 1
}

# UPGRADE lines: <sha1> <unit path> = an older version of one of our files,
# which install may replace and uninstall may remove. Anything else unknown
# at a target path still stops the install.
is_old_ours() {   # is_old_ours <unit path> <sha1>
    [ -f "$PKG/UPGRADE" ] && [ -n "$2" ] || return 1
    exec 5< "$PKG/UPGRADE"
    while read -r U_SHA U_DST <&5; do
        case $U_SHA in ''|\#*) continue ;; esac
        U_DST=${U_DST%%[!A-Za-z0-9_./-]*}
        if [ "$U_SHA" = "$2" ] && [ "$U_DST" = "$1" ]; then exec 5<&-; return 0; fi
    done
    exec 5<&-
    return 1
}

verify_card() {
    ok=1
    if [ "$(sha1_of "$STOCK_SRC")" = "$EXP_STOCK" ]; then say "  card ok   smartphone_integrator.json.stock"
    else say "  card BAD  smartphone_integrator.json.stock"; ok=0; fi
    if [ "$(sha1_of "$PATCHED_SRC")" = "$EXP_PATCHED" ]; then say "  card ok   smartphone_integrator.json.patched"
    else say "  card BAD  smartphone_integrator.json.patched"; ok=0; fi
    open_files
    while next_file; do
        if [ "$(sha1_of "$PKG/payload/$F_SRC")" = "$F_SHA" ]; then say "  card ok   $F_SRC"
        else say "  card BAD  $F_SRC"; ok=0; fi
    done
    close_files
    [ $ok -eq 1 ]
}

read_train() {
    TRAIN=
    for f in "$R/net/rcc/mnt/efs-persist/SWDL/CachedTrain.txt" "$R/mnt/efs-persist/SWDL/CachedTrain.txt"; do
        if [ -f "$f" ]; then read -r TRAIN < "$f"; break; fi
    done
    TRAIN=${TRAIN%%[!A-Za-z0-9_]*}
}

all_installed() {
    r=0
    open_files
    while next_file; do
        [ "$(sha1_of "$R$F_DST")" = "$F_SHA" ] || r=1
    done
    close_files
    return $r
}

# put_file <src> <dst> <mode> <sha1>: copy to dst.new, verify, rename, verify
put_file() {
    if [ -f "$2" ] && [ "$(sha1_of "$2")" = "$4" ]; then say "  ok, already there  ${2#$R}"; return 0; fi
    rm -f "$2.new"
    cp "$1" "$2.new" || return 1
    chmod "$3" "$2.new" || return 1
    if [ "$(sha1_of "$2.new")" != "$4" ]; then rm -f "$2.new"; return 1; fi
    mv -f "$2.new" "$2" || return 1
    [ "$(sha1_of "$2")" = "$4" ] || return 1
    say "  installed  ${2#$R}"
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
    run_t 10 dio_env pidin -p dio_manager env
    run_t 10 netstat netstat -an
    run_t 20 sloginfo sloginfo
    run_t 10 ls_installed ls -la "$APP/root" "$APP/eso/lib/libmibr_carplay111.so" "$BACKDIR"
    run_t 10 core_ls ls -la "$R/mnt/ota/system/core"
    run_t 5  df df -k
    if [ -n "$SHA1" ]; then
        say "  CarPlay config:   $(cfg_state)"
        if all_installed; then say "  installed files:  all present and verified"
        else say "  installed files:  not all present (not installed?)"; fi
    fi
    L=$TMPD/altscreen111.log
    if [ -f "$L" ]; then
        say "  sessions started: $(grep -c 'r25-autostart: spawn' "$L" 2>/dev/null)"
        say "  sessions ended:   $(grep -c 'TEARDOWN entry request=NULL' "$L" 2>/dev/null)"
        say "  stream 111 used:  $(grep -c 'NATIVE-B FORWARD MODE ON' "$L" 2>/dev/null) time(s)"
        x=$(grep_last 'NATIVE-B rx' "$L"); [ -n "$x" ] && say "  last rx: ${x#*NATIVE-B }"
    else
        say "  no hook log yet (it appears once a phone is connected)"
    fi
    V=$TMPD/vc_render.log
    if [ -f "$V" ]; then
        x=$(grep_last 'STATS' "$V"); [ -n "$x" ] && say "  vc_render: ${x#*STATS }"
    fi
    sync
}

# ------------------------------------------------------------ install
do_install() {
    say "Checking the files on the SD card..."
    verify_card || die "files on the SD card are damaged - remake the card"

    say "Checking the unit..."
    read_train
    [ "$TRAIN" = "$EXP_TRAIN" ] || die "firmware train '$TRAIN' is not $EXP_TRAIN"
    say "  train       $TRAIN  ok"
    h=$(sha1_of "$LIBAIRPLAY")
    [ "$h" = "$EXP_LIBAIRPLAY" ] || die "libairplay.so is not the analysed build (sha1 $h)"
    say "  libairplay  identical to the reference  ok"
    STATE=$(cfg_state)
    case $STATE in
        stock|ours) say "  CarPlay config  $STATE  ok" ;;
        *) die "smartphone_integrator.json is neither stock nor ours: another mod?" ;;
    esac
    open_files
    while next_file; do
        if [ -e "$R$F_DST" ]; then
            cur=$(sha1_of "$R$F_DST")
            if [ "$cur" = "$F_SHA" ]; then :
            elif is_old_ours "$F_DST" "$cur"; then say "  older version, will be upgraded  $F_DST"
            else
                close_files
                die "an unknown file is already at $F_DST"
            fi
        fi
    done
    close_files
    if [ -e "$BACKUP" ] && [ "$(sha1_of "$BACKUP")" != "$EXP_STOCK" ]; then
        die "an unknown file is already at ${BACKUP#$R}"
    fi

    if [ "$STATE" = ours ] && all_installed; then
        say "Already installed and verified - nothing to install."
        say "Exporting logs instead."
        do_logs
        return 0
    fi

    say "All checks passed. Installing..."
    mount -uw "$APP" 2>/dev/null
    can_write "$APP/root" || die "/mnt/app could not be made writable"
    CHANGED=1
    mkdir -p "$BACKDIR" || die "cannot create ${BACKDIR#$R}"
    if [ ! -f "$BACKUP" ]; then
        if [ "$STATE" = stock ]; then src=$TARGET; else src=$STOCK_SRC; fi
        put_file "$src" "$BACKUP" 644 "$EXP_STOCK" || die "backup of the stock config failed"
    fi
    cp "$TARGET" "$OUT/smartphone_integrator.json.before" 2>/dev/null
    open_files
    while next_file; do
        if ! put_file "$PKG/payload/$F_SRC" "$R$F_DST" "$F_MODE" "$F_SHA"; then
            close_files
            die "could not install $F_DST"
        fi
    done
    close_files
    { echo "$VERSION"; echo "hook r60 sha1 see mod/altscreen/FILES"; } > "$RECORD" 2>/dev/null
    sync
    mount -ur "$APP" 2>/dev/null

    if [ "$STATE" = stock ]; then
        say "Switching the CarPlay config (last step)..."
        mount -uw "$SYS" 2>/dev/null
        rm -f "$TARGET.new"
        cp "$PATCHED_SRC" "$TARGET.new" || die "cannot write the new config (/mnt/system not writable?)"
        chmod 755 "$TARGET.new"
        if [ "$(sha1_of "$TARGET.new")" != "$EXP_PATCHED" ]; then
            rm -f "$TARGET.new"
            die "the new config did not verify"
        fi
        CFG_TOUCHED=1
        if ! mv -f "$TARGET.new" "$TARGET"; then
            rm -f "$TARGET.new"
            die "could not rename the new config into place"
        fi
        sync
        if [ "$(sha1_of "$TARGET")" != "$EXP_PATCHED" ]; then
            say "!! the config did not verify after the rename - putting the stock one back"
            rm -f "$TARGET.new"
            if cp "$BACKUP" "$TARGET.new" && chmod 755 "$TARGET.new" && \
               [ "$(sha1_of "$TARGET.new")" = "$EXP_STOCK" ]; then
                mv -f "$TARGET.new" "$TARGET"
            fi
            sync
            die "config switch failed"
        fi
        mount -ur "$SYS" 2>/dev/null
        say "  CarPlay config switched  ok"
    fi

    say "Final check..."
    [ "$(cfg_state)" = ours ] || die "final check: CarPlay config is not ours"
    all_installed || die "final check: an installed file did not verify"
    say "  everything verified  ok"
    say ""
    say "INSTALL COMPLETE."
    reboot_countdown
}

# ------------------------------------------------------------ uninstall
do_uninstall() {
    STATE=$(cfg_state)
    say "  CarPlay config  $STATE"
    NEED_REBOOT=0
    case $STATE in
        ours)
            if [ -f "$BACKUP" ] && [ "$(sha1_of "$BACKUP")" = "$EXP_STOCK" ]; then src=$BACKUP
            else src=$STOCK_SRC; say "  (using the stock copy on the card)"; fi
            say "Restoring the stock CarPlay config..."
            mount -uw "$SYS" 2>/dev/null
            rm -f "$TARGET.new"
            cp "$src" "$TARGET.new" || die "cannot write the stock config (/mnt/system not writable?)"
            chmod 755 "$TARGET.new"
            if [ "$(sha1_of "$TARGET.new")" != "$EXP_STOCK" ]; then
                rm -f "$TARGET.new"
                die "the stock config did not verify"
            fi
            CFG_TOUCHED=1
            if ! mv -f "$TARGET.new" "$TARGET"; then
                rm -f "$TARGET.new"
                die "could not rename the stock config into place"
            fi
            sync
            [ "$(cfg_state)" = stock ] || die "stock config did not verify after the rename"
            mount -ur "$SYS" 2>/dev/null
            say "  stock CarPlay config restored  ok"
            NEED_REBOOT=1
            ;;
        stock)
            say "  CarPlay config is already stock" ;;
        *)
            die "smartphone_integrator.json is neither ours nor stock - not touching anything" ;;
    esac

    say "Removing the installed files..."
    mount -uw "$APP" 2>/dev/null
    open_files
    while next_file; do
        rm -f "$R$F_DST.new"
        if [ -e "$R$F_DST" ]; then
            cur=$(sha1_of "$R$F_DST")
            if [ "$cur" = "$F_SHA" ]; then
                CHANGED=1
                rm -f "$R$F_DST" && say "  removed  $F_DST"
            elif is_old_ours "$F_DST" "$cur"; then
                CHANGED=1
                rm -f "$R$F_DST" && say "  removed (older version)  $F_DST"
            else
                say "  left in place (not ours)  $F_DST"
            fi
        fi
    done
    close_files
    rm -f "$RECORD"
    sync
    mount -ur "$APP" 2>/dev/null
    say "  (the stock config backup stays in ${BACKDIR#$R})"
    say ""
    say "UNINSTALL COMPLETE."
    if [ $NEED_REBOOT -eq 1 ]; then reboot_countdown
    else say "No reboot needed."; fi
}

# ------------------------------------------------------------ main
say "action: $ACTION    log: $OUT"
if ! load_expected; then
    [ "$ACTION" = logs ] || die "mod/altscreen/EXPECTED or FILES missing on the card"
fi
if ! find_sha1; then
    [ "$ACTION" = logs ] || die "sha1 self-test failed: no working sha1sum, or the card is damaged"
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
