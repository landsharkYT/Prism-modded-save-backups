# Zip the live world fresh and keep a latest-mirror plus short history

We zip `saves/New World/` on every run instead of re-uploading the FTB mod's `minecraft/backups/*.zip`, and in Drive we maintain both `New World-latest.zip` (overwritten) and the newest 5 timestamped zips, because FTB zips can be 30min stale and a lone overwritten file gives no rollback.

## Considered Options

- Re-upload newest FTB zip: safer while game is open but stale, couples us to `backups.json`.
- Lone mirror with no history: smallest Drive use but one corrupt upload erases the only copy.
