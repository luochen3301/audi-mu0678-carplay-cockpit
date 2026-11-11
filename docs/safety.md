# How the installers protect the unit

The head unit runs QNX 6.5; its `/bin/sh` is pdksh with no `printf`, `find`, `dirname` or `cmp`, so the scripts use only
plain POSIX shell, `cp`, `mv`, `chmod`, `mount`, `grep` and the unit's `sha1sum`.

## Rules every installer follows

1. **Check everything before writing anything.** Firmware train (`CachedTrain.txt`), SHA-1 of every OEM file the change
   depends on, SHA-1 of every payload file on the card, and whatever already sits at each target path. Any mismatch stops
   the run with `!! STOPPED. Nothing on the unit was changed.`
2. **A self-tested hash tool.** The first `sha1sum` that reproduces a known hash of a file on the card is used; if none
   does, install and uninstall refuse to run.
3. **Copy → verify → rename → verify.** Each file is written as a temporary file, hashed, renamed into place on the same
   filesystem, and hashed again. A failed step removes the temporary file.
4. **The switch comes last, and goes first.** The CarPlay map installer rewrites `smartphone_integrator.json` (the only
   thing that makes the hook load) as its very last step; uninstall restores it first. The dual-navigation jar is copied
   to `lsd/` and only renamed into `lsd/jars/` (the folder the HMI loads) after it verified, so a half-written jar is never
   picked up.
5. **Honest stop messages.** If a run stops after writing, the message says exactly what is now in place.
6. **Known older versions only.** An upgrade replaces a file only if its hash is listed in `UPGRADE`; anything unknown at a
   target path stops the install, and uninstall leaves unknown files where they are.
7. **Logs on the card.** Every run writes `log.txt` plus read-only status output to `<card>/<package>_logs/NNN-<action>/`.
8. **Collectors are read-only.** They never remount `/mnt/app` or `/mnt/system` writable and only write to the SD card.

## Tests (`tests/`)

| Suite | What it does |
|---|---|
| `run_tests.sh` | CarPlay map installer on a simulated unit built from the collected files: 25 scenarios (install, repeat, v1 → v1.1 upgrade, uninstall, refusals, mid-way failures, unknown files) |
| `test_r25_script.sh <hook> <dir>` | Extracts the autostart script embedded in a hook binary and runs it against recorder stubs (shows the v1.1 behaviour change) |
| `test_navignore.sh` | Dual-navigation installer with the real `lsd.sh`/`lsd.jxe`: 21 scenarios / 112 checks, including running the stock `lsd.sh` to show the jar lands on the boot class path right before `lsd.jxe` and nothing else changes |
| `test_class_check.sh` | Proves `tools/jxe/check_override.py` rejects incompatible classes (missing/renamed members, changed signatures, static-ness, narrowed access, wrong superclass, unresolvable references) |
| `test_navignore_collect.sh`, `test_zoom_collect.sh` | Dispatcher (`mod/command.sh`) and the read-only collectors |

Suites run the scripts under `dash` and `bash`. Mutation runs (removing each safety check in turn) were used to make sure
the suites catch every removed check.

## Network exposure (DSITracer, for the zoom work)

The unit's packet filter (`/etc/pf.conf`) passes the tracer ports 1797/1798/20991 only on loopback and the internal
MMX↔RCC link; WLAN, mobile data and the CarPlay USB link drop them. Port 1800 (tracer "client" appender) is passed on the
debug USB-Ethernet interface `en0`, which on a stock unit already passes telnet; the planned zoom configuration does not
enable that appender.
