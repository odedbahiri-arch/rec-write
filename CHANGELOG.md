# Changelog

## v1.1.0 — 2026-08-05

Friendly first-run, borrowed with pride from WritingTools' onboarding flow.

- **Onboarding wizard**: welcome page (what the tool does + the hotkeys) → key page with a "Get a free key" button, show/hide toggle, and **Test & Save** that validates the key with a real Gemini round-trip before declaring success → "you're all set" page with first steps.
- **Settings window** (tray → Settings): interface language (עברית/English), start-with-Windows toggle, API key status + change, advanced config shortcut. Config edits go through the brain (`--set`), never hand-written JSON.
- Autostart managed in-app via a Startup-folder shortcut.

## v1.0.0 — 2026-08-05

First public release, rebranded from the internal "RecWrite".

- **● REC — Write Tool branding**: Botan tray icon, red-dot lockup, RecStudio paper/ink palette in the result window.
- **Bilingual UI**: `"ui_language": "he"` gives a full Hebrew, RTL-mirrored interface; Hebrew answers render RTL even in the English UI.
- **First-run key setup**: paste your own free Gemini API key once; stored locally in `.env` beside the app.
- **Self-contained releases**: compiled trigger (`REC-WriteTool.exe`) + compiled brain (`recwrite-brain.exe`) — no AutoHotkey or Python install needed.
- **Update check**: tray → "Check for updates" (check-and-link, never silent).
- Security/robustness pass: API key moved out of the request URL (could leak to the log on network errors), chat transcript markers hardened against injection, popup/clipboard race fixes, privacy-safe logging (`log_text_previews`).

### Earlier internal history (2026-07)

- 2026-07-25: two-layer prompt fix (system instruction + per-action user-turn prefix) — stops the model *answering* selected text that looks like a question; typed exit codes 0–5; result window became a live follow-up thread; Gemini safety filters relaxed for proofreading real-world text.
- 2026-07-15: initial build — scan-code hotkeys (layout-independent), clipboard shuttle, config-driven actions, Gemini brain.
