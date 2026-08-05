#!/usr/bin/env python3
"""
RecWrite — the brain.

A stateless text filter: it takes an ACTION name and some TEXT, sends the text to
Gemini with that action's instruction, and returns the transformed text.

It is deliberately dumb and testable. No hotkeys, no clipboard, no GUI live here —
that is the AutoHotkey layer's job (recwrite.ahk). This file you can run and debug
by hand:

    python recwrite.py proofread --text "this sentence have a error"
    python recwrite.py rewrite   --infile in.txt --outfile out.txt
    python recwrite.py --selftest

Exit codes:  0 = success (outfile written / text printed)
             1 = any error (logged; AHK will abort the paste and restore clipboard)
             2 = the model judged the text incompatible with the action
             3 = Gemini's safety filter blocked the prompt or the answer
             4 = rate limited / quota exhausted — retryable
             5 = success BUT the answer was cut short (hit the output limit);
                 the outfile IS written, so the caller may still paste it
             6 = no API key configured (the AHK layer reopens the key wizard)
             7 = network problem (offline / timeout) — user-fixable, say so
"""

import sys
import os
import json
import argparse
import logging
from logging.handlers import RotatingFileHandler

# Under PyInstaller (--onefile) __file__ points into a temp unpack dir; config
# and log must live beside the real exe instead.
if getattr(sys, "frozen", False):
    HERE = os.path.dirname(os.path.abspath(sys.executable))
else:
    HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(HERE, "config.json")
LOG_PATH = os.path.join(HERE, "recwrite.log")

INCOMPATIBLE = "ERROR_TEXT_INCOMPATIBLE_WITH_REQUEST"

EXIT_OK, EXIT_ERROR, EXIT_INCOMPATIBLE = 0, 1, 2
EXIT_BLOCKED, EXIT_RATELIMIT, EXIT_TRUNCATED = 3, 4, 5
EXIT_NOKEY, EXIT_NETWORK = 6, 7

# Turn Gemini's safety filtering off. A proofreader is asked to fix angry emails,
# medical notes and legal threats — the default filters refuse those, and a refusal
# arrives as a candidate with no parts, which is indistinguishable from a broken
# response unless you look at finishReason. Best-effort: a model may still refuse.
SAFETY_SETTINGS = [
    {"category": c, "threshold": "BLOCK_NONE"}
    for c in (
        "HARM_CATEGORY_HARASSMENT",
        "HARM_CATEGORY_HATE_SPEECH",
        "HARM_CATEGORY_SEXUALLY_EXPLICIT",
        "HARM_CATEGORY_DANGEROUS_CONTENT",
    )
]

DEFAULT_FOLLOWUP = (
    "You are a helpful assistant continuing a conversation about a piece of the user's "
    "text. Answer the user's follow-up directly, keeping the same format and style as "
    "your previous response. Respond in the same language as the conversation. "
    "Use Markdown formatting where it aids readability."
)

# Roles are carried in a line-delimited plain-text file rather than JSON so the
# AutoHotkey side never has to escape quotes, backslashes or Hebrew. The caller
# may add a per-invocation random token (--chatmark) so that user text which
# itself contains a "<<<RECWRITE:user>>>" line can't forge a turn boundary.
CHAT_MARK = "<<<RECWRITE:%s>>>"
CHAT_MARK_TOKENED = "<<<RECWRITE:%s:%s>>>"


class BrainError(RuntimeError):
    """An error that already knows which exit code the caller should return."""

    def __init__(self, message, code=EXIT_ERROR):
        super().__init__(message)
        self.code = code


# ----------------------------------------------------------------------------- logging
def make_logger(debug=False):
    log = logging.getLogger("recwrite")
    log.setLevel(logging.DEBUG if debug else logging.INFO)
    if not log.handlers:
        fh = RotatingFileHandler(LOG_PATH, maxBytes=512 * 1024, backupCount=3, encoding="utf-8")
        fh.setFormatter(logging.Formatter("%(asctime)s  %(levelname)-5s  %(message)s"))
        log.addHandler(fh)
        if debug:
            ch = logging.StreamHandler(sys.stderr)
            ch.setFormatter(logging.Formatter("%(levelname)-5s  %(message)s"))
            log.addHandler(ch)
    return log


def preview(text, n=80):
    """A short, log-safe preview: length + first n chars, newlines flattened."""
    flat = " ".join((text or "").split())
    clip = flat[:n] + ("…" if len(flat) > n else "")
    return f"[{len(text or '')} chars] {clip}"


def make_preview(cfg):
    """Respect config privacy: with log_text_previews false, log lengths only —
    the user's selected text (emails, passwords, contracts) never hits the log."""
    if cfg.get("log_text_previews", True):
        return preview
    return lambda text, n=80: f"[{len(text or '')} chars]"


# ----------------------------------------------------------------------------- config
def load_config(log):
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    return cfg


def load_api_key(cfg, log):
    """Key comes from the environment or a .env file (never hard-coded, never logged).

    Search order: process env → optional "env_file" from config → .env beside
    this program. The last one is what the first-run setup dialog writes, so a
    fresh install needs zero config editing."""
    var = cfg.get("api_key_var", "GOOGLE_API_KEY")
    if os.environ.get(var):
        return os.environ[var].strip()
    candidates = []
    if cfg.get("env_file"):
        candidates.append(cfg["env_file"])
    candidates.append(os.path.join(HERE, ".env"))
    for env_file in candidates:
        if not os.path.exists(env_file):
            continue
        with open(env_file, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                # exact var only — plain startswith(var) would match
                # GOOGLE_API_KEY_BACKUP and return the wrong secret
                if line.startswith(var + "="):
                    val = line.split("=", 1)[1].strip().strip('"').strip("'")
                    if val:
                        return val
    raise BrainError(
        f"API key '{var}' not found (env, config env_file, or .env beside the app)",
        EXIT_NOKEY,
    )


# ----------------------------------------------------------------------------- provider
def call_gemini(cfg, api_key, instruction, contents, log):
    """Returns (text, truncated). Raises BrainError carrying the right exit code."""
    import requests

    model = cfg.get("model", "gemini-flash-lite-latest")
    # The key travels in a header, NOT the URL: requests puts the URL in every
    # exception message, and those messages get logged — a key in the query
    # string would leak into recwrite.log on the first network hiccup.
    url = (
        f"https://generativelanguage.googleapis.com/v1beta/models/"
        f"{model}:generateContent"
    )
    payload = {
        "system_instruction": {"parts": [{"text": instruction}]},
        "contents": contents,
        "safetySettings": SAFETY_SETTINGS,
        "generationConfig": {"temperature": cfg.get("temperature", 0.4)},
    }
    timeout = cfg.get("timeout_seconds", 30)
    log.debug(f"POST {model} (timeout {timeout}s)")
    try:
        r = requests.post(
            url, json=payload, timeout=timeout, headers={"x-goog-api-key": api_key}
        )
    except requests.Timeout:
        raise BrainError(f"Gemini timed out after {timeout}s", EXIT_NETWORK)
    except requests.RequestException as e:
        raise BrainError(f"network error reaching Gemini: {e}", EXIT_NETWORK)

    if r.status_code == 429:
        raise BrainError("rate limited by Gemini (quota) — retry shortly", EXIT_RATELIMIT)
    if r.status_code != 200:
        # surface the API's own error message but never the key/url
        raise BrainError(f"Gemini HTTP {r.status_code}: {r.text[:300]}", EXIT_ERROR)

    data = r.json()

    # A refused prompt never reaches the model at all.
    block = (data.get("promptFeedback") or {}).get("blockReason")
    if block:
        raise BrainError(f"prompt blocked by Gemini ({block})", EXIT_BLOCKED)

    candidates = data.get("candidates") or []
    if not candidates:
        raise BrainError(f"no candidates returned: {json.dumps(data)[:300]}", EXIT_ERROR)

    cand = candidates[0]
    finish = cand.get("finishReason") or ""
    parts = (cand.get("content") or {}).get("parts") or []
    text = "".join(p.get("text", "") for p in parts).strip()

    # A blocked answer comes back as a candidate with no parts — the reason is the
    # only thing that separates "refused" from "the API changed shape on us".
    if not text:
        if finish in ("SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "RECITATION"):
            raise BrainError(f"answer blocked by Gemini ({finish})", EXIT_BLOCKED)
        raise BrainError(f"empty response (finishReason={finish or 'unknown'})", EXIT_ERROR)

    return text, finish == "MAX_TOKENS"


def call_with_fallback(cfg, api_key, instruction, contents, log):
    """Google retires/renames models with little runway; a pinned model id plus
    a pinned fallback keeps every installed copy working through the churn."""
    try:
        return call_gemini(cfg, api_key, instruction, contents, log)
    except BrainError as e:
        fb = cfg.get("model_fallback")
        if fb and fb != cfg.get("model") and "HTTP 404" in str(e):
            log.warning(f"model '{cfg.get('model')}' returned 404 — retrying with '{fb}'")
            cfg2 = dict(cfg)
            cfg2["model"] = fb
            return call_gemini(cfg2, api_key, instruction, contents, log)
        raise


# ----------------------------------------------------------------------------- core
def transform(action, text, log, instruction_override=None):
    cfg = load_config(log)
    actions = cfg.get("actions", {})
    if action not in actions:
        raise RuntimeError(f"Unknown action '{action}'. Known: {', '.join(actions)}")
    spec = actions[action]
    instruction = spec["instruction"]
    prefix = spec.get("prefix", "")

    # The user turn is ALWAYS framed as a job on quoted material, never as a bare
    # message to the model — otherwise text that is itself a question or an order
    # ("log this session and give me a handoff") reads as a request and the model
    # answers it (or calls it incompatible) instead of proofreading it.
    if instruction_override:
        # Custom: the typed instruction is the *described change*, not a new system
        # prompt — the action's own guardrails ("output only the text") must survive.
        user_turn = f"{prefix}Described change: {instruction_override}\n\nText: {text}"
    else:
        user_turn = f"{prefix}{text}"

    api_key = load_api_key(cfg, log)

    pv = make_preview(cfg)
    log.info(f"action={action}  in={pv(text)}")
    if not (text or "").strip():
        log.warning("empty input — nothing to do")
        return None, EXIT_INCOMPATIBLE

    provider = cfg.get("provider", "gemini")
    if provider != "gemini":
        raise BrainError(f"Unknown provider '{provider}'", EXIT_ERROR)
    out, truncated = call_with_fallback(
        cfg, api_key, instruction, [{"role": "user", "parts": [{"text": user_turn}]}], log
    )

    if out.strip() == INCOMPATIBLE or out.strip().startswith(INCOMPATIBLE):
        log.warning("model judged text incompatible with action")
        return None, EXIT_INCOMPATIBLE

    if truncated:
        log.warning("answer hit the output limit and was cut short")
    log.info(f"action={action}  out={pv(out)}")
    return out, (EXIT_TRUNCATED if truncated else EXIT_OK)


# ----------------------------------------------------------------------------- follow-up chat
def read_history(path, token=None):
    """
    Parse the line-delimited transcript written by the result window:

        <<<RECWRITE:user>>>
        ...text...
        <<<RECWRITE:assistant>>>
        ...text...

    With a token, markers are <<<RECWRITE:token:role>>> — unforgeable by
    the text content itself.
    """
    with open(path, "r", encoding="utf-8") as f:
        raw = f.read()

    if token:
        marks = (CHAT_MARK_TOKENED % (token, "user"), CHAT_MARK_TOKENED % (token, "assistant"))
    else:
        marks = (CHAT_MARK % "user", CHAT_MARK % "assistant")

    turns, role, buf = [], None, []
    for line in raw.splitlines():
        stripped = line.strip()
        if stripped in marks:
            if role:
                turns.append((role, "\n".join(buf).strip()))
            role = "assistant" if "assistant" in stripped else "user"
            buf = []
        else:
            buf.append(line)
    if role:
        turns.append((role, "\n".join(buf).strip()))
    return [t for t in turns if t[1]]


def followup(history_path, log, token=None):
    """Answer the latest question in a transcript, with the whole thread as context."""
    cfg = load_config(log)
    turns = read_history(history_path, token=token)
    if not turns:
        raise BrainError("empty chat history", EXIT_ERROR)

    instruction = cfg.get("followup_instruction", DEFAULT_FOLLOWUP)
    api_key = load_api_key(cfg, log)
    contents = [
        {"role": ("model" if role == "assistant" else "user"), "parts": [{"text": body}]}
        for role, body in turns
    ]

    pv = make_preview(cfg)
    log.info(f"action=chat  turns={len(turns)}  q={pv(turns[-1][1])}")
    out, truncated = call_with_fallback(cfg, api_key, instruction, contents, log)
    if truncated:
        log.warning("answer hit the output limit and was cut short")
    log.info(f"action=chat  out={pv(out)}")
    return out, (EXIT_TRUNCATED if truncated else EXIT_OK)


# ----------------------------------------------------------------------------- selftest
def selftest(log):
    print("RecWrite self-test")
    ok = True
    try:
        cfg = load_config(log)
        print(f"  config.json ............. OK ({len(cfg.get('actions', {}))} actions)")
    except Exception as e:
        print(f"  config.json ............. FAIL {e}")
        return 1
    try:
        key = load_api_key(cfg, log)
        print(f"  api key ................. OK ({len(key)} chars, hidden)")
    except Exception as e:
        print(f"  api key ................. FAIL {e}")
        ok = False
    try:
        out, code = transform("proofread", "this sentence have a mistake", log)
        print(f"  gemini round-trip ....... OK -> {preview(out, 60)}")
    except Exception as e:
        print(f"  gemini round-trip ....... FAIL {e}")
        ok = False
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


# ----------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description="RecWrite text transformer")
    ap.add_argument("action", nargs="?", help="action name (e.g. proofread, rewrite)")
    ap.add_argument("--infile", help="read input text from this UTF-8 file")
    ap.add_argument("--outfile", help="write result to this UTF-8 file")
    ap.add_argument("--text", help="input text passed directly (for testing)")
    ap.add_argument("--instruction", help="the described change (used by the Custom popup)")
    ap.add_argument("--instrfile", help="read the described change from this UTF-8 file (Unicode-safe)")
    ap.add_argument("--chatfile", help="follow-up transcript to continue (action: chat)")
    ap.add_argument("--chatmark", help="random token guarding the chatfile turn markers")
    ap.add_argument("--window-actions", action="store_true",
                    help="list the actions that open in a result window (for the AHK layer)")
    ap.add_argument("--ahk-settings", action="store_true",
                    help="emit key=value settings for the AHK layer (window actions, paste delay)")
    ap.add_argument("--has-key", action="store_true",
                    help="exit 0 if an API key is configured, 1 if not (no API call)")
    ap.add_argument("--set", dest="set_kv", metavar="KEY=VALUE",
                    help="safely update one top-level config.json value (the AHK "
                         "settings window uses this instead of hand-editing JSON)")
    ap.add_argument("--selftest", action="store_true", help="verify config, key, and API")
    ap.add_argument("--debug", action="store_true", help="also log to stderr")
    try:
        args = ap.parse_args()
    except SystemExit as e:
        # argparse exits with 2 on bad args — that code means "text incompatible"
        # in our vocabulary, so remap to plain error (0 for --help stays 0)
        return EXIT_OK if not e.code else EXIT_ERROR

    log = make_logger(debug=args.debug)

    def emit(payload):
        if args.outfile:
            with open(args.outfile, "w", encoding="utf-8") as f:
                f.write(payload)
        else:
            sys.stdout.write(payload)

    try:
        if args.selftest:
            return selftest(log)

        # Single source of truth for which actions open a window instead of pasting:
        # config.json owns it, the AHK layer asks for it at startup.
        if args.window_actions:
            cfg = load_config(log)
            names = [n for n, s in cfg.get("actions", {}).items() if s.get("open_in_window")]
            emit(",".join(names))
            return EXIT_OK

        if args.ahk_settings:
            cfg = load_config(log)
            names = [n for n, s in cfg.get("actions", {}).items() if s.get("open_in_window")]
            emit(
                f"window_actions={','.join(names)}\n"
                f"paste_settle_ms={int(cfg.get('paste_settle_ms', 300))}\n"
                f"ui_language={cfg.get('ui_language', 'en')}\n"
                f"hotkey_menu={cfg.get('hotkey_menu', '^!Space')}\n"
            )
            return EXIT_OK

        if args.set_kv:
            if "=" not in args.set_kv:
                sys.stderr.write("RecWrite: --set expects KEY=VALUE\n")
                return EXIT_ERROR
            key, _, raw = args.set_kv.partition("=")
            key, raw = key.strip(), raw.strip()
            # only scalar knobs — never actions/prompts, which deserve an editor
            allowed = {"ui_language", "model", "temperature", "timeout_seconds",
                       "paste_settle_ms", "log_text_previews", "hotkey_menu"}
            if key not in allowed:
                sys.stderr.write(f"RecWrite: --set refuses '{key}' (allowed: {', '.join(sorted(allowed))})\n")
                return EXIT_ERROR
            if raw.lower() in ("true", "false"):
                val = raw.lower() == "true"
            else:
                try:
                    val = int(raw)
                except ValueError:
                    try:
                        val = float(raw)
                    except ValueError:
                        val = raw
            cfg = load_config(log)
            cfg[key] = val
            tmp = CONFIG_PATH + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(cfg, f, ensure_ascii=False, indent=2)
                f.write("\n")
            os.replace(tmp, CONFIG_PATH)
            log.info(f"config set {key}={val!r}")
            return EXIT_OK

        if args.has_key:
            try:
                load_api_key(load_config(log), log)
                return EXIT_OK
            except Exception:
                return EXIT_ERROR

        if args.chatfile:
            out, code = followup(args.chatfile, log, token=args.chatmark)
            emit(out)
            return code

        if not args.action:
            sys.stderr.write("RecWrite: action is required (or use --selftest / --window-actions)\n")
            return EXIT_ERROR

        if args.infile:
            with open(args.infile, "r", encoding="utf-8") as f:
                text = f.read()
        elif args.text is not None:
            text = args.text
        else:
            text = sys.stdin.read()

        instruction_override = args.instruction
        if args.instrfile:
            with open(args.instrfile, "r", encoding="utf-8") as f:
                instruction_override = f.read().strip()

        out, code = transform(args.action, text, log, instruction_override=instruction_override)

        # EXIT_TRUNCATED still carries a usable result — write it and let the
        # caller decide whether to paste it.
        if code in (EXIT_OK, EXIT_TRUNCATED) and out is not None:
            emit(out)
        return code

    except BrainError as e:
        log.error(f"FAILED ({e.code}): {e}")
        sys.stderr.write(f"RecWrite: {e}\n")
        return e.code
    except Exception as e:
        log.exception(f"FAILED: {e}")
        sys.stderr.write(f"RecWrite error: {e}\n")
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main())
