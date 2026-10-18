#!/bin/bash
# Runs on the ProPresenter Mac and takes files from Sermon Captions on other
# Macs. It's the only command their key may run (a "command=" entry in
# ~/.ssh/authorized_keys), so all a copy of the app can do there is:
#   check                       -> "ok <free KB>"
#   upload SIZE NAME            -> a finished video (stdin) into Movies/Spanish sermons
#   upload-to SIZE FOLDER/NAME  -> a trimmed video or its captions into
#                                  Movies/Sermon Captions/FOLDER, to finish there
set -euo pipefail
cmd="${SSH_ORIGINAL_COMMAND:-}"

# A plain name: no folders, not hidden, nothing unprintable.
plain() { [[ -n "$1" && "$1" != */* && "$1" != .* && "$1" != *[[:cntrl:]]* ]]; }

# save DIR SHOWN NAME SIZE: stdin into DIR/NAME through a temporary file of
# its own (so two copies arriving at once can't mix), checking the size.
save() {
  mkdir -p "$1"
  part=$(mktemp "$1/.upload.XXXXXX")
  trap 'rm -f "$part"' EXIT
  cat > "$part"
  chmod 644 "$part"
  got=$(stat -f %z "$part")
  [ "$got" = "$4" ] || { echo "only got $got of $4 bytes" >&2; exit 3; }
  mv -f "$part" "$1/$3"
  echo "saved $2/$3"
}

case "$cmd" in
  check)
    mkdir -p "$HOME/Movies/Spanish sermons"
    echo "ok $(df -k "$HOME/Movies" | awk 'NR==2 {print $4}')"
    ;;
  "upload "*)
    rest="${cmd#upload }"
    size="${rest%% *}"
    name="${rest#* }"
    [[ "$size" =~ ^[0-9]+$ ]] || { echo "bad size" >&2; exit 2; }
    plain "$name" && [[ "$name" == *.mp4 ]] || { echo "bad name" >&2; exit 2; }
    save "$HOME/Movies/Spanish sermons" "Movies/Spanish sermons" "$name" "$size"
    ;;
  "upload-to "*)
    rest="${cmd#upload-to }"
    size="${rest%% *}"
    path="${rest#* }"
    folder="${path%%/*}"
    name="${path#*/}"
    [[ "$size" =~ ^[0-9]+$ ]] || { echo "bad size" >&2; exit 2; }
    shopt -s nocasematch   # .MOV from some exports
    plain "$folder" && plain "$name" && [[ "$name" =~ \.(mp4|mov|m4v|srt)$ ]] \
      || { echo "bad name" >&2; exit 2; }
    shopt -u nocasematch
    save "$HOME/Movies/Sermon Captions/$folder" "Movies/Sermon Captions/$folder" "$name" "$size"
    ;;
  *)
    echo "not allowed" >&2
    exit 1
    ;;
esac
