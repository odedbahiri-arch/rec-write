# Changelog

## v1.5.2 — 2026-08-11

- **The tool can no longer wedge itself.** A single `busy` flag gates every hotkey; it was raised in two places and lowered in four, so any action that died without lowering it left every hotkey silently doing nothing until the app was restarted — indistinguishable, from the outside, from "the tool broke". It had happened for real (2026-07-28). Every write now goes through one `MarkBusy()` that stamps a clock, and a 5-second watchdog releases anything held past 90s, restoring the saved clipboard and saying so. A popup you leave open on screen is left alone — the watchdog only steps in once its window is gone.

## v1.5.1 — 2026-08-10

Fixes the crash that made the popup's action chips unusable.

- **Clicking an action in the `Ctrl+Alt+Space` popup works again.** Every chip died with `This value of type "String" has no method named "Call"` and took the tray icon down with it. Cause: the handler's parameter was named `instr`, and because AutoHotkey identifiers are case-insensitive that name shadowed the built-in `InStr()` for the whole function — so the window-action lookup was calling a string. Renamed to `instruction`. (The direct `Ctrl+Alt+<key>` hotkeys were never affected.)
- **The popup no longer tears itself down from inside its own click handler.** It hid and destroyed the panel while still inside the control's event, then ran the model call for seconds on the freed window — which killed the process with "Invalid memory read/write" often enough to look random. The panel now hides immediately and is destroyed on a fresh thread, with the action dispatched off the event thread too.
- **Losing focus can't take the script down.** `PopupDeactivate` runs inside an `OnMessage` callback, where an uncaught error is fatal, so its body is now defensive throughout and clears the window handle before teardown.
- Popup exceptions log `what` and `line` alongside the message, so the next one names itself instead of needing a repro.

## v1.5.0 — 2026-08-06

Friend-proof install release.

- **Hebrew quick-start page in the zip** («התחלה מהירה.html») — 4 steps with the SmartScreen walkthrough and the hidden-tray-icon tip, branded, opens in any browser.
- **Permanent download link**: every release now also uploads a stable-named `REC-WriteTool.zip`, so `releases/latest/download/REC-WriteTool.zip` always fetches the newest version — one link to share forever.
- **Autostart offered in the wizard**: the "you're all set" page has a checked "Start with Windows" box — no Startup-folder instructions needed.

## v1.4.1 — 2026-08-06

Design polish from Oded's review of v1.4.0:

- Chip labels are bold ink everywhere (the tray cheat-sheet no longer grays them).
- הגדרות and בדיקת עדכונים are plain footer links (no boxes); הגדרות carries a real gear icon (Segoe UI Symbol — ships with Windows, safe for all users).
- שליחה matches the approved mockup: flat lime, no border ring, bold ink, same height as the field.

## v1.4.0 — 2026-08-06

The popup gets its real design (option A of three mockups, refined with Oded).

- **Branded panel**: red hairline on top; the English lockup always sits visual-LEFT with the red dot before "REC", character count + ⚙ always visual-RIGHT — in both UI languages; the rest of the panel follows the language's RTL/LTR.
- **Rounded chips** instead of stock buttons: bold action label + the hotkey in parentheses in a faded tone (so the popup teaches the shortcuts); ⧉ window-marker in brand olive; cream `#FFFDF6` fills instead of pure white.
- **Lime send button** — the panel's single CTA, RecStudio lime with ink text.
- Hotkey hints hide automatically when direct hotkeys are switched off.

## v1.3.1 — 2026-08-05

- **Direct hotkeys can be switched off** (Settings → "קיצורים ישירים") for apps that bind their own Ctrl+Alt shortcuts (e.g. the new Notepad's formatting keys). The menu hotkey keeps every action reachable; the toggle applies instantly.

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
