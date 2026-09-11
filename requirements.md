# Requirements — Prism modded save backups

## 1. Goal

One `.sh` run = fresh zip of the live world `New World`, uploaded to Google Drive as both an overwritten `latest` mirror and a retained timestamped history, with zero lasting local disk cost and loud failure instead of silent corruption.

A reusable `install.sh` turns a fresh clone (or zip-extract) inside any Prism instance folder into the same working setup: detected or newly-authed Drive access, verified scripts, no state files left behind.

## 2. Scope (settled in grilling R1–R2 + installer R1–R2 + robustness R1)

- Instance: `Star Technology` (MC 1.20.1 / Forge 47.4.20) at
  `~/.local/share/PrismLauncher/instances/Star Technology/`
- Source world: `minecraft/saves/New World/` (17M live, ~6.7M zipped). `Funny/` is out of scope.
- "Word files" = Minecraft `World` folders, not `.docx`.
- Remote: `gdrive:Prism-StarTechnology/` via `~/.local/bin/rclone` (remote `gdrive:` already authed). Auto-`mkdir` on first run.
- Script + this file live in instance root. Zero-arg default, optional `WORLD` override arg.
- Git tracks script + docs + stable manifests only (`mmc-pack.json`, `modlist.html`, `flame/`). `instance.cfg` is ignored — it churns every launch (`lastLaunchTime`, `totalTimePlayed`). Game data never in git.
- Reusable entry: `git clone` this repo (or extract its zip) into any Prism instance dir, run `./install.sh`. Clone ≡ zip; both gated by root resolution (FR-10). A stray subfolder placement is recovered, not punished.
- How-to lives in `README.md`; contracts live here; glossary in `CONTEXT.md`. README links, never copies.

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
- **FR-9 Logging.** Append every run (timestamp, world, sizes, sha1, rclone output, result) to `backup-startech.log` next to the script (not the resolved root). Log file itself is gitignored.
- **FR-18 Instance root resolution + layout gate (both scripts, shared helper logic).** The `Instance Root` is the nearest ancestor-or-self of the script's own dir (search up ≤3 levels) containing `minecraft/saves/`. Found above the script dir → adopt it with a loud `NOTICE: using instance root at …` line and continue. None found → abort exit 2 listing every directory checked plus the fix ("clone/extract into your instance folder"). Never search downward. Running cwd is irrelevant — everything derives from the script's location, never `$PWD`.

## 4. Storage / bloat constraints

- Live world 17M → zip ~6.7M. `KEEP=5` ≈ 35M in Drive. Drive has 5 TiB total / 2.68 GiB used — cloud bloat is negligible, cap is hygiene not capacity.
- Local disk `/` is 84% full: script must add 0 bytes net on success (temp in `/tmp`, deleted).
- `minecraft/backups/` (34M, 5× FTB zips) and `minecraft/` (640M total) are explicitly out of git (see `.gitignore`) and out of Drive upload.

## 5. Failure behavior

Exit-code contract (both scripts, asserted in bats): `0` = ok; `1` = runtime failure (game open, upload/verify failed, declined, config/auth failed, suite red); `2` = usage or environment (bad flags, missing deps, wrong folder, no TTY for a choice, world not found).

- Fail loud, exit non-zero, log it: game open, no network, `rclone` auth expired, Drive full, checksum mismatch.
- Never delete Drive history on failure. Never overwrite `-latest.zip` unless the new zip verified.
- Missing `zip`/`rclone` or missing `saves/$WORLD/` = usage error, exit 2.

## 6. Non-goals (v1)

- No scheduling/cron/systemd timer, no restore/download command, no pruning of `minecraft/backups/`, no multi-world loop, no `.docx` handling, no mount-based (`~/gdrive`) copy.
- Installer: no `sudo` package installs, no credential storage in the repo, no `backup.conf` state file.

## 7. Acceptance

- [x] `./backup-startech.sh` with game closed creates `/tmp` zip, uploads dated + latest, `rclone lsd` shows `Prism-StarTechnology/`, log appended, temp deleted. (proven live 2026-09-10, 2 runs)
- [x] Second run overwrites `-latest.zip` (new timestamp/size) and Drive holds ≤5 dated zips. (2 dated + latest after 2nd run)
- [x] Run with game open aborts before zipping, exit 1, nothing uploaded or deleted. (proven live via held `session.lock`, plus backup bats)
- [x] `bats tests/` green (32/32 hermetic: stubs + fixtures, never real saves/Drive).
- [x] `git status --short` shows only intended files — no `minecraft/` content, no `instance.cfg`, no logs.
- [x] `du -sh minecraft/backups minecraft/saves` unchanged after runs. (31M / 34M before and after)
- [x] `./install.sh` aborts outside an instance dir, exit 2. (now: resolves upward first, aborts only past 3 levels)
- [x] Missing `zip`/`rclone` aborts with per-distro install hints, exit 2, nothing changed.
- [x] `tests/test-install.bats` green (hermetic: stub `rclone`, scripted answers, never real `rclone config`).
- [x] Live `install.sh` on this machine: detects `~/.local/bin/rclone` + `gdrive:`, all checks pass, first-backup offer declined. (2026-09-10, `--yes`, suite re-ran green inside)
- [ ] Scripts run from a repo subfolder auto-adopt the instance root ≤3 levels up with a NOTICE line (bats, both scripts).
- [ ] No instance root within 3 levels up → exit 2 listing every directory checked (bats, both scripts).
- [ ] `install.log` is created beside the script with the install transcript; the persists-nothing test allows exactly the two scripts + `minecraft/` + `install.log`.
- [ ] Exit-code contract holds: every failure-path test asserts its code (audit green, no bare `exit` without a code).
- [ ] `README.md` exists: install instructions, subfolder-mistake guidance, troubleshooting; contracts only linked, never copied.

## 8. Installer (reusable setup, settled in installer grilling R1–R2)

- **FR-10 Layout gate.** See FR-18 (shared). Installer additionally requires at least one world in `saves/` (else: "launch the game once, create a world, then re-run").
- **FR-11 Dependency check, no auto-install.** Require `bash`/`zip`; resolve `rclone` per FR-12. `unzip`/`python3`/`bats` optional (`bats` absent = warn-only skip). Anything required and missing → print the exact per-distro install command (`pacman`/`apt`/`dnf`/`brew`, plus rclone's official install script) and exit 2. Never `sudo`, never install.
- **FR-12 rclone discovery.** Candidates in order: `PATH`, then `$HOME/.local/bin/rclone`. Echo resolved path + `rclone version`. Ask y/n to use it (`--yes` implies yes). None found → FR-11 hints + exit 2.
- **FR-13 Remote triage.** `rclone listremotes`, Drive-type only: zero → auth path (FR-14); exactly one → y/n "use `<name>:`?" (no → auth path); several → numbered pick-list + "set up new" option. Non-Drive remotes are never offered.
- **FR-14 Auth loop.** Launch interactive `rclone config`, then re-detect and prove with `rclone about <remote>`. Failure → abort, no partial state. No TTY and no `--yes` → print manual steps instead, exit 2; with `--yes`, attempt the config once (a stubbed/piped config can succeed, a real closed-stdin one falls back to the manual steps).
- **FR-15 Backup configuration, no persistence.** Prompt `WORLD` (default: first world in `saves/`, or `New World` if present), Drive folder (default: instance root dir basename, e.g. `Prism-StarTechnology`), `KEEP` (default 5). Write nothing to disk. Print the exact run command (`WORLD=… REMOTE=<name>:<folder> KEEP=… ./backup-startech.sh`).
- **FR-16 Verification + installer log.** `chmod +x` both scripts, `bash -n` both (abort on failure), `bats tests/` if bats exists else warn. Append the run transcript to `install.log` next to the script (same tee shape as FR-9; gitignored). Offer the first real backup, y/n, default No — never implied, not even by `--yes`.
- **FR-17 Automation.** Flags `--yes`, `--world=`, `--remote=` (full `name:folder`), `--keep=` plus env `INSTALL_YES`/`INSTALL_WORLD`/`INSTALL_REMOTE`/`INSTALL_KEEP`. Prompt only for what is still unset and only if stdin is a TTY; otherwise exit 2.

## 9. Decisions recorded

- ADR-0001: fresh zip + latest-mirror + KEEP=5 over re-uploading FTB zips.
