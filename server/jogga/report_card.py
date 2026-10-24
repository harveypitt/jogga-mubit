"""Weekly report card.

The server works out every grade from run data. The LLM only writes a headline,
a summary and one focus for a closed week, from grades it is given and cannot
change. Nothing here rewards running more than the plan or the runner's own
baseline, and there is no universal target of any kind.
"""

import bisect
import statistics
from collections.abc import Sequence
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from typing import Any, Literal

from .fitness import FIT_WINDOW_DAYS, Effort, fitness, fmt_dur, gap_pace, riegel, run_shape
from .models import Run
from .packet import fit_source
from .schemas import STANDARD_DISTANCES
from .weeks import local_date, local_week, week_end

Grade = Literal["A", "B", "C", "D"]
GRADES: tuple[Grade, ...] = ("A", "B", "C", "D")
GRADE_POINTS = {"A": 4, "B": 3, "C": 2, "D": 1}
CATEGORIES = ("consistency", "pacing", "balance", "load", "progress")
LABELS = {
    "consistency": "Consistency",
    "pacing": "Pacing",
    "balance": "Balance",
    "load": "Load",
    "progress": "Progress",
}
# Focus tie-break when several categories share the lowest grade: safety first.
FOCUS_ORDER = ("load", "balance", "pacing", "consistency", "progress")
DISTANCE_LABELS = {"5k": "5K", "10k": "10K", "half": "Half", "marathon": "Marathon"}
DAY_NAMES = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")

FULL_SPLIT_M = 990.0
NEW_RUNNER_WEEKS = 3
SessionType = Literal["easy", "steady", "hard", "intervals"]


def step_down(grade: Grade, steps: int = 1) -> Grade:
    return GRADES[min(GRADES.index(grade) + steps, len(GRADES) - 1)]


def _plural(n: int, word: str) -> str:
    return f"{n} {word}" if n == 1 else f"{n} {word}s"


def _building(more: int) -> str:
    return f"Building · {_plural(more, 'more week')}"


@dataclass
class Row:
    """One graded category. ``grade`` None shows as "—" (not enough data, never a fail)."""

    category: str
    grade: Grade | None
    metric: str
    inputs: dict[str, Any] = field(default_factory=dict)
    trend: Literal["up", "down", "same"] | None = None
    was: Grade | None = None

    def to_json(self) -> dict[str, Any]:
        return {
            "category": self.category,
            "label": LABELS[self.category],
            "grade": self.grade,
            "trend": self.trend,
            "was": self.was,
            "metric": self.metric,
            "how": HOW[self.category],
            "details": [list(d) for d in explain(self.category, self.inputs)],
            "inputs": self.inputs,
        }


HOW = {
    "consistency": "Runs this week against your plan. Extra runs don't raise it.",
    "pacing": (
        "Hill-adjusted kilometre splits from runs of 3 km or more. "
        "A fast first kilometre or a late fade lowers it."
    ),
    "balance": (
        "Most running should feel easy. Back-to-back hard days, a lot of hard running, "
        "no rest day or mostly in-between pace lower it. More hard sessions never raise it."
    ),
    "load": (
        "Close to your 4-week average is best. Big jumps lower it, and so does a long run "
        "well beyond your recent longest."
    ),
    "progress": "The 4-week trend in your predicted race time, from your best recent efforts.",
}
SHAPE_LABELS = {
    "steady": "Even",
    "sped_up": "Finished faster",
    "faded": "Faded",
    "uneven": "Uneven",
}
REASON_LABELS = {
    "back_to_back_hard": "Back-to-back hard days",
    "hard_share": "A lot of hard running",
    "no_rest_day": "No rest day",
    "grey_zone": "Mostly in-between pace",
}


def explain(category: str, inputs: dict[str, Any]) -> list[tuple[str, str]]:
    """The inputs behind a grade as label/value lines for the detail sheet."""
    if not inputs:
        return []
    if category == "consistency":
        src = {"coach": "Your coach", "history": "Your last 4 weeks"}.get(
            inputs.get("recommended_from") or "", "—"
        )
        return [
            ("Runs", str(inputs["runs"])),
            ("Planned", str(inputs["recommended"])),
            ("Plan from", src),
        ]
    if category == "pacing":
        out = []
        for r in inputs.get("runs", []):
            day = DAY_NAMES[date.fromisoformat(r["date"]).weekday()]
            value = SHAPE_LABELS.get(r["shape"], r["shape"])
            if r["fast_start"]:
                value += f" · first km {r['fast_start_s']} s fast"
            out.append((day, value))
        return out
    if category == "balance":
        out = [
            ("Easy", str(inputs["easy"])),
            ("Steady", str(inputs["steady"])),
            ("Hard", str(inputs["hard"])),
            ("Rest days", str(inputs["rest_days"])),
        ]
        out += [("Held back by", REASON_LABELS[r]) for r in inputs.get("dropped_for", [])]
        return out
    if category == "load":
        out = [
            ("This week", f"{inputs['km']:.1f} km"),
            ("4-week average", f"{inputs['prev4_mean_km']:.1f} km"),
            ("Change", f"{round((inputs['ratio'] - 1) * 100):+d}%"),
            ("Longest run", f"{inputs['longest_km']:.1f} km"),
            ("Longest, last 4 weeks", f"{inputs['long4w_km']:.1f} km"),
        ]
        if inputs.get("planned_cutback"):
            out.append(("Cutback", "After a 3-week build"))
        return out
    if category == "progress":
        preds = inputs.get("predictions", [])
        out = [("Distance", DISTANCE_LABELS.get(inputs["distance"], inputs["distance"]))]
        for i, p in enumerate(preds):
            ago = len(preds) - 1 - i
            label = "This week" if ago == 0 else f"{_plural(ago, 'week')} ago"
            out.append((label, fmt_dur(p) if p is not None else "—"))
        if inputs.get("target_s") is not None:
            out.append(("Target", fmt_dur(inputs["target_s"])))
        if inputs.get("new_effort") is False:
            out.append(("New effort", "None this week"))
        return out
    return []


@dataclass
class Week:
    """Grades and context for one local week."""

    week_start: date
    live: bool
    runs: list[Run]
    km: float
    sessions: dict[str, int]
    rows: dict[str, Row]
    recorded: int
    run_table: list[list[Any]]
    recommended: int | None
    target: dict[str, Any] | None

    @property
    def composite(self) -> float | None:
        points = [GRADE_POINTS[r.grade] for r in self.rows.values() if r.grade is not None]
        return round(statistics.fmean(points), 2) if points else None

    def focus(self) -> str:
        """Lowest-graded category, ties broken by FOCUS_ORDER."""
        graded = [c for c in FOCUS_ORDER if self.rows[c].grade is not None]
        if not graded:
            return "consistency"
        return max(
            graded, key=lambda c: (GRADES.index(self.rows[c].grade or "A"), -FOCUS_ORDER.index(c))
        )

    def grades_json(self) -> dict[str, Any]:
        return {c: self.rows[c].to_json() for c in CATEGORIES}


# --- per-run helpers ---------------------------------------------------------


def _full_flat(run: Run) -> list[int]:
    paces = [
        gap_pace(s["distance_m"], s["moving_s"], s["gain_m"], s["loss_m"])
        for s in run.splits or []
        if s["distance_m"] >= FULL_SPLIT_M
    ]
    return [p for p in paces if p > 0]


def flat_pace(run: Run) -> float:
    """Distance-weighted hill-adjusted pace for the whole run (s/km)."""
    total = sum(s["distance_m"] for s in run.splits or [])
    if total <= 0:
        return run.moving_s / (run.distance_m / 1000.0) if run.distance_m > 0 else 0.0
    return (
        sum(
            gap_pace(s["distance_m"], s["moving_s"], s["gain_m"], s["loss_m"]) * s["distance_m"]
            for s in run.splits
        )
        / total
    )


def zones_at(history_desc: Sequence[Run], at: datetime) -> dict[str, Any] | None:
    """Training zones from fitness as it stood just before ``at`` (history newest first)."""
    src = fit_source([r for r in history_desc if r.started_at < at], at)
    if src is None:
        return None
    zones: dict[str, Any] = fitness(src)["zones"]  # type: ignore[assignment]
    return zones


def session_type(run: Run, zones: dict[str, Any] | None) -> SessionType | None:
    """easy / steady (grey zone) / hard / intervals from hill-adjusted pace vs own zones."""
    if zones is None:
        return None
    pace = flat_pace(run)
    full = _full_flat(run)
    if full and run_shape(run.splits) == "uneven" and min(full) <= zones["tempo"]:
        return "intervals"
    if pace >= zones["easy"][0]:
        return "easy"
    if pace <= zones["tempo"]:
        return "hard"
    return "steady"


def pacing_score(
    run: Run, kind: SessionType | None, zones: dict[str, Any] | None
) -> dict[str, Any] | None:
    """Per-run pacing score 0–1, or None for runs that can't be judged."""
    flat = _full_flat(run)
    if len(flat) < 3 or kind == "intervals":
        return None
    shape = run_shape(run.splits)
    third = max(1, len(flat) // 3)
    late = statistics.fmean(flat[-third:]) / statistics.fmean(flat[:-third]) - 1.0
    if shape in ("steady", "sped_up"):
        score = 1.0
    elif shape == "faded":
        score = 0.7 if late <= 0.03 else 0.4
    else:
        score = 0.7
    rest = statistics.median(flat[1:])
    fast_start_s = round(rest - flat[0])
    fast_start = flat[0] < rest * (1 - 0.04)
    if fast_start:
        score -= 0.2
    easy_share = None
    if kind == "easy" and zones is not None:
        easy_share = sum(1 for p in flat if p >= zones["easy"][0]) / len(flat)
        if easy_share < 0.7:
            score -= 0.2
    return {
        "score": round(max(0.0, score), 2),
        "shape": shape,
        "late_slowdown": round(late, 3),
        "fast_start": fast_start,
        "fast_start_s": fast_start_s,
        "easy_share": round(easy_share, 2) if easy_share is not None else None,
    }


# --- categories --------------------------------------------------------------


def grade_consistency(
    runs: int, recommended: int | None, source: str | None, weeks_known: int
) -> Row:
    if recommended is None:
        return Row("consistency", None, _building(max(1, 2 - weeks_known + 1)))
    ratio = min(runs / recommended, 1.0)
    grade: Grade = "A" if ratio >= 1.0 else "B" if ratio >= 0.66 else "C" if ratio >= 0.33 else "D"
    metric = (
        f"{runs} runs, {recommended} planned"
        if runs > recommended
        else f"{runs} of {_plural(recommended, 'planned run')}"
    )
    return Row(
        "consistency",
        grade,
        metric,
        {"runs": runs, "recommended": recommended, "recommended_from": source},
    )


def grade_pacing(scored: list[tuple[Run, dict[str, Any]]], tz: str | None) -> Row:
    if not scored:
        return Row("pacing", None, "Needs a run of 3 km or more")
    mean = statistics.fmean(s["score"] for _, s in scored)
    grade: Grade = "A" if mean >= 0.85 else "B" if mean >= 0.7 else "C" if mean >= 0.5 else "D"
    even = sum(1 for _, s in scored if s["shape"] in ("steady", "sped_up"))
    parts = [f"{even} of {_plural(len(scored), 'run')} evenly paced"]
    starts = [(r, s) for r, s in scored if s["fast_start"]]
    if starts:
        run, s = max(starts, key=lambda rs: rs[1]["fast_start_s"])
        day = DAY_NAMES[local_date(run.started_at, run.tz or tz).weekday()]
        parts.append(f"first km {s['fast_start_s']} s fast on {day}")
    else:
        faded = [r for r, s in scored if s["shape"] == "faded"]
        if faded:
            day = DAY_NAMES[local_date(faded[-1].started_at, faded[-1].tz or tz).weekday()]
            parts.append(f"faded on {day}")
    return Row(
        "pacing",
        grade,
        " · ".join(parts),
        {
            "mean_score": round(mean, 2),
            "runs": [
                {"date": local_date(r.started_at, r.tz or tz).isoformat(), **s} for r, s in scored
            ],
        },
    )


def grade_balance(
    typed: list[tuple[date, SessionType | None]],
    prev_sunday_hard: bool,
    weeks_known: int,
) -> Row:
    if weeks_known < NEW_RUNNER_WEEKS:
        return Row("balance", None, _building(NEW_RUNNER_WEEKS - weeks_known))
    if len(typed) < 2:
        return Row("balance", None, "Needs 2 runs in the week")
    if any(kind is None for _, kind in typed):
        return Row("balance", None, "Needs a recent timed effort to set your zones")
    easy = sum(1 for _, k in typed if k == "easy")
    steady = sum(1 for _, k in typed if k == "steady")
    hard = sum(1 for _, k in typed if k in ("hard", "intervals"))
    n = len(typed)
    hard_days = {d for d, k in typed if k in ("hard", "intervals")}
    if prev_sunday_hard and typed:
        hard_days.add(
            min(d for d, _ in typed) - timedelta(days=min(d for d, _ in typed).weekday() + 1)
        )
    back_to_back = any(d + timedelta(days=1) in hard_days for d in hard_days)
    hard_share = (hard + 0.5 * steady) / n
    run_days = len({d for d, _ in typed})
    reasons = []
    if back_to_back:
        reasons.append("back_to_back_hard")
    if n >= 3 and hard_share > 0.4:
        reasons.append("hard_share")
    if run_days >= 7:
        reasons.append("no_rest_day")
    if steady > n / 2:
        reasons.append("grey_zone")
    grade = step_down("A", len(reasons))
    counts = [f"{easy} easy"]
    if steady:
        counts.append(f"{steady} steady")
    counts.append(f"{hard} hard")
    if back_to_back:
        counts.append("back-to-back hard days")
    elif "no_rest_day" in reasons:
        counts.append("no rest day")
    elif hard:
        counts.append("no back-to-back hard days")
    return Row(
        "balance",
        grade,
        " · ".join(counts),
        {
            "easy": easy,
            "steady": steady,
            "hard": hard,
            "hard_share": round(hard_share, 2),
            "rest_days": 7 - run_days,
            "dropped_for": reasons,
        },
    )


def grade_load(
    km: float,
    prev_km: list[float],
    longest: float,
    long4w: float,
    weeks_known: int,
    live: bool,
) -> Row:
    """``prev_km`` is the previous 4 weeks, most recent first."""
    needed = NEW_RUNNER_WEEKS + 1
    if weeks_known < needed:
        return Row("load", None, _building(needed - weeks_known))
    mean = sum(prev_km) / 4
    if mean <= 0:
        return Row("load", None, "No runs in the previous 4 weeks to compare")
    r = km / mean
    pct = round((r - 1) * 100)
    inputs: dict[str, Any] = {
        "km": round(km, 1),
        "prev4_mean_km": round(mean, 1),
        "ratio": round(r, 2),
        "longest_km": round(longest, 1),
        "long4w_km": round(long4w, 1),
    }
    if r < 0.75 and live:
        return Row("load", None, f"{km:.1f} km so far · 4-week average {mean:.1f} km", inputs)
    builds = all(prev_km[i] > prev_km[i + 1] > 0 for i in range(3))
    grade: Grade
    if r > 1.5:
        grade = "D"
    elif r > 1.3:
        grade = "C"
    elif r > 1.15:
        grade = "B"
    elif r >= 0.75:
        grade = "A"
    elif builds:
        grade = "A"
        inputs["planned_cutback"] = True
    elif r >= 0.5:
        grade = "B"
    else:
        grade = "C"
    metric = f"{km:.1f} km · {pct:+d}% on your 4-week average"
    if long4w > 0 and longest > 1.3 * long4w and longest - long4w > 2:
        grade = step_down(grade)
        inputs["long_run_jump"] = True
        metric += f" · long run {longest:.1f} km"
    return Row("load", grade, metric, inputs)


def _trend_pct(preds: list[float | None]) -> float | None:
    points = [(i, p) for i, p in enumerate(preds) if p is not None]
    if len(points) < 3:
        return None
    xs = [float(i) for i, _ in points]
    ys = [p for _, p in points]
    slope, intercept = statistics.linear_regression(xs, ys)
    start = intercept + slope * xs[0]
    end = intercept + slope * xs[-1]
    return (end - start) / start if start > 0 else None


def grade_progress(
    preds: list[float | None],
    distance: str,
    target_s: int | None,
    new_effort: bool,
) -> Row:
    """``preds`` are week-end predictions for the last 4 weeks, oldest first.

    Graded from run data alone, never carried from an earlier week, so a week's
    grade is the same whichever window it is read through.
    """
    pct = _trend_pct(preds)
    label = DISTANCE_LABELS[distance]
    if pct is None:
        have = sum(1 for p in preds if p is not None)
        return Row("progress", None, _building(3 - have))
    current = next(p for p in reversed(preds) if p is not None)
    first = next(p for p in preds if p is not None)
    inputs: dict[str, Any] = {
        "distance": distance,
        "predictions": [round(p) if p is not None else None for p in preds],
        "trend_pct": round(pct * 100, 1),
        "target_s": target_s,
        "new_effort": new_effort,
    }
    grade: Grade = "A" if pct <= -0.01 else "B" if pct <= 0.01 else "C" if pct <= 0.03 else "D"
    change = round(first - current)
    parts = [f"{label} prediction {fmt_dur(current)}"]
    if abs(change) >= 1:
        parts.append(f"{fmt_dur(abs(change))} {'faster' if change > 0 else 'slower'} over 4 weeks")
    else:
        parts.append("holding over 4 weeks")
    if target_s is not None:
        gap = current - target_s
        parts.append(f"{fmt_dur(gap)} to target" if gap > 0 else "target beaten")
    return Row("progress", grade, " · ".join(parts), inputs)


# --- weeks -------------------------------------------------------------------


@dataclass
class Context:
    """Everything grading needs, loaded once per request."""

    runs: list[Run]  # oldest first
    tz: str
    now: datetime
    # (started_at of the run the note was for, runs_per_week), oldest first.
    plans: list[tuple[datetime, int]]
    targets: dict[str, int]


def goal_distance(targets: dict[str, int], src: Effort | None) -> str:
    """Target with the largest relative gap to current fitness; 5K without targets."""
    if not targets:
        return "5k"
    if src is None:
        return min(targets, key=lambda d: STANDARD_DISTANCES[d])

    def gap(d: str) -> float:
        return (riegel(src[3], src[2], STANDARD_DISTANCES[d] / 1000.0) - targets[d]) / targets[d]

    return max(targets, key=gap)


def grade_weeks(
    ctx: Context, through: date | None = None, since: date | None = None
) -> dict[date, Week]:
    """Grade local weeks from ``since`` (default: the first run's week) to ``through``.

    ``through`` defaults to this week. Weeks before ``since`` are only walked for the
    trend baseline; they are not returned.
    """
    tz = ctx.tz
    this_week = local_week(ctx.now, tz)
    through = through or this_week
    runs = [r for r in ctx.runs if r.started_at <= ctx.now]
    if not runs:
        return {}

    def week_of(r: Run) -> date:
        return local_week(r.started_at, r.tz or tz)

    by_week: dict[date, list[Run]] = {}
    for r in runs:
        by_week.setdefault(week_of(r), []).append(r)
    first_week = min(by_week)
    km_of = {w: sum(r.distance_m for r in rs) / 1000.0 for w, rs in by_week.items()}
    asc = sorted(runs, key=lambda r: r.started_at)
    times = [r.started_at for r in asc]

    def before(t: datetime, inclusive: bool = True) -> list[Run]:
        """Runs in the fitness window ending at ``t``, newest first."""
        lo = bisect.bisect_left(times, t - timedelta(days=FIT_WINDOW_DAYS))
        hi = (bisect.bisect_right if inclusive else bisect.bisect_left)(times, t)
        return asc[lo:hi][::-1]

    zone_cache: dict[Any, SessionType | None] = {}
    zones_for: dict[Any, dict[str, Any] | None] = {}

    def typed(r: Run) -> SessionType | None:
        if r.id not in zone_cache:
            zones_for[r.id] = zones_at(before(r.started_at, inclusive=False), r.started_at)
            zone_cache[r.id] = session_type(r, zones_for[r.id])
        return zone_cache[r.id]

    out: dict[date, Week] = {}
    week = first_week
    if since is not None and since > first_week:
        # Start far enough back that the previous non-rest week sets the trend.
        recent = [w for w in by_week if w < since]
        week = max(recent) if recent else since
    prev: Week | None = None
    while week <= through:
        end = min(week_end(week, tz), ctx.now)
        live = week == this_week
        wk_runs = sorted(by_week.get(week, []), key=lambda r: r.started_at)
        weeks_known = (week - first_week).days // 7 + 1
        km = km_of.get(week, 0.0)

        plan = None
        plan_src = None
        start_dt = week_end(week - timedelta(weeks=1), tz)
        earlier_plans = [p for at, p in ctx.plans if at < start_dt]
        in_week = [p for at, p in ctx.plans if start_dt <= at < end]
        if earlier_plans:
            plan, plan_src = earlier_plans[-1], "coach"
        elif in_week:
            plan, plan_src = in_week[0], "coach"
        elif weeks_known > 2:
            prev_runs = sum(len(by_week.get(week - timedelta(weeks=i), [])) for i in range(1, 5))
            plan, plan_src = max(2, round(prev_runs / 4)), "history"

        kinds = [(local_date(r.started_at, r.tz or tz), typed(r)) for r in wk_runs]
        prev_sun = week - timedelta(days=1)
        prev_sunday_hard = any(
            local_date(r.started_at, r.tz or tz) == prev_sun and typed(r) in ("hard", "intervals")
            for r in by_week.get(week - timedelta(weeks=1), [])
        )
        scored = [
            (r, s)
            for r in wk_runs
            if (s := pacing_score(r, typed(r), zones_for.get(r.id))) is not None
        ]
        prev_km = [km_of.get(week - timedelta(weeks=i), 0.0) for i in range(1, 5)]
        prev4_runs = [r for i in range(1, 5) for r in by_week.get(week - timedelta(weeks=i), [])]
        long4w = max((r.distance_m for r in prev4_runs), default=0.0) / 1000.0
        longest = max((r.distance_m for r in wk_runs), default=0.0) / 1000.0

        # Progress: week-end predictions over the last 4 weeks.
        src_now = fit_source(before(end), end)
        distance = goal_distance(ctx.targets, src_now)
        d_km = STANDARD_DISTANCES[distance] / 1000.0
        preds: list[float | None] = []
        for i in range(3, -1, -1):
            w_end = min(week_end(week - timedelta(weeks=i), tz), ctx.now)
            if week - timedelta(weeks=i) < first_week:
                preds.append(None)
                continue
            src = fit_source(before(w_end), w_end)
            preds.append(riegel(src[3], src[2], d_km) if src else None)
        new_effort = src_now is not None and src_now[0] >= week

        rows = {
            "consistency": grade_consistency(len(wk_runs), plan, plan_src, weeks_known),
            "pacing": grade_pacing(scored, tz),
            "balance": grade_balance(kinds, prev_sunday_hard, weeks_known),
            "load": grade_load(km, prev_km, longest, long4w, weeks_known, live),
            "progress": grade_progress(
                preds,
                distance,
                ctx.targets.get(distance),
                new_effort,
            ),
        }
        if plan is not None and len(wk_runs) > plan and rows["load"].grade in ("C", "D"):
            rows["consistency"].metric += " · more than planned with a high load"
        if prev is not None and prev.runs:
            for c, row in rows.items():
                was = prev.rows[c].grade
                if row.grade is not None and was is not None:
                    a, b = GRADES.index(row.grade), GRADES.index(was)
                    row.trend = "up" if a < b else "down" if a > b else "same"
                    row.was = was

        sessions = {"easy": 0, "steady": 0, "hard": 0}
        table: list[list[Any]] = []
        for r, (d, k) in zip(wk_runs, kinds, strict=True):
            if k is not None:
                sessions["hard" if k == "intervals" else k] += 1
            table.append(
                [
                    d.isoformat(),
                    DAY_NAMES[d.weekday()],
                    k,
                    round(r.distance_m / 1000.0, 2),
                    fmt_dur(flat_pace(r)),
                    run_shape(r.splits),
                ]
            )
        target = None
        if distance in ctx.targets:
            target = {"d": distance, "t": fmt_dur(ctx.targets[distance])}
        current = Week(
            week_start=week,
            live=live,
            runs=wk_runs,
            km=round(km, 1),
            sessions=sessions,
            rows=rows,
            recorded=sum(1 for r in wk_runs if r.source == "jogga"),
            run_table=table,
            recommended=plan,
            target=target,
        )
        if not wk_runs:
            current.rows = {c: Row(c, None, "Rest week, nothing to grade") for c in CATEGORIES}
        if since is None or week >= since:
            out[week] = current
        # A rest week doesn't set the trend baseline.
        if wk_runs:
            prev = current
        week += timedelta(weeks=1)
    return out
