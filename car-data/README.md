# car-data/ (stays on your PC — git-ignored)

Put the folders the read-only collectors write to the SD card here. They contain OEM firmware files and data from your
own unit, so **never commit or publish them** (`.gitignore` excludes everything here except this file).

| Folder | From the card | Used by |
|---|---|---|
| `altscreen_collect/001/` | `altscreen_collect/001` (step 1, `sd-collect/`) | `tools/check_collect.py`, `tools/build_install_package.py`, `tests/run_tests.sh` |
| `navignore_collect/001/` | `navignore_logs/001-collect` (`mod/RUN` = `navignore-collect`) | `tools/build_navignore_package.py`, `tests/test_navignore.sh`, `tests/test_class_check.sh` |
| `zoom_collect/001/` | `zoom_logs/001-collect` (`mod/RUN` = `zoom-collect`) | zoom work (in progress) |
| `mib-backup/` | M.I.B. backup folder | keep it safe; it holds EEPROM, FEC and password files |
