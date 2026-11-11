#!/bin/bash
# Runs every test suite. A suite that needs private files you have not supplied
# (car-data/, inputs/, build/) is reported as SKIP, not as a failure.
# usage: bash tests/run_all.sh [workdir]
set -u
W=$(cd "$(dirname "$0")/.." && pwd)
T=${1:-${TMPDIR:-/tmp}/mhi2-sdkit-tests}
mkdir -p "$T"
pass=0; fail=0; skip=0
for t in test_navignore_collect test_zoom_collect run_tests test_navignore test_class_check; do
    for sh in dash bash; do
        case $t in run_tests|test_class_check) [ $sh = bash ] && continue ;; esac
        SUT_SHELL=$sh bash "$W/tests/$t.sh" "$T/$t-$sh" > "$T/$t-$sh.log" 2>&1; rc=$?
        last=$(tail -1 "$T/$t-$sh.log")
        case $rc in
            0)  pass=$((pass+1)); echo "PASS  $t ($sh)  $last" ;;
            77) skip=$((skip+1)); echo "SKIP  $t  $last"; break ;;
            *)  fail=$((fail+1)); echo "FAIL  $t ($sh)  $last  (log: $T/$t-$sh.log)" ;;
        esac
    done
done
echo "suites: $pass passed, $fail failed, $skip skipped"
[ $fail -eq 0 ]
