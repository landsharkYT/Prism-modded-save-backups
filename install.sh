#!/usr/bin/env bash
# install.sh — reusable first-run setup (requirements.md §8, FR-10..FR-17).
#
# Clone this repo (or extract its zip) into a Prism instance folder, then:
#   ./install.sh [--yes] [--world=NAME] [--remote=name:folder] [--keep=N]
#
# Detects tools + Drive access (reusing what exists, guiding new OAuth when
# it doesn't), verifies the scripts, and persists NOTHING to disk.
#
# Input model: flags > env (INSTALL_YES/INSTALL_WORLD/INSTALL_REMOTE/
# INSTALL_KEEP) > interactive answer > safe default. Choice prompts with no
# safe default abort on EOF instead of guessing. Works identically on TTYs
# and pipes, which is also what makes it testable.
set -euo pipefail

YES="${INSTALL_YES:-0}"
WORLD="${INSTALL_WORLD:-}"
REMOTE_ARG="${INSTALL_REMOTE:-}"
KEEP="${INSTALL_KEEP:-}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--yes] [--world NAME] [--remote name:folder] [--keep N]
       (--flag value and --flag=value forms both accepted)

First-run setup: layout check, dependency check, rclone discovery,
Drive remote triage (reuse detected or authenticate new), verification.
Writes no config files. Env equivalents: INSTALL_YES=1 INSTALL_WORLD=
INSTALL_REMOTE= INSTALL_KEEP=.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) YES=1 ;;
    --world=* | --remote=* | --keep=*)
      case "$1" in
        --world=*) WORLD="${1#*=}" ;;
        --remote=*) REMOTE_ARG="${1#*=}" ;;
        --keep=*) KEEP="${1#*=}" ;;
      esac ;;
    --world | --remote | --keep)
      [[ $# -ge 2 ]] || { printf 'ERROR: %s needs a value\n' "$1" >&2; usage >&2; exit 2; }
      case "$1" in
        --world) WORLD="$2" ;;
        --remote) REMOTE_ARG="$2" ;;
        --keep) KEEP="$2" ;;
      esac
      shift ;;
    -h | --help) usage; exit 0 ;;
    *) printf 'ERROR: unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RCLONE_BIN=""
REMOTE_NAME=""

say() { printf '%s\n' "$*"; }
die() { local code="$1"; shift; printf 'ERROR: %s\n' "$*" >&2; exit "$code"; }

# --- FR-10: layout gate (clone ≡ zip; anything else aborts) ---
SAVES_DIR="$SCRIPT_DIR/minecraft/saves"
[[ -d "$SAVES_DIR" ]] || die 2 "not a Prism instance folder (no minecraft/saves/ under $SCRIPT_DIR). Clone or extract this repo INTO your instance folder, then re-run."
WORLD_DIRS=()
for d in "$SAVES_DIR"/*/; do
  [[ -d "$d" ]] && WORLD_DIRS+=("$(basename "$d")")
done
((${#WORLD_DIRS[@]} >= 1)) || die 2 "minecraft/saves/ has no worlds yet — launch the game once, create a world, then re-run install.sh."

distro_hint() {
  local id=""
  [[ -f /etc/os-release ]] && id="$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"' || true)"
  case "$id" in
    arch | manjaro | endeavouros) say "  pacman -S zip" ;;
    ubuntu | debian | linuxmint | pop) say "  sudo apt install zip" ;;
    fedora | rhel | centos) say "  sudo dnf install zip" ;;
    *) [[ "$(uname)" == "Darwin" ]] && say "  brew install zip" || say "  install 'zip' with your package manager" ;;
  esac
  say "  rclone: https://rclone.org/install/  (or: curl https://rclone.org/install.sh | sudo bash)"
}

# --- FR-11: dependency check. Required = abort + hints. Optional = warn. ---
command -v zip >/dev/null 2>&1 || {
  say "Missing required tool: zip." >&2
  distro_hint >&2
  die 2 "'zip' is required and was not found; nothing was changed."
}
for opt in unzip python3 bats; do
  command -v "$opt" >/dev/null 2>&1 || say "NOTE: optional tool '$opt' not found (backup guard falls back / test suite skipped)."
done

# --- FR-12: rclone discovery (PATH, then ~/.local/bin). ---
resolve_rclone() {
  if command -v rclone >/dev/null 2>&1; then
    RCLONE_BIN="$(command -v rclone)"
  elif [[ -x "$HOME/.local/bin/rclone" ]]; then
    RCLONE_BIN="$HOME/.local/bin/rclone"
  else
    say "rclone not found on PATH nor at \$HOME/.local/bin/rclone." >&2
    distro_hint >&2
    die 2 "'rclone' is required and was not found; nothing was changed."
  fi
  say "Found rclone: $RCLONE_BIN ($("$RCLONE_BIN" version 2>/dev/null | head -n 1 || echo 'version unknown'))"
}

# read_answer <prompt> -> prints the answer; fails on EOF (closed pipe,
# /dev/null, Ctrl-D). Identical on TTYs and pipes.
read_answer() {
  printf '%s' "$1" >&2
  local ans
  IFS= read -r ans || return 1
  printf '%s' "$ans"
}

# ask_yn <message> -> 0=yes. --yes forces yes. EOF -> abort (no safe default).
ask_yn() {
  if [[ "$YES" == 1 ]]; then say "auto-yes: $1"; return 0; fi
  local ans
  ans="$(read_answer "$1 [y/N]: ")" || die 2 "no answer for '$1': re-run with --yes or the matching flag."
  [[ "$ans" == [Yy]* ]]
}

# prompt <message> <default> -> prints value. Empty/EOF answer = default.
prompt() {
  local msg="$1" def="$2" ans
  ans="$(read_answer "$msg [$def]: ")" || ans=""
  [[ -z "$ans" ]] && ans="$def"
  printf '%s' "$ans"
}

drive_type() { # $1 = remote name (with colon) -> prints type or empty
  "$RCLONE_BIN" config redacted "$1" 2>/dev/null | grep -E '^type[[:space:]]*=' | head -n 1 | cut -d= -f2 | tr -d '[:space:]' || true
}

list_drive_remotes() {
  local r t
  while IFS= read -r r; do
    [[ -z "$r" ]] && continue
    t="$(drive_type "$r")"
    [[ "$t" == "drive" ]] && printf '%s\n' "$r"
  done < <("$RCLONE_BIN" listremotes 2>/dev/null || true)
}

# --- FR-14: auth loop. Guides interactive rclone config, then re-detects. ---
# No TTY and no --yes: print manual steps, exit 2. With --yes, attempt the
# config once (a stubbed/piped config can still succeed; a real closed-stdin
# one fails into the manual steps below).
auth_path() {
  if [[ ! -t 0 && "$YES" != 1 ]]; then
    say "No Drive remote is configured and there is no terminal for setup." >&2
    say "On a machine with a browser run: rclone config   (create a Google Drive remote)," >&2
    say "then re-run install.sh. Headless? See: rclone authorize" >&2
    die 2 "interactive auth required."
  fi
  [[ -t 0 ]] || say "No terminal: attempting 'rclone config' once (needs scripted input to succeed)..."
  say "Launching 'rclone config' — create a Google Drive remote, then quit (q) back here."
  "$RCLONE_BIN" config || {
    say "On a machine with a browser run: rclone config   (create a Google Drive remote)," >&2
    say "then re-run install.sh. Headless? See: rclone authorize" >&2
    die 1 "'rclone config' failed; nothing was changed."
  }
  REMOTE_NAME=""
}

verify_remote() { # $1 = remote name (with colon)
  "$RCLONE_BIN" about "$1" >/dev/null 2>&1 || die 1 "cannot reach remote '$1' (auth broken?). Nothing was changed."
  say "Verified Drive access on '$1'."
}

# --- FR-13: remote triage (zero / one / many Drive remotes). ---
resolve_remote_name() {
  local wanted="$1" Rs=() n r
  mapfile -t Rs < <(list_drive_remotes)
  if [[ -n "$wanted" ]]; then
    for r in "${Rs[@]}"; do [[ "$r" == "$wanted" ]] && {
      REMOTE_NAME="$wanted"
      return 0
    }; done
    say "Remote '$wanted' not found among Drive remotes; falling through to setup."
    auth_path
    mapfile -t Rs < <(list_drive_remotes)
    for r in "${Rs[@]}"; do [[ "$r" == "$wanted" ]] && {
      REMOTE_NAME="$wanted"
      return 0
    }; done
    die 1 "remote '$wanted' still missing after setup."
  fi
  if ((${#Rs[@]} == 0)); then
    say "No Google Drive remotes detected."
    auth_path
    mapfile -t Rs < <(list_drive_remotes)
    ((${#Rs[@]} >= 1)) || die 1 "still no Drive remote after setup."
    if ((${#Rs[@]} == 1)); then
      REMOTE_NAME="${Rs[0]}"
    fi
  elif ((${#Rs[@]} == 1)); then
    if ask_yn "Use detected Drive remote '${Rs[0]}'?"; then
      REMOTE_NAME="${Rs[0]}"
    else
      auth_path
      mapfile -t Rs < <(list_drive_remotes)
      ((${#Rs[@]} >= 1)) || die 1 "no Drive remote available."
      REMOTE_NAME="${Rs[0]}"
    fi
  fi
  if [[ -z "$REMOTE_NAME" ]]; then
    # Several remotes (or post-auth ambiguity): numbered pick-list.
    mapfile -t Rs < <(list_drive_remotes)
    if ((${#Rs[@]} == 1)); then
      REMOTE_NAME="${Rs[0]}"
    else
      [[ "$YES" == 1 ]] && die 2 "several Drive remotes exist; re-run with --remote=name:folder to choose non-interactively."
      local pick
      say "Detected Drive remotes:"
      for n in "${!Rs[@]}"; do printf '  %d) %s\n' "$((n + 1))" "${Rs[$n]}" >&2; done
      say "  n) set up a new remote instead"
      pick="$(read_answer "Pick [1-${#Rs[@]}/n]: ")" || die 2 "no pick given: re-run with --remote=name:folder."
      if [[ "$pick" == [Nn]* ]]; then
        auth_path
        mapfile -t Rs < <(list_drive_remotes)
        REMOTE_NAME="${Rs[-1]}"
      elif [[ "$pick" =~ ^[0-9]+$ ]] && ((pick >= 1 && pick <= ${#Rs[@]})); then
        REMOTE_NAME="${Rs[$((pick - 1))]}"
      else
        die 2 "invalid pick '$pick'."
      fi
    fi
  fi
}

main() {
  resolve_rclone
  ask_yn "Use this rclone?" || die 1 "declined rclone at $RCLONE_BIN."

  local want_name=""
  if [[ -n "$REMOTE_ARG" ]]; then
    [[ "$REMOTE_ARG" == *:* ]] || die 2 "--remote must look like name:folder (got '$REMOTE_ARG')."
    want_name="${REMOTE_ARG%%:*}:"
  fi
  resolve_remote_name "$want_name"
  verify_remote "$REMOTE_NAME"

  # --- FR-15: backup configuration. Prompted, never persisted. ---
  local def_world="${WORLD_DIRS[0]}"
  [[ -d "$SAVES_DIR/New World" ]] && def_world="New World"
  WORLD="${WORLD:-$(prompt "World to back up" "$def_world")}"
  [[ -d "$SAVES_DIR/$WORLD" ]] || die 2 "world '$WORLD' not found in minecraft/saves/. Available: ${WORLD_DIRS[*]}"
  local def_folder folder
  def_folder="$(basename "$SCRIPT_DIR")"
  folder="$(prompt "Drive folder" "$def_folder")"
  [[ -n "$folder" ]] || die 2 "Drive folder must not be empty."
  KEEP="${KEEP:-$(prompt "Versions to keep" "5")}"
  [[ "$KEEP" =~ ^[0-9]+$ ]] && ((KEEP >= 1)) || die 2 "--keep must be a positive integer (got '$KEEP')."
  local full_remote="${REMOTE_ARG:-${REMOTE_NAME%:}:$folder}"

  # --- FR-16: verification. ---
  chmod +x "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/backup-startech.sh"
  bash -n "$SCRIPT_DIR/install.sh" || die 1 "install.sh has a syntax error."
  bash -n "$SCRIPT_DIR/backup-startech.sh" || die 1 "backup-startech.sh has a syntax error."
  if command -v bats >/dev/null 2>&1 && [[ -d "$SCRIPT_DIR/tests" ]]; then
    say "Running test suite..."
    bats "$SCRIPT_DIR/tests" || die 1 "test suite failed; fix before first backup."
  else
    say "NOTE: bats not found or no tests/ dir — skipping test suite (install 'bats' to run it)."
  fi

  say ""
  say "================ install OK ================"
  say "Detected rclone : $RCLONE_BIN"
  say "Drive remote    : $full_remote"
  printf 'Run your backup with:\n  WORLD=%q REMOTE=%q KEEP=%q ./backup-startech.sh\n' "$WORLD" "$full_remote" "$KEEP"

  # First-backup offer: default No on empty/EOF, never implied by --yes (FR-16).
  local go=""
  go="$(read_answer 'Run the first backup now? [y/N]: ')" || go=""
  if [[ "$go" == [Yy]* ]]; then
    WORLD="$WORLD" REMOTE="$full_remote" KEEP="$KEEP" "$SCRIPT_DIR/backup-startech.sh"
  else
    say "First backup skipped — run the command above whenever ready."
  fi
}

main "$@"
