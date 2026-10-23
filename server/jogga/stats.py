"""Per-distance effort statistics shared by /me and the coach packet."""

import uuid
from datetime import UTC, datetime, timedelta

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .models import Run
from .schemas import STANDARD_DISTANCES, DistanceStats


async def distance_stats(
    db: AsyncSession,
    user_id: object,
    now: datetime | None = None,
    *,
    exclude_run_id: uuid.UUID | None = None,
    before: datetime | None = None,
) -> dict[str, DistanceStats]:
    """Best/last/count/count_4w per standard distance that has any effort.

    ``exclude_run_id`` and ``before`` describe history before a given run, so
    ``best_s`` means previous best rather than including the run itself.
    """
    anchor = before or now or datetime.now(UTC)
    cutoff = anchor - timedelta(days=28)
    rows = (
        await db.scalars(select(Run).where(Run.user_id == user_id).order_by(Run.started_at))
    ).all()
    stats: dict[str, DistanceStats] = {}
    for distance in STANDARD_DISTANCES:
        efforts = [
            (run.started_at, run.efforts[distance])
            for run in rows
            if run.id != exclude_run_id
            and (before is None or run.started_at < before)
            and distance in (run.efforts or {})
        ]
        if not efforts:
            continue
        stats[distance] = DistanceStats(
            best_s=min(t for _, t in efforts),
            last_s=efforts[-1][1],
            count=len(efforts),
            count_4w=sum(1 for started, _ in efforts if started >= cutoff),
        )
    return stats
