# Zip the live world fresh and keep a latest-mirror plus short history

We zip `saves/New World/` on every run instead of re-uploading the FTB mod's `minecraft/backups/*.zip`, and in Drive we maintain both `New World-latest.zip` (overwritten) and the newest 5 timestamped zips, because FTB zips can be 30min stale and a lone overwritten file gives no rollback.

## Considered options

- Re-uploading the newest FTB zip is safer while the game is open, but the zip can be 30min stale, and it couples us to `backups.json`.
- A lone mirror with no history uses the least Drive space, but one corrupt upload erases the only copy.
