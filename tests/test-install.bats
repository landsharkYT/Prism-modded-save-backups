#!/usr/bin/env bats
# Hermetic tests for install.sh (requirements.md §8, FR-10..FR-17).
# A stub `rclone` on PATH emulates remotes/auth against local state files;
# the installer under test is copied into a temp fixture instance.
# Real `rclone config` is NEVER invoked. Answers arrive via flags, env,
# or piped stdin — the installer reads identically from TTYs and pipes.

ORIG_INSTALL="$BATS_TEST_DIRNAME/../install.sh"
ORIG_BACKUP="$BATS_TEST_DIRNAME/../backup-startech.sh"
WORLD="New World"

setup() {
  TINSTANCE="$(mktemp -d /tmp/bats-inst-XXXXXX)"
  TMP_BIN="$(mktemp -d /tmp/bats-ibin-XXXXXX)"
  TMP_HOME="$(mktemp -d /tmp/bats-ihome-XXXXXX)"
  STUB_LIST="$TMP_BIN/remotes.txt"
  STUB_TYPES="$TMP_BIN/types.txt"
  STUB_CALLS="$TMP_BIN/calls.log"
  : > "$STUB_LIST"; : > "$STUB_TYPES"; : > "$STUB_CALLS"
  export STUB_LIST STUB_TYPES STUB_CALLS

  cp "$ORIG_INSTALL" "$TINSTANCE/install.sh"
  cp "$ORIG_BACKUP" "$TINSTANCE/backup-startech.sh"
  chmod +x "$TINSTANCE/install.sh"

  mkdir -p "$TINSTANCE/minecraft/saves/$WORLD"
  echo "fake-level" > "$TINSTANCE/minecraft/saves/$WORLD/level.dat"
  : > "$TINSTANCE/minecraft/saves/$WORLD/session.lock"

  # NB: the list must also satisfy anything bats itself shells out to
  # (mktemp/touch/rm/nl/sort/uniq/ln/...) when the installer runs the suite.
  for t in ls grep cut tr head basename uname chmod bash zip unzip python3 cat dirname mkdir mktemp touch rm rmdir nl sort uniq ln comm ps date flock seq wc tee timeout; do
    command -v "$t" >/dev/null 2>&1 && ln -s "$(command -v "$t")" "$TMP_BIN/$t"
  done
  write_stub_rclone
}

write_stub_rclone() {
  cat > "$TMP_BIN/rclone" <<'STUBEOF'
#!/usr/bin/env bash
# Test stub: remotes live in $STUB_LIST (names with colon),
# types in $STUB_TYPES (name:type). Bare `config` simulates a user
# creating one new Drive remote called newdrive:.
echo "rclone $*" >> "$STUB_CALLS"
cmd="${1:-}"; shift || true
case "$cmd" in
  version) echo "rclone v9.9.9-test" ;;
  listremotes) cat "$STUB_LIST" 2>/dev/null || true ;;
  config)
    if [[ "${1:-}" == "redacted" ]]; then
      name="${2%:}"
      t="$(grep -E "^${name}:" "$STUB_TYPES" 2>/dev/null | head -n 1 | cut -d: -f2 || true)"
      printf '[%s]\ntype = %s\ntoken = XXX\n' "$name" "${t:-unknown}"
    else
      echo "newdrive:" >> "$STUB_LIST"
      printf 'newdrive:drive\n' >> "$STUB_TYPES"
    fi ;;
  about)
    [[ "${STUB_ABOUT_FAIL:-0}" == 1 ]] && exit 1
    exit 0 ;;
  *) echo "stub: unknown rclone command: $cmd $*" >&2; exit 1 ;;
esac
STUBEOF
  chmod +x "$TMP_BIN/rclone"
}

teardown() {
  for d in "${TINSTANCE:-}" "${TMP_BIN:-}" "${TMP_HOME:-}" "${EMPTYDIR:-}" "${DEEPROOT:-}"; do
    if [[ -n "$d" && -d "$d" ]]; then rm -rf "$d"; fi
  done
}

run_install() {
  run env HOME="$TMP_HOME" PATH="$TMP_BIN" "${INSTALL_SH:-$TINSTANCE/install.sh}" "$@"
}

@test "layout gate: aborts outside an instance dir (FR-10)" {
  EMPTYDIR="$(mktemp -d /tmp/bats-iempty-XXXXXX)"
  cp "$ORIG_INSTALL" "$EMPTYDIR/install.sh"
  chmod +x "$EMPTYDIR/install.sh"
  run env HOME="$TMP_HOME" PATH="$TMP_BIN" "$EMPTYDIR/install.sh" --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a Prism instance folder"* ]]
}

@test "missing zip aborts with install hints, nothing changed (FR-11)" {
  rm -f "$TMP_BIN/zip"
  run_install --yes --world "$WORLD"
  [ "$status" -eq 2 ]
  [[ "$output" == *"rclone.org"* ]]
  mapfile -t top < <(find "$TINSTANCE" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
  [ "${#top[@]}" -eq 4 ] # scripts + minecraft + install.log transcript — still no state
  [[ " ${top[*]} " == *"install.log"* ]]
}

@test "missing rclone aborts with install hints (FR-11, FR-12)" {
  rm -f "$TMP_BIN/rclone"
  run_install --yes --world "$WORLD"
  [ "$status" -eq 2 ]
  [[ "$output" == *"rclone"* ]]
  [[ "$output" == *"rclone.org"* ]]
}

@test "zero remotes: launches config, detects new remote, verifies, prints command (FR-13,14,15)" {
  run_install --yes --world "$WORLD" --keep 3
  [ "$status" -eq 0 ]
  [[ "$output" == *"install OK"* ]]
  grep -q "^rclone config *$" "$STUB_CALLS"
  grep -q "about newdrive:" "$STUB_CALLS"
  [[ "$output" == *"newdrive:"* ]]
  [[ "$output" == *"WORLD="* ]]
  [[ "$output" == *"./backup-startech.sh"* ]]
  [[ "$output" == *"bats not found"* ]]
}

@test "one remote reused via INSTALL_YES, folder defaults to instance basename (FR-13,15)" {
  echo "gdrive:" > "$STUB_LIST"
  echo "gdrive:drive" > "$STUB_TYPES"
  INSTALL_YES=1 run_install --world "$WORLD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"auto-yes"* ]]
  [[ "$output" == *"gdrive:"* ]]
  [[ "$output" == *"First backup skipped"* ]]
}

@test "many remotes: picked selection wins, non-Drive excluded, no double colon (FR-13)" {
  printf 'gdrive:\nworkdrive:\nphotos:\n' > "$STUB_LIST"
  printf 'gdrive:drive\nworkdrive:drive\nphotos:s3\n' > "$STUB_TYPES"
  run_install --world "$WORLD" --keep 2 <<< $'y\n2\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"REMOTE=workdrive:"* ]]
  [[ "$output" != *"workdrive::"* ]]
  [[ "$output" != *"photos:"* ]]
}

@test "discovers rclone in ~/.local/bin when absent from PATH (FR-12)" {
  rm -f "$TMP_BIN/rclone"
  mkdir -p "$TMP_HOME/.local/bin"
  write_stub_rclone
  cp "$TMP_BIN/rclone" "$TMP_HOME/.local/bin/rclone"
  rm -f "$TMP_BIN/rclone"
  echo "gdrive:" > "$STUB_LIST"
  echo "gdrive:drive" > "$STUB_TYPES"
  run_install --yes --world "$WORLD"
  [ "$status" -eq 0 ]
  [[ "$output" == *".local/bin/rclone"* ]]
}

@test "failed Drive verification aborts with nothing persisted (FR-14)" {
  STUB_ABOUT_FAIL=1 run_install --yes --world "$WORLD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot reach remote"* ]]
}

@test "runs bats suite when present and continues on green (FR-16)" {
  mkdir -p "$TINSTANCE/tests"
  printf '@test "smoke" { true; }\n' > "$TINSTANCE/tests/smoke.bats"
  with_bats
  echo "gdrive:" > "$STUB_LIST"
  echo "gdrive:drive" > "$STUB_TYPES"
  run_install --yes --world "$WORLD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok 1 smoke"* ]]
}

@test "persists nothing but the transcript: scripts + minecraft + install.log (FR-15, FR-16)" {
  echo "gdrive:" > "$STUB_LIST"
  echo "gdrive:drive" > "$STUB_TYPES"
  run_install --yes --world "$WORLD" --keep 5
  [ "$status" -eq 0 ]
  [[ "$output" != *"NOTICE"* ]] # at the root: nothing to resolve
  mapfile -t leftovers < <(find "$TINSTANCE" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
  [ "${#leftovers[@]}" -eq 4 ]
  [[ " ${leftovers[*]} " == *"install.sh"* ]]
  [[ " ${leftovers[*]} " == *"backup-startech.sh"* ]]
  [[ " ${leftovers[*]} " == *"minecraft"* ]]
  [[ " ${leftovers[*]} " == *"install.log"* ]]
  grep -q "install OK" "$TINSTANCE/install.log"
}

# Links real bats + everything its wrapper shells out to (libexec
# helpers, env, readlink) into the hermetic TESTBIN.
with_bats() {
  ln -s "$(command -v bats)" "$TMP_BIN/bats"
  ln -s "$(command -v env)" "$TMP_BIN/env"
  ln -s "$(command -v readlink)" "$TMP_BIN/readlink"
  local libexec b
  libexec="$(dirname "$(readlink -f "$(command -v bats)")")"
  for b in "$libexec"/bats-*; do ln -s "$b" "$TMP_BIN/$(basename "$b")"; done
}

@test "help exits 0 and prints usage" {
  run_install --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "unknown arg is a usage error" {
  run_install --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "flag without value is a usage error" {
  run_install --world
  [ "$status" -eq 2 ]
  [[ "$output" == *"needs a value"* ]]
}

@test "malformed --remote without colon is a usage error" {
  echo "gdrive:" > "$STUB_LIST"
  echo "gdrive:drive" > "$STUB_TYPES"
  run_install --yes --remote "gdrive" --world "$WORLD"
  [ "$status" -eq 2 ]
  [[ "$output" == *"must look like name:folder"* ]]
}

@test "bad --keep values are rejected" {
  echo "gdrive:" > "$STUB_LIST"
  echo "gdrive:drive" > "$STUB_TYPES"
  run_install --yes --world "$WORLD" --keep abc
  [ "$status" -eq 2 ]
  [[ "$output" == *"positive integer"* ]]
  run_install --yes --world "$WORLD" --keep 0
  [ "$status" -eq 2 ]
  [[ "$output" == *"positive integer"* ]]
}

@test "unknown world aborts and lists available worlds" {
  echo "gdrive:" > "$STUB_LIST"
  echo "gdrive:drive" > "$STUB_TYPES"
  run_install --yes --world "Nope" --keep 5
  [ "$status" -eq 2 ]
  [[ "$output" == *"not found"* ]]
  [[ "$output" == *"$WORLD"* ]]
}

@test "declined rclone aborts before touching anything" {
  echo "gdrive:" > "$STUB_LIST"
  echo "gdrive:drive" > "$STUB_TYPES"
  run_install --world "$WORLD" <<< $'n\n'
  [ "$status" -eq 1 ]
  [[ "$output" == *"declined"* ]]
  grep -q "version" "$STUB_CALLS"
  [ "$(grep -c "about\|config" "$STUB_CALLS" || true)" -eq 0 ]
}

@test "invalid pick aborts" {
  printf 'gdrive:\nworkdrive:\n' > "$STUB_LIST"
  printf 'gdrive:drive\nworkdrive:drive\n' > "$STUB_TYPES"
  run_install --world "$WORLD" --keep 2 <<< $'y\n9\n'
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid pick"* ]]
}

@test "--yes with several remotes demands --remote" {
  printf 'gdrive:\nworkdrive:\n' > "$STUB_LIST"
  printf 'gdrive:drive\nworkdrive:drive\n' > "$STUB_TYPES"
  run_install --yes --world "$WORLD"
  [ "$status" -eq 2 ]
  [[ "$output" == *"several Drive remotes"* ]]
}

@test "declining the single remote falls through to setup and uses the new one" {
  echo "gdrive:" > "$STUB_LIST"
  echo "gdrive:drive" > "$STUB_TYPES"
  run script -qec "env HOME='$TMP_HOME' PATH='$TMP_BIN' '$TINSTANCE/install.sh' --world '$WORLD' --keep 5" /dev/null <<< $'y\nn\n\n\n\n\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"REMOTE=newdrive:"* ]]
}

@test "pick-new sets up and uses the new remote" {
  printf 'gdrive:\nworkdrive:\n' > "$STUB_LIST"
  printf 'gdrive:drive\nworkdrive:drive\n' > "$STUB_TYPES"
  run script -qec "env HOME='$TMP_HOME' PATH='$TMP_BIN' '$TINSTANCE/install.sh' --world '$WORLD' --keep 5" /dev/null <<< $'y\nn\n\n\n\n\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"REMOTE=newdrive:"* ]]
}

@test "--remote naming an absent remote falls through to setup, then fails loud" {
  echo "gdrive:" > "$STUB_LIST"
  echo "gdrive:drive" > "$STUB_TYPES"
  run script -qec "env HOME='$TMP_HOME' PATH='$TMP_BIN' '$TINSTANCE/install.sh' --yes --world '$WORLD' --remote 'ghost:Folder'" /dev/null <<< $'\n'
  [ "$status" -eq 1 ]
  [[ "$output" == *"still missing"* ]]
}

@test "red test suite aborts the install (FR-16)" {
  mkdir -p "$TINSTANCE/tests"
  printf '@test "boom" { false; }\n' > "$TINSTANCE/tests/fail.bats"
  with_bats
  echo "gdrive:" > "$STUB_LIST"
  echo "gdrive:drive" > "$STUB_TYPES"
  run_install --yes --world "$WORLD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"test suite failed"* ]]
}

@test "accepting the first backup invokes it with the configured values" {
  cat > "$TINSTANCE/backup-startech.sh" <<'STUBEOF'
#!/usr/bin/env bash
printf 'backup invoked WORLD=%s REMOTE=%s KEEP=%s ARGS=%s\n' "$WORLD" "$REMOTE" "$KEEP" "$*" >> "$BACKUP_CALLS"
exit 0
STUBEOF
  chmod +x "$TINSTANCE/backup-startech.sh"
  BACKUP_CALLS="$TMP_BIN/backup-calls.log"
  : > "$BACKUP_CALLS"
  export BACKUP_CALLS
  echo "gdrive:" > "$STUB_LIST"
  echo "gdrive:drive" > "$STUB_TYPES"
  run_install --world "$WORLD" --keep 7 <<< $'y\ny\n\ny\n'
  [ "$status" -eq 0 ]
  grep -q "WORLD=New World" "$BACKUP_CALLS"
  grep -q "REMOTE=gdrive:" "$BACKUP_CALLS"
  grep -q "KEEP=7" "$BACKUP_CALLS"
}

@test "subfolder placement resolves the instance root with NOTICE (FR-18)" {
  mkdir -p "$TINSTANCE/tools"
  mv "$TINSTANCE/install.sh" "$TINSTANCE/tools/install.sh"
  mv "$TINSTANCE/backup-startech.sh" "$TINSTANCE/tools/backup-startech.sh"
  echo "gdrive:" > "$STUB_LIST"
  echo "gdrive:drive" > "$STUB_TYPES"
  INSTALL_SH="$TINSTANCE/tools/install.sh" run_install --yes --world "$WORLD" --keep 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOTICE: using instance root at $TINSTANCE"* ]]
  [[ "$output" == *"install OK"* ]]
  [[ "$output" == *"REMOTE=gdrive:$(basename "$TINSTANCE")"* ]]
}

@test "no instance root within 3 levels aborts listing checked dirs (FR-18)" {
  DEEPROOT="$(mktemp -d /tmp/bats-ideep-XXXXXX)"
  DEEP="$DEEPROOT/a/b/c/d/e"
  mkdir -p "$DEEP"
  cp "$ORIG_INSTALL" "$DEEP/install.sh"
  chmod +x "$DEEP/install.sh"
  run env HOME="$TMP_HOME" PATH="$TMP_BIN" "$DEEP/install.sh" --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"Checked:"* ]]
  [[ "$output" == *"$DEEP"* ]]
  [[ "$output" == *"no minecraft/saves/ within 3 levels"* ]]
}
