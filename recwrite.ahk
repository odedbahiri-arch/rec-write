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
APP_VERSION := "1.2.0"
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
tmpIn     := A_Temp "\recwrite_in.txt"
tmpOut    := A_Temp "\recwrite_out.txt"
tmpInstr  := A_Temp "\recwrite_instr.txt"
tmpChat   := A_Temp "\recwrite_chat.txt"
settleMs  := 300
busy      := false
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
        "set_hotkey", "Menu hotkey — current:",
        "set_hotkey_note", "Click the box and press the combo you want. Recommended: Ctrl+Alt+Space (the default). The direct hotkeys (Ctrl+Alt+letter) are fixed.",
        "set_hotkey_reset", "Reset to default",
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
        "set_hotkey", "קיצור התפריט — כרגע:",
        "set_hotkey_note", "לוחצים על התיבה ומקישים את הצירוף הרצוי. מומלץ: Ctrl+Alt+Space (ברירת המחדל). הקיצורים הישירים (Ctrl+Alt+אות) קבועים.",
        "set_hotkey_reset", "חזרה לברירת המחדל",
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
^!sc024::RunAction("proofread")     ; J
^!sc013::RunAction("rewrite")       ; R
^!sc021::RunAction("friendly")      ; F
^!sc019::RunAction("professional")  ; P
^!sc02E::RunAction("concise")       ; C
^!sc01F::RunAction("summary")       ; S
^!sc025::RunAction("keypoints")     ; K
^!sc014::RunAction("table")         ; T
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
RunAction(action) {
    global busy
    Log("HOTKEY " action (busy ? " (ignored: busy)" : ""))
    if busy {
        Notify(L["still_working"])
        return
    }
    busy := true
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
        busy := false
    }
}

; ============================================================================
;  Popup path: capture the selection FIRST (source still focused), remember
;  the source window, THEN show the menu. When a button is picked we reactivate
;  the source window before pasting.
; ============================================================================
ShowPopup() {
    global busy, popupText, popupSrc, popupSaved, popupPicked
    if busy
        return
    busy := true                          ; direct hotkeys must not fight the popup for the clipboard
    ReleaseMods()
    popupSaved := ClipboardAll()
    popupSrc := WinExist("A")            ; remember the source window
    popupText := CaptureSelection()       ; grab the selection while it's still focused
    if (popupText = "") {
        A_Clipboard := popupSaved
        popupSaved := ""
        busy := false
        Notify(L["popup_no_sel"])
        return
    }
    Log("popup opened — captured " StrLen(popupText) " chars")
    popupPicked := false

    ; A native menu: renders cleanly, auto-positions on-screen, fires reliably,
    ; and restores focus to the source window when an item is picked.
    m := Menu()
    m.Add(L["m1"], MenuPick)
    m.Add(L["m2"], MenuPick)
    m.Add(L["m3"], MenuPick)
    m.Add(L["m4"], MenuPick)
    m.Add(L["m5"], MenuPick)
    m.Add()
    m.Add(L["m6"], MenuPick)
    m.Add(L["m7"], MenuPick)
    m.Add(L["m8"], MenuPick)
    m.Add()
    m.Add(L["mC"], MenuPick)
    m.Show()                              ; at the mouse cursor; blocks until pick/dismiss
    ; Cleanup is DEFERRED: a pick launches MenuPick as an interrupting thread,
    ; but that ordering isn't guaranteed on all machines — clearing state right
    ; here could race MenuPick and hand it empty text. The timer runs after the
    ; dust settles; MenuPick sets popupPicked as its very first act.
    SetTimer(PopupCleanup, -250)
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
    busy := false
}

; Map a clicked menu label back to an action name.
MenuPick(itemName, itemPos, myMenu) {
    global popupText, popupSrc, popupSaved, popupPicked, busy, windowActions
    popupPicked := true                     ; tell PopupCleanup this thread owns the state now
    static map := Map(
        "1", "proofread", "2", "rewrite", "3", "friendly", "4", "professional",
        "5", "concise", "6", "summary", "7", "keypoints", "8", "table", "C", "custom")
    clean := StrReplace(itemName, "&", "")  ; drop the accelerator marker if present
    key := SubStr(clean, 1, 1)              ; the digit/letter (1-8 or C)
    action := map.Has(key) ? map[key] : ""
    if (action = "") {
        popupPicked := false                ; unknown item — let the cleanup timer restore things
        return
    }
    Log("popup pick: " action)
    instr := ""
    try {
        if (action = "custom") {
            ib := InputBox(L["custom_prompt"], L["app"] " — " L["custom_title"], "w380 h130")
            if (ib.Result != "OK" || Trim(ib.Value) = "")
                return
            instr := ib.Value
        }
        if (popupSrc && !InStr(windowActions, "," action ",")) {
            WinActivate("ahk_id " popupSrc)
            WinWaitActive("ahk_id " popupSrc, , 1)
        }
        keep := Handle(action, popupText, instr, popupSaved, popupSrc)
    } catch as e {
        Notify(ActLabel(action) " — " e.Message)
    } finally {
        if !IsSet(keep) || !keep
            A_Clipboard := popupSaved
        popupSaved := "", popupText := ""
        busy := false
    }
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
    global scriptDir, tmpIn, tmpOut, tmpInstr
    try FileDelete(tmpOut)
    fin := FileOpen(tmpIn, "w", "UTF-8-RAW")
    fin.Write(text)
    fin.Close()
    args := action ' --infile "' tmpIn '" --outfile "' tmpOut '"'
    if (instruction != "") {
        fi := FileOpen(tmpInstr, "w", "UTF-8-RAW")
        fi.Write(instruction)
        fi.Close()
        args .= ' --instrfile "' tmpInstr '"'
    }
    out := ""
    try {
        code := RunWait(BrainCmd() " " args, scriptDir, "Hide")
        if ((code = 0 || code = 5) && FileExist(tmpOut))
            out := FileRead(tmpOut, "UTF-8")
    } finally {
        ; the temp files hold the user's selected text — never leave them behind
        try FileDelete(tmpIn)
        try FileDelete(tmpOut)
        try FileDelete(tmpInstr)
    }
    return {code: code, text: out}
}

; Ask the brain for the AHK-relevant settings (which actions open a window, the
; paste settle delay). Keeps config.json the single source of truth; falls back
; to the built-in defaults if python isn't reachable — and never dies trying.
LoadSettings() {
    global scriptDir, tmpOut, windowActions, settleMs, menuHotkey
    try FileDelete(tmpOut)
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
    global scriptDir, tmpChat, tmpOut
    try FileDelete(tmpOut)
    token := A_TickCount . Random(100000, 999999)
    fc := FileOpen(tmpChat, "w", "UTF-8-RAW")
    loop roles.Length
        fc.Write("<<<RECWRITE:" token ":" roles[A_Index] ">>>`n" texts[A_Index] "`n")
    fc.Close()
    out := ""
    try {
        code := RunWait(BrainCmd() ' --chatfile "' tmpChat '" --chatmark ' token ' --outfile "' tmpOut '"', scriptDir, "Hide")
        if ((code = 0 || code = 5) && FileExist(tmpOut))
            out := FileRead(tmpOut, "UTF-8")
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
    rw.BackColor := "FAF7EF"
    rw.SetFont("s14 cEF4444", "Segoe UI")
    rw.Add("Text", "x12 y10", "●")
    rw.SetFont("s11 c1A1B1D bold", "Segoe UI")
    rw.Add("Text", "x+6 yp+2", "REC — Write Tool   ·   " ActLabel(action))
    rw.SetFont("s10 c1A1B1D norm", "Segoe UI")
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
    bx.OnEvent("Click", (*) => rw.Destroy())
    rw.OnEvent("Escape", (*) => rw.Destroy())
    rw.OnEvent("Close", (*) => rw.Destroy())   ; title-bar X must destroy, not hide (leak otherwise)
    rw.Show("AutoSize")
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
        ask.Enabled := true, ask.Text := L["btn_ask"]
        if (r.code != 0 && r.code != 5) || (r.text = "") {
            roles.Pop(), texts.Pop()      ; drop the unanswered question
            Render()
            inp.Value := q                 ; hand the question back, don't lose it
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
    A_TrayMenu.Add(L["tray_settings"], (*) => ShowSettings())
    A_TrayMenu.Add(L["tray_pause"], TogglePause)
    A_TrayMenu.Add(L["tray_selftest"], (*) => SelfTest())
    A_TrayMenu.Add(L["tray_update"], (*) => CheckUpdates())
    A_TrayMenu.Add(L["tray_reload"], (*) => Reload())
    A_TrayMenu.Add()
    A_TrayMenu.Add(L["tray_exit"], (*) => ExitApp())
    ; double-click on Botan opens Settings — the WritingTools convention
    A_TrayMenu.Default := L["tray_settings"]
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

LoadSettings()   ; must run before BuildTray — it decides the UI language + hotkey
RegisterMenuHotkey(menuHotkey)
BuildTray()
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

; One reusable branded window header: red record dot + lockup.
BrandHeader(g, sub := "") {
    g.BackColor := "FAF7EF"
    g.SetFont("s16 cEF4444", "Segoe UI")
    g.Add("Text", "x16 y14", "●")
    g.SetFont("s13 c1A1B1D bold", "Segoe UI")
    g.Add("Text", "x+8 yp+2", "REC — Write Tool" (sub != "" ? "   ·   " sub : ""))
    g.SetFont("s10 c1A1B1D norm", "Segoe UI")
}

ShowOnboarding(page := 1) {
    global scriptDir, uiLang, L
    static g := ""
    if (g != "") {
        try g.Destroy()
        g := ""
    }
    g := Gui((uiLang = "he" ? "+E0x400000" : ""), "REC — Write Tool")
    g.OnEvent("Close", (*) => (g.Destroy(), g := ""))
    g.OnEvent("Escape", (*) => (g.Destroy(), g := ""))

    if (page = 1) {
        BrandHeader(g, L["ob_title"])
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
        BrandHeader(g, L["ob_key_head"])
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
        BrandHeader(g, L["ob_done_head"])
        g.SetFont("s11 c4F5D00 bold", "Segoe UI")
        g.Add("Text", "xm y+14", "✓  " L["key_saved"])
        g.SetFont("s10 c1A1B1D norm", "Segoe UI")
        g.Add("Text", "xm y+10 w460", L["ob_done_try"])
        fn := g.Add("Button", "xm y+16 w160 Default", L["ob_finish"])
        fn.OnEvent("Click", (*) => (g.Destroy(), g := ""))
    }
    g.Show("AutoSize")

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
ShowSettings() {
    global scriptDir, uiLang, L, menuHotkey
    s := Gui((uiLang = "he" ? "+E0x400000" : ""), "REC — Write Tool — " L["set_title"])
    BrandHeader(s, L["set_title"])
    hkReset := false

    s.Add("Text", "xm y+16", L["set_lang"])
    rHe := s.Add("Radio", "xm y+6" (uiLang = "he" ? " Checked" : ""), "עברית")
    rEn := s.Add("Radio", "x+16" (uiLang != "he" ? " Checked" : ""), "English")

    au := s.Add("Checkbox", "xm y+14" (IsAutostart() ? " Checked" : ""), L["set_autostart"])

    ; Menu-hotkey picker: press the combo you want, no text editing anywhere.
    ; (The Win32 hotkey control can't represent Space, so the current binding is
    ; shown as text and an explicit reset button restores the default.)
    s.SetFont("s10 c1A1B1D bold", "Segoe UI")
    s.Add("Text", "xm y+16", L["set_hotkey"] " " ReadableHotkey(menuHotkey))
    s.SetFont("s10 c1A1B1D norm", "Segoe UI")
    hkc := s.Add("Hotkey", "xm y+6 w200")
    rs := s.Add("Button", "x+8 w170", L["set_hotkey_reset"])
    rs.OnEvent("Click", (*) => (hkReset := true, hkc.Value := ""))
    s.SetFont("s9 c6F695D norm", "Segoe UI")
    s.Add("Text", "xm y+4 w400", L["set_hotkey_note"])
    s.SetFont("s10 c1A1B1D norm", "Segoe UI")

    keyOk := false
    try keyOk := (RunWait(BrainCmd() " --has-key", scriptDir, "Hide") = 0)
    s.Add("Text", "xm y+16", L["set_key"] " " (keyOk ? "✓ " L["set_key_ok"] : "✗ " L["set_key_missing"]))
    kb := s.Add("Button", "x+12 w150", L["set_key_change"])
    kb.OnEvent("Click", (*) => (s.Destroy(), ShowOnboarding(2)))

    sv := s.Add("Button", "xm y+18 w140 Default", L["set_save"])
    cl := s.Add("Button", "x+8 w100", L["btn_close"])
    sv.OnEvent("Click", SaveFn)
    cl.OnEvent("Click", (*) => s.Destroy())
    s.OnEvent("Close", (*) => s.Destroy())
    s.OnEvent("Escape", (*) => s.Destroy())
    s.Show("AutoSize")

    SaveFn(*) {
        SetAutostart(au.Value)
        newLang := rHe.Value ? "he" : "en"
        newHk := hkReset ? "^!Space" : (hkc.Value != "" ? hkc.Value : menuHotkey)
        s.Destroy()
        needReload := false
        if (newLang != uiLang) {
            try RunWait(BrainCmd() ' --set ui_language=' newLang, scriptDir, "Hide")
            needReload := true
        }
        if (newHk != menuHotkey) {
            try RunWait(BrainCmd() ' --set "hotkey_menu=' newHk '"', scriptDir, "Hide")
            needReload := true
        }
        if needReload
            Reload()   ; applies language + hotkey; the tray tip re-announces
        else
            Notify(L["set_saved"])
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
if (A_Args.Length && A_Args[1] = "--preview-onboarding")
    ShowOnboarding(1)
if (A_Args.Length && A_Args[1] = "--preview-settings")
    ShowSettings()
if (A_Args.Length && A_Args[1] = "--preview-window") {
    ShowResultWindow("summary", "טקסט מקור לדוגמה",
        "**סיכום לדוגמה**`n`n- הנקודה הראשונה של הסיכום`n- נקודה שנייה, קצת יותר ארוכה, כדי לראות גלישת שורות`n- נקודה שלישית`n`nכך נראה חלון תוצאה של REC — Write Tool.")
}
