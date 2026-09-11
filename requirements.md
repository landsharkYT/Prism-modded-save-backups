# Requirements — Star Technology Drive backup script

## 1. Goal

One `.sh` run = fresh zip of the live world `New World`, uploaded to Google Drive as both an overwritten `latest` mirror and a retained timestamped history, with zero lasting local disk cost and loud failure instead of silent corruption.

## 2. Scope (settled in grilling R1–R2)

- Instance: `Star Technology` (MC 1.20.1 / Forge 47.4.20) at
  `~/.local/share/PrismLauncher/instances/Star Technology/`
- Source world: `minecraft/saves/New World/` (17M live, ~6.7M zipped). `Funny/` is out of scope.
- "Word files" = Minecraft `World` folders, not `.docx`.
- Remote: `gdrive:Prism-StarTechnology/` via `~/.local/bin/rclone` (remote `gdrive:` already authed). Auto-`mkdir` on first run.
- Script + this file live in instance root. Zero-arg default, optional `WORLD` override arg.
- Git tracks script + docs + stable manifests only (`mmc-pack.json`, `modlist.html`, `flame/`). `instance.cfg` is ignored — it churns every launch (`lastLaunchTime`, `totalTimePlayed`). Game data never in git.

## 3. Functional requirements

- **FR-1 Fresh zip, not FTB reuse.** `zip -r` the live `saves/$WORLD/` each run to a temp dir (`/tmp/`, `mktemp -d`). Do NOT just re-upload `minecraft/backups/*.zip` (up to 30min stale).
- **FR-2 Dual upload.** On success upload two objects:
  1. `gdrive:Prism-StarTechnology/<World>-YYYY-MM-DD_HH-MM.zip` (immutable history)
  2. `gdrive:Prism-StarTechnology/<World>-latest.zip` via `rclone copyto` (overwritten mirror)
- **FR-3 Retention.** Keep newest `KEEP=5` timestamped zips in Drive, delete older with `rclone delete`. Never prune on a failed upload.
- **FR-4 Zero local bloat.** Delete temp dir/zip after successful upload. On failure keep temp for debug and print its path. Never write into `minecraft/backups/` or `minecraft/saves/`.
- **FR-5 FTB folder untouched.** Script must not read, prune, or rewrite `minecraft/backups/` or `backups.json` in v1.
- **FR-6 Guard: refuse while open.** Abort exit 1 if `saves/$WORLD/session.lock` is held by a live game process (`ps` / `lsof` check) or Prism/Minecraft java process for this instance is running. Print "close the game first".
- **FR-7 Verify overwrite.** After upload: `rclone lsf` + size check and `sha1sum` local vs `rclone sha1sum` remote for `-latest.zip`. Mismatch = failure, do not prune.
- **FR-8 Config surface.** Top of script: `WORLD`, `REMOTE="gdrive:Prism-StarTechnology"`, `KEEP=5`, `RCLONE="$HOME/.local/bin/rclone"` as env-overridable `:="${VAR:=...}"` defaults so `tests/` can inject a stub `rclone`, temp remote and small `KEEP` (normal runs unaffected). `set -euo pipefail`. Dependency check for `zip` + `rclone` with clear error.
- **FR-9 Logging.** Append every run (timestamp, world, sizes, sha1, rclone output, result) to `backup-startech.log` next to script. Log file itself is gitignored.

## 4. Storage / bloat constraints

- Live world 17M → zip ~6.7M. `KEEP=5` ≈ 35M in Drive. Drive has 5 TiB total / 2.68 GiB used — cloud bloat is negligible, cap is hygiene not capacity.
- Local disk `/` is 84% full: script must add 0 bytes net on success (temp in `/tmp`, deleted).
- `minecraft/backups/` (34M, 5× FTB zips) and `minecraft/` (640M total) are explicitly out of git (see `.gitignore`) and out of Drive upload.

## 5. Failure behavior

- Fail loud, exit non-zero, log it: game open, no network, `rclone` auth expired, Drive full, checksum mismatch.
- Never delete Drive history on failure. Never overwrite `-latest.zip` unless the new zip verified.
- Missing `zip`/`rclone` or missing `saves/$WORLD/` = usage error, exit 2.

## 6. Non-goals (v1)

- No scheduling/cron/systemd timer, no restore/download command, no pruning of `minecraft/backups/`, no multi-world loop, no `.docx` handling, no mount-based (`~/gdrive`) copy.

## 7. Acceptance

- [x] `./backup-startech.sh` with game closed creates `/tmp` zip, uploads dated + latest, `rclone lsd` shows `Prism-StarTechnology/`, log appended, temp deleted. (proven live 2026-09-10, 2 runs)
- [x] Second run overwrites `-latest.zip` (new timestamp/size) and Drive holds ≤5 dated zips. (2 dated + latest after 2nd run)
- [x] Run with game open aborts before zipping, exit 1, nothing uploaded or deleted. (proven live via held `session.lock`, plus bats test 6)
- [x] `bats tests/` green (8 tests, hermetic: stub `rclone` + fixture world, never real saves/Drive).
- [x] `git status --short` shows only `backup-startech.sh`, `requirements.md`, `CONTEXT.md`, `docs/`, `.gitignore` (+ stable `mmc-pack.json`, `modlist.html`, `flame/`, `tests/`) — no `minecraft/` content, no `instance.cfg`.
- [x] `du -sh minecraft/backups minecraft/saves` unchanged after runs. (31M / 34M before and after)

## 8. Decisions recorded

- ADR-0001: fresh zip + latest-mirror + KEEP=5 over re-uploading FTB zips.
