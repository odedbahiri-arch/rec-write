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
APP_VERSION := "1.0.0"
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
        "tray_popup", "Popup menu: Ctrl+Alt+Space",
        "tray_direct", "Direct: Ctrl+Alt+ J R F P C S K T",
        "tray_log", "Open log", "tray_config", "Edit config",
        "tray_hotkeys", "Edit hotkeys (this script)",
        "tray_selftest", "Self-test", "tray_reload", "Reload",
        "tray_exit", "Exit",
        "tray_update", "Check for updates",
        "upd_avail", "A new version is available", "upd_open", "Open the download page?",
        "upd_none", "You're up to date", "upd_err", "Couldn't check for updates",
        "key_title", "API key setup",
        "key_explain", "REC — Write Tool uses Google's Gemini (free tier is plenty). Get a free API key at the link below, paste it here, and you're set. The key is stored only on this computer.",
        "key_save", "Save key",
        "key_saved", "Key saved — you're ready to go",
        "key_failed", "That key didn't work — check it and try again",
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
        "tray_popup", "תפריט: Ctrl+Alt+Space",
        "tray_direct", "ישיר: Ctrl+Alt+ J R F P C S K T",
        "tray_log", "פתיחת היומן", "tray_config", "עריכת ההגדרות",
        "tray_hotkeys", "עריכת הקיצורים",
        "tray_selftest", "בדיקה עצמית", "tray_reload", "טעינה מחדש",
        "tray_exit", "יציאה",
        "tray_update", "בדיקת עדכונים",
        "upd_avail", "יש גרסה חדשה", "upd_open", "לפתוח את דף ההורדה?",
        "upd_none", "הגרסה הכי עדכנית", "upd_err", "בדיקת העדכונים לא הצליחה",
        "key_title", "הגדרת מפתח API",
        "key_explain", "REC — Write Tool עובד עם Gemini של גוגל (החינמי מספיק בגדול). מוציאים מפתח חינם בקישור למטה, מדביקים כאן — וזהו. המפתח נשמר רק במחשב הזה.",
        "key_save", "שמירת המפתח",
        "key_saved", "המפתח נשמר — אפשר להתחיל",
        "key_failed", "המפתח לא עבד — כדאי לבדוק ולנסות שוב",
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
^!Space::ShowPopup()                ; the popup menu (layout-independent)

; ============================================================================
;  Direct-hotkey path: capture happens while the source app still has focus,
;  so there is no focus/paste race.
; ============================================================================
RunAction(action) {
    global busy
    Log("HOTKEY " action (busy ? " (ignored: busy)" : ""))
    if busy
        return
    busy := true
    ReleaseMods()
    saved := ClipboardAll()
    try {
        text := CaptureSelection()
        if (text = "") {
            Notify(ActLabel(action) " — " L["no_sel"])
            return
        }
        Log("fired " action " — captured " StrLen(text) " chars")
        Handle(action, text, "", saved)
    } catch as e {
        Notify(ActLabel(action) " — " e.Message)
        Log(action " -> EXCEPTION: " e.Message)
    } finally {
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
        Handle(action, popupText, instr, popupSaved)
    } catch as e {
        Notify(ActLabel(action) " — " e.Message)
    } finally {
        A_Clipboard := popupSaved
        popupSaved := "", popupText := ""
        busy := false
    }
}

; ============================================================================
;  Shared: run the brain, then paste OR open a result window.
; ============================================================================
Handle(action, text, instruction, saved) {
    global windowActions, settleMs
    r := CallBrain(action, text, instruction)
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
        A_Clipboard := r.text
        if ClipWait(2)
            Send("^v")
        Sleep(settleMs)
        Log(action " -> pasted " StrLen(r.text) " chars")
    }
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
    global scriptDir, tmpOut, windowActions, settleMs
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
    if !ClipWait(2)
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
            s .= ToCRLF(texts[A_Index]) "`r`n`r`n"
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

; ---- helpers ----------------------------------------------------------------
ReleaseMods() {
    Send("{Ctrl up}{Alt up}{Shift up}")
    Sleep(30)
}
Notify(msg) {
    TrayTip("REC — Write Tool", msg, 1)
    SetTimer(() => TrayTip(), -2500)
}
Log(msg) {
    global logFile
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  AHK   " msg "`n", logFile, "UTF-8-RAW")
}

; ---- tray -------------------------------------------------------------------
BuildTray() {
    global scriptDir, logFile, L
    ; Botan — the RecStudio mascot — is the tray face of the tool.
    if FileExist(scriptDir "\botan.ico")
        try TraySetIcon(scriptDir "\botan.ico")
    A_TrayMenu.Delete()
    A_TrayMenu.Add(L["tray_active"], (*) => "")
    A_TrayMenu.Disable(L["tray_active"])
    A_TrayMenu.Add()
    A_TrayMenu.Add(L["tray_popup"], (*) => "")
    A_TrayMenu.Disable(L["tray_popup"])
    A_TrayMenu.Add(L["tray_direct"], (*) => "")
    A_TrayMenu.Disable(L["tray_direct"])
    A_TrayMenu.Add()
    A_TrayMenu.Add(L["tray_log"], (*) => Run(logFile))
    A_TrayMenu.Add(L["tray_config"], (*) => Run('notepad.exe "' scriptDir '\config.json"'))
    A_TrayMenu.Add(L["tray_hotkeys"], (*) => Run('notepad.exe "' A_ScriptFullPath '"'))
    A_TrayMenu.Add(L["tray_selftest"], (*) => SelfTest())
    A_TrayMenu.Add(L["tray_update"], (*) => CheckUpdates())
    A_TrayMenu.Add(L["tray_reload"], (*) => Reload())
    A_TrayMenu.Add()
    A_TrayMenu.Add(L["tray_exit"], (*) => ExitApp())
    A_IconTip := L["tip_tooltip"]
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

LoadSettings()   ; must run before BuildTray — it decides the UI language
BuildTray()
CheckApiKey()    ; first run: no key yet → branded setup dialog
Log("=== RecWrite started (popup + 8 direct hotkeys, ui=" uiLang ") ===")
TrayTip(L["start_title"], L["start_tip"], 1)
SetTimer(() => TrayTip(), -3000)

; ============================================================================
;  First-run setup: no API key anywhere → ask for one and write it to a .env
;  beside the app. The key never passes through the clipboard/log and the
;  input field is masked.
; ============================================================================
CheckApiKey() {
    global scriptDir
    code := 1
    try code := RunWait(BrainCmd() " --has-key", scriptDir, "Hide")
    if (code = 0)
        return
    ShowKeyDialog()
}

ShowKeyDialog() {
    global scriptDir, uiLang, L
    kw := Gui((uiLang = "he" ? "+E0x400000" : ""), "REC — Write Tool — " L["key_title"])
    kw.BackColor := "FAF7EF"
    kw.SetFont("s14 cEF4444", "Segoe UI")
    kw.Add("Text", "x12 y10", "●")
    kw.SetFont("s11 c1A1B1D bold", "Segoe UI")
    kw.Add("Text", "x+6 yp+2", "REC — Write Tool")
    kw.SetFont("s10 c1A1B1D norm", "Segoe UI")
    kw.Add("Text", "xm y+12 w420", L["key_explain"])
    kw.SetFont("s10 c4F5D00 underline", "Segoe UI")
    lnk := kw.Add("Text", "xm y+6", "aistudio.google.com/apikey")
    lnk.OnEvent("Click", (*) => Run("https://aistudio.google.com/apikey"))
    kw.SetFont("s10 c1A1B1D norm", "Segoe UI")
    ed := kw.Add("Edit", "xm y+12 w420 Password BackgroundFFFFFF")
    sv := kw.Add("Button", "xm y+10 w120 Default", L["key_save"])
    cl := kw.Add("Button", "x+8 w100", L["btn_close"])
    sv.OnEvent("Click", SaveKey)
    cl.OnEvent("Click", (*) => kw.Destroy())
    kw.OnEvent("Close", (*) => kw.Destroy())
    kw.OnEvent("Escape", (*) => kw.Destroy())
    kw.Show("AutoSize")
    ed.Focus()

    SaveKey(*) {
        k := Trim(ed.Value)
        if (k = "")
            return
        f := FileOpen(scriptDir "\.env", "w", "UTF-8-RAW")
        f.Write("GOOGLE_API_KEY=" k "`n")
        f.Close()
        code := 1
        try code := RunWait(BrainCmd() " --has-key", scriptDir, "Hide")
        if (code = 0) {
            kw.Destroy()
            Notify(L["key_saved"])
        } else {
            Notify(L["key_failed"])
        }
    }
}

; Dev/QA aid: `recwrite.ahk --preview-window` opens a demo result window at
; startup so the GUI can be eyeballed (and screenshotted) without a hotkey.
if (A_Args.Length && A_Args[1] = "--preview-window") {
    ShowResultWindow("summary", "טקסט מקור לדוגמה",
        "**סיכום לדוגמה**`n`n- הנקודה הראשונה של הסיכום`n- נקודה שנייה, קצת יותר ארוכה, כדי לראות גלישת שורות`n- נקודה שלישית`n`nכך נראה חלון תוצאה של REC — Write Tool.")
}
