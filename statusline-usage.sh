#!/usr/bin/env bash
# Claude Usage Monitor — Claude Code statusline.
#
# Line 1: what's close to a limit — model, rate-limit meters, context, git, timer.
# Line 2: what it costs — this session, today (per model), this month, usage credits,
#         burn rate, and up to two warnings. (Fold into one line with LINES=1.)
#
# Claude Code only hands the statusline cost.total_cost_usd for the CURRENT session, so
# "today"/"month" are reconstructed from the token usage recorded in the transcripts under
# ~/.claude/projects/*/*.jsonl, priced at published API rates (hence "≈"). Transcripts are
# append-only, so the cache keeps a byte offset per file and each render parses only the
# tail — a 65 MB session transcript costs ~5 ms instead of ~500 ms.
#
# The Fable 5 meter and usage-credit balance are OFF unless REMOTE=1: Claude Code only puts
# five_hour and seven_day in the payload, so those come from the endpoint /usage reads.
# That fetch (and the git dirty count) run detached in the background — a render never
# blocks — read your existing OAuth token, never refresh it, and fail silently.
#
# Configure with:  bash statusline-usage.sh --configure     (wizard, with live previews)
# Preview a theme: bash statusline-usage.sh --preview boxed
# Config file:     ~/.claude/statusline-usage.conf          (env CLAUDE_USAGE_* overrides)

CONF_PATH="${CLAUDE_USAGE_CONF:-$HOME/.claude/statusline-usage.conf}"

PY=$(cat <<'PYEOF'
import sys, json, time, os, glob, tempfile, re, unicodedata
from datetime import datetime, timezone, timedelta

HOME = os.path.expanduser("~/.claude")
_MODE = os.environ.get("USAGE_MODE", "render")

if _MODE in ("render", "preview"):
    try:
        d = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
else:
    d = {}                                    # doctor/report don't read a payload

# ---- configuration ------------------------------------------------------------
# Everything the renderer needs is derived from one flat dict of strings, so the same
# code path serves env+file rendering AND the live TUI (which mutates the dict and
# re-applies it on every keystroke).
CONF_PATH_PY = os.environ.get("CLAUDE_USAGE_CONF") or os.path.join(HOME, "statusline-usage.conf")

DEFAULTS = {
    "THEME": "plain", "PALETTE": "default", "LINES": "2", "STYLE": "adaptive",
    "THRESHOLD": "80", "NOTICE": "50",
    "SEGMENTS": "model,effort,5h,7d,quota,budget,ctx,time",
    "LINE2": "session,today,models,month,eom,credits,warn",
    "GIT": "branch", "REMOTE": "0", "NOTIFY": "off", "REMOTE_DEBUG": "0",
    "ICONS": "unicode", "RULE": "0", "BAR": "theme", "BARW": "8",
    "BUDGET_MONTH": "0", "BUDGET_DAY": "0", "CMD": "", "CMD_TTL": "30",
    "BAR_HEAT": "0",
}
ENV_ALIASES = {"REMOTE": ("FABLE",), "REMOTE_DEBUG": ("FABLE_DEBUG",)}

def _load_conf_file(path=None):
    conf = {}
    try:
        with open(path or CONF_PATH_PY) as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                conf[k.strip().upper()] = v.strip().strip('"').strip("'")
    except Exception:
        pass
    return conf

def effective_conf():
    # env (CLAUDE_USAGE_*) > conf file > defaults
    out = dict(DEFAULTS)
    for k, v in _load_conf_file().items():
        if k in out and v:
            out[k] = v
    for k in out:
        for name in (k,) + ENV_ALIASES.get(k, ()):
            v = os.environ.get("CLAUDE_USAGE_" + name)
            if v:
                out[k] = v
                break
    return out

# ---- themes ---------------------------------------------------------------------
# A segment is data ({key, text, color, suffix, prio}); the theme decides how to paint
# it. Three modes: "sep" joins painted text with a separator, "joined" is a powerline
# train (arrow between blocks), "pills" wraps every segment in its own block.
THEMES = {
    "plain":     {"mode": "sep", "sep": "  ",  "open": "",   "close": "",
                  "bar": ("▉", "░"), "icons": "unicode", "color": True,  "pad": False},
    "boxed":     {"mode": "sep", "sep": " │ ", "open": "│ ", "close": " │",
                  "bar": ("▰", "▱"), "icons": "unicode", "color": True,  "pad": True},
    "frame":     {"mode": "sep", "sep": " · ", "open": "│ ", "close": " │",
                  "bar": ("▰", "▱"), "icons": "unicode", "color": True,  "pad": True,
                  "frame": True},
    "dots":      {"mode": "sep", "sep": " · ", "open": "",   "close": "",
                  "bar": ("▰", "▱"), "icons": "unicode", "color": True,  "pad": False},
    "mono":      {"mode": "sep", "sep": " | ", "open": "",   "close": "",
                  "bar": ("#", "-"), "icons": "none",    "color": False, "pad": False},
    "powerline": {"mode": "joined", "arrow": "", "thin": "",
                  "arrow_alt": "▶", "thin_alt": "›",
                  "bar": ("▰", "▱"), "icons": "nerd",    "color": True,  "pad": False},
    "slant":     {"mode": "joined", "arrow": "", "thin": "",
                  "arrow_alt": "▶", "thin_alt": "›",
                  "bar": ("▰", "▱"), "icons": "nerd",    "color": True,  "pad": False},
    "capsule":   {"mode": "pills", "lcap": "", "rcap": "",
                  "lcap_alt": "▐", "rcap_alt": "▌",
                  "bar": ("▰", "▱"), "icons": "nerd",    "color": True,  "pad": False},
    "badge":     {"mode": "pills", "lcap": "", "rcap": "",
                  "bar": ("▰", "▱"), "icons": "unicode", "color": True,  "pad": False},
}

ICONS = {
    "unicode": {"model": "⚡", "git": "⑂", "dir": "📁", "time": "⏱",
                "search": "🔍", "warn": "⚠", "pr": "#", "fast": "⚡"},
    "nerd":    {"model": "", "git": "", "dir": "", "time": "",
                "search": "", "warn": "", "pr": "", "fast": ""},
    "none":    {"model": "", "git": "", "dir": "", "time": "", "search": "",
                "warn": "!", "pr": "#", "fast": ""},
}

# Palettes remap the hues, never the meaning: the green-amber-red scale stays a scale.
PALETTES = {
    "default": {"red": 203, "amber": 214, "green": 114, "brand": 209, "money": 150,
                "dim": 245, "purple": 141, "blue": 75,  "tan": 180},
    "ocean":   {"red": 203, "amber": 179, "green": 80,  "brand": 39,  "money": 116,
                "dim": 244, "purple": 111, "blue": 45,  "tan": 109},
    "sunset":  {"red": 196, "amber": 208, "green": 150, "brand": 173, "money": 179,
                "dim": 245, "purple": 168, "blue": 132, "tan": 137},
    "forest":  {"red": 167, "amber": 178, "green": 71,  "brand": 107, "money": 108,
                "dim": 243, "purple": 139, "blue": 66,  "tan": 144},
}

# Meter bar styles — an axis of their own; "theme" keeps each theme's native pair.
BARS = {"boxes": ("▉", "░"), "slant": ("▰", "▱"), "shade": ("█", "▒"),
        "line": ("━", "╌"), "dots": ("●", "○"), "mini": ("▪", "▫"),
        "bars": ("▮", "▯"), "ascii": ("#", "-"), "dot": None}   # dot = one ● only

def apply_config(conf):
    """Derive every renderer setting from a flat dict of strings."""
    global THEME_NAME, PALETTE, T, IC, STYLE, LINES, GIT, TH, NOTICE, SEGS, LINE2
    global REMOTE, RDEBUG, NOTIFY
    global C_RED, C_AMBER, C_GREEN, C_BRAND, C_MONEY, C_DIM, C_PURPLE, C_BLUE, C_TAN
    global MODEL_COLORS

    def s(k):   return str(conf.get(k, DEFAULTS[k])).strip()
    def lst(k): return [x.strip() for x in s(k).split(",") if x.strip()]
    def num(k):
        try:
            return float(s(k))
        except ValueError:
            return float(DEFAULTS[k])
    def flag(k):
        return s(k).lower() not in ("", "0", "false", "no", "off")

    THEME_NAME = s("THEME").lower()
    if THEME_NAME not in THEMES:
        THEME_NAME = "plain"
    PALETTE = s("PALETTE").lower()
    if PALETTE not in PALETTES:
        PALETTE = "default"
    T = THEMES[THEME_NAME]
    # Icons are their own axis: nothing renders tofu unless the user opts into nerd.
    global ICON_MODE, T_ARROW, T_THIN, T_LCAP, T_RCAP
    ICON_MODE = s("ICONS").lower()
    if ICON_MODE not in ("unicode", "nerd", "none"):
        ICON_MODE = "unicode"
    if THEME_NAME == "mono":
        ICON_MODE = "none"                    # mono's promise: plain ASCII
    IC = ICONS[ICON_MODE]
    nerd = ICON_MODE == "nerd"
    T_ARROW = T.get("arrow") if nerd else T.get("arrow_alt", T.get("arrow"))
    T_THIN  = T.get("thin")  if nerd else T.get("thin_alt",  T.get("thin"))
    T_LCAP  = T.get("lcap")  if nerd else T.get("lcap_alt",  T.get("lcap"))
    T_RCAP  = T.get("rcap")  if nerd else T.get("rcap_alt",  T.get("rcap"))
    global RULE
    RULE = flag("RULE")
    global T_BAR, BARW
    bar_style = s("BAR").lower()
    if THEME_NAME == "mono":
        T_BAR = BARS["ascii"]                 # mono's promise: plain ASCII
    elif bar_style in BARS:
        T_BAR = BARS[bar_style]
    else:
        T_BAR = T["bar"]                      # "theme": the theme's native pair
    try:
        BARW = max(4, min(16, int(float(s("BARW")))))
    except ValueError:
        BARW = 8
    global BUDGET_MONTH, BUDGET_DAY, CMD, CMD_TTL, BAR_HEAT
    BUDGET_MONTH, BUDGET_DAY = num("BUDGET_MONTH"), num("BUDGET_DAY")
    # Heat needs embedded fg codes inside the segment text, which only sep-mode
    # colored themes render verbatim (blocks themes color by background; mono has none).
    BAR_HEAT = flag("BAR_HEAT") and T.get("mode", "sep") == "sep" and T["color"]
    CMD = conf.get("CMD", "") or ""
    CMD_TTL = max(5, num("CMD_TTL") or 30)
    STYLE = s("STYLE").lower()
    if STYLE not in ("adaptive", "full", "compact"):
        STYLE = "adaptive"
    LINES  = 1 if s("LINES") == "1" else 2
    GIT    = s("GIT").lower()
    TH     = num("THRESHOLD")
    NOTICE = num("NOTICE")
    SEGS   = lst("SEGMENTS")
    LINE2  = lst("LINE2")
    REMOTE = flag("REMOTE")
    RDEBUG = flag("REMOTE_DEBUG")
    NOTIFY = s("NOTIFY").lower()

    p = PALETTES[PALETTE]
    C_RED, C_AMBER, C_GREEN = p["red"], p["amber"], p["green"]
    C_BRAND, C_MONEY, C_DIM = p["brand"], p["money"], p["dim"]
    C_PURPLE, C_BLUE, C_TAN = p["purple"], p["blue"], p["tan"]
    MODEL_COLORS = {"fable": C_PURPLE, "sonnet": C_BLUE, "haiku": C_GREEN, "opus": C_BRAND}

apply_config(effective_conf())
MODE = _MODE                                    # only "render" may notify

try:
    WIDTH = int(os.environ.get("COLUMNS") or 0)     # Claude Code sets this for hooks
except ValueError:
    WIDTH = 0

# Priority decides what gets dropped first when the line is wider than the terminal.
# >= 90 is never dropped: the model, the meters and the warnings are the whole point.
PRIO = {"spark": 10, "title": 12, "dir": 15, "cmd": 16, "vim": 17, "agent": 18, "search": 20, "effort": 22, "proj": 24, "pr": 25,
        "cache": 28, "git": 30, "time": 35, "burn": 45, "ctx": 40, "eom": 48, "month": 50,
        "session": 60, "credits": 65, "today": 80, "model": 95, "meter": 92,
        "warn": 99, "hint": 99}

def seg(key, text, color=None, suffix="", prio=None):
    return {"key": key, "text": text, "color": color, "suffix": suffix,
            "prio": PRIO.get(prio or key, 50)}

ANSI_RE = re.compile(r"\033\[[0-9;]*m")
# Terminals disagree about the width of symbols; these are the ones we actually emit
# that are reliably double-width.
WIDE = {0x26A1, 0x1F4C1, 0x1F50D}

def vlen(s):
    s = ANSI_RE.sub("", s)
    w = 0
    for ch in s:
        if unicodedata.combining(ch):
            continue
        o = ord(ch)
        if o in WIDE or unicodedata.east_asian_width(ch) in ("W", "F") \
                or 0x1F300 <= o <= 0x1FAFF:
            w += 2
        else:
            w += 1
    return w

def paint(text, col):
    if not T["color"] or col is None or text == "":
        return text
    return f"\033[38;5;{col}m{text}\033[0m"

def seg_text(s):
    return s["text"] + (s["suffix"] or "")

def render_line(segs):
    if not segs:
        return ""
    mode = T.get("mode", "sep")
    if mode == "joined":
        # A powerline train: blocks share edges, an arrow marks each color change.
        arrow, thin = T_ARROW, T_THIN
        out = []
        for i, s in enumerate(segs):
            bg = s["color"] if s["color"] is not None else 238
            nxt = segs[i + 1]["color"] if i + 1 < len(segs) else None
            if i + 1 < len(segs) and nxt is None:
                nxt = 238
            out.append(f"\033[48;5;{bg}m\033[38;5;232m {seg_text(s)} \033[0m")
            if nxt is None:
                out.append(f"\033[38;5;{bg}m{arrow}\033[0m")     # tail
            elif nxt == bg:
                # Same background: a solid arrow would be invisible; use the thin
                # separator powerline reserves for exactly this case.
                out.append(f"\033[48;5;{bg}m\033[38;5;232m{thin}\033[0m")
            else:
                out.append(f"\033[38;5;{bg}m\033[48;5;{nxt}m{arrow}\033[0m")
        return "".join(out)
    if mode == "pills":
        # Every segment is its own block; caps (if any) round it into a pill.
        lcap, rcap = T_LCAP, T_RCAP
        out = []
        for s in segs:
            bg = s["color"] if s["color"] is not None else 238
            pill = f"\033[48;5;{bg}m\033[38;5;232m {seg_text(s)} \033[0m"
            if lcap:
                pill = f"\033[38;5;{bg}m{lcap}\033[0m" + pill + f"\033[38;5;{bg}m{rcap}\033[0m"
            out.append(pill)
        return " ".join(out)
    body = T["sep"].join(paint(s["text"], s["color"]) + paint(s["suffix"], C_DIM)
                         for s in segs)
    line = T["open"] + body + T["close"]
    if T["pad"] and WIDTH:
        short = WIDTH - vlen(line)
        if short > 0:
            line = T["open"] + body + " " * short + T["close"]
    if THEME_NAME == "mono":
        # mono promises plain ASCII — swap the typographic characters we emit.
        for a, b in (("≈", "~"), ("·", "-"), ("…", "..."), ("│", "|"), ("✓", "ok"),
                     ("✗", "x"), ("●", "*"), ("◌", "o")):
            line = line.replace(a, b)
    return line

def fit(segs):
    # Drop the least important segments until the line fits the terminal.
    if not WIDTH or not segs:
        return segs
    cur = list(segs)
    while vlen(render_line(cur)) > WIDTH:
        droppable = [i for i, s in enumerate(cur) if s["prio"] < 90]
        if not droppable:
            break
        cur.pop(min(droppable, key=lambda i: cur[i]["prio"]))
    return cur

def clip(line):
    # Last defence for a very narrow terminal: even the protected segments can overflow,
    # and a wrapped status line costs two rows instead of one.
    if not WIDTH or vlen(line) <= WIDTH:
        return line
    out, w, i = [], 0, 0
    while i < len(line):
        m = ANSI_RE.match(line, i)
        if m:
            out.append(m.group(0)); i = m.end(); continue
        cw = vlen(line[i])
        if w + cw > WIDTH - 1:
            break
        out.append(line[i]); w += cw; i += 1
    return "".join(out) + "…\033[0m"

# ---- small formatters -------------------------------------------------------
HOUR = 3600
WINDOW_5H = 5 * HOUR
WINDOW_7D = 7 * 24 * HOUR

def color_for(p):
    if p >= TH:            return C_RED
    if p >= max(0, TH-15): return C_AMBER
    return C_GREEN

def bar(p, n=None):
    if T_BAR is None:                         # dot style: a single status dot
        return "●"
    on, off = T_BAR
    n = n or BARW
    f = max(0, min(n, int(round(p / 100.0 * n))))
    return on * f + off * (n - f)

def heat_bar(p, n=None):
    # Cells colored by the zone they sit in, so the bar itself shows where the
    # danger band starts: green below NOTICE, amber below THRESHOLD, red above.
    if T_BAR is None:
        return None
    on, off = T_BAR
    n = n or BARW
    f = max(0, min(n, int(round(p / 100.0 * n))))
    out = []
    for i in range(n):
        if i < f:
            frac = (i + 1) / n * 100
            col = C_GREEN if frac <= NOTICE else (C_AMBER if frac <= TH else C_RED)
            out.append(f"\033[38;5;{col}m{on}")
        else:
            out.append(f"\033[38;5;{C_DIM}m{off}")
    return "".join(out) + "\033[0m"

def dur(seconds):
    s = int(max(0, seconds))
    if s < 60:  return f"{s}s"
    m = s // 60
    if m < 60:  return f"{m}m"
    h = m // 60
    if h < 24:  return f"{h}h" if m % 60 == 0 else f"{h}h {m % 60}m"
    return f"{h // 24}d" if h % 24 == 0 else f"{h // 24}d {h % 24}h"

def countdown(ts):
    try:
        diff = float(ts) - time.time()
    except Exception:
        return ""
    if diff <= 0: return "now"
    m = int(diff // 60)
    if m < 60:  return f"{m}m"
    h = m // 60
    if h < 48:  return f"{h}h"
    return f"{h // 24}d"

def money(v):
    return f"${v:,.2f}" if abs(v) < 100 else f"${v:,.0f}"

def tokens(n):
    if n >= 1000000: return f"{n / 1000000:.0f}M".replace(".0M", "M")
    if n >= 1000:    return f"{n // 1000}k"
    return str(n)

# ---- model helpers ----------------------------------------------------------
FAMILIES = (("fable", "Fable"), ("mythos", "Fable"), ("sonnet", "Sonnet"),
            ("haiku", "Haiku"), ("opus", "Opus"))

def model_family(model):
    m = (model or "").lower()
    for key, name in FAMILIES:
        if key in m:
            return name
    return "other"

def model_seg(d):
    md   = d.get("model") or {}
    mid  = (md.get("id") or "").lower()
    disp = (md.get("display_name") or "").strip()

    col = C_TAN
    for key in ("fable", "mythos", "sonnet", "haiku", "opus"):
        if key in mid:
            col = MODEL_COLORS["fable" if key == "mythos" else key]
            break

    label = disp
    if not label:
        m = re.search(r"claude-([a-z]+)", mid)
        label = m.group(1).capitalize() if m else (mid or "?")
    mm = re.search(r"claude-[a-z]+-(\d+(?:-\d+)?)", mid)
    if mm:
        ver = mm.group(1).replace("-", ".")
        if ver not in label:
            label += " " + ver

    cw = d.get("context_window") or {}
    is_1m = "[1m]" in mid or (cw.get("context_window_size") or 0) >= 1000000
    low = label.lower()
    if is_1m and "1m" not in low and "context" not in low:
        label += "·1M"
    icon = (IC["model"] + " ") if IC["model"] else ""
    return seg("model", icon + label, col)

# ---- git (branch is free; the dirty count refreshes in the background) -------
GIT_CACHE = os.path.join(HOME, ".usage-git-cache.json")
GIT_LOCK  = os.path.join(HOME, ".usage-git-cache.lock")

def git_dir(start):
    p = os.path.abspath(start or ".")
    while True:
        g = os.path.join(p, ".git")
        if os.path.isdir(g):
            return g
        if os.path.isfile(g):                 # linked worktree: a pointer file
            try:
                with open(g) as fh:
                    line = fh.read().strip()
            except Exception:
                return None
            if line.startswith("gitdir:"):
                gd = line.split(":", 1)[1].strip()
                return gd if os.path.isabs(gd) else os.path.normpath(os.path.join(p, gd))
            return None
        parent = os.path.dirname(p)
        if parent == p:
            return None
        p = parent

def git_branch(gd):
    try:
        with open(os.path.join(gd, "HEAD")) as fh:
            head = fh.read().strip()
    except Exception:
        return None
    if head.startswith("ref: refs/heads/"):
        return head[len("ref: refs/heads/"):]
    return head[:7] if re.fullmatch(r"[0-9a-f]{7,40}", head) else None

def git_state_key(gd):
    parts = []
    for name in ("index", "HEAD"):
        try:
            parts.append(str(os.stat(os.path.join(gd, name)).st_mtime))
        except OSError:
            parts.append("-")
    return "|".join(parts)

def refresh_git_cache(cwd, gd, key):
    import subprocess
    dirty = staged = ahead = behind = None
    try:
        out = subprocess.run(["git", "-C", cwd, "status", "--porcelain", "-b"],
                             capture_output=True, text=True, timeout=10)
        if out.returncode == 0:
            dirty = staged = ahead = behind = 0
            for line in out.stdout.splitlines():
                if line.startswith("## "):
                    m = re.search(r"ahead (\d+)", line)
                    ahead = int(m.group(1)) if m else 0
                    m = re.search(r"behind (\d+)", line)
                    behind = int(m.group(1)) if m else 0
                elif line.strip():
                    dirty += 1
                    if line[:1] not in (" ", "?"):
                        staged += 1
    except Exception:
        pass
    cache = _read_json(GIT_CACHE) or {}
    repos = cache.get("repos", {}) if isinstance(cache, dict) else {}
    repos[gd] = {"key": key, "dirty": dirty, "staged": staged,
                 "ahead": ahead, "behind": behind, "at": time.time()}
    _write_json(GIT_CACHE, {"version": 1, "repos": repos})

def git_seg(d):
    if GIT == "off" or "git" not in SEGS:
        return None
    cwd = d.get("cwd") or (d.get("workspace") or {}).get("current_dir") or os.getcwd()
    gd = git_dir(cwd)
    if not gd:
        return None
    branch = git_branch(gd)
    if not branch:
        return None
    text = (IC["git"] + " " if IC["git"] else "") + branch
    suffix = ""
    if GIT == "dirty":
        key = git_state_key(gd)
        entry = ((_read_json(GIT_CACHE) or {}).get("repos") or {}).get(gd) or {}
        if entry.get("key") != key:
            _spawn_detached(GIT_LOCK, lambda: refresh_git_cache(cwd, gd, key))
        bits = []
        if entry.get("dirty"):
            bits.append(f"!{entry['dirty']}")
        if entry.get("staged"):
            bits.append(f"+{entry['staged']}")
        arrows = ""
        if entry.get("ahead"):
            arrows += f"↑{entry['ahead']}"
        if entry.get("behind"):
            arrows += f"↓{entry['behind']}"
        if arrows:
            bits.append(arrows)
        if bits:
            suffix = " " + " ".join(bits)
    return seg("git", text, C_DIM if not suffix else C_AMBER, suffix)

# ---- custom command segment (runs detached, never on the render path) --------
CMD_CACHE = os.path.join(HOME, ".usage-cmd-cache.json")
CMD_LOCK  = os.path.join(HOME, ".usage-cmd.lock")

def _cmd_hash(cmd):
    import hashlib
    return hashlib.sha1(cmd.encode()).hexdigest()[:12]

def refresh_cmd_cache(cmd):
    import subprocess
    out = None
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        if r.returncode == 0:
            first = (r.stdout or "").strip().split("\n")[0].strip()
            out = first[:60] if first else None
    except Exception:
        pass
    _write_json(CMD_CACHE, {"version": 1, "hash": _cmd_hash(cmd),
                            "out": out, "at": time.time()})

def cmd_seg():
    if not CMD or "cmd" not in SEGS:
        return None
    try:
        c = _read_json(CMD_CACHE) or {}
        fresh = c.get("hash") == _cmd_hash(CMD)
        if not fresh or time.time() - float(c.get("at") or 0) >= CMD_TTL:
            _spawn_detached(CMD_LOCK, lambda: refresh_cmd_cache(CMD), ttl=15)
        if fresh and c.get("out"):
            return seg("cmd", c["out"], C_DIM)
    except Exception:
        pass
    return None

# ---- shared json cache helpers ---------------------------------------------
def _read_json(path):
    try:
        with open(path) as fh:
            c = json.load(fh)
        return c if isinstance(c, dict) else None
    except Exception:
        return None

def _write_json(path, payload):
    try:
        fd, tmp = tempfile.mkstemp(dir=HOME, prefix=".usage-tmp-")
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as fh:
            json.dump(payload, fh)
        os.replace(tmp, path)
    except Exception:
        pass

def _take_lock(path, ttl):
    try:
        if time.time() - os.stat(path).st_mtime < ttl:
            return False
        os.unlink(path)                      # stale lock from a process that died
    except FileNotFoundError:
        pass
    except Exception:
        return False
    try:
        os.close(os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
        return True
    except Exception:
        return False                         # lost the race; someone else is running

def _spawn_detached(lock_path, fn, ttl=30):
    # Run fn in a fully detached grandchild so a render never waits on it.
    if not _take_lock(lock_path, ttl):
        return
    try:
        pid = os.fork()
    except Exception:
        try: os.unlink(lock_path)
        except Exception: pass
        return
    if pid != 0:
        return                               # parent: carry on rendering
    try:
        os.setsid()
        if os.fork() != 0:
            os._exit(0)                      # worker is reparented to init
        # Release the inherited stdout, or Claude Code waits on EOF for the work.
        devnull = os.open(os.devnull, os.O_RDWR)
        for fd in (0, 1, 2):
            os.dup2(devnull, fd)
        fn()
    except Exception:
        pass
    try: os.unlink(lock_path)
    except Exception: pass
    os._exit(0)                              # _exit: never flush inherited buffers

# ---- remote (opt-in): Fable 5 window + usage credits ------------------------
USAGE_URL     = "https://api.anthropic.com/api/oauth/usage"
RCACHE        = os.path.join(HOME, ".usage-remote-cache.json")
RLOCK         = os.path.join(HOME, ".usage-remote-cache.lock")
RCACHE_LEGACY = os.path.join(HOME, ".usage-fable-cache.json")
R_TTL, R_MAX_AGE = 120, 1800

def _epoch(v):
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        try:
            dt = datetime.fromisoformat(v.replace("Z", "+00:00"))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.timestamp()
        except Exception:
            return None
    return None

def _oauth_token():
    # Read-only. We never run the refresh flow: rotating the token could break the
    # live Claude Code session that owns it.
    try:
        with open(os.path.join(HOME, ".credentials.json")) as fh:
            tok = ((json.load(fh) or {}).get("claudeAiOauth") or {}).get("accessToken")
        if tok:
            return tok
    except Exception:
        pass
    try:
        import subprocess
        # Token comes back on stdout; it never appears in argv where ps could see it.
        out = subprocess.run(
            ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
            capture_output=True, text=True, timeout=5)
        if out.returncode == 0:
            raw = out.stdout.strip()
            try:
                return ((json.loads(raw) or {}).get("claudeAiOauth") or {}).get("accessToken")
            except Exception:
                return raw or None
    except Exception:
        pass
    return None

def _parse_usage(data):
    # limits[] holds one entry per window; per-model ones carry a scope:
    #   {"kind": "weekly_scoped", "percent": 11, "resets_at": "2026-08-02T07:00:00+00:00",
    #    "scope": {"model": {"display_name": "Fable"}}, "is_active": true}
    # percent is 0-100, same scale as the sibling five_hour/seven_day utilization fields.
    out = {"buckets": [], "fable": None, "credits": None, "dollars": None}
    for entry in (data or {}).get("limits") or []:
        if not isinstance(entry, dict):
            continue
        name = ((entry.get("scope") or {}).get("model") or {}).get("display_name") or ""
        if not name:
            continue                          # unscoped window: five_hour / seven_day
        v = entry.get("percent")
        if v is None:
            v = entry.get("utilization")
        try:
            v = float(v)
        except (TypeError, ValueError):
            continue
        # Claude Code itself calls the Fable bucket the "Fable 5 limit".
        label = "Fable 5" if name.strip().lower() == "fable" else name
        bucket = {"key": name.strip().lower().split()[0], "label": label,
                  "pct": max(0.0, min(100.0, v)), "resets_at": _epoch(entry.get("resets_at"))}
        out["buckets"].append(bucket)
        if bucket["key"] == "fable":
            out["fable"] = bucket             # kept so older configs keep working
    eu = (data or {}).get("extra_usage")
    if isinstance(eu, dict):
        out["credits"] = {"enabled": bool(eu.get("is_enabled")), "used": eu.get("used_credits"),
                          "limit": eu.get("monthly_limit"), "utilization": eu.get("utilization"),
                          "currency": eu.get("currency") or "USD"}
    # Some plans denominate the weekly window in dollars. Claude Code ignores these
    # fields; when present they are the most useful number on the line.
    wk = (data or {}).get("seven_day")
    if isinstance(wk, dict) and wk.get("remaining_dollars") is not None:
        out["dollars"] = {"remaining": wk.get("remaining_dollars"), "limit": wk.get("limit_dollars"),
                          "used": wk.get("used_dollars"), "resets_at": _epoch(wk.get("resets_at"))}
    return out

def refresh_remote_cache():
    import urllib.request, urllib.error
    prev = _read_json(RCACHE) or {}
    keep = {k: prev.get(k) for k in ("fable", "credits", "dollars", "reading_at")}
    now = time.time()

    tok = _oauth_token()
    if not tok:
        _write_json(RCACHE, {"version": 2, "fetched_at": now, "retry_after": now + 900, **keep})
        return
    req = urllib.request.Request(USAGE_URL, headers={
        "Authorization": "Bearer " + tok, "Content-Type": "application/json",
        "anthropic-beta": "oauth-2025-04-20"})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        # 401/403 means the token expired — Claude Code refreshes it on its own
        # schedule, so back off rather than retry on every render.
        back = 900 if e.code in (401, 403) else 300
        _write_json(RCACHE, {"version": 2, "fetched_at": now, "retry_after": now + back, **keep})
        return
    except Exception:
        _write_json(RCACHE, {"version": 2, "fetched_at": now, "retry_after": now + 300, **keep})
        return

    if RDEBUG:
        try:
            with open(os.path.join(HOME, ".usage-remote-debug.json"), "w") as fh:
                json.dump(data, fh, indent=2)
        except Exception:
            pass

    parsed = _parse_usage(data)
    if not parsed["buckets"] and parsed["credits"] is None:
        _write_json(RCACHE, {"version": 2, "fetched_at": now, "retry_after": now + 3600,
                             "buckets": [], "fable": None, "credits": None,
                             "dollars": None, "reading_at": None})
        return
    _write_json(RCACHE, {"version": 2, "fetched_at": now, "retry_after": 0,
                         "reading_at": now, **parsed})

def remote_state():
    if not REMOTE:
        return {}
    try:
        if os.path.exists(RCACHE_LEGACY):
            os.unlink(RCACHE_LEGACY)         # superseded by the v2 cache
    except Exception:
        pass
    try:
        c = _read_json(RCACHE) or {}
        if c.get("version") != 2:
            c = {}
        now = time.time()
        stale = (now - float(c.get("fetched_at") or 0)) >= R_TTL
        if stale and now >= float(c.get("retry_after") or 0):
            _spawn_detached(RLOCK, refresh_remote_cache)
        # Don't keep using a reading nobody has managed to refresh — a stale quota
        # shown as current is worse than no quota at all.
        if (now - float(c.get("reading_at") or 0)) > R_MAX_AGE:
            return {}
        return c
    except Exception:
        return {}

# ---- meters -----------------------------------------------------------------
def build_meters(d, remote, month_total=0.0, today_total=0.0):
    out = []
    rl = d.get("rate_limits") or {}

    def add(key, label, win, window):
        if key not in SEGS or not isinstance(win, dict):
            return
        p = win.get("used_percentage")
        if p is None:
            return
        out.append({"key": key, "slot": key, "label": label, "pct": float(p),
                    "resets_at": win.get("resets_at"), "window": window})

    add("5h", "5h", rl.get("five_hour"), WINDOW_5H)
    add("7d", "7d", rl.get("seven_day"), WINDOW_7D)

    # Per-model weekly windows from limits[]. "quota" takes whatever the account has;
    # naming a bucket explicitly (fable, opus, sonnet …) picks just that one, which is
    # what existing configs written before this did. "slot" records which SEGMENTS
    # entry the meter renders under, so reordering in the config is honest.
    buckets = (remote or {}).get("buckets")
    if not buckets and isinstance((remote or {}).get("fable"), dict):
        buckets = [remote["fable"]]           # cache written by an older version
    for b in buckets or []:
        if not isinstance(b, dict) or b.get("pct") is None:
            continue
        key = b.get("key") or "quota"
        if key in SEGS:
            slot = key
        elif "quota" in SEGS:
            slot = "quota"
        else:
            continue
        out.append({"key": key, "slot": slot, "label": b.get("label") or "quota",
                    "pct": float(b["pct"]), "resets_at": b.get("resets_at"),
                    "window": WINDOW_7D})

    # Self-imposed dollar budgets ride the same meter machinery: threshold colors,
    # adaptive visibility, warnings, and the runs-out-before-reset projection.
    if "budget" in SEGS and (BUDGET_MONTH > 0 or BUDGET_DAY > 0):
        local = datetime.now().astimezone()
        if BUDGET_MONTH > 0:
            m_start = local.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
            m_next = (m_start + timedelta(days=32)).replace(day=1)
            out.append({"key": "budget", "slot": "budget", "label": "budget",
                        "pct": month_total / BUDGET_MONTH * 100,
                        "resets_at": m_next.timestamp(),
                        "window": (m_next - m_start).total_seconds(),
                        "note": money(max(0.0, BUDGET_MONTH - month_total)) + " left"})
        if BUDGET_DAY > 0:
            d_start = local.replace(hour=0, minute=0, second=0, microsecond=0)
            d_next = d_start + timedelta(days=1)
            out.append({"key": "budget", "slot": "budget", "label": "budget/d",
                        "pct": today_total / BUDGET_DAY * 100,
                        "resets_at": d_next.timestamp(), "window": 86400.0,
                        "note": money(max(0.0, BUDGET_DAY - today_total)) + " left"})
    return out

def meter_slots(meters):
    # Decide which meters are drawn and in what form, then group the rendered segments
    # by the SEGMENTS slot they belong to — line 1 places them where the config says.
    if STYLE == "full":
        drawn = [(m, True) for m in meters]
    elif STYLE == "compact":
        drawn = [(m, False) for m in meters]
    else:
        drawn = [(m, m["pct"] >= TH) for m in meters if m["pct"] >= NOTICE]
        if not drawn and meters:
            # Never go completely blind: keep the highest meter in numeric form.
            drawn = [(max(meters, key=lambda m: m["pct"]), False)]
    slots = {}
    for m, full in drawn:
        slots.setdefault(m["slot"], []).append(meter_seg(m, full))
    return slots

def meter_seg(m, full):
    p, c = m["pct"], color_for(m["pct"])
    if not full:
        return seg(m["key"], f"{m['label']} {p:.0f}%", c, prio="meter")
    warn = (IC["warn"] + " ") if p >= TH and IC["warn"] else ""
    cd = countdown(m.get("resets_at"))
    suffix = f"·{cd}" if cd else ""
    if m.get("note"):
        suffix += " " + m["note"]
    if BAR_HEAT:
        hb = heat_bar(min(p, 100))
        if hb is not None:
            # Colors live inside the text, so the segment itself stays uncolored;
            # label and percentage keep the level color.
            lvl = f"\033[38;5;{c}m"
            return seg(m["key"],
                       f"{lvl}{warn}{m['label']}\033[0m {hb} {lvl}{p:.0f}%\033[0m",
                       None, suffix, prio="meter")
    return seg(m["key"], f"{warn}{m['label']} {bar(min(p, 100))} {p:.0f}%", c,
               suffix, prio="meter")

# Claude Code compacts when input+cache_creation+cache_read reaches
#   context_window − min(max_output, 20000) − 13000
# and every current model has max_output ≥ 20k, so the reserve is a constant. It starts
# warning 20k earlier; we use the same band.
COMPACT_RESERVE, COMPACT_BAND = 33000, 20000

def compact_left(d):
    cw = d.get("context_window") or {}
    size, used = cw.get("context_window_size") or 0, cw.get("total_input_tokens") or 0
    if not size or not used:
        return None                           # no size in the payload: don't guess
    return (size - COMPACT_RESERVE) - used

def eta_to_limit(m, now):
    # How long until this window hits 100% at the pace used so far, or None when it
    # won't happen before the reset (or it is too early in the window to tell).
    r, w, p = m.get("resets_at"), m.get("window"), m.get("pct")
    try:
        r, w, p = float(r), float(w), float(p)
    except (TypeError, ValueError):
        return None
    if p <= 0 or p >= 100:
        return None
    remaining = r - now
    if remaining <= 0:
        return None
    elapsed = w - remaining
    if elapsed < w * 0.10:
        return None                          # just reset: any burn looks extreme
    eta = elapsed * (100.0 - p) / p
    return eta if eta < remaining else None

def build_warnings(meters, remote, now, d, eom_over=None):
    out = []
    credits = (remote or {}).get("credits") or {}
    burning = bool(credits.get("enabled")) and (credits.get("used") or 0) > 0
    for m in meters:
        if m["pct"] >= 100:
            out.append(f"{m['label']} limit reached" + (" — burning usage credits" if burning else ""))
    util = credits.get("utilization")
    if util is not None and credits.get("limit"):
        try:
            if float(util) >= TH:
                out.append(f"usage credits {float(util):.0f}% of {money(float(credits['limit']))}")
        except (TypeError, ValueError):
            pass
    if eom_over is not None:
        out.append(f"projected over budget (eom ≈{money(eom_over)})")
    left = compact_left(d)
    if left is not None and left <= COMPACT_BAND:
        out.append("auto-compact now" if left <= 0 else f"auto-compact in ~{tokens(left)} tokens")
    for m in meters:
        eta = eta_to_limit(m, now)
        if eta is not None:
            out.append(f"{m['label']} limit in ~{dur(eta)}")
    return out[:2]

# ---- spend reconstruction ---------------------------------------------------
# Per-model $/token (input, output). Cache read = 0.1x input; cache write =
# 1.25x (5m) / 2x (1h) input. Standard sticker rates; a reconstruction, so it
# will be close to but not identical to Claude Code cost.total_cost_usd.
SEARCH_COST = 10.0 / 1000    # web search is billed per request, on top of tokens

def model_rates(model, speed=None):
    m = (model or "").lower()
    def per(i, o): return (i / 1e6, o / 1e6)
    if "haiku-3-5" in m or "haiku-3.5" in m: return per(0.80, 4.0)
    if "haiku-3" in m:                       return per(0.25, 1.25)
    if "haiku" in m:                         return per(1.0, 5.0)   # haiku 4.5
    if "fable" in m or "mythos" in m:        return per(10.0, 50.0) # fable/mythos 5
    if "sonnet" in m:                        return per(3.0, 15.0)  # sonnet 4.6-5
    if "opus-4-1" in m or "opus-4-0" in m:   return per(15.0, 75.0)
    if "opus-5" in m or "opus-4-8" in m:
        # Fast mode runs the same model at premium rates where it is supported.
        return per(10.0, 50.0) if speed == "fast" else per(5.0, 25.0)
    if "opus-4" in m or "opus" in m:         return per(5.0, 25.0)  # opus 4.5-4.7
    return per(5.0, 25.0)

def msg_cost(usage, model):
    if not isinstance(usage, dict): return 0.0, 0
    ir, orate = model_rates(model, usage.get("speed"))
    c  = (usage.get("input_tokens") or 0) * ir
    c += (usage.get("output_tokens") or 0) * orate
    c += (usage.get("cache_read_input_tokens") or 0) * ir * 0.1
    cc = usage.get("cache_creation")
    if isinstance(cc, dict):
        c += (cc.get("ephemeral_5m_input_tokens") or 0) * ir * 1.25
        c += (cc.get("ephemeral_1h_input_tokens") or 0) * ir * 2.0
    else:
        c += (usage.get("cache_creation_input_tokens") or 0) * ir * 1.25
    stu = usage.get("server_tool_use")
    searches = (stu.get("web_search_requests") or 0) if isinstance(stu, dict) else 0
    return c + searches * SEARCH_COST, searches

def local_stamp(ts):
    # ISO 8601 like 2026-07-02T09:07:06.416Z -> (local YYYY-MM-DD, local YYYY-MM-DDTHH)
    try:
        s = ts.replace("Z", "+00:00")
        dt = datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        dt = dt.astimezone()
        return dt.strftime("%Y-%m-%d"), dt.strftime("%Y-%m-%dT%H")
    except Exception:
        return None, None

def file_costs(path, start=0, prev=None):
    # Transcripts are append-only JSONL, so we resume from the byte offset we stopped at
    # instead of re-reading a file that can grow past 60 MB in a long session.
    # Returns (days, hours, searches, bytes_consumed); a trailing partial line is left
    # unconsumed so the next pass picks it up whole.
    prev = prev or {}
    days = {day: dict(fams) for day, fams in (prev.get("days") or {}).items()}
    hours = dict(prev.get("hours") or {})
    searches = dict(prev.get("searches") or {})
    toks = {day: dict(t) for day, t in (prev.get("toks") or {}).items()}
    consumed = start
    try:
        with open(path, "rb") as fh:
            fh.seek(start)
            for raw in fh:
                if not raw.endswith(b"\n"):
                    break                     # still being written
                consumed += len(raw)
                if b"usage" not in raw:       # cheap prefilter
                    continue
                try:
                    o = json.loads(raw.decode("utf-8", "replace"))
                except Exception:
                    continue
                msg = o.get("message")
                if not isinstance(msg, dict):
                    continue
                usage = msg.get("usage")
                if not usage:
                    continue
                day, hour = local_stamp(o.get("timestamp") or "")
                if not day:
                    continue
                cost, n_search = msg_cost(usage, msg.get("model"))
                if n_search:
                    searches[day] = searches.get(day, 0) + n_search
                cc = usage.get("cache_creation")
                write = (((cc.get("ephemeral_5m_input_tokens") or 0) +
                          (cc.get("ephemeral_1h_input_tokens") or 0)) if isinstance(cc, dict)
                         else (usage.get("cache_creation_input_tokens") or 0))
                t = toks.setdefault(day, {"in": 0, "read": 0, "write": 0, "out": 0})
                t["in"]    += usage.get("input_tokens") or 0
                t["read"]  += usage.get("cache_read_input_tokens") or 0
                t["write"] += write
                t["out"]   += usage.get("output_tokens") or 0
                if not cost:
                    continue
                fam = model_family(msg.get("model"))
                bucket = days.setdefault(day, {})
                bucket[fam] = bucket.get(fam, 0.0) + cost
                hours[hour] = hours.get(hour, 0.0) + cost
    except Exception:
        return days, hours, searches, toks, start
    if len(hours) > 48:                       # only the last two days matter for burn
        hours = {k: hours[k] for k in sorted(hours)[-48:]}
    return days, hours, searches, toks, consumed

def spend_all():
    # Merged view over every transcript: per-day cost by model family, per-day tokens,
    # per-day searches, hourly buckets for the burn rate, and per-project totals
    # (the project is simply the transcript's parent directory — no cache change).
    out = {"days": {}, "hours": {}, "searches": {}, "toks": {}, "projects": {}}
    files = glob.glob(os.path.join(HOME, "projects", "*", "*.jsonl"))
    if not files:
        return out
    cache_path = os.path.join(HOME, ".usage-cost-cache.json")
    cache = _read_json(cache_path) or {}
    entries = cache.get("files", {}) if cache.get("version") == 4 else {}

    new_entries, dirty = {}, False
    for path in files:
        try:
            st = os.stat(path)
        except OSError:
            continue
        prev = entries.get(path) or {}
        offset = prev.get("offset")
        if prev.get("mtime") == st.st_mtime and prev.get("size") == st.st_size \
                and isinstance(offset, int):
            days, hours, searches, toks, consumed = (
                prev.get("days", {}), prev.get("hours", {}), prev.get("searches", {}),
                prev.get("toks", {}), offset)
        elif isinstance(offset, int) and 0 < offset <= st.st_size:
            days, hours, searches, toks, consumed = file_costs(path, offset, prev)  # appended
            dirty = True
        else:
            days, hours, searches, toks, consumed = file_costs(path)                # new
            dirty = True
        new_entries[path] = {"mtime": st.st_mtime, "size": st.st_size, "offset": consumed,
                             "days": days, "hours": hours, "searches": searches, "toks": toks}
        proj = os.path.basename(os.path.dirname(path))
        for day, fams in (days or {}).items():
            if isinstance(fams, dict):
                agg = out["days"].setdefault(day, {})
                total = 0.0
                for fam, c in fams.items():
                    agg[fam] = agg.get(fam, 0.0) + c
                    total += c
                if total:
                    p_agg = out["projects"].setdefault(proj, {})
                    p_agg[day] = p_agg.get(day, 0.0) + total
        for hour, c in (hours or {}).items():
            out["hours"][hour] = out["hours"].get(hour, 0.0) + c
        for day, n in (searches or {}).items():
            out["searches"][day] = out["searches"].get(day, 0) + n
        for day, t in (toks or {}).items():
            agg = out["toks"].setdefault(day, {"in": 0, "read": 0, "write": 0, "out": 0})
            for k in agg:
                agg[k] += t.get(k, 0)

    if dirty or len(new_entries) != len(entries):
        _write_json(cache_path, {"version": 4, "files": new_entries})
    return out

def project_label(slug, all_slugs):
    # Slugs are munged cwds ("-Users-nik-Sites-my-repo"); strip the prefix shared by
    # every project (typically the home dir) and keep the tail readable.
    slugs = list(all_slugs)
    if len(slugs) > 1:
        common = os.path.commonprefix(slugs)
        cut = common.rfind("-") + 1           # cut at a separator, not mid-word
        if cut > 0 and len(slug) > cut:
            slug = slug[cut:]
    return slug if len(slug) <= 24 else "…" + slug[-23:]

def eom_projection(month_total, now_local):
    # Straight-line month-end forecast; meaningless in the first days of a month.
    if now_local.day < 3 or month_total <= 0:
        return None
    m_start = now_local.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    m_next = (m_start + timedelta(days=32)).replace(day=1)
    frac = (now_local - m_start).total_seconds() / (m_next - m_start).total_seconds()
    return month_total / frac if frac > 0 else None

def cache_hit_rate(toks_day):
    # Share of input tokens served from the prompt cache. High is good: a low number
    # means you are paying full price for context that could have been cached.
    if not toks_day:
        return None
    total = toks_day.get("in", 0) + toks_day.get("read", 0) + toks_day.get("write", 0)
    return (toks_day.get("read", 0) / total * 100) if total else None

def burn_rate(hours):
    # $/h from hourly buckets: extrapolate the current hour once it has enough signal,
    # otherwise report the last complete one.
    now = datetime.now().astimezone()
    cur = hours.get(now.strftime("%Y-%m-%dT%H"))
    if cur and now.minute >= 10:
        return cur * 60.0 / now.minute
    return hours.get((now - timedelta(hours=1)).strftime("%Y-%m-%dT%H"))

SPARK = "▁▂▃▄▅▆▇█"

def sparkline(per_day):
    now = datetime.now().astimezone()
    vals = [per_day.get((now - timedelta(days=i)).strftime("%Y-%m-%d"), 0.0)
            for i in range(6, -1, -1)]
    top = max(vals)
    if top <= 0:
        return ""
    return "".join(SPARK[min(7, int(v / top * 7.999))] for v in vals)

# ---- line 2 pieces ----------------------------------------------------------
def credits_seg(remote):
    c = (remote or {}).get("credits")
    if not isinstance(c, dict):
        return None
    if not c.get("enabled"):
        return seg("credits", "credits off", C_DIM)
    used = c.get("used")
    if used is None:
        return None
    limit = c.get("limit")
    if limit is None:
        return seg("credits", f"credits {money(float(used))}", C_MONEY, " of unlimited")
    try:
        util = float(c.get("utilization") or 0)
    except (TypeError, ValueError):
        util = 0.0
    return seg("credits", f"credits {money(float(used))}", color_for(util),
               f"/{money(float(limit))} ({util:.0f}%)")

def dollars_seg(remote):
    dl = (remote or {}).get("dollars")
    if not isinstance(dl, dict) or dl.get("remaining") is None:
        return None
    return seg("credits", money(float(dl["remaining"])), C_MONEY, " left this week")

# ---- report -----------------------------------------------------------------
def run_report():
    days = int(os.environ.get("REPORT_DAYS") or 30)
    fmt = (os.environ.get("REPORT_FORMAT") or "text").lower()
    data = spend_all()
    now_local = datetime.now().astimezone()
    if os.environ.get("REPORT_PROJECTS"):
        today_k = now_local.strftime("%Y-%m-%d")
        keys = {(now_local - timedelta(days=i)).strftime("%Y-%m-%d") for i in range(days)}
        rows = []
        for slug, per_day in data["projects"].items():
            in_range = sum(v for day, v in per_day.items() if day in keys)
            if in_range <= 0:
                continue
            rows.append({"project": project_label(slug, data["projects"].keys()),
                         "today": round(per_day.get(today_k, 0.0), 2),
                         "range": round(in_range, 2),
                         "all_time": round(sum(per_day.values()), 2)})
        rows.sort(key=lambda r: -r["range"])
        if fmt == "json":
            print(json.dumps({"days_window": days, "projects": rows}, indent=2)); return
        cols = ["project", "today", "range", "all_time"]
        heads = {"range": f"last_{days}d"}
        if fmt == "csv":
            print(",".join(heads.get(c, c) for c in cols))
            for r in rows:
                print(",".join(str(r[c]) for c in cols))
            return
        w = {c: max(len(heads.get(c, c)), *(len(str(r[c])) for r in rows)) if rows
             else len(heads.get(c, c)) for c in cols}
        print("  ".join(heads.get(c, c).ljust(w[c]) if c == "project"
                        else heads.get(c, c).rjust(w[c]) for c in cols))
        for r in rows:
            print("  ".join(str(r[c]).ljust(w[c]) if c == "project"
                            else str(r[c]).rjust(w[c]) for c in cols))
        return
    now = datetime.now().astimezone()
    keys = [(now - timedelta(days=i)).strftime("%Y-%m-%d") for i in range(days - 1, -1, -1)]
    fams = sorted({f for day in keys for f in data["days"].get(day, {})
                   if data["days"].get(day, {}).get(f)})
    rows = []
    for day in keys:
        per_fam = data["days"].get(day, {})
        tok = data["toks"].get(day) or {}
        total = sum(per_fam.values())
        if not total and not tok:
            continue
        rows.append({"day": day, **{f: round(per_fam.get(f, 0.0), 2) for f in fams},
                     "total": round(total, 2),
                     "searches": data["searches"].get(day, 0),
                     "cache_pct": round(cache_hit_rate(tok) or 0.0, 1),
                     "tokens": sum(tok.values()) if tok else 0})

    if fmt == "json":
        print(json.dumps({"days": rows,
                          "month_to_date": round(sum(
                              sum(f.values()) for day, f in data["days"].items()
                              if day.startswith(now.strftime("%Y-%m"))), 2)}, indent=2))
        return
    cols = ["day"] + fams + ["total", "searches", "cache_pct", "tokens"]
    if fmt == "csv":
        print(",".join(cols))
        for r in rows:
            print(",".join(str(r.get(c, 0)) for c in cols))
        return

    width = {c: max(len(c), *(len(f"{r.get(c, 0)}") for r in rows)) if rows else len(c)
             for c in cols}
    print("  ".join(c.rjust(width[c]) if c != "day" else c.ljust(width[c]) for c in cols))
    for r in rows:
        print("  ".join((str(r.get(c, 0)).rjust(width[c]) if c != "day"
                         else r["day"].ljust(width["day"])) for c in cols))
    if rows:
        mtd = sum(sum(f.values()) for day, f in data["days"].items()
                  if day.startswith(now.strftime("%Y-%m")))
        last7 = [sum(data["days"].get((now - timedelta(days=i)).strftime("%Y-%m-%d"), {}).values())
                 for i in range(7)]
        print()
        tail = (f"month to date ≈{money(mtd)} · last 7 days ≈{money(sum(last7) / 7)}/day "
                f"· {len(rows)} active days in the last {days}")
        proj_val = eom_projection(mtd, now_local)
        if proj_val is not None:
            tail += f" · projected month end ≈{money(proj_val)}"
        print(tail)

# ---- doctor -----------------------------------------------------------------
def run_doctor():
    import shutil
    ok, bad, na = "✓", "✗", "–"
    def line(mark, label, detail=""):
        print(f" {mark} {label}" + (f" — {detail}" if detail else ""))

    print("tools")
    line(ok, "python3", sys.version.split()[0])
    line(ok if shutil.which("git") else bad, "git",
         "needed only for the dirty-file count")
    notifier = ("osascript" if sys.platform == "darwin" and shutil.which("osascript")
                else ("notify-send" if shutil.which("notify-send") else None))
    line(ok if notifier else na, "notifier", notifier or "none found; NOTIFY would do nothing")

    print("\nconfig")
    conf_path = os.environ.get("CLAUDE_USAGE_CONF") or os.path.join(HOME, "statusline-usage.conf")
    line(ok if os.path.exists(conf_path) else na, conf_path,
         "" if os.path.exists(conf_path) else "not created yet; defaults in use")
    print(f"   effective: THEME={THEME_NAME} PALETTE={PALETTE} LINES={LINES} STYLE={STYLE} "
          f"THRESHOLD={TH:.0f} NOTICE={NOTICE:.0f} GIT={GIT} REMOTE={int(REMOTE)} NOTIFY={NOTIFY}")
    print(f"   segments : {','.join(SEGS)}")
    print(f"   line2    : {','.join(LINE2)}")
    line(ok if WIDTH else na, "terminal width",
         f"COLUMNS={WIDTH}" if WIDTH else "not set here; Claude Code sets it when it runs the statusline")

    print("\nregistration")
    settings = os.path.join(HOME, "settings.json")
    try:
        sl = (_read_json(settings) or {}).get("statusLine") or {}
        cmd = sl.get("command") or ""
        installed = os.path.join(HOME, "statusline-usage.sh")
        line(ok if cmd else bad, "settings.json statusLine", cmd or "not registered")
        if cmd and os.path.expanduser(cmd) != installed:
            line(na, "points elsewhere", f"expected {installed}")
    except Exception as e:
        line(bad, "settings.json", str(e))

    print("\ndata")
    files = glob.glob(os.path.join(HOME, "projects", "*", "*.jsonl"))
    size = sum(os.path.getsize(f) for f in files if os.path.exists(f))
    line(ok if files else bad, "transcripts", f"{len(files)} files, {size / 1e6:.0f} MB")
    cc = _read_json(os.path.join(HOME, ".usage-cost-cache.json")) or {}
    if cc.get("version") == 4:
        line(ok, "cost cache", f"v4, {len(cc.get('files', {}))} files tracked")
    else:
        line(na, "cost cache", f"version {cc.get('version', 'missing')} — next render re-reads everything once")

    print("\nremote (Fable 5 + usage credits)")
    if not REMOTE:
        line(na, "disabled", "set REMOTE=1 to enable")
    else:
        tok_src = ("credentials file" if os.path.exists(os.path.join(HOME, ".credentials.json"))
                   else ("keychain" if sys.platform == "darwin" else None))
        line(ok if tok_src else bad, "oauth token", f"found via {tok_src}" if tok_src else "not found")
        rc = _read_json(RCACHE) or {}
        if rc:
            age = time.time() - float(rc.get("reading_at") or 0)
            back = float(rc.get("retry_after") or 0) - time.time()
            line(ok if rc.get("reading_at") else na, "last reading",
                 f"{dur(age)} ago" if rc.get("reading_at") else "never succeeded")
            if back > 0:
                line(na, "backing off", f"retries in {dur(back)}")
            line(ok if rc.get("buckets") else na, "per-model buckets",
                 ", ".join(f"{b['label']} {b['pct']:.0f}%" for b in rc.get("buckets") or []) or "none")
            cr = rc.get("credits") or {}
            line(ok if cr.get("enabled") else na, "usage credits",
                 f"{money(float(cr.get('used') or 0))} used" if cr.get("enabled") else "off for this account")
        else:
            line(na, "cache", "empty; the next render starts a background fetch")
        if os.environ.get("DOCTOR_NET"):
            import urllib.request, urllib.error
            t = _oauth_token()
            if not t:
                line(bad, "endpoint", "no token to try with")
            else:
                try:
                    req = urllib.request.Request(USAGE_URL, headers={
                        "Authorization": "Bearer " + t, "Content-Type": "application/json",
                        "anthropic-beta": "oauth-2025-04-20"})
                    with urllib.request.urlopen(req, timeout=5) as r:
                        line(ok, "endpoint", f"HTTP {r.status}")
                except urllib.error.HTTPError as e:
                    line(bad, "endpoint", f"HTTP {e.code}")
                except Exception as e:
                    line(bad, "endpoint", type(e).__name__)

    print("\ngit")
    cwd = os.environ.get("DOCTOR_CWD") or os.getcwd()
    gd = git_dir(cwd)
    if gd:
        line(ok, "repository", f"{git_branch(gd) or '?'} ({gd})")
        gc = ((_read_json(GIT_CACHE) or {}).get("repos") or {}).get(gd) or {}
        line(ok if gc else na, "dirty count",
             f"{gc.get('dirty')} changed" if gc.get("dirty") is not None else "not cached yet")
    else:
        line(na, "repository", f"none found above {cwd}")

    print("\nglyphs — if any of these are boxes, pick a different theme")
    print("   plain/full bars  ▉▉▉░░░░░")
    print("   boxed bars       ▰▰▰▱▱▱▱▱   frame │   dots ·")
    print("   bar styles       " + "  ".join(f"{k} {v[0]}{v[0]}{v[1]}{v[1]}" for k, v in BARS.items()))
    print("   powerline   · slant  · capsule  · icons    (need a Nerd Font)")
    print("   icons            ⚡ ⑂ 📁 🔍 ⚠ ⏱   sparkline ▁▂▃▄▅▆▇█")

if MODE == "report":
    run_report(); sys.exit(0)
if MODE == "doctor":
    run_doctor(); sys.exit(0)

# ---- notifications (opt-in) -------------------------------------------------
# Fires on the *transition*, not on the state: once a key stops being true it re-arms.
# Delivery is detached, so a notification can never hold up a render.
NSTATE, NLOCK, NCOOLDOWN = (os.path.join(HOME, ".usage-notify-state.json"),
                            os.path.join(HOME, ".usage-notify.lock"), 600)

def _deliver(title, message):
    import subprocess, shutil
    try:
        if sys.platform == "darwin" and shutil.which("osascript"):
            subprocess.run(["osascript", "-e", "display notification %s with title %s"
                            % (json.dumps(message), json.dumps(title))],
                           capture_output=True, timeout=10)
        elif shutil.which("notify-send"):
            subprocess.run(["notify-send", title, message], capture_output=True, timeout=10)
    except Exception:
        pass

def maybe_notify(meters, remote, d, now):
    if MODE != "render" or NOTIFY not in ("threshold", "all"):
        return
    events = []
    for m in meters:
        if m["pct"] >= 100:
            events.append((f"{m['key']}:limit", f"{m['label']} limit reached"))
        elif m["pct"] >= TH:
            events.append((f"{m['key']}:{int(TH)}", f"{m['label']} at {m['pct']:.0f}%"))
    credits = (remote or {}).get("credits") or {}
    try:
        if credits.get("limit") and float(credits.get("utilization") or 0) >= TH:
            events.append(("credits", f"usage credits at {float(credits['utilization']):.0f}%"))
    except (TypeError, ValueError):
        pass
    left = compact_left(d)
    if left is not None and left <= COMPACT_BAND:
        events.append(("compact", "context auto-compact is close"))
    if NOTIFY == "all":
        for m in meters:
            eta = eta_to_limit(m, now)
            if eta is not None:
                events.append((f"{m['key']}:eta", f"{m['label']} runs out in ~{dur(eta)}"))

    try:
        fired = ((_read_json(NSTATE) or {}).get("fired")) or {}
        active = {k for k, _ in events}
        due = [(k, msg) for k, msg in events if now - float(fired.get(k) or 0) > NCOOLDOWN]
        kept = {k: v for k, v in fired.items() if k in active}   # inactive keys re-arm
        for k, _ in due:
            kept[k] = now
        if kept != fired:
            _write_json(NSTATE, {"version": 1, "fired": kept})
        if due:
            text = "; ".join(msg for _, msg in due)
            _spawn_detached(NLOCK, lambda: _deliver("Claude usage", text), ttl=5)
    except Exception:
        pass

# ---- assemble ---------------------------------------------------------------
KNOWN1 = {"title", "model", "effort", "dir", "git", "pr", "ctx", "time", "vim", "agent", "cmd"}

def render_status(d):
    now = time.time()
    remote = remote_state()

    _now = datetime.now().astimezone()
    TODAY, MONTH = _now.strftime("%Y-%m-%d"), _now.strftime("%Y-%m")
    spend = {"days": {}, "hours": {}, "searches": {}, "toks": {}}
    need_spend = any(k in LINE2 for k in ("today", "models", "month", "burn",
                                          "spark", "search", "cache")) \
        or ("budget" in SEGS and (BUDGET_MONTH > 0 or BUDGET_DAY > 0))
    if need_spend:
        try:
            spend = spend_all()
        except Exception:
            pass
    per_day = {day: sum(f.values()) for day, f in spend["days"].items()}
    today_by_family = spend["days"].get(TODAY, {})
    today_total = sum(today_by_family.values())
    month_total = sum(v for day, v in per_day.items() if day.startswith(MONTH))
    hours_all = spend["hours"]
    searches_today = spend["searches"].get(TODAY, 0)

    meters = build_meters(d, remote, month_total, today_total)
    slots = meter_slots(meters)
    ws = d.get("workspace") or {}

    line1, hint_done = [], False
    for key in SEGS:
        if key == "title":
            name = (d.get("session_name") or "").strip()
            if name:
                line1.append(seg("title", name if len(name) <= 28 else name[:27] + "…", C_DIM))
        elif key == "model":
            line1.append(model_seg(d))
            if d.get("fast_mode"):
                line1.append(seg("model", (IC["fast"] + "fast") if IC["fast"] else "fast", C_AMBER))
        elif key == "effort":
            lvl = (d.get("effort") or {}).get("level")
            if lvl:
                line1.append(seg("effort", lvl, C_DIM))
        elif key == "dir":
            name = os.path.basename((ws.get("project_dir") or ws.get("current_dir") or "").rstrip("/"))
            repo = (ws.get("repo") or {}).get("name")
            label = repo or name
            if label:
                line1.append(seg("dir", (IC["dir"] + " " if IC["dir"] else "") + label, C_DIM))
        elif key == "git":
            g = git_seg(d)
            if g:
                line1.append(g)
        elif key == "pr":
            pr = d.get("pr") or {}
            if pr.get("number"):
                mark = {"approved": "✓", "changes_requested": "✗",
                        "pending": "●", "draft": "◌"}.get(pr.get("review_state"), "")
                col = {"approved": C_GREEN, "changes_requested": C_RED}.get(pr.get("review_state"), C_DIM)
                line1.append(seg("pr", f"{IC['pr']}{pr['number']} {mark}".strip(), col))
        elif key == "ctx":
            cw = d.get("context_window") or {}
            p = cw.get("used_percentage")
            if p is not None:
                size = cw.get("context_window_size") or 0
                tail = f" of {tokens(size)}" if size else ""
                left = compact_left(d)
                col = color_for(p)
                if left is not None and left <= COMPACT_BAND:
                    tail += " · compact now" if left <= 0 else f" · compact in ~{tokens(left)}"
                    col = C_RED if left <= 0 else C_AMBER
                line1.append(seg("ctx", f"ctx {p:.0f}%", col, tail))
        elif key == "time":
            ms = (d.get("cost") or {}).get("total_duration_ms")
            if ms:
                line1.append(seg("time", (IC["time"] + " " if IC["time"] else "") +
                                 dur(int(ms) // 1000), C_DIM))
        elif key == "vim":
            mode = (d.get("vim") or {}).get("mode")
            if mode:
                line1.append(seg("vim", "vim " + mode,
                                 C_DIM if mode == "INSERT" else C_AMBER))
        elif key == "agent":
            name = (d.get("agent") or {}).get("name")
            if name:
                line1.append(seg("agent", name, C_PURPLE))
        elif key == "cmd":
            s_ = cmd_seg()
            if s_:
                line1.append(s_)
        else:
            # A meter slot: 5h, 7d, quota, or a bucket named outright. Meters render
            # exactly where the config puts them.
            line1.extend(slots.pop(key, []))
            if not hint_done and not meters and not (d.get("rate_limits") or {}):
                line1.append(seg("hint", "usage n/a (Pro/Max, after first reply)", C_DIM))
                hint_done = True

    line2 = []
    for key in LINE2:
        if key == "session":
            sess = (d.get("cost") or {}).get("total_cost_usd")
            if isinstance(sess, (int, float)) and sess > 0:
                line2.append(seg("session", f"session {money(sess)}", C_MONEY))
        elif key == "today" and today_total > 0:
            suffix = ""
            if "models" in LINE2:
                top = [(k, v) for k, v in sorted(today_by_family.items(), key=lambda kv: -kv[1])[:2]
                       if v > 0 and k != "other"]
                if len(top) > 1:
                    suffix = " (" + " · ".join(f"{k} {money(v)}" for k, v in top) + ")"
            line2.append(seg("today", f"today ≈{money(today_total)}", C_MONEY, suffix))
        elif key == "month" and month_total > 0:
            line2.append(seg("month", f"month ≈{money(month_total)}", C_MONEY))
        elif key == "eom":
            proj_val = eom_projection(month_total, _now)
            if proj_val is not None:
                over = BUDGET_MONTH > 0 and proj_val > BUDGET_MONTH
                line2.append(seg("eom", f"eom ≈{money(proj_val)}",
                                 C_RED if over else C_DIM))
        elif key == "proj" and spend["projects"]:
            by_today = sorted(((p, d.get(TODAY, 0.0)) for p, d in spend["projects"].items()),
                              key=lambda kv: -kv[1])
            if by_today and by_today[0][1] > 0:
                name = project_label(by_today[0][0], spend["projects"].keys())
                line2.append(seg("proj", f"top {name}", C_DIM,
                                 " " + money(by_today[0][1])))
        elif key == "spark":
            s = sparkline(per_day)
            if s:
                line2.append(seg("spark", s, C_DIM))
        elif key == "burn":
            b = burn_rate(hours_all)
            if b:
                line2.append(seg("burn", f"≈{money(b)}/h", C_DIM))
        elif key == "search" and searches_today:
            line2.append(seg("search", (IC["search"] + " " if IC["search"] else "search ") +
                             str(searches_today), C_DIM))
        elif key == "cache":
            hit = cache_hit_rate(spend["toks"].get(TODAY))
            if hit is not None:
                # Inverted scale: a high cache-hit rate is the good outcome.
                col = C_GREEN if hit >= 90 else (C_AMBER if hit >= 70 else C_RED)
                line2.append(seg("cache", f"cache {hit:.0f}%", col))
        elif key == "credits":
            for s in (dollars_seg(remote), credits_seg(remote)):
                if s:
                    line2.append(s)
        elif key == "warn":
            _eov = eom_projection(month_total, _now)
            eom_over = _eov if (BUDGET_MONTH > 0 and _eov and _eov > BUDGET_MONTH) else None
            for w in build_warnings(meters, remote, now, d, eom_over):
                line2.append(seg("warn", (IC["warn"] + " " if IC["warn"] else "") + w, C_RED))

    if LINES == 1:
        out = [render_line(fit(line1 + line2))]
    else:
        out = [render_line(fit(line1)), render_line(fit(line2))]
    out = [clip(l) for l in out if l.strip()]
    if T.get("frame") and out:
        # A real box: rounded corners, top and bottom borders. Claude Code trims
        # each line, but the borders aren't whitespace, so they survive.
        w = WIDTH or (max(vlen(l) for l in out) if out else 80)
        out = [paint("╭" + "─" * max(0, w - 2) + "╮", C_DIM)] + out + \
              [paint("╰" + "─" * max(0, w - 2) + "╯", C_DIM)]
    elif RULE and out:
        # A quiet horizontal rule as the last line: the visual boundary between this
        # usage block and Claude Code's own footer below it.
        ch = "-" if THEME_NAME == "mono" else "─"
        out.append(paint(ch * (WIDTH or 80), C_DIM))
    text = "\n".join(out)
    return text, meters, remote, now

# ---- TUI configurator ---------------------------------------------------------
# A live, full-screen editor in the spirit of ccstatusline, with zero dependencies:
# raw-mode /dev/tty + the alternate screen buffer. Every keystroke re-applies the
# config and re-renders the preview with the real renderer, in-process.
CONF_TEMPLATE = """\
# Claude Code usage statusline — configuration.
# Every key can be overridden per-session with the matching CLAUDE_USAGE_<KEY> env var.
# Re-run the configurator any time:  bash ~/.claude/statusline-usage.sh --configure

# plain · boxed · dots · mono (ASCII, no color)
# powerline · slant · capsule (need a Nerd Font) · badge (colored blocks, any font)
THEME={THEME}

# Color palette: default · ocean · sunset · forest
PALETTE={PALETTE}

# unicode = ⚡ ⑂ ⏱ symbols that render in any font (also swaps powerline arrows/caps
# for ▶ and ▐ ▌) · nerd = native Nerd Font glyphs (needs the font) · none = text only
ICONS={ICONS}

# 1 = draw a dim ─ rule as the last line, separating usage from Claude Code's footer
RULE={RULE}

# Meter bar style: theme (each theme's own) · boxes ▉░ · slant ▰▱ · shade █▒
# · line ━╌ · dots ●○ · mini ▪▫ · bars ▮▯ · ascii #- · dot (a single ●)
# BARW = width in cells (4-16). BAR_HEAT=1 colors cells by zone (sep themes only).
BAR={BAR}
BARW={BARW}
BAR_HEAT={BAR_HEAT}

# Your own $ targets (0 = off). With the "budget" segment enabled this draws a meter
# with $ left, threshold warnings and a runs-out-before-reset projection.
BUDGET_MONTH={BUDGET_MONTH}
BUDGET_DAY={BUDGET_DAY}

# A command whose first line of stdout becomes the "cmd" segment. Runs in the
# background (never blocks a render), cached for CMD_TTL seconds.
CMD={CMD}
CMD_TTL={CMD_TTL}

# 1 = fold the money line into the status line, 2 = keep them separate
LINES={LINES}

# adaptive = show a meter only once it matters (see NOTICE/THRESHOLD)
# full     = always draw every meter with its bar
# compact  = always draw every meter, numbers only, no bars
STYLE={STYLE}

# At or above THRESHOLD a meter turns red, gets a bar and a warning marker.
THRESHOLD={THRESHOLD}
# adaptive only: below NOTICE a meter is hidden. The highest one is always shown.
NOTICE={NOTICE}

# Line 1 segments, in order: title, model, effort, git, dir, pr, 5h, 7d, quota, ctx, time
# (quota = every per-model window the account has; or name one: fable, opus, sonnet)
SEGMENTS={SEGMENTS}

# Line 2 parts, in order:
#   session = this session   today/models = today, split per model   month = month to date
#   burn = $/h   spark = last 7 days   cache = prompt-cache hit rate
#   search = web searches   credits = usage credits (REMOTE)   warn = up to two warnings
LINE2={LINE2}

# off = no git segment · branch = branch name only (free) · dirty = also count changes
GIT={GIT}

# 1 = also fetch per-model quotas (Fable 5, Opus, ...) and the usage-credit balance
# from api.anthropic.com. The only part of the script that touches the network.
REMOTE={REMOTE}

# Desktop notification when something crosses THRESHOLD, fired once per crossing:
# off | threshold | all (all also warns when a limit is projected to run out)
NOTIFY={NOTIFY}
"""

PRESET_DIR = os.path.join(HOME, "statusline-presets")

def write_conf_file(conf, path=None):
    path = path or CONF_PATH_PY
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w") as fh:
        fh.write(CONF_TEMPLATE.format(**{k: conf.get(k, DEFAULTS[k]) for k in DEFAULTS}))

def list_presets():
    try:
        return sorted(f[:-5] for f in os.listdir(PRESET_DIR) if f.endswith(".conf"))
    except OSError:
        return []

def _sample_payload():
    now = time.time()
    cwd = os.environ.get("TUI_CWD") or os.getcwd()
    return {
        "session_name": "usage statusline",
        "model": {"id": "claude-opus-5[1m]", "display_name": "Opus 5"},
        "effort": {"level": "high"},
        "cwd": cwd,
        "workspace": {"current_dir": cwd, "project_dir": cwd},
        "pr": {"number": 42, "review_state": "approved"},
        "context_window": {"used_percentage": 12, "context_window_size": 1000000},
        "cost": {"total_cost_usd": 2.10, "total_duration_ms": 4260000},
        "rate_limits": {"five_hour": {"used_percentage": 34, "resets_at": now + 2340},
                        "seven_day": {"used_percentage": 83, "resets_at": now + 200000}},
    }

CATALOG1 = ["title", "model", "effort", "git", "dir", "pr", "vim", "agent", "cmd",
            "5h", "7d", "quota", "budget", "ctx", "time"]
CATALOG2 = ["session", "today", "models", "month", "eom", "proj", "burn", "spark",
            "cache", "search", "credits", "warn"]
TUI_ENUMS = {
    "THEME": list(THEMES.keys()), "PALETTE": list(PALETTES.keys()),
    "ICONS": ["unicode", "nerd", "none"],
    "BAR": ["theme", "boxes", "slant", "shade", "line", "dots", "mini", "bars", "ascii", "dot"],
    "BAR_HEAT": ["0", "1"],
    "LINES": ["2", "1"], "STYLE": ["adaptive", "full", "compact"],
    "RULE": ["0", "1"],
    "GIT": ["branch", "dirty", "off"], "REMOTE": ["0", "1"],
    "NOTIFY": ["off", "threshold", "all"],
}
TUI_HELP = {
    "THEME": "powerline/slant/capsule look best with a Nerd Font; with Icons=unicode they use ▶ and ▐▌ instead, so they work in any font",
    "PALETTE": "recolors every theme; green→amber→red always keeps its meaning",
    "ICONS": "unicode = ⚡ ⑂ ⏱ everywhere · nerd = Nerd Font glyphs (needs the font!) · none = text only",
    "BAR": "meter bar style: theme keeps each theme's own · ▉░ ▰▱ █▒ ━╌ ●○ ▪▫ ▮▯ #-",
    "BARW": "meter bar length in cells (4-16)",
    "BAR_HEAT": "color bar cells by zone (green/amber/red) — sep themes only (plain/boxed/dots/frame)",
    "eom": "straight-line month-end forecast; red + warning when it beats your monthly budget",
    "proj": "the most expensive project today (from transcript folders)",
    "BUDGET_MONTH": "monthly $ target: adds a budget meter with $ left, warnings and a runs-out projection (0 = off)",
    "BUDGET_DAY": "daily $ target, same meter per day (0 = off)",
    "budget": "your own $ target as a meter (set Budget $/mo or $/day)",
    "cmd": "output of your own command (set CMD= in the conf file; cached, never blocks)",
    "LINES": "2 = usage on top, money below · 1 = everything on one line",
    "STYLE": "adaptive shows a meter only once it matters; full always draws bars",
    "THRESHOLD": "at this % a meter turns red, gets a bar and a warning",
    "NOTICE": "adaptive only: meters below this % stay hidden",
    "RULE": "adds a ─ rule as the last line — separates usage from Claude Code's own footer",
    "GIT": "branch is read from .git/HEAD (free); dirty also counts changes in the background",
    "REMOTE": "fetches Fable 5/Opus quotas + usage credits from api.anthropic.com (cached, opt-in)",
    "NOTIFY": "desktop notification when something crosses the threshold",
    "title": "session name set with /rename", "model": "current model + fast-mode badge",
    "effort": "reasoning effort level", "git": "branch (+ changed files with GIT=dirty)",
    "dir": "project / repo name", "pr": "open PR for this branch",
    "vim": "vim editor mode (only in vim mode)", "agent": "agent name (claude --agent)",
    "5h": "5-hour subscription window", "7d": "7-day subscription window",
    "quota": "every per-model weekly window the account has (needs Remote)",
    "ctx": "context window use + auto-compact countdown", "time": "session wall-clock",
    "session": "this session's cost as Claude Code reports it",
    "today": "all local sessions today, reconstructed at API prices",
    "models": "today split per model family", "month": "month to date",
    "burn": "current $/hour", "spark": "last 7 days as a sparkline",
    "cache": "prompt-cache hit rate (high is good)", "search": "web searches today",
    "credits": "usage credits burned this month (needs Remote)",
    "warn": "up to two warnings: limits, credits, auto-compact, projections",
}
TUI_NUMS = {"THRESHOLD": (5, 50, 100), "NOTICE": (5, 0, 95), "BARW": (1, 4, 16),
            "BUDGET_MONTH": (50, 0, 1000000), "BUDGET_DAY": (10, 0, 100000)}

def run_tui():
    import termios, select

    try:
        tin = open("/dev/tty", "rb", buffering=0)
        tout = open("/dev/tty", "w")
    except OSError:
        write_conf_file(dict(DEFAULTS))
        print("No terminal available — wrote defaults to " + CONF_PATH_PY)
        return

    conf = dict(DEFAULTS)
    for k, v in _load_conf_file().items():
        if k in conf and v:
            conf[k] = v

    def mklist(key, catalog):
        cur = [x.strip() for x in conf[key].split(",") if x.strip()]
        items = [[k, True] for k in cur]
        items += [[k, False] for k in catalog if k not in cur]
        return items
    items1, items2 = mklist("SEGMENTS", CATALOG1), mklist("LINE2", CATALOG2)

    opt_keys = ["THEME", "PALETTE", "ICONS", "BAR", "BARW", "BAR_HEAT", "LINES", "STYLE",
                "THRESHOLD", "NOTICE", "RULE", "BUDGET_MONTH", "BUDGET_DAY",
                "GIT", "REMOTE", "NOTIFY"]
    rows = [("opt", k) for k in opt_keys]
    rows.append(("head", "Line 1   space toggle · K/J move up/down"))
    rows += [("seg", (items1, i)) for i in range(len(items1))]
    rows.append(("head", "Line 2"))
    rows += [("seg", (items2, i)) for i in range(len(items2))]

    LABELS = {"THEME": "Theme", "PALETTE": "Palette", "ICONS": "Icons",
              "BAR": "Bar", "BARW": "Bar width", "BAR_HEAT": "Heat bar",
              "LINES": "Lines", "STYLE": "Density", "THRESHOLD": "Threshold",
              "NOTICE": "Notice", "RULE": "Rule line", "GIT": "Git",
              "BUDGET_MONTH": "Budget $/mo", "BUDGET_DAY": "Budget $/day",
              "REMOTE": "Remote fetch", "NOTIFY": "Notify"}
    ENUM_NAMES = {"REMOTE": {"0": "off", "1": "on"}, "RULE": {"0": "off", "1": "on"},
                  "BAR_HEAT": {"0": "off", "1": "on"}}

    def state_conf():
        c = dict(conf)
        c["SEGMENTS"] = ",".join(k for k, on in items1 if on)
        c["LINE2"] = ",".join(k for k, on in items2 if on)
        return c

    def preview_lines(width):
        globals()["WIDTH"] = max(20, width)
        try:
            apply_config(state_conf())
            text, _, _, _ = render_status(_sample_payload())
            return text.split("\n") or [""]
        except Exception as e:
            return ["(preview failed: %s)" % type(e).__name__]

    cursor, top, msg = 0, 0, ""
    preset_idx = -1

    def draw():
        try:
            cols, lines_n = os.get_terminal_size(tout.fileno())
        except OSError:
            cols, lines_n = 80, 24
        buf = ["\033[H\033[2J"]
        if lines_n < 10 or cols < 40:
            buf.append("Terminal too small for the configurator — enlarge the window,\r\n"
                       "or press q to quit.\r\n")
            tout.write("".join(buf)); tout.flush()
            return
        pv = preview_lines(cols - 2)
        head_h, foot_h = 2, 4 + len(pv)
        avail = max(3, lines_n - head_h - foot_h)

        nonlocal top
        if cursor < top: top = cursor
        if cursor >= top + avail: top = cursor - avail + 1

        buf.append("\033[1m Claude statusline — configurator\033[0m"
                   "\033[38;5;245m   ↑↓ move · ←→ change · space toggle · K/J reorder"
                   " · p/P presets · s save · q quit\033[0m\r\n")
        buf.append("\033[38;5;238m" + "─" * (cols - 1) + "\033[0m\r\n")
        brand, green = PALETTES[PALETTE]["brand"], PALETTES[PALETTE]["green"]
        CHIP = "\033[48;5;%dm\033[38;5;232m %%s \033[0m" % brand
        # The highlight background wraps ONLY the label and is closed before anything
        # else is drawn — re-arming it after resets is what smeared the option row.
        def label_cell(text, cur, w=13):
            if cur:
                return ("\033[38;5;%dm▸\033[0m" % brand
                        + "\033[48;5;237m\033[1m %-*s \033[0m" % (w, text))
            return "  %-*s " % (w, text)
        for idx in range(top, min(len(rows), top + avail)):
            kind, ref = rows[idx]
            cur = (idx == cursor)
            if kind == "head":
                buf.append("\033[38;5;245m " + ref + "\033[0m\r\n")
            elif kind == "opt":
                val = conf[ref]
                if ref in TUI_ENUMS:
                    opts = TUI_ENUMS[ref]
                    names = [ENUM_NAMES.get(ref, {}).get(o, o) for o in opts]
                    shown_val = ENUM_NAMES.get(ref, {}).get(val if val in opts else opts[0], val)
                    plain_len = 18 + sum(len(n) + 3 for n in names)
                    if plain_len > cols:             # narrow terminal: chip only
                        body = CHIP % shown_val
                    else:
                        # selected value = colored chip, the rest dim, no background
                        body = " ".join(CHIP % n if n == shown_val
                                        else "\033[38;5;245m %s \033[0m" % n
                                        for n in names)
                else:
                    body = CHIP % val
                buf.append(" %s %s\r\n" % (label_cell(LABELS[ref], cur), body))
            else:
                lst, i = ref
                k, on = lst[i]
                if cur:
                    # one self-contained span: fg changes inside use 38;5;N / 39,
                    # a single reset closes the whole cell
                    box = ("\033[38;5;%dm[x]\033[39m" % green) if on else "[ ]"
                    buf.append("   \033[38;5;%dm▸\033[0m\033[48;5;237m\033[1m %s %s \033[0m\r\n"
                               % (brand, box, k))
                else:
                    box = ("\033[38;5;%dm[x]\033[0m" % green) if on else "\033[38;5;245m[ ]\033[0m"
                    buf.append("     %s %s\r\n" % (box, k))
        buf.append("\033[38;5;238m" + "─" * (cols - 1) + "\033[0m\r\n")
        kind_c, ref_c = rows[cursor]
        help_key = ref_c if kind_c == "opt" else (ref_c[0][ref_c[1]][0] if kind_c == "seg" else "")
        help_txt = TUI_HELP.get(help_key, "")
        if help_txt:
            buf.append("\033[38;5;245m " + help_txt[:cols - 2] + "\033[0m\r\n")
        buf.append("\033[38;5;245m preview — live, with your real spend numbers"
                   + ("   " + msg if msg else "") + "\033[0m\r\n")
        for line in pv:
            buf.append(" " + line + "\r\n")
        tout.write("".join(buf)); tout.flush()

    def read_key():
        b = tin.read(1)
        if not b:
            return ""
        if b == b"\x1b":
            seq = b""
            while len(seq) < 2 and select.select([tin], [], [], 0.05)[0]:
                seq += tin.read(1)
            return {"[A": "up", "[B": "down", "[C": "right", "[D": "left"}.get(
                seq.decode("latin1", "replace"), "esc")
        return b.decode("latin1", "replace")

    def cycle(key, step):
        if key in TUI_ENUMS:
            opts = TUI_ENUMS[key]
            cur = conf[key] if conf[key] in opts else opts[0]
            conf[key] = opts[(opts.index(cur) + step) % len(opts)]
        elif key in TUI_NUMS:
            inc, lo, hi = TUI_NUMS[key]
            try:
                v = int(float(conf[key]))
            except ValueError:
                v = int(DEFAULTS[key])
            conf[key] = str(max(lo, min(hi, v + step * inc)))

    fd = tin.fileno()
    old = termios.tcgetattr(fd)
    raw = termios.tcgetattr(fd)
    raw[3] &= ~(termios.ECHO | termios.ICANON)   # lflags: raw-ish, keep signals
    raw[6][termios.VMIN], raw[6][termios.VTIME] = 1, 0
    tout.write("\033[?1049h\033[?25l")
    tout.flush()
    saved = False
    try:
        termios.tcsetattr(fd, termios.TCSADRAIN, raw)
        while True:
            draw()
            key = read_key()
            msg = ""
            kind, ref = rows[cursor]
            if key in ("q", "\x03", "esc"):
                break
            elif key == "s":
                write_conf_file(state_conf())
                saved = True
                break
            elif key == "r":
                conf = dict(DEFAULTS)
                items1[:], items2[:] = mklist("SEGMENTS", CATALOG1), mklist("LINE2", CATALOG2)
                msg = "reset to defaults"
            elif key == "p":
                names = list_presets()
                if not names:
                    msg = "no presets yet — press P to save one"
                else:
                    preset_idx = (preset_idx + 1) % len(names)
                    loaded = _load_conf_file(os.path.join(PRESET_DIR, names[preset_idx] + ".conf"))
                    conf = dict(DEFAULTS)
                    conf.update({k: v for k, v in loaded.items() if k in conf and v})
                    items1[:], items2[:] = mklist("SEGMENTS", CATALOG1), mklist("LINE2", CATALOG2)
                    msg = "preset: " + names[preset_idx]
            elif key == "P":
                # one-line name prompt in the footer; Enter saves, Esc cancels
                name = ""
                while True:
                    tout.write("\033[999;1H\033[2K save preset as: %s\033[K" % name)
                    tout.flush()
                    ch = read_key()
                    if ch in ("\r", "\n"):
                        break
                    if ch in ("esc", "\x03"):
                        name = ""
                        break
                    if ch in ("\x7f", "\x08"):
                        name = name[:-1]
                    elif len(ch) == 1 and (ch.isalnum() or ch in "-_"):
                        name += ch.lower()
                if name:
                    write_conf_file(state_conf(), os.path.join(PRESET_DIR, name + ".conf"))
                    msg = "saved preset: " + name
            elif key == "\t":
                # jump to the next section: options → line 1 → line 2 → options
                starts = [0] + [i + 1 for i, r in enumerate(rows) if r[0] == "head"]
                cursor = next((s for s in starts if s > cursor), starts[0])
            elif key in ("up", "k"):
                cursor = (cursor - 1) % len(rows)
                if rows[cursor][0] == "head":
                    cursor = (cursor - 1) % len(rows)
            elif key in ("down", "j"):
                cursor = (cursor + 1) % len(rows)
                if rows[cursor][0] == "head":
                    cursor = (cursor + 1) % len(rows)
            elif key in ("left", "right") and kind == "opt":
                cycle(ref, 1 if key == "right" else -1)
            elif key in ("+", "=") and kind == "opt":
                cycle(ref, 1)
            elif key == "-" and kind == "opt":
                cycle(ref, -1)
            elif key == " " and kind == "seg":
                lst, i = ref
                lst[i][1] = not lst[i][1]
            elif key in ("K", "J") and kind == "seg":
                lst, i = ref
                j = i - 1 if key == "K" else i + 1
                if 0 <= j < len(lst):
                    lst[i], lst[j] = lst[j], lst[i]
                    cursor += (-1 if key == "K" else 1)
                    if rows[cursor][0] == "head":
                        cursor += (-1 if key == "K" else 1)
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        tout.write("\033[?1049l\033[?25h")
        tout.flush()
    print(("✓ wrote " + CONF_PATH_PY + "\n  Open a NEW Claude Code session to see it.")
          if saved else "Nothing written.")

# ---- entry ----------------------------------------------------------------------
if MODE == "tui":
    run_tui()
else:
    text, meters, remote, now = render_status(d)
    if MODE == "render":
        maybe_notify(meters, remote, d, now)
    print(text)
PYEOF
)

# ---- sample payload used by --preview and the wizard ------------------------
sample_json() {
  python3 - "$PWD" <<'EOF'
import json, os, sys, time
now = time.time()
print(json.dumps({
    "session_name": "usage statusline v3",
    "model": {"id": "claude-opus-5[1m]", "display_name": "Opus 5"},
    "effort": {"level": "high"},
    "cwd": sys.argv[1],
    "workspace": {"current_dir": sys.argv[1], "project_dir": sys.argv[1]},
    "context_window": {"used_percentage": 12, "context_window_size": 1000000},
    "cost": {"total_cost_usd": 2.10, "total_duration_ms": 4260000},
    "rate_limits": {"five_hour": {"used_percentage": 34, "resets_at": now + 2340},
                    "seven_day": {"used_percentage": 83, "resets_at": now + 200000}},
}))
EOF
}

render_preview() { # render_preview KEY=VAL ...
  sample_json | env USAGE_MODE=preview "$@" python3 -c "$PY"
}

case "${1:-}" in
  --configure)
    # Live TUI editor (raw /dev/tty, zero deps). Falls back to writing defaults
    # when no terminal is attached.
    USAGE_MODE=tui TUI_CWD="$PWD" python3 -c "$PY" < /dev/null
    exit $? ;;
  --preview)
    if [ -n "${2:-}" ]; then
      render_preview CLAUDE_USAGE_THEME="$2" ${3:+CLAUDE_USAGE_PALETTE="$3"}
    else
      for t in plain boxed dots mono badge powerline slant capsule; do
        printf '%s:\n' "$t"; render_preview CLAUDE_USAGE_THEME="$t" | sed 's/^/  /'; echo
      done
    fi
    exit 0 ;;
  --save-preset|--preset|--presets)
    PRESET_DIR="$HOME/.claude/statusline-presets"
    case "$1" in
      --presets)
        ls "$PRESET_DIR" 2>/dev/null | sed -n 's/\.conf$//p' | sed 's/^/  /'
        [ -d "$PRESET_DIR" ] && [ -n "$(ls "$PRESET_DIR" 2>/dev/null)" ] \
          || echo "no presets yet — save one with: $0 --save-preset <name>"
        exit 0 ;;
      --save-preset)
        name="${2:-}"
        case "$name" in
          ''|*[!a-z0-9_-]*) echo "usage: $0 --save-preset <name>  (a-z 0-9 _ -)"; exit 1 ;;
        esac
        [ -f "$CONF_PATH" ] || { echo "no config yet — run: $0 --configure"; exit 1; }
        mkdir -p "$PRESET_DIR"
        cp "$CONF_PATH" "$PRESET_DIR/$name.conf"
        echo "✓ saved preset '$name' from $CONF_PATH"
        exit 0 ;;
      --preset)
        name="${2:-}"
        case "$name" in
          ''|*[!a-z0-9_-]*) echo "usage: $0 --preset <name>"; exit 1 ;;
        esac
        [ -f "$PRESET_DIR/$name.conf" ] || {
          echo "no such preset '$name' — available:"; ls "$PRESET_DIR" 2>/dev/null | sed -n 's/\.conf$/  /p'
          exit 1
        }
        cp "$PRESET_DIR/$name.conf" "$CONF_PATH"
        echo "✓ activated preset '$name' → $CONF_PATH (new Claude Code session to see it)"
        exit 0 ;;
    esac ;;
  --doctor)
    net=""; [ "${2:-}" = "--net" ] && net=1
    USAGE_MODE=doctor DOCTOR_NET="$net" DOCTOR_CWD="$PWD" python3 -c "$PY" < /dev/null
    exit 0 ;;
  --report)
    days=30; fmt=text
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --days) days="${2:-30}"; shift 2 ;;
        --json) fmt=json; shift ;;
        --csv)  fmt=csv;  shift ;;
        --projects) proj=1; shift ;;
        *) shift ;;
      esac
    done
    USAGE_MODE=report REPORT_DAYS="$days" REPORT_FORMAT="$fmt" REPORT_PROJECTS="${proj:-}" \
      python3 -c "$PY" < /dev/null
    exit 0 ;;
  --help|-h)
    echo "usage: statusline-usage.sh [command]"
    echo "  (no arguments)         read the Claude Code statusline JSON on stdin and render"
    echo "  --configure            full-screen live editor (arrows, space, J/K, s to save)"
    echo "  --preview [theme] [palette]"
    echo "                         draw a sample; themes: plain boxed dots mono badge"
    echo "                         powerline slant capsule · palettes: default ocean sunset forest"
    echo "  --doctor [--net]       check config, caches, token, git and glyphs"
    echo "  --report [--days N] [--json|--csv]"
    echo "                         per-day spend by model, tokens, searches, cache hit rate"
    echo "  --save-preset <name> / --preset <name> / --presets"
    echo "                         snapshot, activate or list named configurations"
    exit 0 ;;
esac

input=$(cat)
printf '%s' "$input" | python3 -c "$PY"
