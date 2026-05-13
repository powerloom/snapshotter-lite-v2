"""Unit tests for batched MISSED_SNAPSHOT summary formatting."""

from snapshotter.utils.missed_snapshot_batch_format import format_missed_batch_summary


def test_format_missed_batch_summary_single_item():
    batch = [
        {'epochId': '42', 'projectId': 'T:ns', 'error': 'boom'},
    ]
    out = format_missed_batch_summary(batch)
    assert 'Missed snapshots x1' in out
    assert 'epoch=42' in out
    assert 'project=T:ns' in out


def test_format_missed_batch_summary_multi_joins_delimiter():
    batch = [
        {'epochId': '1', 'projectId': 'A', 'error': 'e1'},
        {'epochId': '2', 'projectId': 'B', 'error': 'e2'},
    ]
    out = format_missed_batch_summary(batch)
    assert 'Missed snapshots x2' in out
    assert '||' in out
    assert 'epoch=1' in out and 'epoch=2' in out


def test_format_missed_batch_summary_truncates_long_error_strings():
    err = 'x' * 500
    batch = [{'epochId': '9', 'projectId': 'P', 'error': err}]
    out = format_missed_batch_summary(batch, max_error_len=20)
    assert '...' in out
    assert len([c for c in out if c == 'x']) < 100
