"""Regression: defer_preloader_failure_notification is synchronous; callers must not await it."""

import inspect

from snapshotter.utils.snapshot_worker import SnapshotAsyncWorker


def test_defer_preloader_failure_notification_is_not_a_coroutine():
    w = SnapshotAsyncWorker()
    assert not inspect.iscoroutinefunction(w.defer_preloader_failure_notification)
