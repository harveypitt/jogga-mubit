"""Coach packet builder — the exact compact shape the LLM expects."""

import json
from collections.abc import Sequence
from datetime import date, datetime, timedelta
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .fitness import (
    FIT_MIN_DAYS,
    FIT_RECENT_RUNS,
    FIT_WINDOW_DAYS,
    MIN_EFFORT_RUN_M,
    Effort,
    best_effort,
    fitness,
    fmt_delta,
    fmt_dur,
    gap_pace,
    run_shape,
    split_pace,
)
from .models import CoachNote, Run, Target
from .schemas import STANDARD_DISTANCES
from .stats import distance_stats


def _pace_s_per_km(distance_m: float, moving_s: float) -> int:
    if distance_m <= 0:
        return 0
    return round(moving_s / (distance_m / 1000.0))


def _primary_distance(distance_m: float) -> str | None:
    reached = [name for name, metres in STANDARD_DISTANCES.items() if distance_m >= metres]
    return max(reached, key=lambda name: STANDARD_DISTANCES[name]) if reached else None


def fit_runs(history: Sequence[Run], now: datetime) -> list[Run]:
    """Runs current fitness is judged from, newest first.

    ``history`` is newest first. The last FIT_RECENT_RUNS always count, plus
    anything in the last FIT_MIN_DAYS, but nothing older than FIT_WINDOW_DAYS.
    """
    window = now - timedelta(days=FIT_WINDOW_DAYS)
    floor = now - timedelta(days=FIT_MIN_DAYS)
    return [
        r
        for i, r in enumerate(history)
        if r.started_at >= window and (i < FIT_RECENT_RUNS or r.started_at >= floor)
    ]


def fit_source(history: Sequence[Run], now: datetime) -> Effort | None:
    """The effort current fitness is based on: best 5K-equivalent among fit_runs."""
    efforts: list[Effort] = []
    for r in fit_runs(history, now):
        r_date = r.started_at.date()
        for d, t in (r.efforts or {}).items():
            if d in STANDARD_DISTANCES:
                efforts.append((r_date, d, STANDARD_DISTANCES[d] / 1000.0, t))
        if r.distance_m >= MIN_EFFORT_RUN_M:
            efforts.append((r_date, None, r.distance_m / 1000.0, r.moving_s))
    return best_effort(efforts)


async def build_packet(db: AsyncSession, run: Run) -> str:
    """Build the compact JSON packet for a run. Short keys, no whitespace.

    History is described as it was before this run: goals stats exclude the
    run, recent only covers earlier runs and load4w is relative to it.
    """
    user_id = run.user_id
    now = run.started_at
    cutoff = now - timedelta(days=28)

    stats = await distance_stats(db, user_id, now, exclude_run_id=run.id, before=run.started_at)
    target_rows = (
        await db.execute(select(Target.distance, Target.target_s).where(Target.user_id == user_id))
    ).all()
    targets = {distance: target_s for distance, target_s in target_rows}

    all_runs = (
        await db.scalars(
            select(Run).where(Run.user_id == user_id).order_by(Run.started_at.desc(), Run.id.desc())
        )
    ).all()

    earlier = [r for r in all_runs if r.id != run.id and r.started_at < run.started_at]

    def best_date(distance: str, best_s: float) -> str | None:
        dates = [
            r.started_at.date().isoformat()
            for r in earlier
            if (r.efforts or {}).get(distance) == best_s
        ]
        return dates[-1] if dates else None

    goals = []
    for distance in sorted(set(targets) | set(stats)):
        s = stats.get(distance)
        target = targets.get(distance)
        goals.append(
            {
                "d": distance,
                "target": fmt_dur(target) if target is not None else None,
                "tpace": (
                    fmt_dur(round(target / (STANDARD_DISTANCES[distance] / 1000.0)))
                    if target is not None
                    else None
                ),
                "pb": fmt_dur(s.best_s) if s and s.best_s is not None else None,
                "pb_d": best_date(distance, s.best_s) if s and s.best_s is not None else None,
                "last": fmt_dur(s.last_s) if s and s.last_s is not None else None,
                "n": s.count if s else 0,
                "n4w": s.count_4w if s else 0,
            }
        )

    hist = {
        "runs": len(earlier),
        "first": (earlier[-1].started_at.date().isoformat() if earlier else None),
        "rest_d": (
            (run.started_at.date() - earlier[0].started_at.date()).days if earlier else None
        ),
    }

    recent_rows: list[list[object]] = []
    for other in earlier:
        if len(recent_rows) >= 10:
            break
        recent_rows.append(
            [
                other.started_at.date().isoformat(),
                _primary_distance(other.distance_m),
                round(other.distance_m / 1000.0, 2),
                fmt_dur(other.moving_s),
                fmt_dur(_pace_s_per_km(other.distance_m, other.moving_s)),
                int(round(other.gain_m)),
            ]
        )

    load_runs = [r for r in earlier if r.started_at >= cutoff]
    load4w = {
        "runs": len(load_runs),
        "km": round(sum(r.distance_m for r in load_runs) / 1000.0, 2),
    }

    # Everything below counts the run itself plus earlier runs.
    history = [r for r in all_runs if r.started_at <= run.started_at]

    long4w = round(
        max((r.distance_m for r in history if r.started_at >= cutoff), default=0.0) / 1000.0, 2
    )

    run_date = run.started_at.date()
    day_runs = [r for r in history if r.started_at.date() == run_date]
    day = {
        "runs": len(day_runs),
        "km": round(sum(r.distance_m for r in day_runs) / 1000.0, 2),
    }

    def monday(d: datetime) -> date:
        return d.date() - timedelta(days=d.weekday())

    run_week = monday(run.started_at)
    weekly: dict[date, dict[str, float]] = {}
    for r in history:
        bucket = weekly.setdefault(monday(r.started_at), {"runs": 0.0, "km": 0.0})
        bucket["runs"] += 1
        bucket["km"] += r.distance_m / 1000.0

    wk_rows = []
    for i in range(8):
        wk_monday = run_week - timedelta(weeks=7 - i)
        bucket = weekly.get(wk_monday, {"runs": 0.0, "km": 0.0})
        wk_rows.append([wk_monday.isoformat(), int(bucket["runs"]), round(bucket["km"], 2)])
    wk = {"cols": ["wk", "runs", "km"], "rows": wk_rows}

    streak = 0
    week = run_week
    while weekly.get(week, {}).get("runs", 0) > 0:
        streak += 1
        week -= timedelta(weeks=1)

    # Yearly totals for history older than the `wk` window (mostly imported runs).
    wk_start = run_week - timedelta(weeks=7)
    years: dict[int, list[Run]] = {}
    for r in earlier:
        if monday(r.started_at) < wk_start:
            years.setdefault(r.started_at.year, []).append(r)
    past_rows = []
    for year in sorted(years):
        runs_in_year = years[year]
        fives = [r.efforts["5k"] for r in runs_in_year if "5k" in (r.efforts or {})]
        past_rows.append(
            [
                year,
                len(runs_in_year),
                round(sum(r.distance_m for r in runs_in_year) / 1000.0, 1),
                fmt_dur(min(fives)) if fives else None,
            ]
        )
    past = {"cols": ["yr", "runs", "km", "best5k"], "rows": past_rows} if past_rows else None

    # Fitness: best 5K-equivalent effort among recent runs, this run included.
    src = fit_source(history, now)
    fit = _format_fit(fitness(src)) if src is not None else None

    # What we prescribed last time vs what they did today.
    prev = None
    if run.mode in (None, "plan"):
        prev_rows = (
            await db.scalars(
                select(CoachNote)
                .join(Run, CoachNote.run_id == Run.id)
                .where(CoachNote.user_id == user_id, Run.started_at < run.started_at)
                .order_by(Run.started_at.desc())
                .limit(10)
            )
        ).all()
        for note in prev_rows:
            nxt = note.payload.get("next") if isinstance(note.payload, dict) else None
            if isinstance(nxt, dict) and {"kind", "km", "pace"} <= nxt.keys():
                prev = {
                    "plan": [nxt["kind"], nxt["km"], fmt_dur(nxt["pace"])],
                    "did": [
                        round(run.distance_m / 1000.0, 2),
                        fmt_dur(_pace_s_per_km(run.distance_m, run.moving_s)),
                    ],
                }
                break

    splits_rows = []
    for split in run.splits:
        d_m = split["distance_m"]
        splits_rows.append(
            [
                round(d_m / 1000.0, 2),
                fmt_dur(split["moving_s"]),
                fmt_dur(split_pace(d_m, split["moving_s"])),
                fmt_dur(gap_pace(d_m, split["moving_s"], split["gain_m"], split["loss_m"])),
                int(round(split["gain_m"])),
                int(round(split["loss_m"])),
            ]
        )

    eff_rows = []
    for d in sorted(run.efforts or {}, key=lambda name: STANDARD_DISTANCES.get(name, 0.0)):
        t = run.efforts[d]
        s = stats.get(d)
        eff_rows.append(
            [
                d,
                fmt_dur(t),
                fmt_delta(t - targets[d]) if d in targets else None,
                fmt_delta(t - s.best_s) if s is not None and s.best_s is not None else None,
            ]
        )

    packet: dict[str, Any] = {
        "v": 6,
        "u": {"km": "km", "t": "m:ss|h:mm:ss", "pace": "m:ss/km", "elev": "m"},
        "today": run.started_at.date().isoformat(),
        "hist": hist,
        "past": past,
        "goals": goals,
        "fit": fit,
        "load4w": load4w,
        "long4w": long4w,
        "wk": wk,
        "streak": streak,
        "day": day,
        "recent": {
            "cols": ["date", "d", "km", "t", "pace", "gain"],
            "rows": recent_rows,
        },
        "prev": prev,
        "run": {
            "date": run.started_at.date().isoformat(),
            "mode": run.mode,
            "d": _primary_distance(run.distance_m),
            "km": round(run.distance_m / 1000.0, 2),
            "t": fmt_dur(run.moving_s),
            "el": fmt_dur(run.elapsed_s),
            "pace": fmt_dur(_pace_s_per_km(run.distance_m, run.moving_s)),
            "gain": int(round(run.gain_m)),
            "loss": int(round(run.loss_m)),
            "shape": run_shape(run.splits),
            "eff": {"cols": ["d", "t", "vs_target", "vs_pb"], "rows": eff_rows},
            "splits": {
                "cols": ["km", "t", "pace", "flat", "gain", "loss"],
                "rows": splits_rows,
            },
        },
    }
    return json.dumps(packet, separators=(",", ":"))


def _format_fit(fit: dict[str, Any]) -> dict[str, Any]:
    """fmt_dur every time/pace in the numeric `fit` block."""
    src = fit["src"]
    zones = fit["zones"]
    return {
        "src": [src[0], src[1], src[2], fmt_dur(src[3])],
        "pred": {name: fmt_dur(t) for name, t in fit["pred"].items()},
        "zones": {
            "easy": [fmt_dur(zones["easy"][0]), fmt_dur(zones["easy"][1])],
            "steady": fmt_dur(zones["steady"]),
            "tempo": fmt_dur(zones["tempo"]),
            "intervals": fmt_dur(zones["intervals"]),
        },
    }
