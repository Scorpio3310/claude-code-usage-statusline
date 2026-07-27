#!/usr/bin/env bash
# One-command installer for the Claude Code usage statusline.
#   npx claude-usage-statusline            install (first run opens the configurator)
#   npx claude-usage-statusline --update   update the installed script, keep the config
#   bash install.sh                        same, from a clone
set -euo pipefail

command -v python3 >/dev/null 2>&1 || {
  echo "❌ python3 is required (the statusline script uses it to parse/format). Install it and re-run."
  exit 1
}

# npx runs this through a node_modules/.bin symlink — resolve to the real package dir.
SELF="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${BASH_SOURCE[0]}")"
HERE="$(cd "$(dirname "$SELF")" && pwd)"
SRC="$HERE/statusline-usage.sh"
DEST_DIR="$HOME/.claude"
DEST="$DEST_DIR/statusline-usage.sh"
SETTINGS="$DEST_DIR/settings.json"

ver() { sed -n 's/^export STATUSLINE_VERSION="\(.*\)"/\1/p' "$1" 2>/dev/null | head -1; }
NEW_VER="$(ver "$SRC")"

if [ "${1:-}" = "--update" ]; then
  OLD_VER="$(ver "$DEST")"
  mkdir -p "$DEST_DIR"
  cp "$SRC" "$DEST"
  chmod +x "$DEST"
  echo "✓ updated $DEST (v${OLD_VER:-?} → v${NEW_VER:-?})"
  echo "  Config and settings untouched. Open a NEW Claude Code session to pick it up."
  exit 0
fi

mkdir -p "$DEST_DIR"
cp "$SRC" "$DEST"
chmod +x "$DEST"
echo "✓ installed script v${NEW_VER:-?} → $DEST"

python3 - "$SETTINGS" "$DEST" <<'PY'
import json, os, shutil, sys
settings, script = sys.argv[1], sys.argv[2]
d = {}
if os.path.exists(settings):
    try:
        d = json.load(open(settings))
    except Exception:
        d = {}
existing = d.get("statusLine")
if existing and existing.get("command") != script:
    print("⚠ You already have a different statusLine configured:")
    print("   ", json.dumps(existing))
    print("   Leaving it untouched (no backup written). To use this one, set")
    print("    statusLine.command to:", script)
else:
    # Back up only when we are about to modify the file — a no-op re-install
    # must not clobber the previous backup.
    if os.path.exists(settings) and existing != {"type": "command", "command": script, "padding": 1}:
        shutil.copy(settings, settings + ".bak")
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
echo "Tip: re-run the editor any time with  bash $DEST --configure"
echo "     bash $DEST --preview     # every theme, rendered with sample data"
echo "     bash $DEST --doctor      # check config, caches, token, glyphs"
echo "     bash $DEST --report      # per-day spend by model (--json / --csv)"
echo "     bash $DEST --save-preset work   # snapshot configs, switch with --preset"
echo "     or override a single setting for one session, e.g."
echo "       export CLAUDE_USAGE_STYLE=full      # adaptive | full | compact"
echo "       export CLAUDE_USAGE_THRESHOLD=75"
echo "       export CLAUDE_USAGE_REMOTE=1        # Fable 5 meter + usage credits"
