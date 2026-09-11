# Requirements — Prism modded save backups

## 1. Goal

One `.sh` run = fresh zip of the live world `New World`, uploaded to Google Drive as both an overwritten `latest` mirror and a retained timestamped history, with zero lasting local disk cost and loud failure instead of silent corruption.

A reusable `install.sh` turns a fresh clone (or zip-extract) inside any Prism instance folder into the same working setup: detected or newly-authed Drive access, verified scripts, no state files left behind.

## 2. Scope (settled in grilling R1–R2 + installer R1–R2)

- Instance: `Star Technology` (MC 1.20.1 / Forge 47.4.20) at
  `~/.local/share/PrismLauncher/instances/Star Technology/`
- Source world: `minecraft/saves/New World/` (17M live, ~6.7M zipped). `Funny/` is out of scope.
- "Word files" = Minecraft `World` folders, not `.docx`.
- Remote: `gdrive:Prism-StarTechnology/` via `~/.local/bin/rclone` (remote `gdrive:` already authed). Auto-`mkdir` on first run.
- Script + this file live in instance root. Zero-arg default, optional `WORLD` override arg.
- Git tracks script + docs + stable manifests only (`mmc-pack.json`, `modlist.html`, `flame/`). `instance.cfg` is ignored — it churns every launch (`lastLaunchTime`, `totalTimePlayed`). Game data never in git.
- Reusable entry: `git clone` this repo (or extract its zip) into any Prism instance dir, run `./install.sh`. Clone ≡ zip; both gated by the layout check (FR-10).

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
- Installer: no `sudo` package installs, no credential storage in the repo, no `backup.conf` state file.

## 7. Acceptance

- [x] `./backup-startech.sh` with game closed creates `/tmp` zip, uploads dated + latest, `rclone lsd` shows `Prism-StarTechnology/`, log appended, temp deleted. (proven live 2026-09-10, 2 runs)
- [x] Second run overwrites `-latest.zip` (new timestamp/size) and Drive holds ≤5 dated zips. (2 dated + latest after 2nd run)
- [x] Run with game open aborts before zipping, exit 1, nothing uploaded or deleted. (proven live via held `session.lock`, plus bats test 6)
- [x] `bats tests/` green (8 tests, hermetic: stub `rclone` + fixture world, never real saves/Drive).
- [x] `git status --short` shows only `backup-startech.sh`, `requirements.md`, `CONTEXT.md`, `docs/`, `.gitignore` (+ stable `mmc-pack.json`, `modlist.html`, `flame/`, `tests/`) — no `minecraft/` content, no `instance.cfg`.
- [x] `du -sh minecraft/backups minecraft/saves` unchanged after runs. (31M / 34M before and after)
- [x] `./install.sh` aborts outside an instance dir (`minecraft/saves/` missing), exit 2. (bats test 9)
- [x] Missing `zip`/`rclone` aborts with per-distro install hints, exit 2, nothing changed. (bats tests 10–11)
- [x] `tests/test-install.bats` green (hermetic: stub `rclone`, piped answers, never real `rclone config`). (10/10, full suite 18/18)
- [x] Live `install.sh` on this machine: detects `~/.local/bin/rclone` + `gdrive:`, all checks pass, first-backup offer declined. (2026-09-10, `--yes`, suite re-ran green inside)

## 8. Installer (reusable setup, settled in installer grilling R1–R2)

- **FR-10 Layout gate.** Refuse unless run from a Prism instance root: `minecraft/saves/` exists with at least one world. Else abort exit 2: "run this from inside your Prism instance folder". Clone ≡ zip, no other entry-path handling.
- **FR-11 Dependency check, no auto-install.** Require `bash`/`zip`; resolve `rclone` per FR-12. `unzip`/`python3`/`bats` optional (`bats` absent = warn-only skip). Anything required and missing → print the exact per-distro install command (`pacman`/`apt`/`dnf`/`brew`, plus rclone's official install script) and exit 2. Never `sudo`, never install.
- **FR-12 rclone discovery.** Candidates in order: `PATH`, then `$HOME/.local/bin/rclone`. Echo resolved path + `rclone version`. Ask y/n to use it (`--yes` implies yes). None found → FR-11 hints + exit 2.
- **FR-13 Remote triage.** `rclone listremotes`, Drive-type only: zero → auth path (FR-14); exactly one → y/n "use `<name>:`?" (no → auth path); several → numbered pick-list + "set up new" option. Non-Drive remotes are never offered.
- **FR-14 Auth loop.** Launch interactive `rclone config`, then re-detect and prove with `rclone about <remote>`. Failure → abort, no partial state. No TTY and no `--yes` → print manual steps instead, exit 2; with `--yes`, attempt the config once (a stubbed/piped config can succeed, a real closed-stdin one falls back to the manual steps).
- **FR-15 Backup configuration, no persistence.** Prompt `WORLD` (default: first world in `saves/`, or `New World` if present), Drive folder (default: instance dir basename, e.g. `Prism-StarTechnology`), `KEEP` (default 5). Write nothing to disk. Print the exact run command (`WORLD=… REMOTE=<name>:<folder> KEEP=… ./backup-startech.sh`).
- **FR-16 Verification.** `chmod +x` both scripts, `bash -n` both (abort on failure), `bats tests/` if bats exists else warn. Offer the first real backup, y/n, default No — never implied, not even by `--yes`.
- **FR-17 Automation.** Flags `--yes`, `--world=`, `--remote=` (full `name:folder`), `--keep=` plus env `INSTALL_YES`/`INSTALL_WORLD`/`INSTALL_REMOTE`/`INSTALL_KEEP`. Prompt only for what is still unset and only if stdin is a TTY; otherwise exit 2.

## 9. Decisions recorded

- ADR-0001: fresh zip + latest-mirror + KEEP=5 over re-uploading FTB zips.
