#!/usr/bin/env bash
# Colab leecher FORCED-RESTART watchdog (v2 - no hanging).
# Every scheduled run: re-fetch notebook from Drive, stop session, create a
# fresh CPU VM, re-run all cells. MUST exit quickly (cron kills at 3600s).
#
# Critical fix: launch the bot fully detached with setsid at TOP level (NOT in a
# bash subshell). A subshell '( ... )' waits on its background children forever,
# and the bot never exits -> the script would hang and get killed by cron.
set -u

export PATH="/root/.local/bin:$PATH"
COLAB="/root/.local/bin/colab"
NBDIR="/root/colab-task"
NOTEBOOK="$NBDIR/note.ipynb"
SESSION="leecher"
PIDFILE="$NBDIR/leecher_pid"
LOG="$NBDIR/exec.log"
ERRLOG="$NBDIR/restart.log"
DRIVE_ID="1sN9yG5Ci32GvQYjMGJbpKnVyR3jObKlS"
DRIVE_URL="https://drive.google.com/uc?export=download&id=${DRIVE_ID}"

# ---- 1) Re-fetch notebook from Drive so local == online (any songlist edits take effect)
echo "$(date -u) fetching notebook from Drive... " >> "$ERRLOG"
TMPNB="$NBDIR/note.online.json"
if timeout 150 curl -sL --max-time 120 "$DRIVE_URL" -o "$TMPNB" \
   && [ -s "$TMPNB" ] \
   && [ "$(wc -c < "$TMPNB")" -gt 10000 ] \
   && grep -q '"cell_type"' "$TMPNB" \
   && grep -q '"nbformat"' "$TMPNB"; then
    mv -f "$TMPNB" "$NOTEBOOK"
    echo "$(date -u) notebook re-fetched from Drive (OK) -> $NOTEBOOK" >> "$ERRLOG"
else
    rm -f "$TMPNB"
    echo "$(date -u) WARN: Drive fetch failed - using last local $NOTEBOOK" >> "$ERRLOG"
fi

# ---- 2) Stop any leftover bot exec (old run) if still alive
if [ -f "$PIDFILE" ]; then
    OPID=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$OPID" ] && kill -0 "$OPID" 2>/dev/null; then
        kill "$OPID" 2>/dev/null
        echo "$(date -u) killed old exec pid $OPID" >> "$ERRLOG"
    fi
fi
rm -f "$PIDFILE"

# ---- 3) Stop old VM, then allocate a fresh CPU VM (timeout-guarded so it can't hang us)
echo "$(date -u) stopping old session $SESSION..." >> "$ERRLOG"
timeout 90 "$COLAB" stop -s "$SESSION" >/dev/null 2>&1 || true
sleep 3
echo "$(date -u) creating fresh session $SESSION..." >> "$ERRLOG"
timeout 150 "$COLAB" new -s "$SESSION" >> "$ERRLOG" 2>&1 || echo "$(date -u) WARN: colab new timed out (session may still be creating)" >> "$ERRLOG"
sleep 2

# ---- 4) Launch "run all" FULLY DETACHED at top level (no subshell!).
# setsid => new session, immune to bash waiting; stdin from /dev/null,
# stdout/stderr to log; the script does NOT wait and exits right after.
setsid "$COLAB" exec -s "$SESSION" -f "$NOTEBOOK" >> "$LOG" 2>&1 < /dev/null &
echo $! > "$PIDFILE"
disown 2>/dev/null || true

echo "[watchdog] forced restart dispatched - session: $SESSION, exec pid: $(cat "$PIDFILE" 2>/dev/null)"
exit 0