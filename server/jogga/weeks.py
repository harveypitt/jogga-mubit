"""Runner-local dates and Monday-to-Sunday weeks."""

from datetime import UTC, date, datetime, time, timedelta, tzinfo
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


def zone(tz: str | None) -> tzinfo:
    """IANA zone for ``tz``; UTC when missing or unknown."""
    if not tz:
        return UTC
    try:
        return ZoneInfo(tz)
    except (ZoneInfoNotFoundError, ValueError):
        return UTC


def valid_tz(tz: str | None) -> str | None:
    """``tz`` if it names a known IANA zone, else None."""
    if not tz:
        return None
    try:
        ZoneInfo(tz)
    except (ZoneInfoNotFoundError, ValueError):
        return None
    return tz


def local_date(dt: datetime, tz: str | None) -> date:
    return dt.astimezone(zone(tz)).date()


def monday(d: date) -> date:
    return d - timedelta(days=d.weekday())


def local_week(dt: datetime, tz: str | None) -> date:
    """Monday of the runner's local week containing ``dt``."""
    return monday(local_date(dt, tz))


def week_end(week_start: date, tz: str | None) -> datetime:
    """The instant the local week starting ``week_start`` ends (next Monday 00:00 local)."""
    return datetime.combine(week_start + timedelta(weeks=1), time(), zone(tz))
