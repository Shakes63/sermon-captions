#!/bin/bash
# Runs on the ProPresenter Mac and takes finished videos from Sermon Captions
# on other Macs. It's the only command their key may run (a "command=" entry
# in ~/.ssh/authorized_keys), so all a copy of the app can do there is:
#   check              -> "ok <free KB>"
#   upload SIZE NAME   -> the video on stdin, saved into $DEST as NAME
set -euo pipefail
DEST="$HOME/Movies/Spanish sermons"
SHOW="Movies/Spanish sermons"
mkdir -p "$DEST"
cmd="${SSH_ORIGINAL_COMMAND:-}"
case "$cmd" in
  check)
    echo "ok $(df -k "$DEST" | awk 'NR==2 {print $4}')"
    ;;
  "upload "*)
    rest="${cmd#upload }"
    size="${rest%% *}"
    name="${rest#* }"
    [[ "$size" =~ ^[0-9]+$ ]] || { echo "bad size" >&2; exit 2; }
    # A plain file name ending in .mp4: no folders, no hidden files, nothing unprintable.
    if [[ "$name" == */* || "$name" == .* || "$name" != *.mp4 || "$name" == *[[:cntrl:]]* ]]; then
      echo "bad name" >&2
      exit 2
    fi
    # Its own temporary file, so two copies arriving at once can't mix.
    part=$(mktemp "$DEST/.upload.XXXXXX")
    trap 'rm -f "$part"' EXIT
    cat > "$part"
    chmod 644 "$part"
    got=$(stat -f %z "$part")
    [ "$got" = "$size" ] || { echo "only got $got of $size bytes" >&2; exit 3; }
    mv -f "$part" "$DEST/$name"
    echo "saved $SHOW/$name"
    ;;
  *)
    echo "not allowed" >&2
    exit 1
    ;;
esac
