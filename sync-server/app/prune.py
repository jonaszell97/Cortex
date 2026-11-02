"""Pruning and blob GC. Pruning only removes rows from the server: both Macs keep their own copy,
and clients never treat a pruned record as a delete."""

import asyncio
import logging
import time

from app.store import Store

log = logging.getLogger("sync")

DAY_MS = 86_400_000
TOMBSTONE_DAYS = 180
# Blobs are uploaded before the record that refers to them; the grace period keeps a blob whose
# record is still on its way.
BLOB_GRACE_MS = DAY_MS


def prune(store: Store, clip_days: int, now_ms: int | None = None) -> tuple[int, int]:
    """Returns the number of records and blobs removed."""
    now = int(time.time() * 1000) if now_ms is None else now_ms
    records = store.prune_records(
        clip_before_ms=now - clip_days * DAY_MS,
        tombstone_before_ms=now - TOMBSTONE_DAYS * DAY_MS,
    )
    # After the records, so blobs that only pruned records referred to go in the same run.
    blobs = store.prune_blobs(created_before_ms=now - BLOB_GRACE_MS)
    log.info("prune: removed %d records, %d blobs", records, blobs)
    return records, blobs


async def prune_daily(store: Store, clip_days: int) -> None:
    while True:
        await asyncio.sleep(DAY_MS / 1000)
        try:
            await asyncio.to_thread(prune, store, clip_days)
        except Exception:
            log.exception("prune failed")
