#!/bin/bash
# Download the files this kit builds on from joeyQuery/MHI2-altScreen (GPL-3.0-or-later)
# at a pinned commit, and check each against a pinned SHA-256.
# usage: bash tools/fetch_upstream.sh            -> inputs/
set -eu
W=$(cd "$(dirname "$0")/.." && pwd)
COMMIT=6ff7ca40107fb27126fef7fb0c5023252d610871
BASE=https://raw.githubusercontent.com/joeyQuery/MHI2-altScreen/$COMMIT
mkdir -p "$W/inputs"

fetch() {   # fetch <path in upstream> <local name> <sha256>
    out=$W/inputs/$2
    curl -fsSL "$BASE/$1" -o "$out.part"
    got=$(sha256sum "$out.part" | cut -d' ' -f1)
    if [ "$got" != "$3" ]; then
        rm -f "$out.part"
        echo "REFUSING: $1 sha256 $got != pinned $3" >&2
        exit 1
    fi
    mv -f "$out.part" "$out"
    echo "ok  $2"
}

fetch artifacts/mu0678/r60/libaltscreen111.so libaltscreen111.so 2ce451a472ea98e09971db34f75099dcfd20c0ce5d554df9f9f69755cc5f9ddb
fetch artifacts/mu0678/r60/vc_render          vc_render          a28ca6975e21105c721f673aa95926d7fb3c22789ac0d196bb8978afb1c35198
fetch tools/make_patched_carplay_json.py      make_patched_carplay_json.py c6fa1e5f572fb2a093bfb663b9579b5c58a7ffd84001b602a0731e3ffee3d8f5
echo "Upstream source for these binaries: https://github.com/joeyQuery/MHI2-altScreen/tree/$COMMIT/src"
