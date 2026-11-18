# Backup and restore drill

The cluster can be rebuilt from Git, so the only thing worth backing up is **data**: Redis's volume (`data-shop-redis-0`, AOF persistence).
This drill backs it up with [Velero](https://velero.io) to a MinIO bucket inside the cluster (nothing leaves your machine), then
restores it and checks that the data came back. Run it with `make backup-drill`. Predictions were written before the first run.

## What the drill does

1. Install MinIO and Velero (chart pinned, node agent on for file-level volume backup, no cloud snapshots on kind).
2. Create a known set of orders through the API, wait until the counters stop moving, and record `orders:next_id` and the per-product
   counts straight from Redis.
3. Back up the `shop` namespace, volumes included (`defaultVolumesToFsBackup`).
4. Restore it into a **second namespace** (`shop-restored`) and read the same numbers from the restored Redis.
5. Clean up the second namespace.

## Predictions

1. **The backup completes** (phase `Completed`, one volume backed up by the node agent) in **under 2 minutes**.
2. **The restore into `shop-restored` completes in under 3 minutes**, and the restored Redis holds **exactly the same numbers** as at
   backup time (`orders:next_id` and the per-product counts). Not "close": equal.
3. **Restoring in place, into `shop` itself, will not just work.** Velero adds an init container to restored pods, and the Kyverno
   policies in `shop` refuse pods that are not hardened. I expect the in-place restore to fail or end up partial. This is a guess about
   an interaction, so it is only a prediction until tried.

What would make me wrong: the node agent failing to read the volume on kind, the AOF files being copied mid-write (the drill waits
for traffic to stop first), or Velero's own pods being refused by a policy.

Not claimed: backups of anything but this one volume, restore time at real data sizes, restoring to a different cluster, or encryption
of the backup (MinIO here is a lab target with throwaway credentials).
