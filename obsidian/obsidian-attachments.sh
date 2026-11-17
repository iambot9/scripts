#!/bin/bash
# Tidy an Obsidian vault on macOS:
#   1. create an "attachments" folder in the vault
#   2. move "Pasted image *.png" files from the vault root into it
#   3. set that folder as the default location for new attachments
#
# Usage: ./obsidian-attachments.sh [/path/to/vault]
# With no path, the vault is detected from Obsidian's own vault list
# (only works when exactly one vault is registered).

set -euo pipefail

FOLDER="attachments"
VAULT_LIST="$HOME/Library/Application Support/obsidian/obsidian.json"

json() { /usr/bin/osascript -l JavaScript -e "$1" "${@:2}"; }

# --- find the vault ---------------------------------------------------------
if [ $# -ge 1 ]; then
  VAULT="${1%/}"
else
  [ -f "$VAULT_LIST" ] || { echo "No vault path given and $VAULT_LIST not found." >&2; exit 1; }
  VAULTS=$(json 'function run(a){ObjC.import("Foundation");
    const s=$.NSString.stringWithContentsOfFileEncodingError(a[0],4,null).js;
    return Object.values(JSON.parse(s).vaults||{}).map(v=>v.path).join("\n");}' "$VAULT_LIST")
  if [ "$(printf '%s\n' "$VAULTS" | grep -c .)" -ne 1 ]; then
    echo "Found these vaults; pass one as an argument:" >&2
    printf '%s\n' "$VAULTS" | sed 's/^/  /' >&2
    exit 1
  fi
  VAULT="$VAULTS"
fi

[ -d "$VAULT/.obsidian" ] || { echo "Not an Obsidian vault: $VAULT" >&2; exit 1; }

# Obsidian can overwrite app.json with its in-memory settings, so it must be closed.
if [ -z "${SKIP_RUNNING_CHECK:-}" ] && pgrep -xq Obsidian; then
  echo "Quit Obsidian first, then run this again." >&2
  exit 1
fi

echo "Vault: $VAULT"

# --- move existing pasted screenshots ---------------------------------------
mkdir -p "$VAULT/$FOLDER"
moved=0
for f in "$VAULT"/Pasted\ image\ *.png; do
  [ -e "$f" ] || continue
  if [ -e "$VAULT/$FOLDER/$(basename "$f")" ]; then
    echo "  skipped (already exists in $FOLDER): $(basename "$f")"
    continue
  fi
  mv "$f" "$VAULT/$FOLDER/"
  moved=$((moved + 1))
done
echo "Moved $moved pasted image(s) into $FOLDER/"

# --- point new attachments at the folder ------------------------------------
APP="$VAULT/.obsidian/app.json"
[ -f "$APP" ] && cp "$APP" "$APP.bak"
json 'function run(a){ObjC.import("Foundation");
  const fm=$.NSFileManager.defaultManager; let o={};
  if(fm.fileExistsAtPath(a[0])){
    const s=$.NSString.stringWithContentsOfFileEncodingError(a[0],4,null).js;
    if(s.trim()) o=JSON.parse(s);
  }
  o.attachmentFolderPath=a[1];
  $(JSON.stringify(o,null,2)+"\n").writeToFileAtomicallyEncodingError(a[0],true,4,null);
}' "$APP" "$FOLDER"
echo "Set default attachment location to \"$FOLDER\" (backup: app.json.bak)"

# --- warn about links that would not survive the move -----------------------
if grep -rlE '!\[\[[^]|]*/Pasted image|!\[[^]]*\]\([^)]*Pasted(%20| )image' --include='*.md' "$VAULT" >/dev/null 2>&1; then
  echo "Note: some notes link to pasted images by path; check those embeds still show."
fi
echo "Done. Reopen Obsidian."
