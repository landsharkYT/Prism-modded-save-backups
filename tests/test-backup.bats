#!/usr/bin/env bats
# Hermetic tests for backup-startech.sh (requirements.md FR-1..FR-9).
# Never touches the real saves/ or the real gdrive:. A stub `rclone` on
# PATH emulates the remote with a local directory, and the script under
# test is copied into a temp fixture instance so its SCRIPT_DIR logic is
# exercised for real.

ORIG_SCRIPT="$BATS_TEST_DIRNAME/../backup-startech.sh"
WORLD="New World"
REMOTE="gdrive:Prism-StarTechnology"

setup() {
  TINSTANCE="$(mktemp -d /tmp/bats-instance-XXXXXX)"
  FAKE_REMOTE="$(mktemp -d /tmp/bats-remote-XXXXXX)"
  TMP_BIN="$(mktemp -d /tmp/bats-bin-XXXXXX)"
  TMP_HOME="$(mktemp -d /tmp/bats-home-XXXXXX)"
  STUB_CALLS="$TMP_BIN/calls.log"
  : > "$STUB_CALLS"
  export STUB_REMOTE="$FAKE_REMOTE" STUB_CALLS

  cp "$ORIG_SCRIPT" "$TINSTANCE/backup-startech.sh"
  chmod +x "$TINSTANCE/backup-startech.sh"

  # Tiny fixture world. The name keeps its space to prove quoting.
  mkdir -p "$TINSTANCE/minecraft/saves/$WORLD/region" \
           "$TINSTANCE/minecraft/saves/$WORLD/playerdata"
  echo "fake-level" > "$TINSTANCE/minecraft/saves/$WORLD/level.dat"
  echo "fake-region" > "$TINSTANCE/minecraft/saves/$WORLD/region/r.0.0.mca"
  echo "fake-player" > "$TINSTANCE/minecraft/saves/$WORLD/playerdata/x.dat"
  : > "$TINSTANCE/minecraft/saves/$WORLD/session.lock" # present but unlocked

  # Sentinel proving minecraft/backups is never touched (FR-5).
  mkdir -p "$TINSTANCE/minecraft/backups"
  echo "sentinel" > "$TINSTANCE/minecraft/backups/DO_NOT_TOUCH.txt"

  write_stub_rclone
}

write_stub_rclone() {
  cat > "$TMP_BIN/rclone" <<'STUBEOF'
#!/usr/bin/env bash
# Test stub: maps REMOTE:path -> $STUB_REMOTE/path. Logs every call.
echo "rclone $*" >> "$STUB_CALLS"
cmd="$1"; shift
to_path() { local r="$1"; r="${r#*:}"; printf '%s/%s' "$STUB_REMOTE" "$r"; }
case "$cmd" in
  mkdir) mkdir -p "$(to_path "$1")" ;;
  copyto)
    dest="$(to_path "$2")"; mkdir -p "$(dirname "$dest")"; cp "$1" "$dest" ;;
  lsl)
    p="$(to_path "$1")"
    printf '%s 2026-01-01 00:00:00 %s\n' "$(stat -c%s "$p")" "$(basename "$p")" ;;
  lsf)
    ( cd "$(to_path "$1")" && ls -1 ) ;;
  sha1sum)
    p="$(to_path "$1")"
    if [[ "${STUB_CORRUPT_LATEST:-0}" == 1 && "$p" == *-latest.zip ]]; then
      printf '0000000000000000000000000000000000000000  %s\n' "$(basename "$p")"
    else
      ( cd "$(dirname "$p")" && sha1sum "$(basename "$p")" )
    fi ;;
  deletefile) rm -f "$(to_path "$1")" ;;
  *) echo "stub: unknown rclone command: $cmd" >&2; exit 1 ;;
esac
STUBEOF
  chmod +x "$TMP_BIN/rclone"
}

teardown() {
  if [[ -n "${HOLDER_PID:-}" ]]; then kill "$HOLDER_PID" 2>/dev/null || true; fi
  for d in "${TINSTANCE:-}" "${FAKE_REMOTE:-}" "${TMP_BIN:-}" "${TMP_HOME:-}"; do
    [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
  done
}

# Run the script against the fixture instance.
run_backup() {
  run env RCLONE="$TMP_BIN/rclone" REMOTE="$REMOTE" KEEP="${KEEP:-5}" \
    HOME="$TMP_HOME" PATH="$TMP_BIN:$PATH" \
    "$TINSTANCE/backup-startech.sh" "$@"
}

remote_dir() { printf '%s/%s' "$FAKE_REMOTE" "Prism-StarTechnology"; }

@test "help exits 0 and prints usage (FR-8)" {
  run_backup --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "unknown world exits 2 and lists available worlds" {
  run_backup "Nope"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Available worlds:"* ]]
  [[ "$output" == *"$WORLD"* ]]
}

@test "more than one arg is a usage error (FR-8)" {
  run_backup "$WORLD" extra
  [ "$status" -eq 2 ]
}

@test "happy path: zips, uploads dated + latest, verifies, cleans temp, logs (FR-1,2,4,7,9)" {
  before=$(ls -d /tmp/startech-backup-* 2>/dev/null | wc -l || true)
  run_backup "$WORLD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Backup OK"* ]]

  mapfile -t all < <(find "$(remote_dir)" -maxdepth 1 -name "$WORLD-*.zip" -printf '%f\n' | sort || true)
  [ "${#all[@]}" -eq 2 ]
  [[ " ${all[*]} " == *"$WORLD-latest.zip"* ]]

  latest="$(remote_dir)/$WORLD-latest.zip"
  unzip -l "$latest" | grep -q "$WORLD/level.dat"
  unzip -l "$latest" | grep -q "$WORLD/region/r.0.0.mca"
  [ "$(unzip -l "$latest" | grep -c "session.lock" || true)" -eq 0 ]

  after=$(ls -d /tmp/startech-backup-* 2>/dev/null | wc -l || true)
  [ "$after" -eq "$before" ]
  grep -q "Backup OK" "$TINSTANCE/backup-startech.log"
}

@test "second run prunes dated history to KEEP, latest always overwritten (FR-2,3)" {
  mkdir -p "$(remote_dir)"
  for d in 2026-01-01_00-00 2026-01-02_00-00 2026-01-03_00-00; do
    echo "old-$d" > "$(remote_dir)/$WORLD-$d.zip"
  done
  KEEP=2 run_backup "$WORLD"
  [ "$status" -eq 0 ]

  mapfile -t dated < <(find "$(remote_dir)" -maxdepth 1 -name "$WORLD-20*.zip" -printf '%f\n' | sort || true)
  [ "${#dated[@]}" -eq 2 ]
  [[ " ${dated[*]} " != *"2026-01-01_00-00"* ]]
  [[ " ${dated[*]} " != *"2026-01-02_00-00"* ]]
  [[ " ${dated[*]} " == *"2026-01-03_00-00"* ]]
  [ -f "$(remote_dir)/$WORLD-latest.zip" ]
  grep -q "deletefile" "$STUB_CALLS"
}

@test "guard refuses while session.lock is held: exit 1, nothing uploaded or deleted (FR-6)" {
  lock="$TINSTANCE/minecraft/saves/$WORLD/session.lock"
  flock -x "$lock" sleep 60 &
  HOLDER_PID=$!
  sleep 0.5
  run_backup "$WORLD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"close Minecraft"* ]]
  [ -z "$(ls -A "$(remote_dir)" 2>/dev/null || true)" ]
  grep -q "ABORT" "$TINSTANCE/backup-startech.log"
}

@test "checksum mismatch fails loud, keeps history and temp for debug (FR-3,4,7)" {
  mkdir -p "$(remote_dir)"
  echo "precious" > "$(remote_dir)/$WORLD-2026-01-01_00-00.zip"
  STUB_CORRUPT_LATEST=1 run_backup "$WORLD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sha1 mismatch"* ]]
  [ -f "$(remote_dir)/$WORLD-2026-01-01_00-00.zip" ]
  [ "$(grep -c "deletefile" "$STUB_CALLS" || true)" -eq 0 ]
  kept="$(grep -o '/tmp/startech-backup-[^ ]*' "$TINSTANCE/backup-startech.log" | tail -n 1)"
  [ -n "$kept" ]
  [ -d "$kept" ]
  rm -rf "$kept"
}

@test "minecraft/backups is never read, pruned or rewritten (FR-5)" {
  before="$(sha1sum "$TINSTANCE/minecraft/backups/DO_NOT_TOUCH.txt")"
  run_backup "$WORLD"
  [ "$status" -eq 0 ]
  [ "$(sha1sum "$TINSTANCE/minecraft/backups/DO_NOT_TOUCH.txt")" == "$before" ]
  [ "$(ls -A "$TINSTANCE/minecraft/backups")" == "DO_NOT_TOUCH.txt" ]
}
