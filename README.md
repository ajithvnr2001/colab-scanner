# colab-scanner

**Author:** Ajith Kumar

An **end-to-end automation stack** that keeps a Google Colab notebook — a **Telegram "Leecher" bot** — running continuously on a **free, CPU-only Colab session**.

The notebook builds a `songlist.txt` from an Apple Music playlist, then the bot downloads every track (in **ALAC / AAC-LC / Atmos** formats) and **mirrors the files to a Telegram channel**, resuming exactly where it left off after every restart.

What this repository actually adds on top of the notebook is the **self-healing watchdog** — it force-restarts the Colab session on a fixed cadence, and it **re-fetches the notebook from Google Drive** on every run so that any edits you make (e.g. updating the songlist) always take effect. No local/online drift, no stalled bots.

---

## Table of Contents

1. [What this repo contains](#1-what-this-repo-contains)
2. [High-level architecture](#2-high-level-architecture)
3. [How the watchdog works (the core)](#3-how-the-watchdog-works-the-core)
4. [Deep dive: the two tricky bugs this fixes](#4-deep-dive-the-two-tricky-bugs-this-fixes)
5. [The notebook: credentials you must fill in](#5-the-notebook-credentials-you-must-fill-in)
6. [End-to-end setup from scratch](#6-end-to-end-setup-from-scratch)
7. [Scheduling the watchdog with cron](#7-scheduling-the-watchdog-with-cron)
8. [Verification checklist](#8-verification-checklist)
9. [Security notes](#9-security-notes)
10. [Troubleshooting](#10-troubleshooting)
11. [License](#11-license)

---

## 1. What this repo contains

| File | Purpose |
|------|---------|
| `colab-scanner.ipynb` | The Colab notebook, **sanitized** — all real credentials replaced with `YOUR_*` placeholders. Fill in your own values before running. |
| `watchdog.sh` | The self-healing watchdog script (enterprise-grade restarts, Drive re-fetch). |
| `README.md` | This documentation. |
| `LICENSE` | MIT license. |

> ⚠️ **`colab-scanner.ipynb` has been scrubbed of all secrets.** See [Section 5](#5-the-notebook-credentials-you-must-fill-in) and [Section 9](#9-security-notes).

---

## 2. High-level architecture

```
                    ┌──────────────────────────────────────────────┐
                    │              YOUR LOCAL HOST                 │
                    │  (terminal / Hermes agent / cron)            │
                    │                                              │
                    │  ┌────────────────────────────────────────┐  │
                    │  │  cron job (every 70 min, no_agent)     │  │
                    │  │  runs watchdog.sh                      │  │
                    │  └──────────────────┬─────────────────────┘  │
                    │                     │  1. re-fetch notebook  │
                    │                     │     from Google Drive  │
                    └──┬──────────────────┼────────────────────────┘
                       │                  │
                       │   colab CLI:     │
                       │   stop + new     │  curl (Drive)
                       ▼                  ▼
             ┌──────────────────┐   ┌──────────────────┐
             │  colab exec      │◄──│  Google Drive     │
             │  (fresh CPU VM)  │   │  note.ipynb       │
             └────────┬─────────┘   └──────────────────┘
                      │  runs all cells
                      ▼
        ┌──────────────────────────────────┐
        │  Colab session "leecher" (CPU)   │
        │   cell 1: write songlist.txt     │
        │   cell 2: Telegram Leecher bot   │
        │           download + mirror      │
        └──────────────────────────────────┘
```

- **Local host** = wherever you run this. It only needs the [google-colab-cli](https://github.com/googlecolab/google-colab-cli), `git`, `curl`, and a scheduler (cron).
- **Google Colab** = the free CPU session that actually does the download/mirror work.
- **Google Drive** = the **single source of truth** for the notebook. Every restart re-downloads it, so local can never drift from online.

`watchdog.sh` runs the whole lifecycle for you, so you don't touch Colab manually at all.

---

## 3. How the watchdog works (the core)

`watchdog.sh` is a **forced-restart** script. Every time it is invoked (whether by cron or by you) it does **all** of the following, unconditionally:

### Step 1 — Re-fetch the notebook from Google Drive
```bash
curl -sL "https://drive.google.com/uc?export=download&id=${DRIVE_ID}" -o temp
# validate it's a real notebook before using it
grep '"cell_type"' temp && grep '"nbformat"' temp && size > 10000
mv -f temp note.ipynb            # atomic swap
```
- The notebook is downloaded to a temporary file first.
- It is **validated** (must be a real `.ipynb`: has `cell_type`, `nbformat`, and be > 10 KB) before it replaces the local copy.
- If the download fails or returns garbage, the script **keeps the last good copy** and still restarts — it never crashes on a corrupt download.
- **Result:** any edits you make on Drive (songlist additions, runtime tweaks) are picked up on the very next restart. Local == online, always.

### Step 2 — Kill any leftover bot process
Reads `leecher_pid`; if that PID is still alive, it is `kill`ed so two bots never run at once. The PID file is then cleared.

### Step 3 — Release the old VM, allocate a fresh CPU VM
```bash
colab stop -s leecher     # tear down the old one (no stale state)
colab new  -s leecher     # fresh CPU-only VM
```
A brand new VM each cycle guarantees a **clean slate** and no orphaned process.

### Step 4 — Launch the notebook, totally detached
```bash
setsid colab exec -s leecher -f note.ipynb >> exec.log 2>&1 < /dev/null &
echo $! > leecher_pid
exit 0
```
`setsid` detaches the bot into its own process group so the script can **return immediately**. This is the linchpin that makes the whole system reliable (see the bug in Section 4).

### Every step is time-boxed
`colab stop`, `colab new`, and the `curl` are each wrapped in `timeout ...` so **no single operation can hang the script**. The script **always exits 0** within a few seconds.

---

## 4. Deep dive: the two tricky bugs this fixes

This section is worth reading — the "obvious" version of this script silently fails in subtle ways.

### Bug 1 — The bash subshell that hangs forever

**The bug:** if you launch the bot inside a bash subshell,
```bash
( nohup colab exec -s leecher -f note.ipynb & echo $! > pidfile )
```
a **subshell `( ... )` waits for all of its background children to finish before it exits**. The leecher bot runs forever, so the subshell (and therefore the whole watchdog script) never exits. The cron scheduler has a hard **1-hour** kill, so every run would be killed after 3600 seconds and reported as:

> `Cron failed: ... Script timed out after 3600s`

Meanwhile, a stuck watchdog process lingers in `S` state (`do_wait`) with the bot as its child.

**The fix:** launch with `setsid` at **top level** (no subshell) and `exit 0` immediately. `setsid` puts the bot in a new session that the script no longer waits on, and `disown` removes it from the job table. The script returns in milliseconds; the cron never sees it as "hanging."

### Bug 2 — The "stalled but alive" bot that the old watchdog missed

An earlier design only restarted the bot **when it was detected dead** (checking the exec process PID). But the leecher's batches can time out internally (e.g. an upload hits `Request timed out` and a batch stalls for hours) **while the process stays alive** — so the PID was alive, the check said "healthy," and the bot just sat idle.

**The fix:** switch from *reactive* ("restart if dead") to **proactive forced restart** on a fixed cadence (every 70 minutes). A fresh VM + fresh bot on a schedule means a stall can never accumulate. The persistent resume log (tracked by the bot itself) means a restart **continues** where it left off instead of restarting from zero.

---

## 5. The notebook: credentials you must fill in

`colab-scanner.ipynb` is a template. The following real secrets were **removed** and replaced with placeholders — you **must** put your own values in before it will work:

| Placeholder | What it is | Where to get it |
|-------------|------------|-----------------|
| `YOUR_API_ID` | Telegram **API ID** | https://my.telegram.org → API development tools |
| `YOUR_API_HASH` | Telegram **API hash** | same page as above |
| `YOUR_BOT_TOKEN` | Your **Telegram bot token** | https://t.me/BotFather → `/newbot` |
| `YOUR_AM_MEDIA_TOKEN` | Apple Music **media-user-token** | signed into an active Apple Music subscription (needed for AAC-LC/Atmos/ALAC) |
| `YOUR_S3_ACCESS_KEY` | Wasabi/Cloudflare-R2 **access key** | your S3-compatible provider dashboard |
| `YOUR_S3_SECRET_KEY` | matching **secret key** | your S3-compatible provider dashboard |

> The notebook also has optional fields (`AM_AUTH_TOKEN`, `S3_REGION`, `S3_BUCKET_NAME`, `S3_ENDPOINT_URL`) that are not secrets and can stay as-is / be configured to your bucket.

### What the notebook does, cell by cell
- **Cell 1 — songlist builder:** constructs `songlist.txt` containing the full A.R. Rahman Apple Music playlist (1,456 tracks grouped by album).
- **Cell 2 — the Leecher bot:** clones the Telegram-Leecher repo, installs OS deps (`ffmpeg`, `aria2`, `gpac`), writes `credentials.json`, and launches the Pyrogram bot event loop that downloads each song in all three formats and mirrors them to your Telegram channel. It keeps its own **resume/dedupe state** so interrupted tracks are picked back up after every restart.

---

## 6. End-to-end setup from scratch

### Prerequisites
- A Linux/macOS machine with internet.
- A GitHub account (for the repo) and a Google account, plus the Google Colab CLI installed and authenticated.

### 1) Get the Google Colab CLI
```bash
# Python 3.9+ / manage via pipx, uv, or pip. Example with uv:
uv tool install google-colab-cli
# or
pipx install google-colab-cli
# or (with pip in a venv):
python3 -m venv colab-venv && source colab-venv/bin/activate
pip install google-colab-cli
```

### 2) Authenticate the CLI
```bash
colab auth login        # opens a browser, signs in with your Google account
colab sessions          # should list no sessions but return without error
```

### 3) Create a CPU-only session
```bash
colab new -s leecher
colab status -s leecher   # expect: Hardware: CPU | Status: IDLE
```
> **Never select GPU** for this workload — it is configured for CPU only.

### 4) Get the notebook
Either download `colab-scanner.ipynb` from this repo and **fill in your credentials**, or use your own notebook on Google Drive:
```bash
curl -sL "https://drive.google.com/uc?export=download&id=${DRIVE_ID}" -o note.ipynb
```
where `DRIVE_ID` is the file ID from your notebook's share link (`https://colab.research.google.com/drive/<DRIVE_ID>?...`). Put `note.ipynb` and `watchdog.sh` in the same directory.

### 5) Configure the watchdog
Edit the variables at the top of `watchdog.sh` if needed:
```bash
NBDIR="/path/to/your/dir"          # directory containing the notebook
DRIVE_ID="<your-notebook-file-id>" # the Drive file to re-fetch every run
SESSION="leecher"                  # the Colab session name
```
Make it executable:
```bash
chmod +x watchdog.sh
```

### 6) First manual run
```bash
cd NBDIR && ./watchdog.sh
# exit code 0 and prints "[watchdog] forced restart dispatched"
colab status -s leecher   # becomes BUSY running note.ipynb
```
Check progress (the bot's log, filtering progress-bar characters):
```bash
tr '\r' '\n' < exec.log | grep -v '░' | tail -50
```
You should see it connect to Telegram and start walking the songlist.

---

## 7. Scheduling the watchdog with cron

The watchdog is designed to run as a **no_agent cron job every 70 minutes**, so each tick is a forced restart.

**Install the script where your scheduler can find it:**
```bash
mkdir -p ~/.hermes/scripts
cp watchdog.sh ~/.hermes/scripts/colab-leecher-watchdog.sh
chmod +x ~/.hermes/scripts/colab-leecher-watchdog.sh
```

**Create the cron job** (via Hermes cron or your own cron):
```yaml
name:     colab-leecher-watchdog
schedule: every 70m
repeat:   forever
script:   colab-leecher-watchdog.sh
no_agent: true
```

> **Why `no_agent`?** The job is purely a script run — it needs no LLM. `no_agent` runs the script and delivers its stdout verbatim: **empty stdout = silent; any output = delivered**. This script prints one line on every restart, so you get a short ping each cycle.

Because 70 doesn't divide 60, if your scheduler only accepts cron expressions use a fixed minute list that lands every 70 min (e.g. `0,10,20,30,40,50 0,1,2,3,4,5,7,8,...` style), or just use `every 70m` where supported.

---

## 8. Verification checklist

Run through these after setup:

- [ ] `watchdog.sh` returns **exit 0** quickly (under a minute), not hanging or killed at 3600s.
- [ ] `colab status -s leecher` shows **BUSY** running `note.ipynb`.
- [ ] A fresh **CPU** VM is allocated each cycle (`Hardware: CPU`).
- [ ] `tr '\r' '\n' < exec.log | grep -v '░' | tail` shows Telegram connected + songlist walking.
- [ ] After editing the notebook on Drive, the next run re-fetches it (log line `notebook re-fetched from Drive`).
- [ ] Cron reports `status: ok` / `execution_success: true` (not `error`).

---

## 9. Security notes

- **This repository is public.** Treat every committed byte as public. **Never commit real API secrets.**
- `colab-scanner.ipynb` in this repo is **sanitized** — Telegram API ID/hash, bot token, Apple Music token, and S3 keys are all replaced with `YOUR_*` placeholders.
- Add `credentials.json`, `*.session`, `*.log`, and any `.env` to `.gitignore` (already done here) so generated secrets can't slip in.
- **If you ever paste a real token into chat/logs by accident, revoke it immediately** (BotFather `/revoke`, Telegram my.telegram.org, and your S3 provider).
- **Responsible use:** only download content you are authorized to access; respect Apple Music's terms and the Telegram Leecher's intended use. Do not use this to redistribute copyrighted content you don't own rights to.

---

## 10. Troubleshooting

| Symptom | Cause & fix |
|---------|-------------|
| Cron reports `... Script timed out after 3600s` (or a scary "provider timeout" message) | The script hung — almost always the old **subshell bug**. Make sure launch uses `setsid ... &` at top level, **not** `( ... & )`. Every op should be wrapped in `timeout`. |
| `colab status` says Session not found | The session name doesn't match `SESSION` in the script, or it was just torn down by a restart. Re-run `colab new -s leecher`. |
| `colab status` shows **IDLE** while the bot runs | Normal — Colab status is unreliable at detecting a busy kernel. Trust `exec.log` instead. |
| No cron notification | Empty stdout = silent by design. If healthy, the watchdog prints nothing; it only outputs a line when it restarts. |
| Bot processed nothing after restart | Check `exec.log`; the bot resumes via its own dedupe log — give it time to re-scan the songlist before judging. |
| `colab exec` appears to hang when run manually | `colab exec` queues behind a busy kernel. That's expected — the watchdog launches it detached and returns, it doesn't wait. |
| Drive re-fetch keeps the old notebook | The validation only swaps on a valid download. If your genuinely-new notebook is rejected, check it still exports as valid `.ipynb` (>10 KB, with `cell_type`/`nbformat`). |

---

## 11. License

[MIT](LICENSE) — Copyright (c) 2026 **Ajith Kumar**.