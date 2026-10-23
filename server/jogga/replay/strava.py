"""Strava export -> run summaries, with the same maths the iOS app applies on import.

Mirrors ios/Jogga/Import/StravaImporter.swift and RunMath.swift: GPX points are filtered
(implied speed > 12 m/s against the previous raw point is dropped), moving time skips
gaps > 10 s, elevation uses 3 m hysteresis, splits are per km plus a final partial
>= 50 m, and efforts are the moving time at which each standard distance is first
crossed. Activities without a readable GPX fall back to the CSV summary.
"""

import csv
import gzip
import math
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

from ..schemas import STANDARD_DISTANCES

RUN_TYPES = {"Run", "Trail Run", "Virtual Run"}
MAX_SPEED_MPS = 12.0
PAUSE_GAP_S = 10.0
ELEV_HYSTERESIS_M = 3.0
GPX_NS = "{http://www.topografix.com/GPX/1/1}"


@dataclass
class Sample:
    t: float
    lat: float
    lon: float
    ele: float | None


@dataclass
class ReplayRun:
    external_id: str
    started_at: datetime
    distance_m: float
    moving_s: float
    elapsed_s: float
    gain_m: float
    loss_m: float
    splits: list[dict[str, float]] = field(default_factory=list)
    efforts: dict[str, float] = field(default_factory=dict)
    from_route: bool = False


def haversine(a: Sample, b: Sample) -> float:
    r = 6_371_000.0
    d_lat = math.radians(b.lat - a.lat)
    d_lon = math.radians(b.lon - a.lon)
    h = (
        math.sin(d_lat / 2) ** 2
        + math.cos(math.radians(a.lat)) * math.cos(math.radians(b.lat)) * math.sin(d_lon / 2) ** 2
    )
    return 2 * r * math.asin(math.sqrt(h))


def _accept(sample: Sample, previous_raw: Sample | None) -> bool:
    if previous_raw is not None:
        gap = sample.t - previous_raw.t
        if 0 < gap <= PAUSE_GAP_S and haversine(previous_raw, sample) / gap > MAX_SPEED_MPS:
            return False
    return True


class _Elevation:
    def __init__(self) -> None:
        self.gain = 0.0
        self.loss = 0.0
        self.anchor: float | None = None

    def ingest(self, s: Sample) -> None:
        if s.ele is None:
            return
        if self.anchor is None:
            self.anchor = s.ele
            return
        delta = s.ele - self.anchor
        if delta >= ELEV_HYSTERESIS_M:
            self.gain += delta
            self.anchor = s.ele
        elif delta <= -ELEV_HYSTERESIS_M:
            self.loss -= delta
            self.anchor = s.ele


def elevation(samples: list[Sample]) -> tuple[float, float]:
    acc = _Elevation()
    for s in samples:
        acc.ingest(s)
    return acc.gain, acc.loss


def moving_time(samples: list[Sample]) -> float:
    return sum(
        gap for a, b in zip(samples, samples[1:], strict=False) if (gap := b.t - a.t) <= PAUSE_GAP_S
    )


def splits(samples: list[Sample]) -> list[dict[str, float]]:
    out: list[dict[str, float]] = []
    if len(samples) < 2:
        return out
    split_d = 0.0
    split_t = 0.0
    split_samples = [samples[0]]

    def close(distance: float, moving: float, source: list[Sample]) -> None:
        if distance < 0.5:
            return
        g, lo = elevation(source)
        out.append({"distance_m": distance, "moving_s": moving, "gain_m": g, "loss_m": lo})

    for prev, cur in zip(samples, samples[1:], strict=False):
        leg = haversine(prev, cur)
        leg_t = max(min(cur.t - prev.t, PAUSE_GAP_S), 0.0)
        split_samples.append(cur)
        remaining = leg
        while remaining > 0:
            take = min(remaining, 1000.0 - split_d)
            split_d += take
            split_t += leg_t * (take / leg if leg > 0 else 0.0)
            remaining -= take
            if split_d >= 1000.0 - 1e-9:
                close(1000.0, split_t, split_samples)
                split_samples = [cur]
                split_d = 0.0
                split_t = 0.0
    if split_d >= 50.0:
        close(split_d, split_t, split_samples)
    return out


def efforts(samples: list[Sample]) -> dict[str, float]:
    out: dict[str, float] = {}
    pending = sorted(STANDARD_DISTANCES.items(), key=lambda kv: kv[1])
    cumulative = 0.0
    moving_before = 0.0
    for prev, cur in zip(samples, samples[1:], strict=False):
        leg = haversine(prev, cur)
        gap = cur.t - prev.t
        leg_t = min(gap, PAUSE_GAP_S)
        while pending and cumulative + leg >= pending[0][1]:
            key, metres = pending.pop(0)
            frac = (metres - cumulative) / leg if leg > 0 else 0.0
            out[key] = moving_before + frac * leg_t
        cumulative += leg
        if gap <= PAUSE_GAP_S:
            moving_before += gap
    return out


def parse_gpx(data: bytes) -> list[tuple[float, float, float | None, datetime | None]]:
    root = ET.fromstring(data)
    points: list[tuple[float, float, float | None, datetime | None]] = []
    for pt in root.iter(f"{GPX_NS}trkpt"):
        ele_el = pt.find(f"{GPX_NS}ele")
        time_el = pt.find(f"{GPX_NS}time")
        ele = float(ele_el.text) if ele_el is not None and ele_el.text else None
        when = (
            datetime.fromisoformat(time_el.text.replace("Z", "+00:00"))
            if time_el is not None and time_el.text
            else None
        )
        points.append((float(pt.attrib["lat"]), float(pt.attrib["lon"]), ele, when))
    return points


def route_run(
    external_id: str,
    csv_elapsed: float | None,
    points: list[tuple[float, float, float | None, datetime | None]],
) -> ReplayRun | None:
    start = next((p[3] for p in points if p[3] is not None), None)
    if start is None:
        return None
    accepted: list[Sample] = []
    previous: Sample | None = None
    for lat, lon, ele, when in points:
        if when is None:
            continue
        s = Sample((when - start).total_seconds(), lat, lon, ele)
        if s.t < (accepted[-1].t if accepted else 0.0):
            continue
        if _accept(s, previous):
            accepted.append(s)
        previous = s
    if len(accepted) < 2:
        return None
    distance = sum(haversine(a, b) for a, b in zip(accepted, accepted[1:], strict=False))
    moving = moving_time(accepted)
    if distance <= 0 or moving <= 0:
        return None
    gain, loss = elevation(accepted)
    return ReplayRun(
        external_id=external_id,
        started_at=start,
        distance_m=distance,
        moving_s=moving,
        elapsed_s=max(csv_elapsed or 0.0, accepted[-1].t),
        gain_m=gain,
        loss_m=loss,
        splits=splits(accepted),
        efforts=efforts(accepted),
        from_route=True,
    )


def _num(row: list[str], col: int | None) -> float | None:
    if col is None or col >= len(row) or not row[col].strip():
        return None
    try:
        return float(row[col])
    except ValueError:
        return None


def _date(text: str) -> datetime:
    norm = text.replace("\u202f", " ").replace("\u00a0", " ").strip()
    return datetime.strptime(norm, "%b %d, %Y, %I:%M:%S %p").replace(tzinfo=UTC)


def load_export(root: Path) -> tuple[list[ReplayRun], dict[str, int]]:
    """Runs from an unzipped export folder, oldest first, plus import counts."""
    with (root / "activities.csv").open(newline="", encoding="utf-8-sig") as f:
        rows = list(csv.reader(f))
    header = [h.strip() for h in rows[0]]

    def cols(name: str) -> list[int]:
        return [i for i, h in enumerate(header) if h == name]

    def first(name: str) -> int | None:
        found = cols(name)
        return found[0] if found else None

    id_c, date_c = cols("Activity ID")[0], cols("Activity Date")[0]
    type_c = cols("Activity Type")[0]
    file_c = cols("Filename")[0]
    elapsed_c = cols("Elapsed Time")[-1]
    moving_c = first("Moving Time")
    dist_cs = cols("Distance")
    gain_c = first("Elevation Gain")
    loss_c = first("Elevation Loss")

    runs: list[ReplayRun] = []
    counts = {"activities": 0, "runs": 0, "with_route": 0, "summary_only": 0, "unreadable": 0}
    for row in rows[1:]:
        if len(row) <= max(id_c, date_c, type_c):
            continue
        counts["activities"] += 1
        if row[type_c].strip() not in RUN_TYPES:
            continue
        counts["runs"] += 1
        ext = row[id_c].strip()
        elapsed = _num(row, elapsed_c)
        filename = row[file_c].strip() if file_c < len(row) else ""
        data: bytes | None = None
        path = root / filename if filename else None
        if path is not None and path.is_file():
            if filename.endswith(".gpx"):
                data = path.read_bytes()
            elif filename.endswith(".gpx.gz"):
                data = gzip.decompress(path.read_bytes())
        run = route_run(ext, elapsed, parse_gpx(data)) if data else None
        if run is None:
            if len(dist_cs) > 1:
                distance = _num(row, dist_cs[-1])
            else:
                km = _num(row, dist_cs[0]) if dist_cs else None
                distance = km * 1000 if km is not None else None
            moving = _num(row, moving_c) or elapsed
            if not distance or distance <= 0 or not moving or moving <= 0:
                counts["unreadable"] += 1
                continue
            run = ReplayRun(
                external_id=ext,
                started_at=_date(row[date_c]),
                distance_m=distance,
                moving_s=moving,
                elapsed_s=elapsed or moving,
                gain_m=_num(row, gain_c) or 0.0,
                loss_m=_num(row, loss_c) or 0.0,
            )
            counts["summary_only"] += 1
        else:
            counts["with_route"] += 1
        runs.append(run)
    runs.sort(key=lambda r: r.started_at)
    return runs, counts
