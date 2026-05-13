"""Deferred preloader failures flush to batched Telegram when no compute runs for the epoch."""

import asyncio
import unittest

from snapshotter.utils.snapshot_worker import SnapshotAsyncWorker


class TestPreloaderFlushTelegram(unittest.TestCase):
    def test_flush_drains_pending_and_enqueues_each_row(self):
        w = SnapshotAsyncWorker()
        w.defer_preloader_failure_notification(
            100, 'baseSnapshot', Exception('Failed preloaders for baseSnapshot: eth_price'),
        )
        w.defer_preloader_failure_notification(
            100, 'other', Exception('Failed preloaders for other: block_details'),
        )
        self.assertEqual(len(w._pending_preloader_misses_by_epoch[100]), 2)

        enqueued = []

        async def fake_enqueue(*, epoch_id, project_id, error):
            enqueued.append((epoch_id, project_id, str(error)))

        async def run():
            w._enqueue_missed_snapshot_notification = fake_enqueue  # type: ignore[method-assign]
            w._missed_batch_lock = asyncio.Lock()
            await w.flush_deferred_preloader_failures_to_telegram_batch(100)

        asyncio.run(run())
        self.assertEqual(len(enqueued), 2)
        self.assertEqual(enqueued[0][0], '100')
        self.assertEqual(enqueued[1][0], '100')
        self.assertNotIn(100, w._pending_preloader_misses_by_epoch)

    def test_flush_no_pending_is_noop(self):
        w = SnapshotAsyncWorker()
        called = []

        async def fake_enqueue(**kwargs):
            called.append(kwargs)

        async def run():
            w._enqueue_missed_snapshot_notification = fake_enqueue  # type: ignore[method-assign]
            w._missed_batch_lock = asyncio.Lock()
            await w.flush_deferred_preloader_failures_to_telegram_batch(999)

        asyncio.run(run())
        self.assertEqual(called, [])


if __name__ == '__main__':
    unittest.main()
