# Prism Modded Save Backups

Versioned Google Drive backups for a Prism Launcher modded-Minecraft instance. One script run zips a world and uploads it as a timestamped backup plus an overwritten `-latest` mirror; an installer sets the whole thing up on any machine.

Works from a `git clone` or a zip extract — no build step, no dependencies beyond `bash`, `zip`, and `rclone`.

## Install (about 5 minutes)

**1. Prerequisites:** `bash`, `zip`, and [`rclone`](https://rclone.org/install/) (any recent version). The installer checks and tells you exactly what's missing.

**2. Put this project inside your instance folder** — the folder that contains `minecraft/` (e.g. `~/.local/share/PrismLauncher/instances/Star Technology/`):

```sh
# option A: clone
git clone https://github.com/landsharkYT/Prism-modded-save-backups.git .
# option B: download the repo zip and extract its contents here ("Extract Here", not into a new folder)
```

One level too deep still works (the scripts print a `NOTICE` with the instance root they adopted). Any deeper, re-extract — the installer aborts and lists the folders it checked.

**3. Run the installer:**

```sh
./install.sh
```

It detects your `rclone` (asks before using it), reuses a detected Google Drive remote or walks you through `rclone config` for a new Google account, asks which world / Drive folder / history length, verifies everything (including the test suite when `bats` is present), prints your personal backup command, and offers to run the first backup. Non-interactive? `./install.sh --yes --world "New World" --remote "gdrive:Backups" --keep 5` (see `--help`).

**4. Back up after each play session** with the printed command, e.g.:

```sh
WORLD="New World" REMOTE=gdrive:Prism-StarTechnology KEEP=5 ./backup-startech.sh
```

Close the game first — the script refuses to run while the world is open.

## How the backup behaves

- Fresh zip of the live world each run (ignores the mod's own auto-backups, which can be 30 min stale), uploaded twice: `World-YYYY-MM-DD_HH-MM.zip` (kept history, newest 5 by default) and `World-latest.zip` (overwritten mirror).
- Verifies size + checksum after upload; never prunes history on a failed run; temp files are deleted on success and kept for debugging on failure.
- Appends to `backup-startech.log` next to the script. Close the game first — `session.lock` held means instant refusal, nothing uploaded, nothing deleted.

## Troubleshooting

- **"not a Prism instance folder" + a Checked: list** — the project isn't inside an instance (or is buried >3 levels deep). Move it next to `minecraft/` and re-run. A `NOTICE: using instance root at …` line instead means it recovered on its own; all good.
- **Missing `zip`/`rclone`** — the installer prints the exact install command for your distro and exits; install, re-run.
- **Google auth expired or rejected** — reconnect with `rclone config` (re-do the Drive remote), then back up again. Note: remotes created with rclone's *shared* OAuth client may stop working during 2026 when Google retires it — creating your own client ID (`https://rclone.org/drive/#making-your-own-client-id`) is the durable fix.
- **"game is running" but it isn't** — a crashed session can leave the lock held briefly; make sure no `java`/Prism process for the instance survives, then retry.
- **Verification sits a while after upload** — normal. Drive hashes server-side before checksums compare (~1 min for a small world); don't Ctrl-C it.
- **Drive filling up** — lower `KEEP` (e.g. `KEEP=3`) or delete old dated zips in the Drive web UI. `-latest.zip` is always safe to leave alone.

## Project map

- `backup-startech.sh` — the backup. `install.sh` — the installer.
- `tests/` — hermetic `bats` suites (stubbed `rclone`, fixture worlds). Run with `bats tests/`.
- `requirements.md` — the contract: behavior, exit codes (`0` ok / `1` runtime failure / `2` usage-or-environment), acceptance list.
- `CONTEXT.md` — glossary (`World` vs `Save` vs `Backup` vs `Latest Mirror`, …).
- `docs/adr/` — why the shape is what it is.

Game data (`minecraft/`), logs (`*.log`), and churn (`instance.cfg`) are gitignored by design — the repo stays small and credential-free.
