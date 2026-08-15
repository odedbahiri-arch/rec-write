# Releasing REC — Write Tool

How a new version of this tool gets built and published. Written for someone
who is comfortable pushing code to GitHub but has not shipped installable
desktop software before.

---

## The mental model

Shipping a website means pushing code and letting a host serve it. Shipping a
desktop tool is different in one way that matters: **users do not run your
source code, they run a file you built for them.** So a release here has two
halves —

1. **Compile.** Two source files become two Windows executables:
   `recwrite.py` → `recwrite-brain.exe` (via PyInstaller) and `recwrite.ahk` →
   `REC-WriteTool.exe` (via Ahk2Exe). Users have neither Python nor AutoHotkey
   installed, which is the whole point of compiling.
2. **Publish.** Those exes plus the icon, README, LICENSE, CHANGELOG and the
   Hebrew quick-start page are zipped and attached to a GitHub Release.

**You never do either by hand.** `.github/workflows/release.yml` does both, on
a clean Windows machine, every time you push a tag starting with `v`. A zip you
built locally would carry whatever happened to be in your folder that day —
your personal `config.json` with your API key in it, for instance. The robot
starts from a fresh `git clone`, so it physically cannot.

**The tag is the trigger.** Not the commit, not the push to `main`. Pushing to
`main` alone builds nothing. Pushing `v1.5.4` builds and publishes.

---

## The three numbers that must agree

| Where | What it looks like | Who reads it |
|---|---|---|
| `recwrite.ahk` line 18 | `APP_VERSION := "1.5.4"` | The running app, for its update check |
| The git tag | `v1.5.4` | GitHub, to name the release |
| `CHANGELOG.md` heading | `## v1.5.4 — 2026-08-15` | Humans |

The first two are enforced. The workflow's first step re-reads `APP_VERSION`
out of `recwrite.ahk`, compares it to the tag, and **fails the build** if they
disagree — before spending three minutes compiling. That guard exists because a
mismatch is silently corrosive rather than loudly broken:

> Tray → *Check for updates* fetches `releases/latest`, strips the leading `v`
> from the tag, and compares it to `APP_VERSION`. If the shipped app says
> `1.5.3` but the release is tagged `v1.5.4`, then **every user is told they are
> out of date, forever** — including immediately after they update. If it says
> `1.5.5` but you tagged `v1.5.4`, nobody is ever told about anything again.

The CHANGELOG is not enforced, only shipped. Keep it honest anyway — it goes
inside the zip, so it is what a user reads when they wonder what changed.

---

## Choosing the number

Ordinary [semver](https://semver.org), read through this tool's lens:

- **Patch** (`1.5.3` → `1.5.4`) — a bug fixed, nothing new to learn. Almost
  every release so far.
- **Minor** (`1.5.4` → `1.6.0`) — a new action, a new hotkey, a new window,
  anything that changes what the tool can do or how it looks.
- **Major** (`1.x` → `2.0.0`) — an existing install would break or behave
  differently without the user asking. A renamed config key, a dropped hotkey,
  a different key storage location.

`config.json` is the thing most likely to force a major: the shipped
`config.example.json` becomes the user's `config.json` on first run and is
**never overwritten again**. Anything you add to it must work when absent.

---

## The steps

Everything below assumes a clean tree on `main` with the change already
committed, or ready to be.

**1. Bump `APP_VERSION`** in `recwrite.ahk` (line 18).

**2. Add the CHANGELOG entry** at the top, under `# Changelog`.

House voice: plain language, what the *user* experienced first, then the cause.
Not "fixed a DPI scaling bug in the clamp" but "the popup no longer opens
half-hidden under the taskbar — it measured itself in the wrong units". Match
the entries already there.

**3. Check it still parses.** `/validate` proves syntax only — never layout,
never wiring — but a syntax error here wastes a whole build:

```bash
Start-Process -FilePath "C:\Users\User\AppData\Local\Programs\AutoHotkey\v2\AutoHotkey64.exe" -ArgumentList '/validate','recwrite.ahk' -Wait -PassThru -NoNewWindow | Select-Object -ExpandProperty ExitCode
```

Exit code `0` is a pass. PowerShell swallows it unless you ask for it exactly
like that.

**4. Commit, tag, push.**

```bash
git add -A && git commit -m "v1.5.4 — short description of what the user gets"
```

```bash
git tag v1.5.4 && git push origin main v1.5.4
```

Push `main` and the tag together. A tag whose commit isn't on `main` builds a
release from code nobody can see.

**5. Watch the build** (about a minute):

```bash
gh run watch
```

**6. Verify** — see below. Not optional: the build going green means the files
were produced, not that they work.

---

## What the robot actually does

Read this when a build fails, so the log tells you something.

1. **Guard** — tag vs `APP_VERSION`. Fails instantly on mismatch.
2. **Build the brain** — `pip install requests pyinstaller`, then PyInstaller
   bundles `recwrite.py` and a whole Python interpreter into one exe.
3. **Smoke-test the brain** — runs `recwrite-brain.exe --ahk-settings` and
   requires exit `0`. This catches a brain that compiled but cannot start
   (a missing import, a broken `config.example.json`).
4. **Compile the trigger** — downloads pinned AutoHotkey **v2.0.26** and
   Ahk2Exe, compiles `recwrite.ahk` into `REC-WriteTool.exe` with `botan.ico`.
5. **Assemble the zip** — the two exes, `config.example.json` renamed to
   `config.json`, the icon, README, LICENSE, CHANGELOG, and
   `docs/quickstart-he.html` renamed to «התחלה מהירה.html».
6. **Publish** — creates the Release with two assets and auto-generated notes:
   - `REC-WriteTool-v1.5.4.zip` — the versioned copy, a permanent record.
   - `REC-WriteTool.zip` — an identical stable-named copy, so that
     `releases/latest/download/REC-WriteTool.zip` is a link that never changes.
     The download page and the README both point at it. **Never break that
     name.**

---

## Verifying a release

```bash
gh release view v1.5.4
```

Then, in order of how much they'd hurt if wrong:

- **Both assets are attached**, and `REC-WriteTool.zip` is present under exactly
  that name.
- **The permanent link resolves** — `https://github.com/odedbahiri-arch/rec-write/releases/latest/download/REC-WriteTool.zip`
  should download the new zip, not the previous one. This is the link real
  people use.
- **The download page still works** — <https://lab.recstudio.dev/x/rec-write>.
  It lives in the `rec-lab` project (island at `public/x/rec-write/`) and points
  at the versioned asset, so **it needs its own update when the version
  changes.** Easy to forget; it is a separate repo.
- **The in-app check agrees** — tray → *Check for updates* on an install of the
  *previous* version should now offer the new one.
- **Unzip and run it once.** The build machine proves the exes exist. Only you
  can prove they start.

---

## When something goes wrong

**The guard failed.** You tagged before bumping, or bumped without committing.
Nothing was published, so just move the tag:

```bash
git tag -d v1.5.4 && git push origin :refs/tags/v1.5.4
```

Fix `APP_VERSION`, commit, then tag and push again.

**The build failed after publishing.** It can't — publishing is the last step.
A failed run means no release exists, and the tag is the only leftover. Delete
it as above.

**A release is out and it's wrong.** Do not edit the assets in place; the
permanent link is cached and people have already downloaded it. Ship a new
patch version. That is what patch versions are for. Only delete a release
outright if it leaks something private.

**The version needs to go backwards.** It doesn't. `VerCompare` only offers
users an update when the tag is *greater*, so a lower number is invisible.
Go forwards.

---

## What is never part of a release

- **Hand-built zips.** The robot's clean clone is the safety mechanism.
- **`config.json`.** Yours is gitignored and personal — it points `env_file` at
  a path on your machine and sets `ui_language` to `he`. The shipped default
  comes from `config.example.json` and is **English**. Remember that when
  writing anything user-facing.
- **`CLAUDE.md`, `PROJECT-LOG.md`, `qa/`, `recwrite.log`, `*.bak`.** All
  gitignored on purpose — this repo is public. Check with
  `git status` before committing; `git add -A` respects `.gitignore`, but only
  if the entry is actually there.
- **Your API key.** It lives in a `.env`, never in the repo, never in the zip.
