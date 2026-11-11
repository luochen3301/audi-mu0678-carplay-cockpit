# Credits and third-party material

| What | From | License / terms | In this repo? |
|---|---|---|---|
| CarPlay alt-screen hook (r60), `vc_render`, safe-area values, `make_patched_carplay_json.py`, the research this kit relies on | [joeyQuery/MHI2-altScreen](https://github.com/joeyQuery/MHI2-altScreen) (itself ported from `harman-f/mhi2_altscreen_carplay`) | GPL-3.0-or-later | No — downloaded at a pinned commit by `tools/fetch_upstream.sh` and checked by SHA-256 |
| v1.1 hook | 3 bytes changed in the r60 hook by `tools/make_hook_v11.py` (corresponding source: upstream `src/gen2-audi/` at the pinned commit; the change is the two strings documented in that script) | GPL-3.0-or-later | No — generated locally |
| `NavActiveIgnore.jar` (`navignore_audi.jar`) | [M.I.B. – More Incredible Bash](https://github.com/Mr-MIBonk/M.I.B._More-Incredible-Bash) V3.6.0, based on work from [jilleb/mib2-toolbox#189](https://github.com/jilleb/mib2-toolbox/pull/189) | M.I.B. terms ("not for commercial use") | No — copy it from your own M.I.B. card |
| M.I.B. itself (launcher, green-menu scripts) | M.I.B. | M.I.B. terms | No |
| Head-unit firmware files (`lsd.jxe`, `lsd.sh`, `libairplay.so`, configuration files) | Audi / Volkswagen Group / Harman | proprietary | No — collected from your own unit, kept in the git-ignored `car-data/` |

Card detection, MMX forwarding and the time-limit pattern in the shell scripts follow
`luka-dev/mib2q-carplay-rgi` and `chefranov/mhi2-au37x-carplay`, as noted in the scripts.

This project is not affiliated with, sponsored by, or endorsed by Audi AG, Volkswagen AG, Harman, Apple or the M.I.B. team.
Product names belong to their owners.
