# Prism modded save backups

Versioned Google Drive backups for a Prism Launcher modded-Minecraft instance. One script run zips a world and uploads it as a timestamped backup plus an overwritten `-latest` mirror. A separate installer sets the same thing up on any machine.

Works from a `git clone` or a zip extract. No build step. Nothing needed beyond `bash`, `zip`, and `rclone`.

## Install

Takes about 5 minutes.

1. Prerequisites. You need `bash`, `zip`, and [`rclone`](https://rclone.org/install/) (any recent version). The installer checks for all three and tells you exactly what is missing.

2. Put this project inside your instance folder, the one that contains `minecraft/` (for example `~/.local/share/PrismLauncher/instances/Star Technology/`):

```sh
# option A: clone
git clone https://github.com/landsharkYT/Prism-modded-save-backups.git .
# option B: download the repo zip and extract its contents here ("Extract Here", not into a new folder)
```

One level too deep still works. The scripts print a `NOTICE` with the instance root they adopted. Any deeper than that, re-extract. The installer aborts and lists the folders it checked.

3. Run the installer:

```sh
./install.sh
```

It finds your `rclone` and asks before using it. It reuses a detected Google Drive remote, or walks you through `rclone config` for a new Google account. It asks which world, Drive folder, and history length to use. It verifies everything, running the test suite when `bats` is present. Then it prints your personal backup command and offers to run the first backup. For non-interactive runs: `./install.sh --yes --world "New World" --remote "gdrive:Backups" --keep 5` (see `--help`).

4. Back up after each play session with the printed command, for example:

```sh
WORLD="New World" REMOTE=gdrive:Prism-StarTechnology KEEP=5 ./backup-startech.sh
```

Close the game first. The script refuses to run while the world is open.

## How the backup behaves

- Each run zips the live world fresh. It ignores the mod's own auto-backups, which can be 30 min stale. It uploads twice: `World-YYYY-MM-DD_HH-MM.zip`, kept history with the newest 5 by default, and `World-latest.zip`, the overwritten mirror.
- It verifies size and checksum after upload. It never prunes history on a failed run. Temp files are deleted on success and kept for debugging on failure.
- It appends to `backup-startech.log` next to the script. Close the game first. A held `session.lock` means instant refusal. Nothing uploaded, nothing deleted.

## Troubleshooting

- "not a Prism instance folder" plus a Checked list means the project is not inside an instance, or it is buried more than 3 levels deep. Move it next to `minecraft/` and re-run. If you saw `NOTICE: using instance root at ...` instead, it recovered on its own. All good.
- Missing `zip` or `rclone`. The installer prints the exact install command for your distro and exits. Install it, re-run.
- Google auth expired or rejected. Reconnect with `rclone config` by redoing the Drive remote, then back up again. One warning: remotes created with rclone's shared OAuth client may stop working during 2026 when Google retires it. Creating your own client ID (https://rclone.org/drive/#making-your-own-client-id) is the durable fix.
- "game is running" but it is not. A crashed session can leave the lock held briefly. Make sure no `java` or Prism process for the instance survives, then retry.
- Verification sits a while after upload. That is normal. Drive hashes server-side before the checksums compare, about a minute for a small world. Don't Ctrl-C it.
- Drive filling up. Lower `KEEP`, for example `KEEP=3`, or delete old dated zips in the Drive web UI. Leave `-latest.zip` alone.

## Project map

- `backup-startech.sh` is the backup. `install.sh` is the installer.
- `tests/` holds hermetic `bats` suites with a stubbed `rclone` and fixture worlds. Run them with `bats tests/`.
- `requirements.md` is the contract. It covers behavior, exit codes (`0` ok, `1` runtime failure, `2` usage or environment), and the acceptance list.
- `CONTEXT.md` is the glossary. `World` vs `Save` vs `Backup` vs `Latest Mirror`, and the rest.
- `docs/adr/` records the decisions behind this setup.

Game data (`minecraft/`), logs (`*.log`), and churn (`instance.cfg`) stay out of git by design. The repo stays small and credential-free.
