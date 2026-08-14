#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================================
;  RecWrite — the trigger layer.
;  Owns the fragile OS integration: layout-independent global hotkeys
;  (registered by SCAN CODE, so they fire under a Hebrew layout) and the
;  clipboard shuttle. The AI logic lives in recwrite.py (the brain).
;
;  Two ways to use it:
;   * DIRECT hotkey per action  (Ctrl+Alt+J = proofread, etc.)
;   * POPUP menu                (Ctrl+Alt+Space) — pick any action, incl. Custom
;
;  Actions replace the selection in place, EXCEPT summary / keypoints / table,
;  which open in a result window so they don't overwrite your text.
; ============================================================================

; ---- version / repo ---------------------------------------------------------
APP_VERSION := "1.5.3"
REPO_SLUG   := "odedbahiri-arch/rec-write"

; ---- paths / settings -------------------------------------------------------
scriptDir := A_ScriptDir
scriptPy  := scriptDir "\recwrite.py"
brainExe  := scriptDir "\recwrite-brain.exe"   ; the packaged brain (releases)
pythonExe := FindPython()                       ; dev fallback: run recwrite.py

; Releases ship the brain as a self-contained exe; a source checkout runs it
; through whatever Python is installed. Every call site goes through this.
BrainCmd() {
    global brainExe, pythonExe, scriptPy
    if FileExist(brainExe)
        return '"' brainExe '"'
    return '"' pythonExe '" "' scriptPy '"'
}

FindPython() {
    local base := EnvGet("LOCALAPPDATA") "\Programs\Python"
    for v in ["Python313", "Python312", "Python311"]
        if FileExist(base "\" v "\pythonw.exe")
            return base "\" v "\pythonw.exe"
    return "pythonw.exe"   ; last resort: PATH (RunWait throws if absent — call sites guard)
}
logFile   := scriptDir "\recwrite.log"
; Every brain call gets its OWN temp files. They used to be four fixed paths
; shared by every call, and a follow-up chat never raises `busy` — so an action
; fired while a follow-up was still running wrote and then deleted the same
; recwrite_out.txt. Whichever finished first destroyed the other's answer: the
; chat came back "success, 0 characters" and the user's question was silently
; rolled back even though the model had answered fine.
tmpSeq := 0
TmpPath(kind) {
    global tmpSeq
    tmpSeq += 1
    return Format("{1}\recwrite_{2}_{3}_{4}_{5}.txt", A_Temp, kind,
        DllCall("GetCurrentProcessId", "uint"), A_TickCount, tmpSeq)
}
; A call that is killed mid-flight can't delete its own file, and those files
; hold the user's selected text — so sweep leftovers at startup.
;
; AGE-GUARDED on purpose, and the guard is load-bearing. This glob is shared
; with every sibling instance — `#SingleInstance Force` matches on script path,
; so a second install, or a dev copy living somewhere else, runs alongside this
; one — and NOTHING holds these files open between AHK writing them and the
; brain reading them. A blind wildcard delete here would therefore rip the input
; file out from under a sibling's in-flight call and make that call fail. A live
; call lives seconds (the brain times out at 30s, BusyWatchdog releases at 90s),
; so an hour is ~40x the worst case and cannot catch a running call.
; The PID check, NOT the clock, is what makes this safe. Both values in a
; DateDiff are local wall-clock, so a DST shift or an NTP correction can make a
; seconds-old file look an hour old — but it cannot make a running process
; disappear. Age is only the second opinion, for files whose owner is gone.
; Files from <= v1.5.2 carry no PID in their name and fall through to age alone.
SweepTempFiles() {
    loop files, A_Temp "\recwrite_*.txt" {
        try {
            alive := RegExMatch(A_LoopFileName, "^recwrite_[a-z]+_(\d+)_", &m)
                     && ProcessExist(Integer(m[1]))
            if (!alive && DateDiff(A_Now, FileGetTime(A_LoopFilePath, "M"), "Minutes") >= 60)
                FileDelete(A_LoopFilePath)
        }
    }
}
settleMs  := 300
busy      := false
busyAt    := 0            ; A_TickCount when `busy` was raised — see BusyWatchdog
; Generous on purpose: the brain's own timeout is `timeout_seconds` (30) and the
; fallback model can double that, so nothing legitimate lives past ~60s.
BUSY_TIMEOUT := 90000
popupGui  := ""
OnMessage(0x0006, PopupDeactivate)   ; WM_ACTIVATE — dismiss the popup on focus loss
; Which actions open a result window instead of pasting is owned by config.json
; ("open_in_window"), so adding an action never means editing this script. The
; literal below is only the fallback if the brain can't be reached at startup.
windowActions := ",summary,keypoints,table,"

; ---- UI language ------------------------------------------------------------
; config.json owns it ("ui_language": "he" / "en"), delivered by LoadSettings.
; Every user-facing string lives in these tables — the logic below only ever
; says L["key"], so adding a language never means touching the flow.
uiLang := "en"
L := Map()
SetLang(lang) {
    global uiLang, L
    en := Map(
        "app", "REC",
        "brand", "● REC — Write Tool",
        "m1", "&1  Proofread`t(Ctrl+Alt+J)",
        "m2", "&2  Rewrite`t(Ctrl+Alt+R)",
        "m3", "&3  Friendly`t(Ctrl+Alt+F)",
        "m4", "&4  Professional`t(Ctrl+Alt+P)",
        "m5", "&5  Concise`t(Ctrl+Alt+C)",
        "m6", "&6  Summary  (window)",
        "m7", "&7  Key Points  (window)",
        "m8", "&8  Table  (window)",
        "mC", "&C  Custom…",
        "act_proofread", "Proofread", "act_rewrite", "Rewrite",
        "act_friendly", "Friendly", "act_professional", "Professional",
        "act_concise", "Concise", "act_summary", "Summary",
        "act_keypoints", "Key Points", "act_table", "Table", "act_custom", "Custom",
        "popup_no_sel", "select some text first",
        "no_sel", "no text selected",
        "not_suitable", "text not suitable for this action",
        "blocked", "blocked by Gemini's safety filter",
        "rate", "rate limited, try again in a moment",
        "error", "error (see recwrite.log)",
        "empty", "empty result",
        "truncated", "heads up: the answer was cut short",
        "custom_title", "Custom instruction",
        "custom_prompt", "Describe the change you want (any language):",
        "p_cue", "Describe any change… (then Enter)",
        "p_chars", "chars selected",
        "p_hint", "select text, then Ctrl+Alt+Space",
        "p_send", "Send",
        "tray_menu", "Menu",
        "followup_label", "Ask a follow-up (Enter to send):",
        "btn_ask", "Ask", "btn_copy_answer", "Copy answer",
        "btn_copy_all", "Copy all (Markdown)", "btn_close", "Close",
        "sep_user", "───  You  ───", "sep_assistant", "───  REC  ───",
        "copied_answer", "Answer copied", "copied_all", "Conversation copied",
        "fu", "Follow-up",
        "tray_active", "● REC — Write Tool",
        "tray_popup", "Menu:",
        "tray_direct", "Direct: Ctrl+Alt+ J R F P C S K T",
        "tray_selftest", "Self-test", "tray_reload", "Reload",
        "tray_exit", "Exit",
        "tray_update", "Check for updates",
        "upd_avail", "A new version is available", "upd_open", "Open the download page?",
        "upd_none", "You're up to date", "upd_err", "Couldn't check for updates",
        "tray_pause", "Pause hotkeys",
        "paused", "Hotkeys paused — click again to resume",
        "resumed", "Hotkeys back on",
        "working", "REC — working…",
        "still_working", "Still working on the previous one…",
        "unstuck", "That one got stuck — REC is ready again",
        "copied_fallback", "The window changed — the result is on your clipboard, paste with Ctrl+V",
        "nokey", "No API key set — opening setup",
        "offline", "no internet connection — check the network and try again",
        "key_empty", "Paste a key first",
        "key_privacy", "Good to know: you need a Google account (Gmail); a school/work account may be blocked. On the free tier Google may use processed text to improve its models. Daily cap is ~1,000 actions — plenty for writing.",
        "key_title", "API key setup",
        "key_explain", "REC — Write Tool runs on Google's Gemini — the free tier is plenty. Click the button to get a free key (takes ~30 seconds, no credit card), paste it below, and hit Test && Save. The key is stored only on this computer.",
        "key_save", "Save key",
        "key_saved", "Key saved and verified — you're ready to go",
        "key_failed", "That key didn't pass a live test — check for missing characters and try again",
        "key_get", "Get a free key ↗",
        "key_show", "Show key",
        "key_test_save", "Test && Save",
        "key_testing", "Testing against Gemini…",
        "ob_title", "Welcome",
        "ob_what1", "• Select text in ANY app, press a hotkey — and it's proofread, rewritten or translated in place.",
        "ob_what2", "• The hotkeys are bound to physical keys, so they work the same under Hebrew and English layouts.",
        "ob_what3", "• Summary, Key Points and Table open a window you can keep chatting with — refine the answer instead of redoing it.",
        "ob_hotkeys", "The hotkeys:",
        "ob_menu", "full menu",
        "ob_next", "Next",
        "ob_key_head", "Connect your free AI key",
        "ob_done_head", "You're all set!",
        "ob_done_try", "Try it now: select some text anywhere and press Ctrl+Alt+J to proofread — or Ctrl+Alt+Space for the full menu. Botan in the tray means it's running — if you don't see him, click the ^ arrow near the clock (you can drag him onto the taskbar to pin him).",
        "ob_finish", "Start writing",
        "set_title", "Settings",
        "set_lang", "Interface language:",
        "set_autostart", "Start with Windows",
        "set_key", "API key:",
        "set_key_ok", "configured",
        "set_key_missing", "missing",
        "set_key_change", "Change key…",
        "set_hotkey", "Menu hotkey:",
        "set_hotkey_note", "To change it: click the box and press the combo you want — it applies immediately. Recommended: the default, Ctrl+Alt+Space. The direct hotkeys (Ctrl+Alt+letter) are fixed.",
        "set_hotkey_reset", "Reset to default",
        "hk_applied", "Menu hotkey is now", "hk_rejected", "That combo can't be used — keeping the previous one",
        "set_direct", "Direct hotkeys (Ctrl+Alt+letter)",
        "set_direct_note", "Turn off if a combo clashes with an app's own shortcuts (e.g. Notepad's formatting) — the menu hotkey keeps every action available.",
        "set_save", "Save",
        "set_saved", "Settings saved",
        "tray_settings", "Settings…",
        "tip_tooltip", "REC — Write Tool (active)",
        "st_pass", "Self-test PASSED — Gemini reachable",
        "st_fail", "Self-test FAILED — see recwrite.log",
        "start_title", "REC — Write Tool is running",
        "start_tip", "Ctrl+Alt+Space = menu · Ctrl+Alt+J = proofread")
    he := Map(
        "app", "REC",
        "brand", "● REC — Write Tool",
        "m1", "&1  הגהה`t(Ctrl+Alt+J)",
        "m2", "&2  ניסוח מחדש`t(Ctrl+Alt+R)",
        "m3", "&3  ידידותי`t(Ctrl+Alt+F)",
        "m4", "&4  מקצועי`t(Ctrl+Alt+P)",
        "m5", "&5  תמציתי`t(Ctrl+Alt+C)",
        "m6", "&6  סיכום  (בחלון)",
        "m7", "&7  נקודות עיקריות  (בחלון)",
        "m8", "&8  טבלה  (בחלון)",
        "mC", "&C  הוראה חופשית…",
        "act_proofread", "הגהה", "act_rewrite", "ניסוח מחדש",
        "act_friendly", "ידידותי", "act_professional", "מקצועי",
        "act_concise", "תמציתי", "act_summary", "סיכום",
        "act_keypoints", "נקודות עיקריות", "act_table", "טבלה", "act_custom", "הוראה חופשית",
        "popup_no_sel", "קודם צריך לסמן טקסט",
        "no_sel", "לא סומן טקסט",
        "not_suitable", "הטקסט לא מתאים לפעולה הזאת",
        "blocked", "נחסם על ידי מסנן הבטיחות של Gemini",
        "rate", "יש עומס — שווה לנסות שוב עוד רגע",
        "error", "שגיאה — הפרטים ביומן (recwrite.log)",
        "empty", "חזרה תשובה ריקה",
        "truncated", "שימו לב: התשובה נקטעה באמצע",
        "custom_title", "הוראה חופשית",
        "custom_prompt", "מה לעשות בטקסט? (אפשר בכל שפה)",
        "p_cue", "מה לעשות בטקסט? כותבים כאן ולוחצים Enter",
        "p_chars", "תווים מסומנים",
        "p_hint", "מסמנים טקסט ואז Ctrl+Alt+Space",
        "p_send", "שליחה",
        "tray_menu", "תפריט",
        "followup_label", "שאלת המשך (Enter לשליחה):",
        "btn_ask", "שליחה", "btn_copy_answer", "העתקת התשובה",
        "btn_copy_all", "העתקת הכול (Markdown)", "btn_close", "סגירה",
        "sep_user", "───  שאלה  ───", "sep_assistant", "───  תשובה  ───",
        "copied_answer", "התשובה הועתקה", "copied_all", "השיחה הועתקה",
        "fu", "שאלת המשך",
        "tray_active", "● REC — Write Tool — פעיל",
        "tray_popup", "תפריט:",
        "tray_direct", "ישיר: Ctrl+Alt+ J R F P C S K T",
        "tray_selftest", "בדיקה עצמית", "tray_reload", "טעינה מחדש",
        "tray_exit", "יציאה",
        "tray_update", "בדיקת עדכונים",
        "upd_avail", "יש גרסה חדשה", "upd_open", "לפתוח את דף ההורדה?",
        "upd_none", "הגרסה הכי עדכנית", "upd_err", "בדיקת העדכונים לא הצליחה",
        "tray_pause", "השהיית הקיצורים",
        "paused", "הקיצורים מושהים — לחיצה נוספת מפעילה שוב",
        "resumed", "הקיצורים פועלים שוב",
        "working", "REC — חושב…",
        "still_working", "עדיין עובד על הפעולה הקודמת…",
        "unstuck", "הפעולה הקודמת נתקעה — REC מוכן שוב",
        "copied_fallback", "החלון התחלף — התוצאה הועתקה, אפשר להדביק עם Ctrl+V",
        "nokey", "לא מוגדר מפתח — פותח את ההגדרה",
        "offline", "אין חיבור לאינטרנט — כדאי לבדוק את הרשת ולנסות שוב",
        "key_empty", "קודם מדביקים מפתח",
        "key_privacy", "טוב לדעת: צריך חשבון Google (Gmail); חשבון של עבודה או בית ספר עלול להיות חסום. בגרסה החינמית גוגל עשויה להשתמש בטקסט לשיפור המודלים. המכסה היומית — כ-1,000 פעולות, הרבה מעבר לכתיבה רגילה.",
        "key_title", "הגדרת מפתח API",
        "key_explain", "REC — Write Tool עובד עם Gemini של גוגל — והחינמי מספיק בגדול. לוחצים על הכפתור לקבלת מפתח חינם (לוקח חצי דקה, בלי כרטיס אשראי), מדביקים למטה ולוחצים על בדיקה ושמירה. המפתח נשמר רק במחשב הזה.",
        "key_save", "שמירת המפתח",
        "key_saved", "המפתח נשמר ונבדק — אפשר להתחיל",
        "key_failed", "המפתח לא עבר בדיקה מול Gemini — כדאי לוודא שהודבק במלואו ולנסות שוב",
        "key_get", "קבלת מפתח חינם ↗",
        "key_show", "הצגת המפתח",
        "key_test_save", "בדיקה ושמירה",
        "key_testing", "בודק מול Gemini…",
        "ob_title", "ברוכים הבאים",
        "ob_what1", "• מסמנים טקסט בכל תוכנה, לוחצים קיצור — והטקסט עובר הגהה, ניסוח מחדש או סיכום, במקום.",
        "ob_what2", "• הקיצורים קשורים למקשים הפיזיים, אז הם עובדים אותו דבר בעברית ובאנגלית.",
        "ob_what3", "• סיכום, נקודות עיקריות וטבלה נפתחים בחלון שאפשר להמשיך לשוחח איתו — מלטשים את התשובה במקום להתחיל מהתחלה.",
        "ob_hotkeys", "הקיצורים:",
        "ob_menu", "תפריט מלא",
        "ob_next", "המשך",
        "ob_key_head", "חיבור מפתח AI חינמי",
        "ob_done_head", "הכול מוכן!",
        "ob_done_try", "שווה לנסות עכשיו: מסמנים טקסט בכל מקום ולוחצים Ctrl+Alt+J להגהה — או Ctrl+Alt+Space לתפריט המלא. בוטן ליד השעון = הכלי רץ. לא רואים אותו? לוחצים על חץ ה-^ ליד השעון (אפשר לגרור אותו לשורת המשימות כדי לקבע).",
        "ob_finish", "מתחילים לכתוב",
        "set_title", "הגדרות",
        "set_lang", "שפת הממשק:",
        "set_autostart", "הפעלה אוטומטית עם Windows",
        "set_key", "מפתח ה-API:",
        "set_key_ok", "מוגדר",
        "set_key_missing", "חסר",
        "set_key_change", "החלפת מפתח…",
        "set_hotkey", "קיצור התפריט:",
        "set_hotkey_note", "לשינוי: לוחצים על התיבה ומקישים את הצירוף הרצוי — הוא נכנס לתוקף מיד. מומלץ להישאר עם ברירת המחדל, Ctrl+Alt+Space. הקיצורים הישירים (Ctrl+Alt+אות) קבועים.",
        "set_hotkey_reset", "חזרה לברירת המחדל",
        "hk_applied", "קיצור התפריט מעכשיו:", "hk_rejected", "הצירוף הזה לא זמין — נשארים עם הקודם",
        "set_direct", "קיצורים ישירים (Ctrl+Alt+אות)",
        "set_direct_note", "כדאי לכבות אם קיצור מתנגש עם קיצורים של תוכנה (למשל העיצוב בפנקס הרשימות) — התפריט משאיר את כל הפעולות זמינות.",
        "set_save", "שמירה",
        "set_saved", "ההגדרות נשמרו",
        "tray_settings", "הגדרות…",
        "tip_tooltip", "REC — Write Tool — כתיבה עם AI (פעיל)",
        "st_pass", "הבדיקה עברה — יש חיבור ל-Gemini",
        "st_fail", "הבדיקה נכשלה — הפרטים ביומן",
        "start_title", "REC — Write Tool פועל",
        "start_tip", "Ctrl+Alt+Space לתפריט · Ctrl+Alt+J להגהה")
    uiLang := lang
    L := (lang = "he") ? he : en
}
SetLang("en")   ; safe default until LoadSettings reads config

; The action's display name for titles and toasts.
ActLabel(action) {
    global L
    return L.Has("act_" action) ? L["act_" action] : action
}

; True if the text is mostly Hebrew — decides RTL display for content.
HasHebrew(t) {
    return RegExMatch(t, "[\x{05D0}-\x{05EA}]") ? true : false
}

; ---- direct hotkeys (Ctrl+Alt+<physical position>) --------------------------
; Registered dynamically so Settings can switch them off: Ctrl+Alt+letter will
; always clash with SOME app (the new Notepad's formatting shortcuts, Word's
; accelerators…), and the escape hatch is popup-only mode — the menu hotkey
; keeps every action reachable.
directHotkeys := true
directMap := Map(
    "sc024", "proofread",     ; J
    "sc013", "rewrite",       ; R
    "sc021", "friendly",      ; F
    "sc019", "professional",  ; P
    "sc02E", "concise",       ; C
    "sc01F", "summary",       ; S
    "sc025", "keypoints",     ; K
    "sc014", "table")         ; T

RegisterDirectHotkeys(on) {
    global directMap
    for sc, act in directMap {
        if on
            Hotkey("^!" sc, RunAction.Bind(act), "On")
        else
            try Hotkey("^!" sc, "Off")
    }
}
; The menu hotkey is config-owned ("hotkey_menu", default Ctrl+Alt+Space) and
; registered dynamically in RegisterMenuHotkey() so Settings can rebind it
; without anyone touching this file.
menuHotkey := "^!Space"

RegisterMenuHotkey(hk) {
    global menuHotkey
    try {
        Hotkey(hk, (*) => ShowPopup(), "On")
        menuHotkey := hk
        return true
    } catch as e {
        Log("hotkey_menu '" hk "' rejected (" e.Message ") — falling back to ^!Space")
        try Hotkey("^!Space", (*) => ShowPopup(), "On")
        menuHotkey := "^!Space"
        return false
    }
}

; "^!Space" → "Ctrl+Alt+Space" for labels and tray hints.
ReadableHotkey(hk) {
    s := ""
    if InStr(hk, "^")
        s .= "Ctrl+"
    if InStr(hk, "!")
        s .= "Alt+"
    if InStr(hk, "+")
        s .= "Shift+"
    if InStr(hk, "#")
        s .= "Win+"
    return s . Format("{:T}", RegExReplace(hk, "[\^!+#]"))
}

; ============================================================================
;  Direct-hotkey path: capture happens while the source app still has focus,
;  so there is no focus/paste race.
; ============================================================================
RunAction(action, *) {
    global busy
    Log("HOTKEY " action (busy ? " (ignored: busy)" : ""))
    if busy {
        Notify(L["still_working"])
        return
    }
    MarkBusy(true)
    ReleaseMods()
    saved := ClipboardAll()
    src := WinExist("A")                 ; remember where the text came from
    try {
        text := CaptureSelection()
        if (text = "") {
            Notify(ActLabel(action) " — " L["no_sel"])
            return
        }
        Log("fired " action " — captured " StrLen(text) " chars")
        keep := Handle(action, text, "", saved, src)
    } catch as e {
        Notify(ActLabel(action) " — " e.Message)
        Log(action " -> EXCEPTION: " e.Message)
    } finally {
        if !IsSet(keep) || !keep
            A_Clipboard := saved
        saved := ""
        MarkBusy(false)
    }
}

; ============================================================================
;  Popup path: capture the selection FIRST (source still focused), remember
;  the source window, THEN show the menu. When a button is picked we reactivate
;  the source window before pasting.
; ============================================================================
; trayMode (double-click on Botan): same panel with no captured text — actions
; are shown as a cheat-sheet (disabled) and Settings/Updates become buttons.
ShowPopup(trayMode := false) {
    global busy, popupText, popupSrc, popupSaved, popupPicked, popupGui, uiLang, L, windowActions, directHotkeys
    if trayMode {
        ; The tray panel is a cheat-sheet: it captures nothing and restores
        ; nothing, so `popupPicked` is all it actually needs. Clearing the rest
        ; used to blank popupSaved OUT FROM UNDER a still-running action, whose
        ; cleanup then handed that empty value back — double-clicking Botan
        ; while REC was working wiped the user's clipboard. Only tidy up stale
        ; state when nothing is in flight.
        if !busy {
            popupText := "", popupSaved := "", popupSrc := 0
        }
        popupPicked := true               ; nothing to restore on dismiss
    } else {
        if busy
            return
        MarkBusy(true)                    ; direct hotkeys must not fight the popup for the clipboard
        ReleaseMods()
        popupSaved := ClipboardAll()
        popupSrc := WinExist("A")        ; remember the source window
        popupText := CaptureSelection()   ; grab the selection while it's still focused
        if (popupText = "") {
            A_Clipboard := popupSaved
            popupSaved := ""
            MarkBusy(false)
            Notify(L["popup_no_sel"])
            return
        }
        Log("popup opened — captured " StrLen(popupText) " chars")
        popupPicked := false
    }

    ; The branded action panel (design signed off 2026-08-06): red hairline,
    ; English lockup ALWAYS visual-left with the dot before REC, count + gear
    ; visual-right, rounded cream chips with a bold label + faded hotkey hint,
    ; and the lime send button as the panel's single CTA.
    mirrored := (uiLang = "he")
    W := 416, M := 14, CW := 190, CH := 38
    H := (trayMode ? 302 : 268)
    p := Gui("-Caption +AlwaysOnTop +ToolWindow +Border" (mirrored ? " +E0x400000" : ""))
    popupGui := p
    p.BackColor := "FAF7EF"
    p.Add("Text", "x0 y0 w" W " h3 BackgroundEF4444")

    ; a run of controls placed at explicit VISUAL coordinates (logical flips in
    ; mirrored windows), so the header reads the same in both languages
    PlaceRunL(parts, vx) {
        ; NB: out-var must not be named "w"/"h" — AHK is case-insensitive and a
        ; free variable in a nested func captures the OUTER W (panel width).
        for c in parts {
            c.GetPos(, , &runW)
            c.Move(mirrored ? W - vx - runW : vx)
            vx += runW + 8
        }
    }
    PlaceRunR(parts, rm) {
        tw := 0
        for c in parts {
            c.GetPos(, , &runW)
            tw += runW + 8
        }
        PlaceRunL(parts, W - rm - (tw - 8))
    }

    p.SetFont("s12 cEF4444", "Segoe UI")
    dot := p.Add("Text", "x16 y12", "●")
    p.SetFont("s10 c1A1B1D bold", "Segoe UI")
    brand := p.Add("Text", "x+7 yp+2", "REC — Write Tool")
    p.SetFont("s9 c6F695D norm", "Segoe UI")
    cnt := p.Add("Text", "x+10 yp+1", trayMode ? L["p_hint"] : StrLen(popupText) " " L["p_chars"])
    p.SetFont("s11 c57534A norm", "Segoe UI Symbol")   ; plain Segoe UI draws ⚙ as tofu
    gear := p.Add("Text", "x+8 yp-3", "⚙")
    p.SetFont("s10 c1A1B1D norm", "Segoe UI")
    gear.OnEvent("Click", (*) => (ClosePopup(), ShowSettings()))
    PlaceRunL([dot, brand], 16)
    PlaceRunR([cnt, gear], 14)

    ; rounded chip = border layer + fill layer + label (+ ⧉ / hotkey hint)
    AddChip(cx, cy, w, h, label, hintTxt, isWin, enabled, cb, lime := false) {
        fill := lime ? "D4F534" : "FFFDF6"
        parts := []
        if lime {
            ; the CTA is flat lime, no border ring (per the signed-off mockup)
            fl := p.Add("Text", Format("x{} y{} w{} h{} Background{}", cx, cy, w, h, fill))
            RoundCtrl(fl, 7)
        } else {
            bd := p.Add("Text", Format("x{} y{} w{} h{} BackgroundD9D4C6", cx, cy, w, h))
            fl := p.Add("Text", Format("x{} y{} w{} h{} Background{}", cx + 1, cy + 1, w - 2, h - 2, fill))
            RoundCtrl(bd, 8), RoundCtrl(fl, 7)
            parts.Push(bd)
        }
        p.SetFont("s10 c1A1B1D bold", "Segoe UI")   ; labels are always bold ink
        ly := cy + Max(4, (h - 22) // 2 + 1)
        lb := p.Add("Text", Format("x{} y{} Background{}", cx + 12, ly, fill), label)
        parts.Push(fl), parts.Push(lb)
        if lime {
            lb.GetPos(, , &lw)
            lb.Move(cx + (w - lw) // 2)
        }
        if isWin {
            ; tiny on purpose — at label size it pushes long Hebrew labels
            ; (נקודות עיקריות) into a second line
            p.SetFont("s7 c4F5D00 norm", "Segoe UI")
            parts.Push(p.Add("Text", "x+3 yp+5 Background" fill, "⧉"))
        }
        if (hintTxt != "") {
            p.SetFont("s8 cA89F8E norm", "Segoe UI")
            ht := p.Add("Text", Format("x{} y{} Background{}", cx + 12, cy + (h - 14) // 2, fill), "(" hintTxt ")")
            ht.GetPos(, , &hw)
            ht.Move(cx + w - 10 - hw)
            parts.Push(ht)
        }
        p.SetFont("s10 c1A1B1D norm", "Segoe UI")
        if enabled {
            for c in parts
                c.OnEvent("Click", cb)
        }
    }

    p.SetFont("s10 c1A1B1D norm", "Segoe UI")
    ci := p.Add("Edit", Format("x{} y44 w{} h28 BackgroundFFFDF6", M, W - M * 2 - 76 - 8))
    SetCue(ci, L["p_cue"])
    AddChip(W - M - 76, 44, 76, 28, L["p_send"], "", false, !trayMode, SendCustom, true)
    if trayMode
        ci.Enabled := false

    keys := ["proofread", "rewrite", "friendly", "professional", "concise", "summary", "keypoints", "table"]
    hintKey := Map("proofread", "J", "rewrite", "R", "friendly", "F", "professional", "P",
        "concise", "C", "summary", "S", "keypoints", "K", "table", "T")
    for i, k in keys {
        cx := M + Mod(i - 1, 2) * (CW + 8), cy := 78 + ((i - 1) // 2) * 46
        AddChip(cx, cy, CW, CH, ActLabel(k),
            (directHotkeys ? "Ctrl+Alt+" hintKey[k] : ""),
            InStr(windowActions, "," k ",") != 0, !trayMode, RunPick.Bind(k))
    }
    if trayMode {
        ; footer links — no boxes: הגדרות (with a real gear) and updates
        fy := 78 + 4 * 46 + 6
        p.SetFont("s10 c1A1B1D bold", "Segoe UI")
        stL := p.Add("Text", Format("x{} y{}", M + 10, fy), L["set_title"])
        p.SetFont("s10 c57534A norm", "Segoe UI Symbol")
        stG := p.Add("Text", "x+5 yp", "⚙")
        p.SetFont("s10 c1A1B1D bold", "Segoe UI")
        upL := p.Add("Text", Format("x{} y{}", 240, fy), L["tray_update"])
        upL.GetPos(, , &upw)
        upL.Move(W - M - 10 - upw)
        p.SetFont("s10 c1A1B1D norm", "Segoe UI")
        stL.OnEvent("Click", (*) => (ClosePopup(), ShowSettings()))
        stG.OnEvent("Click", (*) => (ClosePopup(), ShowSettings()))
        upL.OnEvent("Click", (*) => (ClosePopup(), CheckUpdates()))
    }

    ; Enter in the field submits the custom instruction (hidden default button)
    hb := p.Add("Button", "x-20 y-20 w1 h1 Default", "")
    hb.OnEvent("Click", SendCustom)
    p.OnEvent("Escape", (*) => ClosePopup())
    p.OnEvent("Close", (*) => ClosePopup())

    ; show at the cursor, clamped to the work area of the monitor it's on
    CoordMode("Mouse", "Screen")
    MouseGetPos(&mx, &my)
    p.Show(Format("w{} h{} Hide", W, H))
    p.GetPos(, , &pw, &ph)
    WorkAreaAt(mx, my, &wl, &wt, &wr, &wb)
    x := Max(wl + 8, Min(mx, wr - pw - 8)), y := Max(wt + 8, Min(my, wb - ph - 8))
    p.Show("x" x " y" y)
    if !trayMode
        ci.Focus()

    ; Tearing the panel down from INSIDE one of its own control click handlers
    ; corrupts AHK's event dispatch (the handler returns into a freed control and
    ; the process dies with "Invalid memory read/write"). So: drop the global
    ; handle first, hide for instant feedback, and destroy on a fresh thread.
    DismissPanel() {
        g := p
        popupGui := ""
        try g.Hide()
        SetTimer(() => g.Destroy(), -1)
    }
    RunPick(action, *) {
        popupPicked := true
        DismissPanel()
        SetTimer(() => DoPopupAction(action, ""), -1)   ; off the Gui event thread
    }
    SendCustom(*) {
        q := Trim(ci.Value)
        if (q = "")
            return
        popupPicked := true
        DismissPanel()
        SetTimer(() => DoPopupAction("custom", q), -1)
    }
    ClosePopup() {
        DismissPanel()
        if !popupPicked
            PopupCleanup()
    }
}

; Clicking anywhere else must dismiss the popup (and give the clipboard back).
; This runs inside an OnMessage callback, where an uncaught error takes the whole
; script down — so the body is defensive end to end, the handle is cleared before
; the teardown, and the Destroy happens on a fresh thread (same reason as
; DismissPanel above: never free a window from inside its own message handler).
PopupDeactivate(wParam, lParam, msg, hwnd) {
    global popupGui, popupPicked
    try {
        if (popupGui = "" || wParam != 0 || hwnd != popupGui.Hwnd)
            return
        g := popupGui
        popupGui := ""
        try g.Hide()
        SetTimer(() => g.Destroy(), -1)
        if !popupPicked
            PopupCleanup()
    }
}

; ---- the stuck-busy watchdog ------------------------------------------------
; `busy` gates every hotkey, and it is raised in two places but lowered in four.
; If any action ever dies without lowering it, EVERY hotkey silently stops
; working until the app is restarted — which to a non-technical user is
; indistinguishable from "the tool broke". It has happened for real (2026-07-28:
; eight `HOTKEY summary (ignored: busy)` in one second, cured only by a restart),
; and nothing else in the script can recover from it. So every write goes through
; MarkBusy() to stamp the clock, and this timer is the net.
MarkBusy(on) {
    global busy, busyAt
    busy   := on
    busyAt := on ? A_TickCount : 0
}
BusyWatchdog() {
    global busy, busyAt, popupGui, popupSaved, popupText, popupPicked, BUSY_TIMEOUT, L
    if (!busy || !busyAt || A_TickCount - busyAt < BUSY_TIMEOUT)
        return
    ; a popup still on screen is legitimately holding `busy` — the user is just
    ; taking their time. Only step in once its window is actually gone.
    if (popupGui != "") {
        try {
            if WinExist("ahk_id " popupGui.Hwnd)
                return
        }
        popupGui := ""                     ; handle outlived its window
    }
    Log("watchdog: busy stuck for " Round((A_TickCount - busyAt) / 1000) "s — releasing")
    try {
        if (popupSaved != "")
            A_Clipboard := popupSaved      ; never strand the user's clipboard
    }
    popupSaved := "", popupText := "", popupPicked := true
    MarkBusy(false)
    Notify(L["unstuck"])
}

PopupCleanup() {
    global popupPicked, popupSaved, popupText, busy
    if popupPicked
        return
    if (popupSaved != "") {
        A_Clipboard := popupSaved
        popupSaved := ""
    }
    popupText := ""
    MarkBusy(false)
}

; Run the picked action against the captured selection, restoring focus to the
; source window first (unless the result opens in a window anyway).
; NB: the instruction parameter must NOT be called `instr` — AHK identifiers are
; case-insensitive, so that name shadows the built-in InStr() for this whole
; function and every InStr(...) call here dies with "String has no method Call".
DoPopupAction(action, instruction) {
    global popupText, popupSrc, popupSaved, busy, windowActions
    Log("popup pick: " action)
    try {
        if (popupSrc && !InStr(windowActions, "," action ",")) {
            WinActivate("ahk_id " popupSrc)
            WinWaitActive("ahk_id " popupSrc, , 1)
        }
        keep := Handle(action, popupText, instruction, popupSaved, popupSrc)
    } catch as e {
        Notify(ActLabel(action) " — " e.Message)
        ; one line per entry — a raw e.Stack is multi-line and breaks the log
        Log("popup " action " -> EXCEPTION: " e.Message " | what=" e.What " | line=" e.Line
            " | stack=" Trim(StrReplace(StrReplace(e.Stack, "`r", ""), "`n", " » ")))
    } finally {
        if !IsSet(keep) || !keep
            A_Clipboard := popupSaved
        popupSaved := "", popupText := ""
        MarkBusy(false)
    }
}

; Gray hint text inside an empty Edit control (EM_SETCUEBANNER).
SetCue(ctrl, text) {
    DllCall("SendMessage", "ptr", ctrl.Hwnd, "uint", 0x1501, "ptr", 1, "wstr", text)
}

; Clip a control to a rounded rectangle (the poor man's border-radius).
RoundCtrl(ctrl, r := 7) {
    ctrl.GetPos(, , &w, &h)
    rgn := DllCall("CreateRoundRectRgn", "int", 0, "int", 0, "int", w + 1, "int", h + 1, "int", r, "int", r, "ptr")
    DllCall("SetWindowRgn", "ptr", ctrl.Hwnd, "ptr", rgn, "int", true)
}

; Work area of the monitor containing the point (multi-monitor safe).
WorkAreaAt(x, y, &l, &t, &r, &b) {
    loop MonitorGetCount() {
        MonitorGetWorkArea(A_Index, &l, &t, &r, &b)
        if (x >= l && x < r && y >= t && y < b)
            return
    }
    MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
}

; ============================================================================
;  Shared: run the brain, then paste OR open a result window.
; ============================================================================
Handle(action, text, instruction, saved, srcWin := 0) {
    global windowActions, settleMs
    ToolTip(L["working"])               ; in-flight feedback — DND can't mute a tooltip
    r := CallBrain(action, text, instruction)
    ToolTip()
    ; Exit codes are the brain's vocabulary — see the docstring in recwrite.py.
    ; Codes 0 and 5 both carry a usable result; everything else is a dead end.
    if (r.code = 2) {
        Notify(ActLabel(action) " — " L["not_suitable"])
        return
    }
    if (r.code = 3) {
        Notify(ActLabel(action) " — " L["blocked"])
        return
    }
    if (r.code = 4) {
        Notify(ActLabel(action) " — " L["rate"])
        return
    }
    if (r.code = 6) {
        Notify(L["nokey"])
        ShowOnboarding(2)               ; missing key: reopen the wizard, not a log pointer
        return
    }
    if (r.code = 7) {
        Notify(ActLabel(action) " — " L["offline"])
        return
    }
    if (r.code != 0 && r.code != 5) {
        Notify(ActLabel(action) " — " L["error"])
        return
    }
    if (r.text = "") {
        Notify(ActLabel(action) " — " L["empty"])
        return
    }
    if (r.code = 5)
        Notify(ActLabel(action) " — " L["truncated"])
    if InStr(windowActions, "," action ",") {
        ShowResultWindow(action, text, r.text)
        Log(action " -> shown in window (" StrLen(r.text) " chars)")
    } else {
        ; If the user wandered off during a slow call, do NOT paste into
        ; whatever window is focused now — that overwrites unrelated work.
        if (srcWin && WinExist("A") != srcWin) {
            ok := false
            try {
                WinActivate("ahk_id " srcWin)
                ok := WinWaitActive("ahk_id " srcWin, , 1)
            }
            if !ok {
                A_Clipboard := r.text
                Notify(L["copied_fallback"])
                Log(action " -> source window gone; result left on clipboard")
                return true    ; tells the caller: do NOT restore the old clipboard
            }
        }
        A_Clipboard := r.text
        if ClipWait(2)
            Send("^v")
        Sleep(settleMs)
        Log(action " -> pasted " StrLen(r.text) " chars")
    }
    return false
}

CallBrain(action, text, instruction) {
    global scriptDir
    tmpIn := TmpPath("in"), tmpOut := TmpPath("out"), tmpInstr := ""
    fin := FileOpen(tmpIn, "w", "UTF-8-RAW")
    fin.Write(text)
    fin.Close()
    args := action ' --infile "' tmpIn '" --outfile "' tmpOut '"'
    if (instruction != "") {
        tmpInstr := TmpPath("instr")
        fi := FileOpen(tmpInstr, "w", "UTF-8-RAW")
        fi.Write(instruction)
        fi.Close()
        args .= ' --instrfile "' tmpInstr '"'
    }
    out := "", code := -1
    try {
        code := RunWait(BrainCmd() " " args, scriptDir, "Hide")
        if ((code = 0 || code = 5) && FileExist(tmpOut))
            out := FileRead(tmpOut, "UTF-8")
    } catch as e {
        Log("CallBrain launch failed: " e.Message " (cmd: " BrainCmd() ")")
        code := 1
    } finally {
        ; the temp files hold the user's selected text — never leave them behind
        try FileDelete(tmpIn)
        try FileDelete(tmpOut)
        if (tmpInstr != "")
            try FileDelete(tmpInstr)
    }
    return {code: code, text: out}
}

; Ask the brain for the AHK-relevant settings (which actions open a window, the
; paste settle delay). Keeps config.json the single source of truth; falls back
; to the built-in defaults if python isn't reachable — and never dies trying.
LoadSettings() {
    global scriptDir, windowActions, settleMs, menuHotkey, directHotkeys
    tmpOut := TmpPath("settings")
    code := -1
    try code := RunWait(BrainCmd() ' --ahk-settings --outfile "' tmpOut '"', scriptDir, "Hide")
    catch as e
        Log("settings handshake failed: " e.Message)
    if (code = 0 && FileExist(tmpOut)) {
        loop parse FileRead(tmpOut, "UTF-8"), "`n", "`r" {
            if !InStr(A_LoopField, "=")
                continue
            k := Trim(SubStr(A_LoopField, 1, InStr(A_LoopField, "=") - 1))
            v := Trim(SubStr(A_LoopField, InStr(A_LoopField, "=") + 1))
            if (k = "window_actions" && v != "")
                windowActions := "," v ","
            else if (k = "paste_settle_ms" && IsInteger(v))
                settleMs := Integer(v)
            else if (k = "ui_language" && v != "")
                SetLang(v)
            else if (k = "hotkey_menu" && v != "")
                menuHotkey := v
            else if (k = "direct_hotkeys")
                directHotkeys := (v = "true")
        }
        Log("settings from config: windows=" windowActions " settle=" settleMs "ms")
    } else {
        Log("settings: using fallbacks (windows=" windowActions " settle=" settleMs "ms)")
    }
    try FileDelete(tmpOut)
}

; Continue a result-window conversation: hand the whole transcript to the brain.
; Turn markers carry a per-call random token so text that itself contains a
; "<<<RECWRITE:user>>>" line (e.g. someone summarizing this tool's own docs)
; cannot forge a turn boundary and scramble the conversation.
CallChat(roles, texts) {
    global scriptDir
    tmpChat := TmpPath("chat"), tmpOut := TmpPath("out")
    token := A_TickCount . Random(100000, 999999)
    out := "", code := -1
    try {
        fc := FileOpen(tmpChat, "w", "UTF-8-RAW")
        loop roles.Length
            fc.Write("<<<RECWRITE:" token ":" roles[A_Index] ">>>`n" texts[A_Index] "`n")
        fc.Close()
        code := RunWait(BrainCmd() ' --chatfile "' tmpChat '" --chatmark ' token ' --outfile "' tmpOut '"', scriptDir, "Hide")
        if ((code = 0 || code = 5) && FileExist(tmpOut))
            out := FileRead(tmpOut, "UTF-8")
    } catch as e {
        ; Without this the follow-up path threw a RAW AutoHotkey error dialog at
        ; the user — full command line, temp paths and an ExitApp button — while
        ; the identical failure on the paste path (CallBrain) was already handled
        ; as a friendly "error (see recwrite.log)".
        Log("CallChat failed: " e.Message " (cmd: " BrainCmd() ")")
        code := 1
    } finally {
        try FileDelete(tmpChat)
        try FileDelete(tmpOut)
    }
    return {code: code, text: out}
}

CaptureSelection() {
    A_Clipboard := ""
    Send("^c")
    ; 1s, not longer: with nothing selected this wait runs to the end before we
    ; can say "no text selected" — a long timeout reads as the tool hanging.
    if !ClipWait(1)
        return ""
    return A_Clipboard
}

; ============================================================================
;  Result window (summary / keypoints / table). Not a dead end: the thread stays
;  alive, so a near-miss answer can be corrected by asking, instead of redoing
;  the whole action. The original selection is kept in the history the model
;  sees, but not shown — the answer is what you came for.
; ============================================================================
ShowResultWindow(action, srcText, resultText) {
    global uiLang, L
    roles := ["user", "assistant"]
    texts := [action ":`n`n" srcText, resultText]

    ; Hebrew UI mirrors the whole window (WS_EX_LAYOUTRTL); Hebrew CONTENT under
    ; an English UI still gets RTL reading order on the transcript control.
    mirrored := (uiLang = "he")
    rw := Gui("+Resize" (mirrored ? " +E0x400000" : ""), L["app"] " — " ActLabel(action))
    ; RecStudio brand: warm paper ground, ink text, the red record dot up top.
    hdr := BrandHeader(rw, ActLabel(action))
    edOpts := "xm y+10 w700 r20 ReadOnly VScroll BackgroundFFFFFF"
    if (!mirrored && HasHebrew(resultText))
        edOpts .= " +E0x2000 Right"     ; WS_EX_RTLREADING for Hebrew answers
    ed  := rw.Add("Edit", edOpts)
    rw.Add("Text", "y+6", L["followup_label"])
    inp := rw.Add("Edit", "w700 BackgroundFFFFFF")
    ask := rw.Add("Button", "w110 y+8 Default", L["btn_ask"])
    bc  := rw.Add("Button", "x+8 w130", L["btn_copy_answer"])
    ba  := rw.Add("Button", "x+8 w150", L["btn_copy_all"])
    bx  := rw.Add("Button", "x+8 w100", L["btn_close"])

    Render()
    ask.OnEvent("Click", AskFn)
    bc.OnEvent("Click", (*) => (A_Clipboard := LastAnswer(), Notify(L["copied_answer"])))
    ba.OnEvent("Click", (*) => (A_Clipboard := AsMarkdown(), Notify(L["copied_all"])))
    ; A follow-up takes 10-30s and RunWait stays interruptible, so the user can
    ; (and does) close this window while an answer is still on its way. Every
    ; teardown goes through CloseWin so AskFn can tell that its controls are
    ; gone before it touches them — otherwise it resumes into a destroyed
    ; window and AutoHotkey throws a raw error dialog in the user's face.
    closed := false
    CloseWin() {
        closed := true
        try rw.Destroy()
    }
    bx.OnEvent("Click", (*) => CloseWin())
    rw.OnEvent("Escape", (*) => CloseWin())
    rw.OnEvent("Close", (*) => CloseWin())   ; title-bar X must destroy, not hide (leak otherwise)
    rw.Show("AutoSize Hide")
    if mirrored {
        PlaceHeaderLTR(rw, hdr)
        ; resizable window: keep the lockup pinned to the visual left on resize
        rw.OnEvent("Size", (*) => PlaceHeaderLTR(rw, hdr))
    }
    rw.Show()
    inp.Focus()

    ; -- nested helpers: closures over roles/texts/controls above ---------------
    Render() {
        s := ""
        loop roles.Length {
            if (A_Index = 1)          ; the original selection — context, not content
                continue
            s .= (roles[A_Index] = "user" ? L["sep_user"] "`r`n" : L["sep_assistant"] "`r`n")
            s .= ToCRLF(DisplayText(texts[A_Index])) "`r`n`r`n"
        }
        ed.Value := s
        ; keep the newest message in view
        SendMessage(0x0115, 7, 0, ed)   ; WM_VSCROLL / SB_BOTTOM
    }

    AskFn(*) {
        q := Trim(inp.Value)
        if (q = "")
            return
        inp.Value := ""
        roles.Push("user"), texts.Push(q)
        Render()
        ask.Enabled := false, ask.Text := "…"
        Log("chat follow-up (" StrLen(q) " chars, turn " roles.Length ")")
        r := CallChat(roles, texts)
        if closed {
            ; the user shut the window while we were waiting — the answer has
            ; nowhere to go, and every control below is already destroyed
            Log("chat follow-up discarded — window closed while waiting")
            return
        }
        ask.Enabled := true, ask.Text := L["btn_ask"]
        if (r.code != 0 && r.code != 5) || (r.text = "") {
            roles.Pop(), texts.Pop()      ; drop the unanswered question
            Render()
            ; Hand the question back — but only into an EMPTY box. A follow-up
            ; takes 10-30s and people keep typing while they wait; force-setting
            ; this erased whatever they had written next.
            if (inp.Value = "")
                inp.Value := q
            Notify(L["fu"] " — " (r.code = 4 ? L["rate"] : r.code = 3 ? L["blocked"] : L["error"]))
            return
        }
        roles.Push("assistant"), texts.Push(r.text)
        Render()
        if (r.code = 5)
            Notify(L["fu"] " — " L["truncated"])
        inp.Focus()
    }

    LastAnswer() {
        loop roles.Length {
            i := roles.Length - A_Index + 1
            if (roles[i] = "assistant")
                return texts[i]
        }
        return ""
    }

    AsMarkdown() {
        s := ""
        loop roles.Length {
            if (A_Index = 1)
                continue
            ; Markdown export keeps Latin role labels — it's meant to be pasted anywhere.
            s .= (roles[A_Index] = "user" ? "**You**: " : "**" L["app"] "**: ") texts[A_Index] "`n`n"
        }
        return s
    }
}

; Edit controls want CRLF; the brain speaks LF.
ToCRLF(t) {
    return StrReplace(StrReplace(t, "`r`n", "`n"), "`n", "`r`n")
}

; The model answers in Markdown; a plain Edit control shows the syntax as
; garbage symbols ("**חשוב**"). Strip the light stuff for DISPLAY only —
; "Copy all (Markdown)" still exports the real thing.
DisplayText(t) {
    t := RegExReplace(t, "\*\*(.*?)\*\*", "$1")     ; **bold**
    t := RegExReplace(t, "m)^#{1,6}\s*", "")          ; # headings
    t := RegExReplace(t, "``(.*?)``", "$1")           ; `code`
    t := RegExReplace(t, "m)^\s*[-*]\s", "• ")       ; list bullets
    return t
}

; ---- helpers ----------------------------------------------------------------
ReleaseMods() {
    Send("{Ctrl up}{Alt up}{Shift up}")
    ; Also wait for the PHYSICAL keys: injecting ^c while the user still holds
    ; the hotkey's own modifiers is WritingTools' #1 destroyed-text bug class
    ; (their issues #183/#207 — the 'c' lands unmodified and overwrites the
    ; selection). Timeout keeps a stuck key from freezing us.
    KeyWait("Ctrl", "T0.5"), KeyWait("Alt", "T0.5"), KeyWait("Shift", "T0.5")
    Sleep(30)
}
; Operational feedback rides a cursor-anchored ToolTip, NOT TrayTip: Windows 11
; turns TrayTips into toasts, which Do-Not-Disturb / Focus sessions silently
; swallow — and then "no text selected" or "rate limited" becomes dead silence.
Notify(msg) {
    ToolTip(msg)
    SetTimer(() => ToolTip(), -2500)
}
Log(msg) {
    global logFile
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  AHK   " msg "`n", logFile, "UTF-8-RAW")
}

; ---- tray -------------------------------------------------------------------
BuildTray() {
    global scriptDir, L, menuHotkey
    ; Botan — the RecStudio mascot — is the tray face of the tool.
    if FileExist(scriptDir "\botan.ico")
        try TraySetIcon(scriptDir "\botan.ico")
    A_TrayMenu.Delete()
    A_TrayMenu.Add(L["tray_active"], (*) => "")
    A_TrayMenu.Disable(L["tray_active"])
    A_TrayMenu.Add()
    hint := L["tray_popup"] " " ReadableHotkey(menuHotkey)
    A_TrayMenu.Add(hint, (*) => "")
    A_TrayMenu.Disable(hint)
    A_TrayMenu.Add(L["tray_direct"], (*) => "")
    A_TrayMenu.Disable(L["tray_direct"])
    A_TrayMenu.Add()
    A_TrayMenu.Add(L["tray_menu"], (*) => ShowPopup(true))
    A_TrayMenu.Add(L["tray_settings"], (*) => ShowSettings())
    A_TrayMenu.Add(L["tray_pause"], TogglePause)
    A_TrayMenu.Add(L["tray_selftest"], (*) => SelfTest())
    A_TrayMenu.Add(L["tray_update"], (*) => CheckUpdates())
    A_TrayMenu.Add(L["tray_reload"], (*) => Reload())
    A_TrayMenu.Add()
    A_TrayMenu.Add(L["tray_exit"], (*) => ExitApp())
    ; double-click on Botan opens the menu panel (Settings is a button inside it)
    A_TrayMenu.Default := L["tray_menu"]
    A_IconTip := L["tip_tooltip"]
}
; A one-click mute for every global hotkey — a global keyboard hook you can't
; switch off is scary; this is the trust valve (WritingTools' Pause/Resume).
TogglePause(*) {
    global L
    Suspend(-1)
    if A_IsSuspended
        A_TrayMenu.Check(L["tray_pause"])
    else
        A_TrayMenu.Uncheck(L["tray_pause"])
    TrayTip("REC — Write Tool", A_IsSuspended ? L["paused"] : L["resumed"], 1)
    SetTimer(() => TrayTip(), -2500)
}

SelfTest() {
    global scriptDir
    code := -1
    try code := RunWait(BrainCmd() " --selftest", scriptDir, "Hide")
    Notify(code = 0 ? L["st_pass"] : L["st_fail"])
}

; Check GitHub Releases for a newer tag. Deliberately check-and-link only —
; no self-replacing binaries, no silent updates.
CheckUpdates() {
    global APP_VERSION, REPO_SLUG, L
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.Open("GET", "https://api.github.com/repos/" REPO_SLUG "/releases/latest", true)
        req.SetRequestHeader("User-Agent", "REC-WriteTool")
        req.Send()
        req.WaitForResponse(10)
        if (req.Status = 200 && RegExMatch(req.ResponseText, '"tag_name"\s*:\s*"v?([^"]+)"', &m)) {
            latest := m[1]
            if (VerCompare(latest, APP_VERSION) > 0) {
                if (MsgBox(L["upd_avail"] " (v" latest ")`n`n" L["upd_open"],
                           "REC — Write Tool", "YesNo Iconi") = "Yes")
                    Run("https://github.com/" REPO_SLUG "/releases/latest")
            } else {
                Notify(L["upd_none"] " (v" APP_VERSION ")")
            }
        } else {
            Notify(L["upd_err"])
        }
    } catch {
        Notify(L["upd_err"])
    }
}

; A missing brain must not kill the script with a raw AHK error dialog before
; the tray icon even appears — say what's wrong and how to fix it.
if (!FileExist(brainExe) && !FileExist(pythonExe)) {
    pathOk := false
    try pathOk := (RunWait(A_ComSpec " /c where pythonw.exe >nul 2>&1", , "Hide") = 0)
    if !pathOk {
        MsgBox(
            "REC — Write Tool needs its brain and found neither:`n"
            "  " brainExe "  (release build)`n"
            "  a Python installation  (source checkout)`n`n"
            "Install Python 3.11+ or re-download the release zip.",
            "REC — Write Tool — setup needed", "Iconx")
    }
}

SweepTempFiles()  ; clear any temp files a killed call left behind (they hold user text)
LoadSettings()   ; must run before BuildTray — it decides the UI language + hotkeys
RegisterMenuHotkey(menuHotkey)
RegisterDirectHotkeys(directHotkeys)
BuildTray()
SetTimer(BusyWatchdog, 5000)   ; the only thing that can un-wedge a stuck `busy`
CheckApiKey()    ; first run: no key yet → branded setup dialog
Log("=== RecWrite started (popup + 8 direct hotkeys, ui=" uiLang ") ===")
TrayTip(L["start_title"], L["start_tip"], 1)
SetTimer(() => TrayTip(), -3000)

; ============================================================================
;  First-run onboarding + settings (structure borrowed from WritingTools'
;  OnboardingWindow/SettingsWindow, rebuilt as branded AHK GUIs).
;  Page 1: what the tool does + the hotkeys.  Page 2: connect a free Gemini
;  key — the key is written to .env beside the app and validated with a REAL
;  API round-trip before we call it done.  Page 3: "you're set" + first steps.
; ============================================================================
CheckApiKey() {
    global scriptDir
    code := 1
    try code := RunWait(BrainCmd() " --has-key", scriptDir, "Hide")
    if (code = 0)
        return
    ShowOnboarding()
}

; One reusable branded window header: red record dot + lockup. The lockup must
; ALWAYS read left-to-right — ● REC — Write Tool · <sub> — even in mirrored
; Hebrew windows. Returns the header controls so PlaceHeaderLTR can re-anchor
; them after AutoSize (mirrored windows lay controls out from the right).
BrandHeader(g, sub := "") {
    g.BackColor := "FAF7EF"
    g.SetFont("s16 cEF4444", "Segoe UI")
    dot := g.Add("Text", "x16 y14", "●")
    g.SetFont("s13 c1A1B1D bold", "Segoe UI")
    brand := g.Add("Text", "x+8 yp+2", "REC — Write Tool")
    parts := [dot, brand]
    if (sub != "") {
        g.SetFont("s13 c57534A norm", "Segoe UI")
        parts.Push(g.Add("Text", "x+10 yp", "·"))
        parts.Push(g.Add("Text", "x+10 yp", sub))
    }
    g.SetFont("s10 c1A1B1D norm", "Segoe UI")
    return parts
}

; Re-place header controls at explicit visual-left coordinates. In a
; WS_EX_LAYOUTRTL window logical x is measured from the RIGHT edge, so
; logical = clientW - visualX - ctrlW. Call after Show("AutoSize Hide").
PlaceHeaderLTR(g, parts) {
    g.GetClientPos(, , &cw)
    vx := 16
    for c in parts {
        c.GetPos(, , &w)
        c.Move(cw - vx - w)
        vx += w + 10
    }
}

ShowOnboarding(page := 1) {
    global scriptDir, uiLang, L
    static g := "", wizLive := ""
    ; Replacing a live wizard has to MARK THE OLD ONE CLOSED, not merely destroy
    ; it. "closed" below is per-invocation, so a previous TestAndSave sitting in
    ; RunWait can only be told through the object it captured. Without this,
    ; Settings → "Change key…" during a running test destroys that window and
    ; the old test then resumes into its dead controls — the exact raw dialog
    ; CloseWiz exists to prevent.
    if (g != "") {
        if IsObject(wizLive)
            wizLive.closed := true
        try g.Destroy()
        g := ""
    }
    g := Gui((uiLang = "he" ? "+E0x400000" : ""), "REC — Write Tool")
    ; Test && Save makes a REAL API round-trip, so this window can be closed
    ; mid-test. Route every teardown through CloseWiz so TestAndSave knows its
    ; controls are gone instead of resuming into them and throwing a raw error
    ; dialog — during first-run setup, of all moments.
    ; A shared box, not a plain local: the flag has to be reachable both from
    ; this invocation's handlers and from a LATER call that replaces us.
    closed := {closed: false}
    wizLive := closed
    CloseWiz() {
        closed.closed := true
        try g.Destroy()
        g := ""
    }
    g.OnEvent("Close", (*) => CloseWiz())
    g.OnEvent("Escape", (*) => CloseWiz())

    hdr := []
    if (page = 1) {
        hdr := BrandHeader(g, L["ob_title"])
        g.Add("Text", "xm y+14 w460", L["ob_what1"])
        g.Add("Text", "xm y+8 w460", L["ob_what2"])
        g.Add("Text", "xm y+8 w460", L["ob_what3"])
        g.SetFont("s10 c1A1B1D bold", "Segoe UI")
        g.Add("Text", "xm y+14", L["ob_hotkeys"])
        g.SetFont("s10 c57534A norm", "Consolas")
        g.Add("Text", "xm y+6", "Ctrl+Alt+Space   " L["act_custom"] " + " L["ob_menu"]
            "`nCtrl+Alt+J  " L["act_proofread"] "      Ctrl+Alt+R  " L["act_rewrite"]
            "`nCtrl+Alt+S  " L["act_summary"] "      Ctrl+Alt+K  " L["act_keypoints"])
        g.SetFont("s10 c1A1B1D norm", "Segoe UI")
        nx := g.Add("Button", "xm y+18 w140 Default", L["ob_next"])
        nx.OnEvent("Click", (*) => ShowOnboarding(2))
    } else if (page = 2) {
        hdr := BrandHeader(g, L["ob_key_head"])
        g.Add("Text", "xm y+14 w460", L["key_explain"])
        gk := g.Add("Button", "xm y+12 w180", L["key_get"])
        gk.OnEvent("Click", (*) => Run("https://aistudio.google.com/apikey"))
        ed := g.Add("Edit", "xm y+14 w460 Password BackgroundFFFFFF")
        sh := g.Add("Checkbox", "xm y+6", L["key_show"])
        sh.OnEvent("Click", (*) => (ed.Opt(sh.Value ? "-Password" : "+Password")))
        g.SetFont("s9 cB91C1C norm", "Segoe UI")
        err := g.Add("Text", "xm y+8 w460", " ")
        g.SetFont("s10 c1A1B1D norm", "Segoe UI")
        ts := g.Add("Button", "xm y+8 w180 Default", L["key_test_save"])
        ts.OnEvent("Click", TestAndSave)
        g.SetFont("s9 c6F695D norm", "Segoe UI")
        g.Add("Text", "xm y+10 w460", L["key_privacy"])
        g.SetFont("s10 c1A1B1D norm", "Segoe UI")
    } else {
        hdr := BrandHeader(g, L["ob_done_head"])
        g.SetFont("s11 c4F5D00 bold", "Segoe UI")
        g.Add("Text", "xm y+14", "✓  " L["key_saved"])
        g.SetFont("s10 c1A1B1D norm", "Segoe UI")
        g.Add("Text", "xm y+10 w460", L["ob_done_try"])
        au := g.Add("Checkbox", "xm y+14 Checked", L["set_autostart"])
        fn := g.Add("Button", "xm y+16 w160 Default", L["ob_finish"])
        fn.OnEvent("Click", (*) => (SetAutostart(au.Value), g.Destroy(), g := ""))
    }
    g.Show("AutoSize Hide")
    if (uiLang = "he")
        PlaceHeaderLTR(g, hdr)
    g.Show()

    TestAndSave(*) {
        ; keys are [\w-] only — strip stray words/invisible unicode from web copies
        k := RegExReplace(Trim(ed.Value), "[^\w\-]")
        if (k = "") {
            err.Text := L["key_empty"]
            return
        }
        ; never destroy a working key for an unproven one — restore on failure
        oldEnv := FileExist(scriptDir "\.env") ? FileRead(scriptDir "\.env", "UTF-8") : ""
        f := FileOpen(scriptDir "\.env", "w", "UTF-8-RAW")
        f.Write("GOOGLE_API_KEY=" k "`n")
        f.Close()
        ts.Enabled := false, ts.Text := L["key_testing"], err.Text := " "
        code := 1
        try code := RunWait(BrainCmd() " --selftest", scriptDir, "Hide")   ; real round-trip
        if closed.closed {
            ; wizard shut mid-test: the controls below are gone, and the key we
            ; wrote before testing is still unproven — put the old one back
            if (oldEnv != "") {
                try {
                    f := FileOpen(scriptDir "\.env", "w", "UTF-8-RAW")
                    f.Write(oldEnv)
                    f.Close()
                }
            } else {
                ; Fresh install — there was no old key to restore, so the
                ; unproven one must NOT survive. `--has-key` only checks that a
                ; key loads, so leaving it here would skip onboarding on the
                ; next start and then fail every single action with no clue why.
                try FileDelete(scriptDir "\.env")
            }
            Log("key test abandoned — wizard closed while testing")
            return
        }
        ts.Enabled := true, ts.Text := L["key_test_save"]
        if (code = 0) {
            ShowOnboarding(3)
        } else {
            if (oldEnv != "") {
                f := FileOpen(scriptDir "\.env", "w", "UTF-8-RAW")
                f.Write(oldEnv)
                f.Close()
            }
            err.Text := L["key_failed"]
        }
    }
}

; ---- settings window (tray → Settings, or double-click on Botan) ------------
; Everything applies INSTANTLY — no Save button. A save-to-apply settings
; window was WritingTools' single most repeated user complaint, and testing
; showed people click a language and expect the world to change right there.
ShowSettings() {
    global scriptDir, uiLang, L, menuHotkey, directHotkeys
    s := Gui((uiLang = "he" ? "+E0x400000" : ""), "REC — Write Tool — " L["set_title"])
    hdr := BrandHeader(s, L["set_title"])

    s.Add("Text", "xm y+16", L["set_lang"])
    rHe := s.Add("Radio", "xm y+6" (uiLang = "he" ? " Checked" : ""), "עברית")
    rEn := s.Add("Radio", "x+16" (uiLang != "he" ? " Checked" : ""), "English")
    rHe.OnEvent("Click", (*) => ApplyLanguage("he", s))
    rEn.OnEvent("Click", (*) => ApplyLanguage("en", s))

    au := s.Add("Checkbox", "xm y+14" (IsAutostart() ? " Checked" : ""), L["set_autostart"])
    au.OnEvent("Click", (*) => (SetAutostart(au.Value), Notify(L["set_saved"])))

    dh := s.Add("Checkbox", "xm y+8" (directHotkeys ? " Checked" : ""), L["set_direct"])
    dh.OnEvent("Click", ToggleDirect)
    s.SetFont("s9 c6F695D norm", "Segoe UI")
    s.Add("Text", "xm y+2 w400", L["set_direct_note"])
    s.SetFont("s10 c1A1B1D norm", "Segoe UI")

    ; Menu-hotkey picker: press the combo in the box — it applies on the spot.
    ; (The Win32 hotkey control can't represent Space, so the current binding
    ; lives in the bold line above and a reset button restores the default.)
    s.SetFont("s10 c1A1B1D bold", "Segoe UI")
    hkCur := s.Add("Text", "xm y+16 w400", L["set_hotkey"] " " ReadableHotkey(menuHotkey) (menuHotkey = "^!Space" ? "  ✓" : ""))
    s.SetFont("s10 c1A1B1D norm", "Segoe UI")
    hkc := s.Add("Hotkey", "xm y+6 w200")
    rs := s.Add("Button", "x+8 w170", L["set_hotkey_reset"])
    s.SetFont("s9 c6F695D norm", "Segoe UI")
    s.Add("Text", "xm y+4 w400", L["set_hotkey_note"])
    s.SetFont("s10 c1A1B1D norm", "Segoe UI")
    hkc.OnEvent("Change", (*) => SetTimer(ApplyPicked, -400))   ; debounce partial combos
    rs.OnEvent("Click", (*) => (hkc.Value := "", ApplyHotkey("^!Space")))

    keyOk := false
    try keyOk := (RunWait(BrainCmd() " --has-key", scriptDir, "Hide") = 0)
    s.Add("Text", "xm y+16", L["set_key"] " " (keyOk ? "✓ " L["set_key_ok"] : "✗ " L["set_key_missing"]))
    kb := s.Add("Button", "x+12 w150", L["set_key_change"])
    kb.OnEvent("Click", (*) => (s.Destroy(), ShowOnboarding(2)))

    cl := s.Add("Button", "xm y+18 w120 Default", L["btn_close"])
    cl.OnEvent("Click", (*) => s.Destroy())
    s.OnEvent("Close", (*) => s.Destroy())
    s.OnEvent("Escape", (*) => s.Destroy())
    s.Show("AutoSize Hide")
    if (uiLang = "he")
        PlaceHeaderLTR(s, hdr)
    s.Show()

    ToggleDirect(*) {
        global directHotkeys
        directHotkeys := dh.Value ? true : false
        RegisterDirectHotkeys(directHotkeys)
        try RunWait(BrainCmd() ' --set direct_hotkeys=' (directHotkeys ? "true" : "false"), scriptDir, "Hide")
        Notify(L["set_saved"])
    }

    ApplyPicked() {
        v := ""
        try v := hkc.Value
        if (v = "" || !RegExMatch(v, "[^\^!+#]"))   ; ignore modifier-only states
            return
        ; …and refuse anything without Ctrl/Alt/Win. Hotkey() accepts "a" and
        ; registers it GLOBALLY with no `~` prefix, so the key is SWALLOWED
        ; rather than passed through: bind `a` and every `a` you type in any app
        ; opens the panel instead of typing a letter. It saves to config too, so
        ; it survives a restart. Shift does NOT count — "+a" is still a key
        ; people type, and binding it eats every capital A.
        if !RegExMatch(v, "[\^!#]") {
            Notify(L["hk_rejected"])
            return
        }
        ApplyHotkey(v)
    }
    ApplyHotkey(hk) {
        global menuHotkey
        old := menuHotkey
        if (hk = old) {
            hkCur.Text := L["set_hotkey"] " " ReadableHotkey(menuHotkey) (menuHotkey = "^!Space" ? "  ✓" : "")
            return
        }
        try Hotkey(old, "Off")
        if RegisterMenuHotkey(hk) {
            try RunWait(BrainCmd() ' --set "hotkey_menu=' hk '"', scriptDir, "Hide")
            BuildTray()   ; refresh the menu-hotkey hint line
            Notify(L["hk_applied"] " " ReadableHotkey(hk))
        } else {
            Notify(L["hk_rejected"])
        }
        hkCur.Text := L["set_hotkey"] " " ReadableHotkey(menuHotkey) (menuHotkey = "^!Space" ? "  ✓" : "")
    }
}

; Live language switch: config first (the brain owns the file), then re-skin
; everything built from L — tray now, this window by rebuilding it. No Reload.
ApplyLanguage(newLang, settingsGui := "") {
    global scriptDir, uiLang
    if (newLang = uiLang)
        return
    try RunWait(BrainCmd() ' --set ui_language=' newLang, scriptDir, "Hide")
    SetLang(newLang)
    BuildTray()
    if (settingsGui != "") {
        try settingsGui.Destroy()
        ShowSettings()
    }
}

; Startup-folder shortcut (WritingTools' AutostartManager, the AHK way).
; Also honors the older "RecWrite.lnk" name from pre-rebrand installs.
IsAutostart() {
    return FileExist(A_Startup "\REC-WriteTool.lnk") || FileExist(A_Startup "\RecWrite.lnk")
}
SetAutostart(on) {
    if on {
        if !FileExist(A_Startup "\REC-WriteTool.lnk") && !FileExist(A_Startup "\RecWrite.lnk")
            try FileCreateShortcut(A_ScriptFullPath, A_Startup "\REC-WriteTool.lnk", A_ScriptDir)
    } else {
        try FileDelete(A_Startup "\REC-WriteTool.lnk")
        try FileDelete(A_Startup "\RecWrite.lnk")
    }
}

; Dev/QA aid: `recwrite.ahk --preview-window` opens a demo result window at
; startup so the GUI can be eyeballed (and screenshotted) without a hotkey.
if (A_Args.Length && A_Args[1] = "--preview-menu")
    ShowPopup(true)
if (A_Args.Length && A_Args[1] = "--preview-onboarding")
    ShowOnboarding(1)
if (A_Args.Length && A_Args[1] = "--preview-settings")
    ShowSettings()
if (A_Args.Length && A_Args[1] = "--preview-window") {
    ShowResultWindow("summary", "טקסט מקור לדוגמה",
        "**סיכום לדוגמה**`n`n- הנקודה הראשונה של הסיכום`n- נקודה שנייה, קצת יותר ארוכה, כדי לראות גלישת שורות`n- נקודה שלישית`n`nכך נראה חלון תוצאה של REC — Write Tool.")
}
