#!/usr/bin/env bash
# One-command installer for the Claude Code usage statusline.
# Run this on any machine that has Claude Code:  bash install.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/statusline-usage.sh"
DEST_DIR="$HOME/.claude"
DEST="$DEST_DIR/statusline-usage.sh"
SETTINGS="$DEST_DIR/settings.json"

command -v python3 >/dev/null 2>&1 || {
  echo "❌ python3 is required (the statusline script uses it to parse/format). Install it and re-run."
  exit 1
}

mkdir -p "$DEST_DIR"
cp "$SRC" "$DEST"
chmod +x "$DEST"
echo "✓ installed script → $DEST"

python3 - "$SETTINGS" "$DEST" <<'PY'
import json, os, shutil, sys
settings, script = sys.argv[1], sys.argv[2]
d = {}
if os.path.exists(settings):
    try:
        d = json.load(open(settings))
    except Exception:
        d = {}
    shutil.copy(settings, settings + ".bak")  # backup existing
existing = d.get("statusLine")
if existing and existing.get("command") != script:
    print("⚠ You already have a different statusLine configured:")
    print("   ", json.dumps(existing))
    print("   Leaving it untouched. To use this one, set statusLine.command to:")
    print("   ", script)
else:
    d["statusLine"] = {"type": "command", "command": script, "padding": 1}
    with open(settings, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
    print("✓ registered statusLine in", settings)
    if os.path.exists(settings + ".bak"):
        print("  (backup saved as settings.json.bak)")
PY

echo
echo "Done. Open a NEW Claude Code session to see the usage statusline."
echo "Tip: override the alert threshold with  export CLAUDE_USAGE_THRESHOLD=75"
