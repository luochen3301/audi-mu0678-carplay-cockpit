#!/bin/sh
# command.sh - entry point for M.I.B. V3.6 and later.
# Their "Advanced Settings -> Run individual script" runs /mod/command.sh.
# This only hands over to one package on this card, chosen by the first
# word of the file mod/RUN:
#   no RUN file, empty, or "altscreen"  -> mod/custom.sh  (CarPlay map installer)
#   "navignore-collect"                 -> mod/navignore/collect.sh  (read-only)
#   "navignore"                         -> mod/navignore/navignore.sh
#   "zoom-collect"                      -> mod/zoom/collect.sh  (read-only)
#   "zoom"                              -> mod/zoom/zoom.sh
# Anything else stops without running anything.

case $0 in
    */*) SELF_DIR=${0%/*} ;;
    *)   SELF_DIR=. ;;
esac

RUN=
if [ -f "$SELF_DIR/RUN" ]; then
    read -r RUN _ < "$SELF_DIR/RUN"
fi
RUN=${RUN%%[!A-Za-z0-9_-]*}     # drop a CR or anything else odd

case $RUN in
    ''|altscreen)      S=$SELF_DIR/custom.sh ;;
    navignore-collect) S=$SELF_DIR/navignore/collect.sh ;;
    navignore)         S=$SELF_DIR/navignore/navignore.sh ;;
    zoom-collect)      S=$SELF_DIR/zoom/collect.sh ;;
    zoom)              S=$SELF_DIR/zoom/zoom.sh ;;
    *)
        echo "!! mod/RUN says '$RUN': no such package on this card."
        echo "!! Nothing was run."
        exit 1 ;;
esac

if [ ! -f "$S" ]; then
    echo "!! $S not found on the card."
    echo "!! Nothing was run."
    exit 1
fi

exec sh "$S"
