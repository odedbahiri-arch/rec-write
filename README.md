# ● REC — Write Tool

A system-wide AI writing assistant for Windows, by [RecStudio](https://lab.recstudio.dev).
Select text in **any app**, press a hotkey, and it's proofread / rewritten /
summarized in place. Fully bilingual — the hotkeys work under Hebrew and English
keyboard layouts alike, and the UI itself speaks both languages.

## Install (60 seconds)

1. Download the latest release zip from the [Releases page](../../releases/latest) and unzip it anywhere (e.g. `C:\Tools\REC-WriteTool`).
2. Run `REC-WriteTool.exe`. Botan (the peanut 🥜) appears in your tray.
3. A short setup wizard opens: it explains the hotkeys, then walks you through
   getting a **free Gemini API key** (button opens
   [aistudio.google.com/apikey](https://aistudio.google.com/apikey) — ~30
   seconds, no credit card). The key is tested against Gemini before setup
   completes, and stored only on your computer, in a `.env` next to the app.
4. Select some text anywhere and press `Ctrl+Alt+J`. Done.

Tray → **Settings** for interface language (English/עברית), starting with
Windows, and changing the key later.

## Hotkeys

| Keys | Action |
|------|--------|
| Ctrl+Alt+Space | **Popup menu** (all actions + a free-form Custom instruction) |
| Ctrl+Alt+J | Proofread |
| Ctrl+Alt+R | Rewrite |
| Ctrl+Alt+F | Friendly |
| Ctrl+Alt+P | Professional |
| Ctrl+Alt+C | Concise |
| Ctrl+Alt+S | Summary (opens a window) |
| Ctrl+Alt+K | Key points (opens a window) |
| Ctrl+Alt+T | Table (opens a window) |

Hotkeys are bound to **physical key positions** (scan codes), so they fire the
same whether your keyboard is currently on English or Hebrew — that's the whole
reason this tool exists.

Most actions replace your selection in place. Summary / Key Points / Table open
a **result window** instead — and that window is a live conversation: type a
follow-up ("shorter", "in Hebrew", "drop the last row") and press Enter.

## Hebrew

- Hebrew text in, Hebrew text out — all actions are language-preserving.
- Set `"ui_language": "he"` in `config.json` for a full Hebrew, right-to-left UI
  (popup menu, result window, tray). `"en"` is the default.
- Hebrew answers get proper RTL display even in the English UI.

## Configuration (`config.json`)

Every action is just config — a `label`, an `instruction` (system prompt), a
`prefix`, and whether it opens a window. Add your own actions without touching
code; the tray has an "Edit config" shortcut. Other knobs: `model`,
`temperature`, `timeout_seconds`, `paste_settle_ms`, `ui_language`.

Privacy defaults: `log_text_previews` is `false` in the shipped config — the
local log records only text *lengths*, never content. Your selected text goes to
Google's Gemini API for processing and nowhere else.

## Running from source

Releases are self-contained (no Python needed). To run from a checkout instead:

```
# needs AutoHotkey v2 + Python 3.11+
pip install requests
copy config.example.json config.json
# then run recwrite.ahk (the tool auto-detects your Python)
python recwrite.py --selftest   # verify config + key + API
```

The design is two deliberately separate layers:

- **`recwrite.ahk`** — the trigger layer: layout-independent global hotkeys and
  the clipboard shuttle (copy selection → run the brain → paste result →
  restore your clipboard). The only part that touches Windows internals.
- **`recwrite.py`** — the brain: a stateless text filter (`action + text in →
  transformed text out`), testable from the command line. Ships compiled as
  `recwrite-brain.exe` in releases.

Exit codes are the contract between them: `0` ok · `1` error · `2` text
unsuitable · `3` blocked by safety filter · `4` rate limited · `5` result
truncated but usable.

## Known limitations

- Runs without elevation, so hotkeys/paste can't reach windows running **as
  administrator** (Windows UIPI). Browsers, Office, chat apps are all fine.
- In editors that "copy the whole line when nothing is selected" (VS Code
  style), a stray hotkey press can rewrite the current line — select first.

## Updates

Tray → "Check for updates" pings the GitHub Releases feed and opens the
download page when a newer version exists. Nothing updates itself silently.

## License

MIT © RecStudio
