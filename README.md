# ● REC — Write Tool

A system-wide AI writing assistant for Windows, by [RecStudio](https://lab.recstudio.dev).
Select text in **any app**, press a hotkey, and it's proofread / rewritten /
summarized in place. Fully bilingual — the hotkeys work under Hebrew and English
keyboard layouts alike, and the UI itself speaks both languages.

## Install (60 seconds)

1. Download the latest zip — permanent link: [REC-WriteTool.zip](../../releases/latest/download/REC-WriteTool.zip) — and unzip it to a **permanent folder** (e.g. `C:\REC-WriteTool` — not Downloads, or autostart will break if you tidy up later). Hebrew speakers: the zip includes «התחלה מהירה.html» with the whole walkthrough.
2. Run `REC-WriteTool.exe`. Botan (the peanut 🥜) appears in your tray.
3. A short setup wizard opens: it explains the hotkeys, then walks you through
   getting a **free Gemini API key** (button opens
   [aistudio.google.com/apikey](https://aistudio.google.com/apikey) — ~30
   seconds, no credit card). The key is tested against Gemini before setup
   completes, and stored only on your computer, in a `.env` next to the app.
4. Select some text anywhere and press `Ctrl+Alt+J`. Done.

Tray → **Settings** (or double-click Botan) for interface language
(English/עברית), starting with Windows, your preferred menu hotkey, pausing the
hotkeys, and changing the key later.

> **Tip:** On Windows 11 new tray icons hide behind the **^** arrow near the
> clock. Click it to find Botan — and drag him onto the taskbar to pin him.

### "Windows protected your PC"?

This is normal for a free tool downloaded from GitHub that isn't code-signed
(signing certificates cost hundreds of dollars a year). Windows SmartScreen
shows a blue **"Windows protected your PC"** box because the file is new and
unsigned — not because anything is wrong. To proceed:

1. Click **More info** (small link, easy to miss).
2. Click **Run anyway**.

If "Run anyway" doesn't appear: right-click the downloaded **zip** →
Properties → check **Unblock** → OK, then re-extract. The whole source code of
this tool is public in this repository — you can read exactly what it does.

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

Releases are built and published entirely by GitHub Actions from a pushed tag —
see [docs/RELEASING.md](docs/RELEASING.md).

## Known limitations

- Runs without elevation, so hotkeys/paste can't reach windows running **as
  administrator** (Windows UIPI). Browsers, Office, chat apps are all fine.
- In editors that "copy the whole line when nothing is selected" (VS Code
  style), a stray hotkey press can rewrite the current line — select first.
- Some apps bind their own Ctrl+Alt shortcuts (the new Windows 11 Notepad's
  formatting keys, Word accelerators). If a direct hotkey clashes in an app
  you use a lot, turn off **Direct hotkeys** in Settings and work through the
  menu hotkey — every action stays available there.

## Updates

Tray → "Check for updates" pings the GitHub Releases feed and opens the
download page when a newer version exists. Nothing updates itself silently.

## License

MIT © RecStudio
