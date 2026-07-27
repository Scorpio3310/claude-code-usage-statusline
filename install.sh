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

# Ask what to show. Falls back to writing defaults when there's no terminal
# (piped installs, CI), so this never blocks an unattended run.
if [ -f "$HOME/.claude/statusline-usage.conf" ]; then
  echo "✓ keeping existing config → $HOME/.claude/statusline-usage.conf"
  echo "  (change it with: bash $DEST --configure)"
else
  bash "$DEST" --configure
fi

echo
echo "Done. Open a NEW Claude Code session to see the usage statusline."
echo "Tip: re-run the picker any time with  bash $DEST --configure"
echo "     bash $DEST --doctor      # check config, caches, token, glyphs"
echo "     bash $DEST --report      # per-day spend by model (--json / --csv)"
echo "     or override a single setting for one session, e.g."
echo "       export CLAUDE_USAGE_STYLE=full      # adaptive | full | compact"
echo "       export CLAUDE_USAGE_THRESHOLD=75"
echo "       export CLAUDE_USAGE_REMOTE=1        # Fable 5 meter + usage credits"
