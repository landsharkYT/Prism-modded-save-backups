# Star Technology Backup

One Prism instance's world backups pushed to Google Drive via rclone, with no local bloat and no accidental git commits of game data.

## Language

**World**:
The live playable folder `minecraft/saves/<Name>/`, e.g. `New World`.
_Avoid_: word file, save file, level

**Save**:
The live `World` folder on disk. Never zipped in place, only read.
_Avoid_: backup, export

**Backup**:
A timestamped zip of a `World`, e.g. `New World-2026-09-11_12-00.zip`. Immutable once uploaded.
_Avoid_: save, mirror, latest

**Latest Mirror**:
The single Drive file `New World-latest.zip` overwritten every successful run. Points at the newest `Backup`.
_Avoid_: backup, copy, sync

**FTB Backup**:
The mod's own auto-zips in `minecraft/backups/` every 30min. Input we deliberately do NOT reuse.
_Avoid_: script backup, Drive backup

**Guard**:
The pre-flight check that refuses to run while the game holds `session.lock`.
_Avoid_: lock check, safety check
