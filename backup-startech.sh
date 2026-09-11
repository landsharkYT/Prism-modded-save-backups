#!/usr/bin/env bash
# Star Technology — New World -> Google Drive backup.
# Spec: requirements.md (FR-1..FR-9). Glossary: CONTEXT.md.
# One run = fresh zip of the live world, uploaded as dated history +
# overwritten latest mirror, temp deleted on success.
set -euo pipefail

# --- Config (FR-8: tweak here, not below) ---
# Env-overridable (":=${...}") so tests/ can inject a stub rclone, a temp
# remote and a small KEEP. Normal runs are unaffected.
: "${WORLD:=New World}"
: "${REMOTE:=gdrive:Prism-StarTechnology}"
: "${KEEP:=5}"
: "${RCLONE:=$HOME/.local/bin/rclone}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [WORLD_NAME]

Backs up 'minecraft/saves/<WORLD_NAME>' (default: "$WORLD") to $REMOTE.
Refuses to run while the game is open. Keeps newest $KEEP dated zips.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -gt 1 ]]; then
  usage >&2
  exit 2
fi
if [[ $# -eq 1 ]]; then
  WORLD="$1"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$SCRIPT_DIR/backup-startech.log"
INSTANCE_ROOT=""
TMPDIR=""

log() {
  echo "[$(date '+%F %T')] $*" | tee -a "$LOG"
}

fail() {
  log "ERROR: $*"
  if [[ -n "$TMPDIR" && -d "$TMPDIR" ]]; then
    log "Temp kept for debug at: $TMPDIR"
    echo "Debug files kept in: $TMPDIR" >&2
  fi
  echo "ERROR: $*" >&2
  exit 1
}

# --- FR-18: instance root resolution (self + ≤3 levels up, never down). ---
resolve_instance_root() {
  local d="$SCRIPT_DIR" i checked=()
  for i in 1 2 3 4; do
    checked+=("$d")
    if [[ -d "$d/minecraft/saves" ]]; then
      INSTANCE_ROOT="$d"
      [[ "$INSTANCE_ROOT" != "$SCRIPT_DIR" ]] && log "NOTICE: using instance root at $INSTANCE_ROOT (scripts live in $SCRIPT_DIR)"
      return 0
    fi
    [[ "$d" == "/" ]] && break
    d="$(dirname "$d")"
  done
  echo "ERROR: not a Prism instance folder. Clone or extract this repo INTO your instance folder." >&2
  echo "Checked:" >&2
  printf '  %s\n' "${checked[@]}" >&2
  echo "ERROR: no minecraft/saves/ within 3 levels above $SCRIPT_DIR." >&2
  exit 2
}
resolve_instance_root
SAVES_DIR="$INSTANCE_ROOT/minecraft/saves"
WORLD_DIR="$SAVES_DIR/$WORLD"
LOCK_FILE="$WORLD_DIR/session.lock"

# --- FR-8: dependencies (missing = usage error, exit 2) ---
if ! command -v zip >/dev/null 2>&1; then
  echo "ERROR: 'zip' not found. Install it (e.g. sudo pacman -S zip)." >&2
  exit 2
fi
if [[ ! -x "$RCLONE" ]]; then
  if command -v rclone >/dev/null 2>&1; then
    RCLONE="$(command -v rclone)"
  else
    echo "ERROR: rclone not found at $RCLONE and not in PATH." >&2
    exit 2
  fi
fi
if [[ ! -d "$WORLD_DIR" ]]; then
  echo "ERROR: world not found: $WORLD_DIR" >&2
  echo "Available worlds:" >&2
  ls -1 "$SAVES_DIR" >&2 || true
  exit 2
fi

# --- FR-6: Guard — refuse while the game is open ---
# session.lock exists even when idle, so existence proves nothing.
# Layer 1: OS file-lock probe (does any process hold the lock?).
# Layer 2: any live java process whose cmdline points at this game.
game_is_open() {
  if [[ -f "$LOCK_FILE" ]]; then
    if command -v fuser >/dev/null 2>&1 && fuser -s "$LOCK_FILE" 2>/dev/null; then
      return 0
    fi
    if command -v lsof >/dev/null 2>&1 && [[ -n "$(lsof -t "$LOCK_FILE" 2>/dev/null || true)" ]]; then
      return 0
    fi
    if command -v python3 >/dev/null 2>&1 && ! python3 - "$LOCK_FILE" <<'PYEOF' 2>/dev/null; then
import fcntl, sys
with open(sys.argv[1], "rb") as fh:
    try:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit(1)
PYEOF
      return 0
    fi
  fi
  # Java processes only (our own bash script can never match this).
  if command -v pgrep >/dev/null 2>&1; then
    local java_procs
    java_procs="$(pgrep -af '(^|/)java' 2>/dev/null || true)"
    if [[ -n "$java_procs" ]] && grep -Ei 'prismlauncher|minecraft|forge|fabric|Star Technology|1\.20\.1' <<<"$java_procs" | grep -v 'backup-startech' >/dev/null 2>&1; then
      return 0
    fi
  else
    local ps_out
    ps_out="$(ps -eo pid,args 2>/dev/null | grep -i '[j]ava' || true)"
    if [[ -n "$ps_out" ]] && grep -Ei 'prismlauncher|minecraft|forge|fabric|Star Technology|1\.20\.1' <<<"$ps_out" | grep -v 'backup-startech' >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

if game_is_open; then
  log "ABORT: game appears to be running (world: $WORLD). Close Minecraft/Prism first — nothing uploaded, nothing deleted."
  echo "ERROR: game is running — close Minecraft first, then re-run." >&2
  exit 1
fi

log "=== Backup start: world='$WORLD' remote='$REMOTE' keep=$KEEP ==="

# --- Remote reachable? Fail before spending time zipping. ---
if ! "$RCLONE" mkdir "$REMOTE" 2>&1 | tee -a "$LOG"; then
  fail "cannot reach remote $REMOTE (network down or rclone auth expired?)"
fi

# --- FR-1: fresh zip to /tmp (FR-4: deleted on success) ---
TMPDIR="$(mktemp -d /tmp/startech-backup-XXXXXX)"
trap 'ec=$?; if [[ $ec -ne 0 && -n "${TMPDIR:-}" && -d "${TMPDIR:-}" ]]; then echo "[$(date "+%F %T")] FAILED (exit $ec). Temp kept at: $TMPDIR" | tee -a "$LOG"; fi' ERR

STAMP="$(date +%F_%H-%M)"
DATED="${WORLD}-${STAMP}.zip"
LATEST="${WORLD}-latest.zip"
LOCAL_ZIP="$TMPDIR/$DATED"

log "Zipping '$WORLD_DIR' -> $LOCAL_ZIP (excluding session.lock)"
(cd "$SAVES_DIR" && zip -r -X -q "$LOCAL_ZIP" "$WORLD" -x '*/session.lock') 2>&1 | tee -a "$LOG"
[[ -f "$LOCAL_ZIP" ]] || fail "zip produced no file"

LOCAL_SIZE="$(stat -c%s "$LOCAL_ZIP")"
LOCAL_SHA="$(sha1sum "$LOCAL_ZIP" | awk '{print $1}')"
log "Local zip: bytes=$LOCAL_SIZE sha1=$LOCAL_SHA"

# --- FR-2: dual upload ---
log "Uploading dated copy: $REMOTE/$DATED"
"$RCLONE" copyto "$LOCAL_ZIP" "$REMOTE/$DATED" 2>&1 | tee -a "$LOG"
log "Overwriting latest mirror: $REMOTE/$LATEST"
"$RCLONE" copyto "$LOCAL_ZIP" "$REMOTE/$LATEST" 2>&1 | tee -a "$LOG"

# --- FR-7: verify overwrite before pruning ---
REMOTE_SIZE="$("$RCLONE" lsl "$REMOTE/$LATEST" 2>/dev/null | awk '{print $1}' || true)"
if [[ -z "$REMOTE_SIZE" ]]; then
  fail "verify failed: $LATEST not found on remote after upload"
fi
if [[ "$REMOTE_SIZE" != "$LOCAL_SIZE" ]]; then
  fail "verify failed: size mismatch local=$LOCAL_SIZE remote=$REMOTE_SIZE"
fi
log "Verify size OK: $REMOTE_SIZE bytes"

if REMOTE_SHA="$("$RCLONE" sha1sum "$REMOTE/$LATEST" 2>/dev/null | awk '{print $1}' || true)"; then
  if [[ -n "$REMOTE_SHA" ]]; then
    if [[ "$REMOTE_SHA" != "$LOCAL_SHA" ]]; then
      fail "verify failed: sha1 mismatch local=$LOCAL_SHA remote=$REMOTE_SHA"
    fi
    log "Verify sha1 OK: $LOCAL_SHA"
  else
    log "WARN: remote sha1 unavailable (Drive backend) — size-only verify"
  fi
else
  log "WARN: 'rclone sha1sum' unsupported here — size-only verify"
fi

# --- FR-3: retention — newest KEEP dated zips survive (never on failure) ---
mapfile -t DATED_LIST < <("$RCLONE" lsf "$REMOTE" --format p 2>/dev/null | grep -E "^${WORLD//\//\\/}-[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}\\.zip$" | sort || true)
COUNT="${#DATED_LIST[@]}"
log "Dated backups on remote: $COUNT (keep=$KEEP)"
if [[ "$COUNT" -gt "$KEEP" ]]; then
  TO_DELETE=$((COUNT - KEEP))
  log "Pruning $TO_DELETE oldest:"
  for ((i = 0; i < TO_DELETE; i++)); do
    OLD="${DATED_LIST[$i]}"
    log "  delete $OLD"
    "$RCLONE" deletefile "$REMOTE/$OLD" 2>&1 | tee -a "$LOG"
  done
fi

# --- FR-4: zero local bloat on success ---
rm -rf "$TMPDIR"
TMPDIR=""
trap - ERR
log "=== Backup OK: $DATED + $LATEST bytes=$LOCAL_SIZE sha1=$LOCAL_SHA ==="
echo "Backup OK: $DATED + $LATEST"
