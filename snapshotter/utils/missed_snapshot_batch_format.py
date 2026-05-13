"""Human-readable formatting for batched MISSED_SNAPSHOT Telegram payloads (no I/O)."""

from typing import Any, Dict, List


def format_missed_batch_summary(batch: List[Dict[str, Any]], max_error_len: int = 240) -> str:
    """
    One line with || delimiters so reporting UIs that do not render newline in issueDetails
    still read clearly.
    """
    n = len(batch)
    parts = []
    for i, item in enumerate(batch, 1):
        err = item.get('error', '')
        if len(err) > max_error_len:
            err = err[: max_error_len - 3] + '...'
        parts.append(
            f'({i}) epoch={item.get("epochId")} project={item.get("projectId")} - {err}',
        )
    body = ' || '.join(parts)
    text = f'Missed snapshots x{n} (batched): {body}'
    max_total = 3800
    if len(text) > max_total:
        text = text[: max_total - 25] + ' ... (truncated)'
    return text
