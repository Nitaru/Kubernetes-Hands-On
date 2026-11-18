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

## Part 1 result: Velero reported success and backed up nothing that mattered (2026-11-18)

Raw output: `docs/backup-results/2026-11-18-velero-skipped-the-data-volume/`. The first attempt failed for a dull reason (MinIO no longer publishes
images to Docker Hub, so the lab target is now Bitnami's frozen mirror), the second ran.

| Prediction | Measured | Verdict |
|---|---|---|
| 1. Backup `Completed` in under 2 min, one volume backed up | `Completed` in **12 s**, but the volumes backed up were the two API pods' scratch `tmp` volumes. **Redis's volume was not backed up at all** | Status confirmed, the content **refuted** |
| 2. Restore into `shop-restored` in under 3 min, restored data equal to the original | `Completed` in **18 s**, Redis Ready after 5 s, and **empty**: `next_id` did not exist (the original was 7213) | **Refuted** |
| 3. In-place restore blocked by Kyverno | Not tried, because part 1 failed earlier | Untested |

**Why.** Redis's PersistentVolume is of type `hostPath` (that is what kind's default storage creates), and Velero's file-level backup does not
support `hostPath` volumes. It skipped the volume without failing, so the backup said `Completed` and the restore faithfully restored an empty disk.
I tried a second storage class asking the provisioner for `local` volumes (which Velero can back up) and kind's provisioner ignored the setting, so
I stopped there instead of building a CSI snapshot stack. On a real cluster with CSI or cloud disks this would behave differently.
The drill now **checks that the Redis volume is in the backup** and fails loudly if not (`scripts/backup-drill.sh`), because a green backup
status alone proved nothing.

## Part 2: a Redis-level backup and restore that does not depend on the storage type

`scripts/redis-restore-drill.sh` (`make redis-restore-drill`) uses Redis's own snapshot instead: `redis-cli --rdb` takes a point-in-time dump,
the volume is then **deleted** (the real loss), and the dump is loaded into a fresh volume. Setting this up in Docker first showed a second
silent failure: starting Redis the production way (`--appendonly yes`) with only a `dump.rdb` in the directory gives an **empty dataset and no
error**, because Redis ignores the RDB when append-only mode is on. The restore has to load the RDB with append-only off, turn it on so Redis writes
its own append-only files, and only then start normally.

Predictions, written before the first cluster run:

1. The dump takes **under 5 seconds** and is **small** (a few KB: the dataset is a handful of counters and one list).
2. After the PVC is deleted and the dump restored, **`orders:next_id`, the per-product counts and the revenue are identical** to before.
3. From deleting the volume to the data being verified through the restored Redis: **under 3 minutes**.
4. While Redis is gone, **`GET /api/products` keeps returning 200 and `POST /api/orders` returns 503**, because readiness no longer depends on
   Redis (the fix from the Redis postmortem). The API pods are not restarted.
5. The drill **fails loudly** if any number differs: it compares them and exits non-zero.

Not claimed: backups of anything other than Redis's data, restore time at real data sizes, an off-cluster copy of the dump (it is copied to the
machine running the drill and not kept), or encryption of the dump.
