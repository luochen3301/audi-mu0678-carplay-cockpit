#!/bin/sh
# command.sh - entry point for M.I.B. V3.6 and later.
# Their "Advanced Settings -> Run individual script" runs /mod/command.sh;
# older M.I.B. runs /mod/custom.sh directly. This only hands over to
# custom.sh beside it, so both menu items do the same thing.

case $0 in
    */*) SELF_DIR=${0%/*} ;;
    *)   SELF_DIR=. ;;
esac

if [ ! -f "$SELF_DIR/custom.sh" ]; then
    echo "!! custom.sh not found next to command.sh ($SELF_DIR)."
    echo "!! Copy both files into /mod/ on the M.I.B. SD card."
    exit 1
fi

exec sh "$SELF_DIR/custom.sh"
