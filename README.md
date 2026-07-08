# Claude Code Usage Statusline

A single Bash script that turns the data Claude Code passes to a
[statusline](https://code.claude.com/docs/en/statusline) into a compact, colored
status bar showing your **current model**, **rate‑limit usage**, **context window**,
**reasoning effort**, and **cost** — no API key, no external server, nothing leaves
your machine.

![Claude Code usage statusline](screenshot.png)

```
⚡ Opus 4.8·1M high  5h ▉▉▉░░░░░ 34%·39m  7d ▉▉▉▉▉▉▉░ 83%·2d  ctx 12%  ⏱ 12m  session $2.10 · today ≈$28.90
```

## Install

Requires `python3` (the script uses it to parse and format the JSON).

```bash
bash install.sh      # copies the script to ~/.claude/ and registers it in settings.json
```

Then open a **new** Claude Code session. The installer backs up any existing
`settings.json` and refuses to overwrite a different statusline you already use.

<details>
<summary>Manual install</summary>

Copy `statusline-usage.sh` to `~/.claude/statusline-usage.sh`, make it executable
(`chmod +x`), and add this to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline-usage.sh",
    "padding": 1
  }
}
```
</details>

## What each part means

| Segment | Source | Meaning |
|---|---|---|
| `⚡ Opus 4.8·1M` | `model.id` | Current model, colored per family (Opus / Sonnet / Haiku / Fable), with version and a `·1M` tag when the model is running with the 1M‑token extended context window. |
| `high` | `effort.level` | Reasoning effort (`low`/`medium`/`high`/`xhigh`/`max`). Omitted when the model doesn't support it. |
| `5h … %·39m` | `rate_limits.five_hour` | Your **5‑hour** subscription usage and the countdown to reset. |
| `7d … %·2d` | `rate_limits.seven_day` | Your **7‑day (weekly)** subscription usage and reset countdown. |
| `ctx 12%` | `context_window.used_percentage` | How much of the context window is used, colored by the same green/orange/red threshold. |
| `⏱ 12m` | `cost.total_duration_ms` | Wall‑clock time since this session started (`45s` / `12m` / `1h 5m`). |
| `session $2.10` | `cost.total_cost_usd` | Cost of **this** Claude Code session, as reported by Claude Code. |
| `today ≈$28.90` | local transcripts | Estimated total across **all** local Claude Code sessions today (see below). |

The `⚠` marker and green → orange → red coloring kick in as you approach the
threshold (default **80%**; override with `CLAUDE_USAGE_THRESHOLD`).

### About `today ≈$`

Claude Code only gives the statusline the **current** session's cost. To show a true
daily total, the script reads your local transcripts under `~/.claude/projects/*/*.jsonl`
and reconstructs per‑message cost from token usage (input/output/cache × per‑model
rates), summing today's (local day) across every session. It's cached per file (by
mtime + size), so only changed transcripts are re‑parsed — it stays fast.

Important:
- It's an **estimate at published API list prices** (hence `≈`). On **Pro/Max** plans
  you pay a flat subscription, so this is a notional API‑equivalent figure, **not an
  actual bill**.
- It counts only **local Claude Code** sessions — it does **not** include claude.ai
  web usage or other machines.

### New models

The model segment is future‑proof — you rarely need to touch the script when Anthropic
ships a new model:

- **A new version of a known family** (e.g. `claude-opus-5`, `claude-sonnet-6`) works
  automatically: right family color, and the version is parsed from the id.
- **A brand‑new family** (a new name) still renders automatically — the label comes from
  Claude Code's `model.display_name`, the version from the id, and it gets a neutral default
  color. To give it a dedicated color, add one line to `MODEL_COLORS` (and, optionally, one
  `elif` for the family key).
- **Pricing** for the `today ≈$` estimate falls back to a default rate for an unrecognized
  model until you add its rate to `model_rates()` — API prices aren't part of the statusline
  data, so they can't be detected automatically.

## Notes & limitations

- `rate_limits` only appear for **Pro/Max** subscribers and only **after the first
  reply** in a session. Until then the statusline shows the model plus a short
  `usage n/a` hint.
- The `5h` and `7d` figures are **account‑wide** (shared across claude.ai, Claude
  Desktop, and Claude Code) — not per‑session — and only range **0 → 100%**. There is
  **no "how far over the limit"** value, and **no "extra/overage tokens beyond your
  plan"** value, because Claude Code does not send those to the statusline.
- Everything runs locally; no data is collected or transmitted anywhere.

## Files

| File | Role |
|------|------|
| `statusline-usage.sh` | The statusline script (Bash wrapper around inline `python3`). |
| `install.sh` | One‑command installer. |
| `README.md` | This file. |
| `screenshot.png` | Demo screenshot used above. |
| `LICENSE` | MIT license. |

## License

MIT — see [LICENSE](LICENSE).
