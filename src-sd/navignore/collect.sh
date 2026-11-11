#!/bin/sh
# navignore-collect v1 - READ-ONLY information collector for the
# "dual navigation" (M.I.B. NavActiveIgnore) step on an Audi MHI2 MU0678.
#
# Run it from M.I.B.: GEM -> m.i.b -> Advanced Settings -> Run individual
# script, with the word "navignore-collect" in mod/RUN on the card.
#
# It copies to <card>/navignore_logs/NNN-collect/ :
#   - the HMI start script /mnt/app/eso/hmi/lsd/lsd.sh (and any old backup
#     copies of it that another tool may have left beside it),
#   - the HMI program image /ifs/lsd.jxe (58 MB; copied last),
#   - folder listings, mounts, free space, the process list, the system log,
#   - SHA-1 sums taken on the unit, to prove the copies on the card are exact.
#
# It changes NOTHING on the unit:
#   - /mnt/app and /mnt/system are never remounted writable; only the SD card
#     itself is remounted writable if it came up read-only,
#   - no file is created, edited or deleted anywhere except on the SD card,
#   - nothing is started, stopped or signalled except the short-lived status
#     commands this script runs itself, each with a time limit.
#
# QNX 6.5 /bin/sh is pdksh: no printf, find, dirname, cmp; sed/awk not used.
set -u

# Test harness only: on a PC the tests point R at a fake unit. On the car the
# marker file cannot exist, so R stays empty and every path is the real one.
R=
if [ -n "${NAVIGNORE_TEST_ROOT:-}" ] && [ -f "$NAVIGNORE_TEST_ROOT/THIS_IS_A_TEST_ROOT" ]; then
    R=$NAVIGNORE_TEST_ROOT
    PATH=$R/bin:$PATH
else
    PATH=/proc/boot:/bin:/usr/bin:/usr/sbin:/sbin:/mnt/app/armle/bin:/mnt/app/armle/usr/bin:/mnt/app/armle/sbin:/mnt/app/armle/usr/sbin
fi
export PATH
unset LD_PRELOAD

VERSION=navignore-collect-v1

case $0 in */*) D=${0%/*} ;; *) D=. ;; esac
D=$(cd "$D" && pwd) || exit 1

# GEM runs on the MMX, where the HMI and /mnt/app live. Forward a launch on RCC.
if [ -z "$R" ] && [ ! -d /mnt/app/eso/hmi/lsd ] && [ -d /net/mmx/mnt/app/eso/hmi/lsd ]; then
    exec on -f mmx /bin/sh "$D/collect.sh" "$@"
fi

echo "=== $VERSION (read-only) ==="

# ------------------------------------------------------------- the SD card
case $D in
    */mod/navignore) CARD=${D%/mod/navignore} ;;
    *) echo "FAILED: collect.sh must be in <card>/mod/navignore/ (it is in $D)"; exit 1 ;;
esac
can_write() { ( : > "$1/.navignore_write_test" ) 2>/dev/null && rm -f "$1/.navignore_write_test"; }   # subshell: a failed redirection must not end the script
if ! can_write "$CARD"; then
    for m in "$CARD" /fs/sda0 /fs/sdb0 /net/mmx/fs/sda0 /net/mmx/fs/sdb0; do
        [ -f "$m/mod/navignore/collect.sh" ] || continue
        mount -uw "$m" 2>/dev/null
        if can_write "$m"; then CARD=$m; break; fi
    done
fi
can_write "$CARD" || { echo "FAILED: SD card at $CARD is not writable"; exit 1; }

BASE=$CARD/navignore_logs
mkdir -p "$BASE" || { echo "FAILED: mkdir $BASE"; exit 1; }
# Next number = highest existing NNN-... folder + 1 (the unit clock is often wrong).
last=0
for d in "$BASE"/*; do
    v=${d##*/}
    v=${v%%-*}
    case $v in ''|*[!0-9]*) continue ;; esac
    while :; do case $v in 0?*) v=${v#0} ;; *) break ;; esac; done   # 008 is octal to ksh
    [ "$v" -gt "$last" ] && last=$v
done
n=$((last+1))
case $n in ?) NN=00$n ;; ??) NN=0$n ;; *) NN=$n ;; esac
OUT=$BASE/$NN-collect
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

# grab <unit path>: record its listing and copy it into files/ when it is a file.
grab() {
    ls -l "$R$1" >> "$OUT/files_ls.txt" 2>&1
    if [ -f "$R$1" ]; then
        cp "$R$1" "$OUT/files/$(flat "$1")" 2>> "$OUT/files_ls.txt" \
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

{
    echo "version     $VERSION"
    echo "run         $NN"
    echo "date        $(date 2>&1)"
    echo "card        $CARD"
    echo "script      $D/collect.sh"
} > "$OUT/info.txt"

L=/mnt/app/eso/hmi/lsd

# ------------------------------------------------------------- identity
TRAIN=
for f in /net/rcc/mnt/efs-persist/SWDL/CachedTrain.txt /mnt/efs-persist/SWDL/CachedTrain.txt; do
    if [ -f "$R$f" ]; then
        read -r TRAIN < "$R$f"
        grab "$f"
        break
    fi
done
grab $L/version.txt

# ------------------------------------------------------------- small files
say "copying lsd.sh and listings..."
grab $L/lsd.sh
for f in $L/lsd.sh.bu $L/lsd.shr $L/lsd.sh.orig $L/lsd.sh.bak $L/bundles.properties /etc/boot/startup.sh; do
    [ -e "$R$f" ] && grab "$f"
done

# ------------------------------------------------------------- unit state (read-only commands)
run_t 10 ls_lsd    ls -la "$R$L" "$R$L/jars" "$R/ifs"
run_t 5  mount     mount
run_t 5  df        df -k
run_t 10 pidin_ar  pidin ar
run_t 20 who_starts_lsd grep -n 'lsd\.sh' "$R/etc/boot/startup.sh" "$R/etc/eso/production/"*.json "$R/mnt/system/etc/eso/production/"*.json
run_t 30 sloginfo  sloginfo

SHA1=
for t in /net/rcc/usr/bin/sha1sum /usr/bin/sha1sum /bin/sha1sum /proc/boot/sha1sum; do
    if [ -f "$R$t" ]; then SHA1=$R$t; break; fi
done
# sha1_of <file>: the 40-hex-digit word sha1sum prints, empty on any failure
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
# same <a> <b>: both hashed, and the hashes are equal
same() { [ -n "$1" ] && [ "$1" = "$2" ]; }

LSD_CARD=$OUT/files/$(flat $L/lsd.sh)
H_LSD=$(sha1_of "$R$L/lsd.sh")
H_LSDC=$(sha1_of "$LSD_CARD")
echo "sha1 tool: ${SHA1:-none}" > "$OUT/sha1.txt"
echo "${H_LSD:-none} unit $L/lsd.sh" >> "$OUT/sha1.txt"
echo "${H_LSDC:-none} card $LSD_CARD" >> "$OUT/sha1.txt"
sync

# ------------------------------------------------------------- the HMI image, last
JXE_UNIT=$R/ifs/lsd.jxe
JXE_CARD=$OUT/files/$(flat /ifs/lsd.jxe)
say "copying /ifs/lsd.jxe ($(size_of "$JXE_UNIT") bytes)."
say "This can take a few minutes. Please wait..."
run_t 600 copy_jxe cp "$JXE_UNIT" "$JXE_CARD"
sync
say "checking the copy..."
H_JU=$(sha1_of "$JXE_UNIT")
H_JC=$(sha1_of "$JXE_CARD")
echo "${H_JU:-none} unit /ifs/lsd.jxe" >> "$OUT/sha1.txt"
echo "${H_JC:-none} card $JXE_CARD" >> "$OUT/sha1.txt"
sync

# ------------------------------------------------------------- short summary on screen
say ""
say "train:          ${TRAIN:-(not found)}"
say "lsd.sh:         $(size_of "$R$L/lsd.sh") bytes  sha1 ${H_LSD:-?}"
if same "$H_LSD" "$H_LSDC"; then say "lsd.sh copy:    verified"; else say "lsd.sh copy:    NOT verified"; fi
if same "$H_JU" "$H_JC"; then say "lsd.jxe copy:   verified"; else say "lsd.jxe copy:   NOT verified"; fi
if [ -e "$R$L/jars/NavActiveIgnore.jar" ]; then
    say "NavActiveIgnore.jar: ALREADY PRESENT"
else
    say "NavActiveIgnore.jar: not present"
fi
if grep 'Xbootclasspath/p' "$R$L/lsd.sh" > /dev/null 2>&1; then
    say "lsd.sh:         already has a bootclasspath/p line"
else
    say "lsd.sh:         no bootclasspath/p line (stock)"
fi
say ""
say "DONE: $OUT"
say "Nothing on the unit was changed."
say "Take the card to the PC."
