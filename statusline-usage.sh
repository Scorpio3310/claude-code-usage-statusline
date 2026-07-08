#!/usr/bin/env bash
# Claude Usage Monitor — Claude Code statusline.
# Shows the current model, 5-hour session and 7-day weekly usage (colored by
# threshold, with reset countdowns), context-window %, reasoning effort, and cost.
# Usage % comes from Claude Code on stdin (rate_limits.*).
#
# The trailing "today ≈$" is the TOTAL spend across ALL your Claude Code
# sessions/windows for the current local day — not just this window. Claude Code
# only hands the statusline the current session's cost.total_cost_usd (shown as
# "session $"), so to get a true daily total we reconstruct per-message cost from
# the token usage recorded in the transcripts under ~/.claude/projects/*/*.jsonl
# and sum today's across every session. It is an estimate at published API rates.
# Results are cached per-file (by mtime+size) so this stays fast across renders.
#
# Threshold matches the browser extension; override with CLAUDE_USAGE_THRESHOLD.
input=$(cat)
printf '%s' "$input" | THRESHOLD="${CLAUDE_USAGE_THRESHOLD:-80}" python3 -c '
import sys, json, time, os, glob, tempfile, re
from datetime import datetime, timezone

th = float(os.environ.get("THRESHOLD", "80"))
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)

RESET = "\033[0m"
DIM   = "\033[38;5;245m"
BRAND = "\033[38;5;209m"   # claude-ish coral for the bolt
MONEY = "\033[38;5;150m"   # soft green for the dollar amount

MODEL_COLORS = {
    "fable":  "\033[38;5;141m",  # purple
    "sonnet": "\033[38;5;75m",   # blue
    "haiku":  "\033[38;5;114m",  # green
    "opus":   BRAND,             # coral
}
DEFAULT_MODEL_COLOR = "\033[38;5;180m"  # warm tan for unknown/new families

def color(p):
    if p >= th:            return "\033[38;5;203m"  # red
    if p >= max(0, th-15): return "\033[38;5;214m"  # orange
    return "\033[38;5;114m"                          # green

def bar(p, n=8):
    f = max(0, min(n, int(round(p / 100.0 * n))))
    return "▉" * f + "░" * (n - f)

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

def model_str(d):
    # Colored model name: label from display_name, color + version + 1M tag from
    # the id. Future-proof: unknown/new families still get a color and version.
    md   = d.get("model") or {}
    mid  = (md.get("id") or "").lower()
    disp = (md.get("display_name") or "").strip()

    # color from a known family; anything new falls back to a visible default
    fam_key = None
    for key in ("fable", "mythos", "sonnet", "haiku", "opus"):
        if key in mid:
            fam_key = "fable" if key == "mythos" else key
            break
    col = MODEL_COLORS.get(fam_key, DEFAULT_MODEL_COLOR)

    # label: prefer Claude Code display_name; else derive from the id
    label = disp
    if not label:
        m = re.search(r"claude-([a-z]+)", mid)
        label = m.group(1).capitalize() if m else (mid or "?")

    # version parsed generically (works for any future family); avoid duplicating
    mm = re.search(r"claude-[a-z]+-(\d+(?:-\d+)?)", mid)
    if mm:
        ver = mm.group(1).replace("-", ".")
        if ver not in label:
            label += " " + ver

    cw = d.get("context_window") or {}
    is_1m = "[1m]" in mid or (cw.get("context_window_size") or 0) >= 1000000
    low = label.lower()
    one_m = "·1M" if (is_1m and "1m" not in low and "context" not in low) else ""
    return f"{col}{label}{one_m}{RESET}"

def effort_str(d):
    # Reasoning effort (low/medium/high/xhigh/max); absent if unsupported.
    lvl = (d.get("effort") or {}).get("level")
    return f"{DIM}{lvl}{RESET}" if lvl else ""

def ctx_str(d):
    # Context-window usage %, colored by the same threshold as the meters.
    p = (d.get("context_window") or {}).get("used_percentage")
    if p is None: return ""
    return f"{color(p)}ctx {p:.0f}%{RESET}"

def dur_str(d):
    # Wall-clock time since the session started (cost.total_duration_ms).
    ms = (d.get("cost") or {}).get("total_duration_ms")
    if not ms: return ""
    s = int(ms) // 1000
    if   s < 60:   t = f"{s}s"
    elif s < 3600: t = f"{s // 60}m"
    else:          t = f"{s // 3600}h {(s % 3600) // 60}m"
    return f"{DIM}⏱ {t}{RESET}"

def seg(label, win):
    if not isinstance(win, dict): return None
    p = win.get("used_percentage")
    if p is None: return None
    c = color(p)
    warn = "⚠ " if p >= th else ""
    cd = countdown(win.get("resets_at"))
    s = f"{c}{warn}{label} {bar(p)} {p:.0f}%{RESET}"
    if cd: s += f"{DIM}·{cd}{RESET}"
    return s

rl = d.get("rate_limits") or {}
parts = [x for x in (seg("5h", rl.get("five_hour")),
                     seg("7d", rl.get("seven_day"))) if x]

# ---- aggregate spend across ALL sessions for today (local day) --------------
# Per-model $/token (input, output). Cache read = 0.1x input; cache write =
# 1.25x (5m) / 2x (1h) input. Standard sticker rates; a reconstruction, so it
# will be close to but not identical to Claude Code cost.total_cost_usd.
def model_rates(model):
    m = (model or "").lower()
    def per(i, o): return (i / 1e6, o / 1e6)
    if "haiku-3-5" in m or "haiku-3.5" in m: return per(0.80, 4.0)
    if "haiku-3" in m:                       return per(0.25, 1.25)
    if "haiku" in m:                         return per(1.0, 5.0)   # haiku 4.5
    if "fable" in m or "mythos" in m:        return per(10.0, 50.0)
    if "sonnet" in m:                        return per(3.0, 15.0)
    if "opus-4-1" in m or "opus-4-0" in m:   return per(15.0, 75.0)
    if "opus-4" in m or "opus" in m:         return per(5.0, 25.0)  # opus 4.5-4.8
    return per(5.0, 25.0)                                           # sensible default

def msg_cost(usage, model):
    if not isinstance(usage, dict): return 0.0
    ir, orate = model_rates(model)
    c  = (usage.get("input_tokens") or 0) * ir
    c += (usage.get("output_tokens") or 0) * orate
    c += (usage.get("cache_read_input_tokens") or 0) * ir * 0.1
    cc = usage.get("cache_creation")
    if isinstance(cc, dict):
        c += (cc.get("ephemeral_5m_input_tokens") or 0) * ir * 1.25
        c += (cc.get("ephemeral_1h_input_tokens") or 0) * ir * 2.0
    else:
        c += (usage.get("cache_creation_input_tokens") or 0) * ir * 1.25
    return c

def local_day(ts):
    # ISO 8601 like 2026-07-02T09:07:06.416Z -> local YYYY-MM-DD
    try:
        s = ts.replace("Z", "+00:00")
        dt = datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone().strftime("%Y-%m-%d")
    except Exception:
        return None

def file_daily_costs(path):
    # Sum cost per local day for one transcript file.
    days = {}
    try:
        with open(path, "r", errors="ignore") as fh:
            for line in fh:
                if "usage" not in line:   # cheap prefilter (double quotes only: this python is inside a single-quoted -c)
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                msg = o.get("message")
                if not isinstance(msg, dict):
                    continue
                usage = msg.get("usage")
                if not usage:
                    continue
                day = local_day(o.get("timestamp") or "")
                if not day:
                    continue
                days[day] = days.get(day, 0.0) + msg_cost(usage, msg.get("model"))
    except Exception:
        return {}
    return days

def today_total():
    home = os.path.expanduser("~/.claude")
    files = glob.glob(os.path.join(home, "projects", "*", "*.jsonl"))
    if not files:
        return None
    cache_path = os.path.join(home, ".usage-cost-cache.json")
    cache = {}
    try:
        with open(cache_path) as fh:
            cache = json.load(fh)
    except Exception:
        cache = {}
    entries = cache.get("files", {}) if isinstance(cache, dict) else {}

    today = datetime.now().astimezone().strftime("%Y-%m-%d")
    total = 0.0
    new_entries = {}
    dirty = False
    for path in files:
        try:
            st = os.stat(path)
        except OSError:
            continue
        prev = entries.get(path)
        if prev and prev.get("mtime") == st.st_mtime and prev.get("size") == st.st_size:
            days = prev.get("days", {})
        else:
            days = file_daily_costs(path)
            dirty = True
        new_entries[path] = {"mtime": st.st_mtime, "size": st.st_size, "days": days}
        total += days.get(today, 0.0)

    if dirty or len(new_entries) != len(entries):
        try:
            fd, tmp = tempfile.mkstemp(dir=home, prefix=".usage-cost-")
            with os.fdopen(fd, "w") as fh:
                json.dump({"version": 1, "files": new_entries}, fh)
            os.replace(tmp, cache_path)
        except Exception:
            pass
    return total

# ---- cost segment: this session (stdin) + today total (reconstruction) ------
spend = ""
try:
    sess = (d.get("cost") or {}).get("total_cost_usd")
    tot  = today_total()
    bits = []
    if isinstance(sess, (int, float)) and sess > 0:
        bits.append(f"session {MONEY}${sess:.2f}{RESET}")
    if tot:
        bits.append(f"today {MONEY}≈${tot:.2f}{RESET}")
    if bits:
        spend = "  " + f"{DIM} · {RESET}".join(bits)
except Exception:
    spend = ""

# ---- assemble ---------------------------------------------------------------
bolt = f"{BRAND}⚡{RESET}"
head = f"{bolt} {model_str(d)}"
e = effort_str(d)
if e: head += f" {e}"

if parts:
    body = "  " + "  ".join(parts)
else:
    body = f"  {DIM}usage n/a (Pro/Max, after first reply){RESET}"

c = ctx_str(d)
if c: body += f"  {c}"

du = dur_str(d)
if du: body += f"  {du}"

print(head + body + spend)
'
