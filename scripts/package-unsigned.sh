#!/bin/sh
# Developer-only zip. Not for Reddit. Gatekeeper will reject this unless the
# recipient removes quarantine: xattr -dr com.apple.quarantine "Lots of Agents.app"
set -euo pipefail
cd "$(dirname "$0")/.."

# Keep AppleDouble `._*` resource-fork sidecars out of the archive. ditto
# otherwise stores xattrs as `._*` members, and those files show up after unzip.
export COPYFILE_DISABLE=1

./scripts/build-app.sh

ZIP="dist/Lots-of-Agents-unsigned.zip"
rm -f "$ZIP"

cat > dist/README-DEVELOPERS.txt <<'TXT'
Lots of Agents — developer build (NOT notarized)

Gatekeeper will block this app. That is expected.

  xattr -dr com.apple.quarantine "Lots of Agents.app"
  open "Lots of Agents.app"

Do not post this zip as the public download. Strangers need the stapled DMG
from GitHub Releases after ./scripts/notarize.sh.

This archive does not contain Grok Bot.app or Cursor.app. Install those
from Anysphere first.
TXT

# --norsrc: do not pack resource forks / FinderInfo as AppleDouble members.
ditto -c -k --keepParent --norsrc "dist/Lots of Agents.app" "$ZIP"

if command -v zipinfo >/dev/null 2>&1; then
  if zipinfo -1 "$ZIP" | grep -E '(^|/)\._|__MACOSX' >/dev/null; then
    echo "error: $ZIP still contains AppleDouble or __MACOSX entries" >&2
    zipinfo -1 "$ZIP" | grep -E '(^|/)\._|__MACOSX' >&2 || true
    exit 1
  fi
fi

# Also tuck the readme next to the zip, not inside the .app.
echo "Wrote $ZIP"
echo "This is developers-only. Do not Reddit this file."
