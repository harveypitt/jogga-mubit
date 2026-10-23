"""Pure maths behind packet v3: GAP paces, Riegel fitness, training zones.

No DB access — everything here is unit-testable in isolation.
"""

import re
import statistics
from datetime import date

from .schemas import STANDARD_DISTANCES, Shape

RIEGEL = 1.06  # Riegel exponent: T2 = T1 * (D2/D1) ** RIEGEL

# Grade-adjusted pace: factor = 1 + GAP_UP*grade% - GAP_DOWN*grade%,
# clamped so extreme splits don't produce nonsense.
GAP_UP = 3.3
GAP_DOWN = 1.8
GAP_MIN_FACTOR = 0.85
GAP_MAX_FACTOR = 1.5

# Fitness estimation inputs: the best effort among recent runs only. Racing
# fitness measurably detrains within 2-4 weeks of reduced training, so older
# bests describe past rather than current form.
FIT_RECENT_RUNS = 10  # the last N runs are always candidates...
FIT_MIN_DAYS = 21  # ...as is any run in the last 3 weeks...
FIT_WINDOW_DAYS = 42  # ...but never a run older than 6 weeks
MIN_EFFORT_RUN_M = 3000.0  # whole runs count as efforts at this length or more

# Training zone multipliers on the 5K-equivalent pace.
ZONE_EASY_LO = 1.20
ZONE_EASY_HI = 1.30
ZONE_STEADY = 1.12
ZONE_TEMPO = 1.05
ZONE_INTERVALS = 0.97

# One effort: (date, standard-distance key or None for a whole run, km, seconds).
Effort = tuple[date, str | None, float, float]


def _hms(s: int) -> str:
    h, rem = divmod(s, 3600)
    if h:
        return f"{h}:{rem // 60:02d}:{rem % 60:02d}"
    return f"{rem // 60}:{rem % 60:02d}"


def fmt_dur(s: float) -> str:
    """Seconds -> "m:ss" under an hour, "h:mm:ss" above. Negatives count as 0."""
    return _hms(max(0, round(s)))


def fmt_delta(s: float) -> str:
    """Signed difference -> "+m:ss" / "-m:ss" (the sign is always present)."""
    v = round(s)
    return ("-" if v < 0 else "+") + _hms(abs(v))


def _parse_pace_one(text: str) -> int:
    m = re.fullmatch(r"(\d{1,2}):([0-5]\d)", text.strip())
    if m is None:
        raise ValueError(f"not an m:ss pace: {text!r}")
    return int(m.group(1)) * 60 + int(m.group(2))


def parse_pace(text: str) -> int:
    """Inverse of fmt_dur for < 1 h: "m:ss" -> seconds, "/km" suffix tolerated.

    Also accepts a range "a–b", "a-b" or "a to b" (each end optionally "/km")
    and returns the slower end.
    """
    t = text.strip()

    def one(part: str) -> int:
        return _parse_pace_one(part.strip().removesuffix("/km"))

    for sep in ("–", "-", " to "):
        parts = t.split(sep)
        if len(parts) == 2:
            return max(one(parts[0]), one(parts[1]))
    return one(t)


def run_shape(splits: list[dict[str, float]]) -> Shape:
    """Classify the run's shape on hill-adjusted paces (full splits only).

    The trend check runs before spread on purpose: a steady fade is not
    uneven just because its endpoints are far apart.
    """
    flat = [
        gap_pace(s["distance_m"], s["moving_s"], s["gain_m"], s["loss_m"])
        for s in splits
        if s["distance_m"] >= 990.0
    ]
    flat = [p for p in flat if p > 0]
    if len(flat) < 2:
        return "steady"
    half = len(flat) // 2
    change = statistics.fmean(flat[-half:]) / statistics.fmean(flat[:half]) - 1.0
    if change > 0.04:
        return "faded"
    if change < -0.04:
        return "sped_up"
    if statistics.stdev(flat) / statistics.fmean(flat) > 0.08:
        return "uneven"
    return "steady"


def riegel(t: float, km_from: float, km_to: float) -> float:
    """Predict time at `km_to` from a `t` effort at `km_from`."""
    return float(t * (km_to / km_from) ** RIEGEL)


def split_pace(distance_m: float, moving_s: float) -> int:
    if distance_m <= 0:
        return 0
    return round(moving_s / (distance_m / 1000.0))


def gap_pace(distance_m: float, moving_s: float, gain_m: float, loss_m: float) -> int:
    """Flat-ground equivalent pace for one split (0 when distance is 0)."""
    if distance_m <= 0:
        return 0
    pace = moving_s / (distance_m / 1000.0)
    factor = 1.0 + GAP_UP * gain_m / distance_m - GAP_DOWN * loss_m / distance_m
    factor = min(max(factor, GAP_MIN_FACTOR), GAP_MAX_FACTOR)
    return round(pace / factor)


def best_effort(efforts: list[Effort]) -> Effort | None:
    """The effort with the best 5K-equivalent time; ties go to the latest date."""
    if not efforts:
        return None
    return min(efforts, key=lambda e: (riegel(e[3], e[2], 5.0), -e[0].toordinal()))


def fitness(src: Effort) -> dict[str, object]:
    """The `fit` packet block from the chosen source effort."""
    src_date, src_d, src_km, src_t = src
    pred = {
        name: int(round(riegel(src_t, src_km, STANDARD_DISTANCES[name] / 1000.0)))
        for name in ("5k", "10k", "half")
    }
    p5 = riegel(src_t, src_km, 5.0) / 5.0
    zones = {
        "easy": [round(p5 * ZONE_EASY_LO), round(p5 * ZONE_EASY_HI)],
        "steady": round(p5 * ZONE_STEADY),
        "tempo": round(p5 * ZONE_TEMPO),
        "intervals": round(p5 * ZONE_INTERVALS),
    }
    return {
        "src": [src_date.isoformat(), src_d, round(src_km, 2), int(round(src_t))],
        "pred": pred,
        "zones": zones,
    }
