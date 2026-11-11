#!/bin/bash
# Behaviour test of the r25 autostart shell script embedded in the hook.
# usage: bash tests/test_r25_script.sh <hook.so> <workdir>   -> prints the event trace per scenario
# The script is extracted from the binary itself, its absolute paths are redirected into a
# sandbox, and every car command (pidin, on, sloginfo, dmdt, sleep, touch) is a recorder.
set -u
HOOK=$1; T=$2
rm -rf "${T:?}"; mkdir -p "$T/bin" "$T/tmp"

# extract: from "R=/mnt/app/root/vc_render;" to the terminating NUL
python -I - "$HOOK" "$T/r25.sh" "$T" <<'EOF'
import sys
data = open(sys.argv[1], "rb").read()
start = data.index(b"R=/mnt/app/root/vc_render;")
assert data.count(b"R=/mnt/app/root/vc_render;") == 1
end = data.index(b"\0", start)
s = data[start:end].decode()
t = sys.argv[3]
s = s.replace("%d", "542")
s = s.replace("/mnt/app/root/vc_render", t + "/bin/vc_render")
s = s.replace("/eso/bin/apps/dmdt", t + "/bin/dmdt")
s = s.replace("/tmp/", t + "/tmp/")
open(sys.argv[2], "w", newline="\n").write(s + "\n")
EOF

ev="$T/events.log"
mk() { printf '#!/bin/sh\n%s\n' "$2" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }
mk pidin    'exit 0'
mk on       "echo \"on \$*\" >> $ev"
mk dmdt     "echo \"dmdt \$*\" >> $ev"
mk sleep    "echo \"sleep \$*\" >> $ev"
mk touch    "echo \"touch \${1##*/}\" >> $ev; /usr/bin/touch \"\$1\""
mk vc_render 'exit 0'
# sloginfo prints N NavState lines; N comes from the Nth line of $T/navseq (last line repeats)
mk sloginfo "n=\$(cat $T/navcalls 2>/dev/null || echo 0); n=\$((n+1)); echo \$n > $T/navcalls
c=\$(sed -n \"\${n}p\" $T/navseq); [ -n \"\$c\" ] || c=\$(tail -n 1 $T/navseq)
i=0; while [ \$i -lt \$c ]; do echo 'x Change NavStateOfOperation to 5'; i=\$((i+1)); done"

run() {   # run <name> <navseq...> ; uses $SPAWN/$TEAR for the phone-present gate
    name=$1; shift
    : > "$ev"; rm -f "$T/navcalls" "$T/tmp/mibr-alt111-gen2-reacquire"
    printf '%s\n' "$@" > "$T/navseq"
    : > "$T/tmp/altscreen111.log"
    i=0; while [ $i -lt $SPAWN ]; do echo "r25-autostart: spawn" >> "$T/tmp/altscreen111.log"; i=$((i+1)); done
    i=0; while [ $i -lt $TEAR ]; do echo "TEARDOWN entry request=NULL" >> "$T/tmp/altscreen111.log"; i=$((i+1)); done
    PATH="$T/bin:$PATH" dash "$T/r25.sh"
    wait
    echo "[$name] $(grep -v '^on ' "$ev" | sed 's/ >>.*//' | tr '\n' ';')"
}

SPAWN=1; TEAR=0
run "A nav ready at start"            2
run "B nav ready after 1 wait"        1 1 2
SPAWN=1; TEAR=1
run "C phone already gone (gate)"     2
