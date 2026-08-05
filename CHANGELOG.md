# Changelog

## v1.3.0 — 2026-08-05

The popup grows up, settings go instant.

- **New popup**: `Ctrl+Alt+Space` now opens a branded button window at the cursor (the WritingTools shape) — action buttons in a grid, window-actions marked ⧉, and a free-text "describe any change" field with Enter-to-send (replaces the separate Custom dialog). Dismisses on Esc or clicking elsewhere; multi-monitor aware. Verified end-to-end with a real synthetic-hotkey drive.
- **Settings apply instantly** — no Save button. Click עברית/English and the whole UI switches on the spot (no restart); autostart applies on click; the menu hotkey applies as soon as you press the combo in the picker, with the current binding always shown in bold (and a reset-to-default button).
- **Brand lockup always reads left-to-right** — "● REC — Write Tool · הגדרות" — in every window, including mirrored Hebrew ones (dot first, title after).
- Diagnostics: brain-launch failures and popup exceptions now log their cause instead of only flashing a tooltip.

## v1.2.0 — 2026-08-05

UX hardening release, driven by a WritingTools issue-tracker autopsy, a free-API-tier research pass, and a full UX audit.

- **Double-click Botan opens Settings**; tray menu simplified for non-technical users (config/script editors removed).
- **Hotkey picker in Settings** — click the box, press the combo you want; default and recommendation shown; reset button. Stored in config, applied on save.
- **"REC — working…" cursor tooltip** during every API call, and all operational messages moved from toast notifications to cursor tooltips — Do-Not-Disturb can no longer silence errors.
- **Wrong-window paste guard**: if you switch windows during a slow call, the result goes to the clipboard with a note instead of pasting into the wrong app.
- **Physical modifier-release wait** before the copy simulation (kills the classic "hotkey typed a letter over my selection" failure class, WritingTools #183/#207).
- **Pause hotkeys** tray toggle.
- **Safer key changes**: a new key is stripped of stray characters, live-tested, and a working old key is restored if the new one fails.
- **Typed no-key (6) and offline (7) exit codes** — missing key reopens the wizard; being offline says so in plain language.
- **Model pinned to `gemini-3.1-flash-lite`** (free tier, best Hebrew of the free field) with automatic fallback to `gemini-2.5-flash-lite` — no more `-latest` alias surprises.
- Result window strips Markdown syntax for display (Copy all still exports Markdown).
- Onboarding discloses the free-tier privacy tradeoff and daily cap; README gained the SmartScreen "Windows protected your PC" walkthrough and Win11 hidden-tray-icon tip.

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
