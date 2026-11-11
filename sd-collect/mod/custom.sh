#!/bin/sh
# altscreen-collect v1 - READ-ONLY information collector for porting
# joeyQuery/MHI2-altScreen (CarPlay map in the Virtual Cockpit) to an
# Audi MHI2 MU0678 unit.
#
# Run it from M.I.B.:
#   GEM -> m.i.b -> Advanced Settings -> Run Custom Script
#   (M.I.B. V3.6 and later: "Run individual script", which runs
#    mod/command.sh; that file only hands over to this one.)
#
# It copies a few firmware/config files and the output of status commands to
#   <card>/altscreen_collect/NNN/      (001, 002, ... one folder per run)
#
# It changes NOTHING on the unit:
#   - /mnt/app and /mnt/system are never remounted writable; only the SD card
#     itself is remounted writable if it came up read-only,
#   - no file is created, edited or deleted anywhere except on the SD card,
#   - nothing is started, stopped or signalled except the short-lived status
#     commands this script runs itself, each with a time limit.
#
# QNX 6.5 /bin/sh is pdksh. The unit has no printf, find, dirname, cmp, and
# sed/awk are not relied on. Card detection, MMX forwarding and the time-limit
# pattern follow luka-dev/mib2q-carplay-rgi and chefranov/mhi2-au37x-carplay.
set -u
PATH=/proc/boot:/bin:/usr/bin:/usr/sbin:/sbin:/mnt/app/armle/bin:/mnt/app/armle/usr/bin:/mnt/app/armle/sbin:/mnt/app/armle/usr/sbin
export PATH
unset LD_PRELOAD

VERSION=altscreen-collect-v1

case $0 in */*) D=${0%/*} ;; *) D=. ;; esac
D=$(cd "$D" && pwd) || exit 1

# GEM runs on the MMX, where CarPlay and /mnt/app live. Forward a launch on RCC.
if [ ! -d /mnt/app/eso/hmi/lsd ] && [ -d /net/mmx/mnt/app/eso/hmi/lsd ]; then
    exec on -f mmx /bin/sh "$D/custom.sh" "$@"
fi

echo "=== $VERSION (read-only) ==="

# ------------------------------------------------------------- the SD card
CARD=${D%/mod}
can_write() { : > "$1/.altscreen_write_test" 2>/dev/null && rm -f "$1/.altscreen_write_test"; }
if ! can_write "$CARD"; then
    for m in "$CARD" /fs/sda0 /fs/sdb0 /net/mmx/fs/sda0 /net/mmx/fs/sdb0; do
        [ -f "$m/mod/custom.sh" ] || continue
        mount -uw "$m" 2>/dev/null
        if can_write "$m"; then CARD=$m; break; fi
    done
fi
can_write "$CARD" || { echo "FAILED: SD card at $CARD is not writable"; exit 1; }

BASE=$CARD/altscreen_collect
mkdir -p "$BASE" || { echo "FAILED: mkdir $BASE"; exit 1; }
# Next number = highest existing folder + 1 (the unit clock is often wrong).
last=0
for d in "$BASE"/*; do
    v=${d##*/}
    case $v in ''|*[!0-9]*) continue ;; esac
    while :; do case $v in 0?*) v=${v#0} ;; *) break ;; esac; done   # 008 is octal to ksh
    [ "$v" -gt "$last" ] && last=$v
done
n=$((last+1))
case $n in ?) NN=00$n ;; ??) NN=0$n ;; *) NN=$n ;; esac
OUT=$BASE/$NN
mkdir "$OUT" || { echo "FAILED: mkdir $OUT"; exit 1; }
mkdir "$OUT/files" "$OUT/cmd" || { echo "FAILED: mkdir in $OUT"; exit 1; }

# ------------------------------------------------------------- helpers
say() { echo "$@"; echo "$@" >> "$OUT/summary.txt"; }

# flat /a/b/c.txt -> a__b__c.txt (no sed on the unit)
flat() {
    r=${1#/}; o=
    while :; do
        case $r in
            */*) o=$o${r%%/*}__; r=${r#*/} ;;
            *)   o=$o$r; break ;;
        esac
    done
    echo "$o"
}

# grab <path>: record its listing and copy it into files/ when it is a file.
grab() {
    ls -l "$1" >> "$OUT/files_ls.txt" 2>&1
    if [ -f "$1" ]; then
        cp "$1" "$OUT/files/$(flat "$1")" 2>> "$OUT/files_ls.txt" \
            || echo "COPY FAILED: $1" >> "$OUT/files_ls.txt"
    fi
}

# run_t <seconds> <name> <command...>: output to cmd/<name>.txt, stopped after <seconds>.
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

# size_of <file>: 5th field of ls -l, empty if missing
size_of() { set -- $(ls -l "$1" 2>/dev/null); echo "${5:-}"; }

DMDT=/eso/bin/apps/dmdt
[ -x "$DMDT" ] || DMDT=/mnt/app/eso/bin/apps/dmdt
dmdt_q() { LD_LIBRARY_PATH=/eso/lib IPL_CONFIG_DIR=/etc/eso/production "$DMDT" "$@"; }
slog_nav() { sloginfo 2>&1 | grep 'NavStateOfOperation'; }
slog_cp() { sloginfo 2>&1 | grep -i 'carplay'; }

{
    echo "version     $VERSION"
    echo "run         $NN"
    echo "date        $(date 2>&1)"
    echo "card        $CARD"
    echo "script      $D/custom.sh"
} > "$OUT/info.txt"

# ------------------------------------------------------------- identity
TRAIN=
for f in /net/rcc/mnt/efs-persist/SWDL/CachedTrain.txt /mnt/efs-persist/SWDL/CachedTrain.txt; do
    if [ -f "$f" ]; then
        read -r TRAIN < "$f"
        grab "$f"
        break
    fi
done
run_t 10 e2p_train on -f rcc /usr/apps/modifyE2P r 3A0 19
run_t 5 uname uname -a
for f in /mnt/app/eso/hmi/lsd/version.txt /mnt/system/etc/project.txt /etc/project.txt /mnt/app/version_info.txt; do
    [ -f "$f" ] && grab "$f"
done

# ------------------------------------------------------------- files the port depends on
grab /mnt/app/eso/lib/libairplay.so
for f in smartphone_integrator.json displaymanager.json dio_manager.json; do
    grab /mnt/system/etc/eso/production/$f
    grab /etc/eso/production/$f
done
for f in /etc/pf.conf /mnt/system/etc/pf.conf /mnt/system/etc/pf.*.conf /etc/pf.*.conf; do
    [ -f "$f" ] && grab "$f"
done
for f in /mnt/app/eso/hmi/lsd/traceConfig.properties /mnt/app/eso/hmi/lsd/traceConfig.properties.orig; do
    grab "$f"
done
# listed only (size/date), not copied
for f in /mnt/app/eso/bin/apps/dio_manager /mnt/app/eso/bin/apps/smartphone_integrator \
         /mnt/app/eso/bin/apps/dmdt /mnt/app/armle/lib/libnvss_video.so \
         /mnt/app/armle/usr/sbin/mm-ipod /ifs/lsd.jxe; do
    ls -l "$f" >> "$OUT/files_ls.txt" 2>&1
done

# ------------------------------------------------------------- unit state (read-only commands)
run_t 5  mount mount
run_t 5  df df -k
run_t 5  tmp_link ls -ld /tmp
run_t 10 pidin_ar pidin ar
run_t 10 dio_env pidin -p dio_manager env
run_t 10 netstat netstat -an
run_t 10 pf_rules pfctl -sr
run_t 10 dmdt_gs dmdt_q gs
run_t 10 dmdt_gc dmdt_q gc
run_t 10 dmdt_gd dmdt_q gd
run_t 20 slog_nav slog_nav
run_t 20 slog_carplay slog_cp
run_t 10 ls_app ls -la /mnt/app /mnt/app/root
run_t 10 ls_eso ls -la /mnt/app/eso/lib /mnt/app/eso/hmi/lib /mnt/app/eso/hmi/lsd /mnt/app/eso/hmi/lsd/jars

# ------------------------------------------------------------- traces of earlier mods
MODS=0
for m in /mnt/app/eso/lib/libmibr_carplay111.so /mnt/app/root/mibr-carplay111-backup \
         /mnt/app/root/vc_render /mnt/app/root/mibr-carplay111-native-b \
         /mnt/app/eso/hmi/lib/librgd_hook.so /mnt/app/eso/hmi/lib/libcarplay_hook.so \
         /mnt/app/altscreen_inject /mnt/app/rgd_disable /mnt/app/root/carplay \
         /mnt/app/eso/hmi/lsd/dsitracer_activated; do
    if [ -e "$m" ]; then echo "PRESENT $m" >> "$OUT/mods.txt"; MODS=$((MODS+1)); fi
done
[ $MODS -eq 0 ] && echo "none of the known mod files present" >> "$OUT/mods.txt"

sync

# ------------------------------------------------------------- short summary on screen
say ""
say "train:       ${TRAIN:-(not found, see cmd/e2p_train.txt)}"
S=$(size_of /mnt/app/eso/lib/libairplay.so)
if [ "$S" = "857727" ]; then
    say "libairplay:  $S bytes (same size as reference)"
else
    say "libairplay:  ${S:-missing} bytes (reference: 857727)"
fi
if grep 2nd_lvds "$OUT/cmd/dmdt_gs.txt" > /dev/null 2>&1; then
    say "cluster:     2nd_lvds display found"
else
    say "cluster:     2nd_lvds NOT seen (see cmd/dmdt_gs.txt)"
fi
say "other mods:  $MODS known mod file(s) found"
say ""
say "DONE: $OUT"
say "Nothing on the unit was changed."
say "Take the card to the PC and send this folder."
