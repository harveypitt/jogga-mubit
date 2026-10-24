"""Weekly training plan: the planner LLM writes the week, the server checks it.

One LLM call on the first read after the runner's local Monday, then at most
one replan a day when a planned run is missed. Every plan is checked against
fixed safety rules (`check_plan`); a plan that breaks one is replaced by a
rules-based plan (`fallback_plan`). Runs tick off sessions without an LLM.
"""

import asyncio
import json
import logging
import statistics
import time
import uuid
from dataclasses import dataclass, field
from datetime import UTC, date, datetime, timedelta
from functools import lru_cache
from importlib import resources
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict
from sqlalchemy import func, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from . import config
from .coach import LLMClient, LLMResult, OpenRouterClient
from .fitness import fitness, fmt_dur, parse_pace, split_pace
from .models import CoachNote, ReportCard, Run, RunnerProfile, RunSurvey, Target, WeekPlan
from .packet import _format_fit, fit_source
from .weeks import local_date, local_week, valid_tz

logger = logging.getLogger(__name__)

PlanKind = Literal["easy", "steady", "tempo", "intervals", "long"]
HARD_KINDS = frozenset({"steady", "tempo", "intervals"})
BEGINNER_RUNS = 8
BEGINNER_WEEK_KM = 15.0
LONG_GROWTH = 1.25
WEEK_GROWTH = 1.10
# Longest run and week allowed when there is no recent history to scale from.
MIN_RUN_CAP_KM = 5.0
MIN_WEEK_CAP_KM = 10.0
# Shortest run worth planning: 20 minutes at easy pace, and never under 3 km.
MIN_SESSION_KM = 3.0
MIN_SESSION_MIN = 20
# Weekly growth from check-ins (see docs/PLANNER_EVIDENCE.md): big jumps (>~30%) are the
# risk, not a fixed 10%; hold after a flat-out run or a niggle, cut back with real pain.
GROWTH_DEFAULT = 1.10
GROWTH_COMFY = {"beginner": 1.25, "experienced": 1.30}
GROWTH_HOLD = 1.0
GROWTH_CUT = 0.75
# A comfortable long run points at weeks of about 1.5x its length, reached gradually.
TARGET_FROM_LONG_RUN = 1.5
# With two or more hard sessions, they may take at most this share of the week's km.
HARD_SHARE = 0.2
STOP_REST_DAYS = 2
STOP_MAX_SESSIONS = 2
PHYSIO_REPORTS = 2
RPE = {"easy": 3, "moderate": 5, "hard": 7, "max": 9}
PACE_TOLERANCE_S = 15
NO_FIT_EASY_EXTRA_S = 45
KM_SLACK = 0.05
WORD_LIMITS = {"note": 25, "change": 20, "detail": 15, "why": 25}
DEFAULT_RUNS_PER_WEEK = 3
WEEKDAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
# A reported injury cuts the longest run allowed, and any injury rules out hard sessions.
INJURY_RUN_CAP = {"niggle": 1.0, "sore": 0.7, "stopped": 0.5}
INJURY_SEVERITY = ("niggle", "sore", "stopped")
FEEL_DAYS = 14
INJURY_DAYS = 7
# Packet keys the LLM sees but analytics never does (health data and free text).
PRIVATE_KEYS = ("feel", "injury", "rest_until", "see_physio", "profile")


class LLMSession(BaseModel):
    model_config = ConfigDict(extra="forbid")

    date: str
    kind: PlanKind
    km: float
    pace: str
    detail: str
    why: str


class LLMPlan(BaseModel):
    model_config = ConfigDict(extra="forbid")

    note: str
    change: str
    sessions: list[LLMSession]


@dataclass
class Facts:
    """What the plan has to fit around, worked out from run data."""

    today: date
    week_start: date
    days_left: list[date]
    done: list[dict[str, Any]]
    long4w: float
    avg4w_km: float
    beginner: bool
    zones: dict[str, Any] | None
    hard_dates: set[date]
    runs_per_week: int
    typical_km: float
    typical_pace: int
    fit: dict[str, Any] | None = None
    wk: list[list[Any]] = field(default_factory=list)
    # Worst injury reported in the last week ("niggle", "sore" or "stopped").
    injury: str | None = None
    feel: list[list[Any]] = field(default_factory=list)
    growth: float = GROWTH_DEFAULT
    target_km: float | None = None
    rest_until: date | None = None
    see_physio: bool = False
    # From onboarding: kinds they asked to avoid, and the most runs a week they want.
    banned: frozenset[str] = frozenset()
    max_runs: int | None = None
    profile: dict[str, Any] | None = None

    @property
    def run_cap(self) -> float:
        cap = max(LONG_GROWTH * self.long4w, MIN_RUN_CAP_KM)
        return round(cap * INJURY_RUN_CAP.get(self.injury or "", 1.0), 1)

    @property
    def done_km(self) -> float:
        return float(round(sum(float(d["km"]) for d in self.done), 2))

    @property
    def week_cap(self) -> float:
        """km left for the rest of the week."""
        if self.growth < GROWTH_HOLD:
            total = self.growth * self.avg4w_km
        else:
            total = max(self.growth * self.avg4w_km, MIN_WEEK_CAP_KM)
            if self.growth > GROWTH_HOLD:
                # A low-volume runner may always add one usual run.
                total = max(total, self.avg4w_km + self.typical_km)
        return round(max(0.0, total - self.done_km), 1)

    @property
    def min_km(self) -> float:
        easy = int(self.zones["easy"][1]) if self.zones else self.typical_pace + NO_FIT_EASY_EXTRA_S
        floor = max(MIN_SESSION_KM, MIN_SESSION_MIN * 60 / easy)
        return round(min(self.run_cap, floor), 1)

    @property
    def hard_cap(self) -> int:
        if self.injury is not None:
            return 0
        done_hard = sum(1 for d in self.done if d["hard"])
        return max(0, (1 if self.beginner else 2) - done_hard)


def _pace(run: Run) -> int:
    return split_pace(run.distance_m, run.moving_s)


def _is_hard(run: Run, zones: dict[str, Any] | None) -> bool:
    return zones is not None and _pace(run) <= int(zones["steady"])


def facts(
    runs: list[Run],
    tz: str,
    now: datetime,
    prev_count: int | None,
    from_day: date | None = None,
    surveys: list[RunSurvey] | None = None,
    profile: RunnerProfile | None = None,
) -> Facts:
    """``from_day`` is the first day a new session may go on (default today)."""
    today = local_date(now, tz)
    ws = local_week(now, tz)
    history = [r for r in runs if r.started_at <= now]
    src = fit_source(history, now)
    fit = fitness(src) if src is not None else None
    zones: dict[str, Any] | None = fit["zones"] if fit is not None else None  # type: ignore[assignment]
    recent = [r for r in history if r.started_at >= now - timedelta(days=28)]
    long4w = round(max((r.distance_m for r in recent), default=0.0) / 1000.0, 2)
    before = [r for r in history if ws - timedelta(weeks=4) <= local_week(r.started_at, tz) < ws]
    avg4w = round(sum(r.distance_m for r in before) / 1000.0 / 4, 2)
    week_runs = [r for r in history if local_week(r.started_at, tz) == ws]
    done: list[dict[str, Any]] = [
        {
            "date": local_date(r.started_at, tz),
            "km": round(r.distance_m / 1000.0, 2),
            "pace": _pace(r),
            "hard": _is_hard(r, zones),
            "run_id": str(r.id),
        }
        for r in week_runs
    ]
    sunday_before = ws - timedelta(days=1)
    hard_dates = {d["date"] for d in done if d["hard"]} | {
        sunday_before
        for r in history
        if local_date(r.started_at, tz) == sunday_before and _is_hard(r, zones)
    }
    start = from_day or today
    if any(d["date"] == start for d in done):
        start += timedelta(days=1)
    days_left = [start + timedelta(days=i) for i in range((ws + timedelta(days=7) - start).days)]
    last10 = history[-10:]
    typical_km = (
        round(statistics.median(r.distance_m for r in last10) / 1000.0, 1) if last10 else 3.0
    )
    typical_pace = int(statistics.median(_pace(r) for r in last10)) if last10 else 420
    beginner = len(history) < BEGINNER_RUNS or avg4w < BEGINNER_WEEK_KM
    if prev_count:
        rpw = prev_count
    elif recent:
        rpw = max(2, min(4, round(len(recent) / 4)))
    else:
        rpw = DEFAULT_RUNS_PER_WEEK
    if profile is not None:
        if profile.runs_per_week:
            rpw = profile.runs_per_week
        if profile.experience == "new":
            beginner = True
        elif profile.experience == "regular" and (profile.usual_week_km or 0) >= BEGINNER_WEEK_KM:
            beginner = False
        if not before and profile.usual_week_km:
            avg4w = float(profile.usual_week_km)
    wk = []
    for i in range(8):
        monday = ws - timedelta(weeks=7 - i)
        in_wk = [r for r in history if local_week(r.started_at, tz) == monday]
        wk.append(
            [
                monday.isoformat(),
                len(in_wk),
                round(sum(r.distance_m for r in in_wk) / 1000.0, 1),
                round(max((r.distance_m for r in in_wk), default=0.0) / 1000.0, 1),
            ]
        )
    started = {r.id: r.started_at for r in runs}
    feel: list[list[Any]] = []
    injury: str | None = None
    for s in sorted(surveys or [], key=lambda s: started.get(s.run_id, s.created_at)):
        at = started.get(s.run_id, s.created_at)
        if at < now - timedelta(days=FEEL_DAYS) or at > now:
            continue
        hurt = f"{s.injury_area or 'other'}/{s.injury_severity or 'niggle'}" if s.injury else None
        feel.append([local_date(at, tz).isoformat(), s.difficulty, hurt, s.notes])
        if s.injury and at >= now - timedelta(days=INJURY_DAYS):
            sev = s.injury_severity or "niggle"
            if injury is None or INJURY_SEVERITY.index(sev) > INJURY_SEVERITY.index(injury):
                injury = sev
    reports = [s for s in surveys or [] if s.injury]
    stops = [
        local_date(started.get(s.run_id, s.created_at), tz)
        for s in reports
        if s.injury_severity == "stopped"
        and started.get(s.run_id, s.created_at) >= now - timedelta(days=INJURY_DAYS)
    ]
    rest_until = max(stops) + timedelta(days=STOP_REST_DAYS) if stops else None
    if rest_until is not None:
        days_left = [d for d in days_left if d > rest_until]
    if profile is not None and profile.days:
        days_left = [d for d in days_left if d.weekday() in profile.days]
    window = [
        (started.get(s.run_id, s.created_at), s)
        for s in surveys or []
        if now - timedelta(days=FEEL_DAYS) <= started.get(s.run_id, s.created_at) <= now
    ]
    window.sort(key=lambda p: p[0])
    feelings = [s.difficulty for _, s in window if s.difficulty]
    km_of = {r.id: r.distance_m / 1000.0 for r in runs}
    comfy = [
        km_of[s.run_id]
        for s in surveys or []
        if s.difficulty in ("easy", "moderate") and s.run_id in km_of
    ]
    return Facts(
        growth=growth_factor(feelings, injury, beginner),
        target_km=round(TARGET_FROM_LONG_RUN * max(comfy), 1) if comfy else None,
        rest_until=rest_until,
        see_physio=sum(1 for _, s in window if s.injury) >= PHYSIO_REPORTS,
        injury=injury,
        feel=feel,
        banned=frozenset(
            k for d in (profile.dislikes if profile else []) for k in DISLIKE_KINDS.get(d, ())
        ),
        max_runs=profile.runs_per_week if profile else None,
        profile=_profile_packet(profile),
        today=today,
        week_start=ws,
        days_left=days_left,
        done=done,
        long4w=long4w,
        avg4w_km=avg4w,
        beginner=beginner,
        zones=zones,
        hard_dates=hard_dates,
        runs_per_week=rpw,
        typical_km=typical_km,
        typical_pace=typical_pace,
        fit=fit,
        wk=wk,
    )


DISLIKE_KINDS = {
    "track": ("intervals",),
    "intervals": ("intervals",),
    "tempo": ("tempo",),
    "long_runs": ("long",),
}


def _profile_packet(p: RunnerProfile | None) -> dict[str, Any] | None:
    if p is None:
        return None
    return {
        "goal": p.goal,
        "race_date": p.race_date.isoformat() if p.race_date else None,
        "days": [WEEKDAYS[d] for d in p.days],
        "runs_per_week": p.runs_per_week,
        "experience": p.experience,
        "dislikes": p.dislikes or None,
        "niggles": p.niggles,
    }


def growth_factor(feelings: list[str], injury: str | None, beginner: bool) -> float:
    """How much the week may grow, from recent check-ins (oldest first) and pain."""
    if injury in ("sore", "stopped"):
        return GROWTH_CUT
    if injury == "niggle" or "max" in feelings[-3:]:
        return GROWTH_HOLD
    if not feelings or 2 * sum(1 for x in feelings if x in ("hard", "max")) >= len(feelings):
        return GROWTH_DEFAULT
    return GROWTH_COMFY["beginner" if beginner else "experienced"]


# --- checks ------------------------------------------------------------------


def _check_text(name: str, value: str) -> None:
    if len(value.split()) > WORD_LIMITS[name]:
        raise ValueError(f"{name} has {len(value.split())} words (max {WORD_LIMITS[name]})")
    if "—" in value or "!" in value:
        raise ValueError(f"{name} has an em dash or exclamation mark")


def _check_pace(kind: str, pace: int, f: Facts) -> None:
    if not 120 <= pace <= 1200:
        raise ValueError(f"pace {pace} s/km out of range")
    if f.zones is None:
        if kind in HARD_KINDS:
            raise ValueError("hard session without a fitness estimate")
        return
    if kind in ("easy", "long"):
        fast, slow = f.zones["easy"]
        ok = fast - PACE_TOLERANCE_S <= pace <= slow + PACE_TOLERANCE_S
    else:
        ok = abs(pace - int(f.zones[kind])) <= PACE_TOLERANCE_S
    if not ok:
        raise ValueError(f"{kind} pace {fmt_dur(pace)} outside its zone")


def _check_hard(sessions: list[dict[str, Any]], f: Facts) -> None:
    planned = sorted(date.fromisoformat(s["date"]) for s in sessions if s["kind"] in HARD_KINDS)
    if len(planned) > f.hard_cap:
        raise ValueError(f"{len(planned)} hard sessions, only {f.hard_cap} allowed")
    hard = sorted(set(planned) | f.hard_dates)
    for a, b in zip(hard, hard[1:], strict=False):
        if (b - a).days == 1:
            raise ValueError(f"hard days back to back: {a} and {b}")
    hard_km = sum(float(s["km"]) for s in sessions if s["kind"] in HARD_KINDS)
    week_km = sum(float(s["km"]) for s in sessions) + f.done_km
    if len(planned) >= 2 and hard_km > HARD_SHARE * week_km + KM_SLACK:
        raise ValueError(f"hard sessions are {hard_km:.1f} of {week_km:.1f} km, over 20%")


def cap_sessions(f: Facts, budget_count: int | None) -> int:
    n = len(f.days_left)
    if f.injury == "stopped":
        n = min(n, STOP_MAX_SESSIONS)
    if f.max_runs is not None:
        n = min(n, max(0, f.max_runs - len(f.done)))
    return n if budget_count is None else min(n, budget_count)


def check_plan(
    raw: str, f: Facts, *, budget_km: float | None = None, budget_count: int | None = None
) -> tuple[list[dict[str, Any]], str, str]:
    """Validate the planner's JSON against the safety rules; raises ValueError on any breach."""
    plan = LLMPlan.model_validate_json(raw)
    note, change = plan.note.strip(), plan.change.strip()
    _check_text("note", note)
    _check_text("change", change)
    sessions: list[dict[str, Any]] = []
    seen: set[date] = set()
    for s in plan.sessions:
        day = date.fromisoformat(s.date)
        if day not in f.days_left:
            raise ValueError(f"{day} is not a day left this week")
        if day in seen:
            raise ValueError(f"two runs on {day}")
        seen.add(day)
        if not 0 < s.km <= f.run_cap + KM_SLACK:
            raise ValueError(f"{s.km} km is over the {f.run_cap} km cap")
        if s.km < f.min_km - KM_SLACK:
            raise ValueError(f"{s.km} km is under the {f.min_km} km minimum")
        if s.kind in f.banned:
            raise ValueError(f"{s.kind} is a kind of run they asked to avoid")
        pace = parse_pace(s.pace)
        _check_pace(s.kind, pace, f)
        detail, why = s.detail.strip(), s.why.strip()
        _check_text("detail", detail)
        _check_text("why", why)
        sessions.append(_session(day, s.kind, s.km, pace, detail, why))
    if len(sessions) > cap_sessions(f, budget_count):
        raise ValueError(f"{len(sessions)} runs, at most {cap_sessions(f, budget_count)}")
    total = sum(s["km"] for s in sessions)
    # Each run is rounded to 0.1 km, so allow that much per run.
    slack = KM_SLACK * max(1, len(sessions))
    if total > min(f.week_cap, budget_km if budget_km is not None else f.week_cap) + slack:
        raise ValueError(f"{total:.1f} km is over what is left for the week")
    _check_hard(sessions, f)
    return sorted(sessions, key=lambda s: str(s["date"])), note, change


def _session(
    day: date, kind: str, km: float, pace: int, detail: str, why: str, status: str = "planned"
) -> dict[str, Any]:
    return {
        "id": uuid.uuid4().hex[:12],
        "date": day.isoformat(),
        "kind": kind,
        "km": round(km, 1),
        "pace": pace,
        "detail": detail,
        "why": why,
        "status": status,
        "run_id": None,
        "moved_from": None,
    }


def fallback_plan(
    f: Facts, *, budget_km: float | None = None, budget_count: int | None = None
) -> list[dict[str, Any]]:
    """Rules-only plan: the usual runs, spread out with rest days, mostly easy."""
    days = f.days_left
    n = min(f.runs_per_week - len(f.done), cap_sessions(f, budget_count))
    n = min(n, (len(days) + 1) // 2)
    km_left = min(f.week_cap, budget_km) if budget_km is not None else f.week_cap
    while n > 0 and km_left / n < f.min_km - KM_SLACK:
        n -= 1
    if n <= 0:
        return []
    idx = [0] if n == 1 else [round(i * (len(days) - 1) / (n - 1)) for i in range(n)]
    km = round(min(max(f.typical_km, f.min_km), f.run_cap, km_left / n), 1)
    if f.zones is not None:
        easy = int(f.zones["easy"][1])
    else:
        easy = f.typical_pace + NO_FIT_EASY_EXTRA_S
    sessions = [
        _session(days[i], "easy", km, easy, f"Easy {km:g} km, conversational.", _FALLBACK_WHY)
        for i in idx
    ]
    if n >= 2 and f.zones is not None and "tempo" not in f.banned:
        mid = sessions[n // 2]
        tempo = dict(mid, kind="tempo", pace=int(f.zones["tempo"]))
        tempo["detail"] = f"{km:g} km with the middle part at {fmt_dur(tempo['pace'])}/km."
        trial = [*sessions[: n // 2], tempo, *sessions[n // 2 + 1 :]]
        try:
            _check_hard(trial, f)
            sessions = trial
        except ValueError:
            pass
    return sessions


_FALLBACK_WHY = "Steady, easy running builds the base your goal needs."


# --- matching runs to sessions (no LLM) --------------------------------------


def match_runs(row: WeekPlan, f: Facts) -> bool:
    """Tick off sessions with this week's runs and mark missed ones. True if anything changed."""
    sessions = [dict(s) for s in row.sessions]
    before = json.dumps(sessions, sort_keys=True)
    linked = {s["run_id"] for s in sessions if s.get("run_id")}
    for d in sorted(f.done, key=lambda d: d["date"]):
        if d["run_id"] in linked:
            continue
        day = d["date"].isoformat()
        same = next(
            (s for s in sessions if s["date"] == day and s["status"] in ("planned", "missed")),
            None,
        )
        target = same or next(
            (
                s
                for s in sorted(sessions, key=lambda s: str(s["date"]))
                if s["status"] == "planned" and str(s["date"]) > day
            ),
            None,
        )
        if target is None:
            continue
        if target is not same:
            target["moved_from"] = target["date"]
            target["date"] = day
        target["status"] = "done"
        target["run_id"] = d["run_id"]
        linked.add(d["run_id"])
    today = f.today.isoformat()
    for s in sessions:
        if s["status"] == "planned" and str(s["date"]) < today:
            s["status"] = "missed"
            row.needs_replan = True
    # A run done early can leave a hard session right after a hard run.
    try:
        _check_hard([s for s in sessions if s["status"] == "planned"], f)
    except ValueError:
        row.needs_replan = True
    row.sessions = sorted(sessions, key=lambda s: str(s["date"]))
    return json.dumps(row.sessions, sort_keys=True) != before


# --- packet ------------------------------------------------------------------


def plan_packet(
    f: Facts,
    why: str,
    goals: list[dict[str, Any]],
    report: dict[str, Any] | None,
    sessions: list[dict[str, Any]],
    budget_km: float | None,
    budget_count: int | None,
) -> str:
    week_km = f.week_cap if budget_km is None else min(f.week_cap, budget_km)
    body: dict[str, Any] = {
        "today": [f.today.isoformat(), WEEKDAYS[f.today.weekday()]],
        "days_left": [[d.isoformat(), WEEKDAYS[d.weekday()]] for d in f.days_left],
        "why": why,
        "fit": _format_fit(f.fit) if f.fit is not None else None,
        "goals": goals,
        "wk": {"cols": ["wk", "runs", "km", "long"], "rows": f.wk},
        "long4w": f.long4w,
        "avg4w": f.avg4w_km,
        "beginner": f.beginner,
        "report": report,
        "feel": f.feel or None,
        "injury": f.injury,
        "profile": f.profile,
        "rest_until": f.rest_until.isoformat() if f.rest_until else None,
        "see_physio": f.see_physio,
        "done": [
            [d["date"].isoformat(), d["km"], fmt_dur(d["pace"]), "hard" if d["hard"] else "easy"]
            for d in f.done
        ],
        "plan": [
            [s["date"], s["kind"], s["km"], fmt_dur(int(s["pace"])), s["status"]] for s in sessions
        ]
        or None,
        "cap": {
            "run_km": f.run_cap,
            "min_km": f.min_km,
            "target_week_km": f.target_km,
            "growth": f.growth,
            "week_km": round(week_km, 1),
            "sessions": cap_sessions(f, budget_count),
            "hard": f.hard_cap,
        },
    }
    return json.dumps(body, separators=(",", ":"), ensure_ascii=False)


async def _goals(db: AsyncSession, user_id: Any, runs: list[Run]) -> list[dict[str, Any]]:
    targets = dict(
        (
            await db.execute(
                select(Target.distance, Target.target_s).where(Target.user_id == user_id)
            )
        )
        .tuples()
        .all()
    )
    month_ago = datetime.now(UTC) - timedelta(days=28)
    out = []
    for d in sorted(set(targets) | {k for r in runs for k in (r.efforts or {})}):
        times = [r.efforts[d] for r in runs if d in (r.efforts or {})]
        out.append(
            {
                "d": d,
                "target": fmt_dur(targets[d]) if d in targets else None,
                "pb": fmt_dur(min(times)) if times else None,
                "n4w": sum(1 for r in runs if d in (r.efforts or {}) and r.started_at >= month_ago),
            }
        )
    return out


async def _report(db: AsyncSession, user_id: Any, week_start: date) -> dict[str, Any] | None:
    card = await db.scalar(
        select(ReportCard)
        .where(
            ReportCard.user_id == user_id,
            ReportCard.status == "closed",
            ReportCard.week_start < week_start,
        )
        .order_by(ReportCard.week_start.desc())
        .limit(1)
    )
    if card is None:
        return None
    grades = {
        c: (v.get("grade") if isinstance(v, dict) else v) for c, v in (card.grades or {}).items()
    }
    summary: dict[str, Any] = dict(card.summary or {})
    focus_obj = summary.get("focus")
    focus = focus_obj.get("category") if isinstance(focus_obj, dict) else None
    return {"wk": card.week_start.isoformat(), "g": grades, "focus": focus}


# --- LLM ---------------------------------------------------------------------


def public_packet(packet: str) -> str:
    """The packet without health data or free text, for analytics traces."""
    body = json.loads(packet)
    for key in PRIVATE_KEYS:
        body.pop(key, None)
    return json.dumps(body, separators=(",", ":"), ensure_ascii=False)


async def flag_injury(db: AsyncSession, user_id: Any, run: Run) -> None:
    """A reported injury replans the rest of this week on the next read, even if it
    was already replanned today."""
    row = await db.get(WeekPlan, (user_id, local_week(run.started_at, run.tz or "UTC")))
    if row is not None:
        row.needs_replan = True
        row.replanned_on = None


def load_plan_prompt() -> str:
    return resources.files("jogga").joinpath("prompts/plan_system.md").read_text(encoding="utf-8")


@lru_cache(maxsize=1)
def load_plan_schema() -> dict[str, Any]:
    raw = resources.files("jogga").joinpath("prompts/plan_schema.json").read_text(encoding="utf-8")
    schema: dict[str, Any] = json.loads(raw)
    return schema


def plan_llm_client() -> LLMClient | None:
    schema = load_plan_schema()
    if config.MUBIT_API_KEY:
        return OpenRouterClient(
            config.MUBIT_API_KEY, config.LLM_MODEL, url=config.MUBIT_URL, response_schema=schema
        )
    if config.OPENROUTER_API_KEY:
        return OpenRouterClient(config.OPENROUTER_API_KEY, config.LLM_MODEL, response_schema=schema)
    return None


async def _write_plan(
    user_id: Any,
    f: Facts,
    packet: str,
    llm_client: LLMClient | None,
    budget_km: float | None,
    budget_count: int | None,
) -> tuple[list[dict[str, Any]], str | None, str | None, str, str | None, str | None]:
    """(sessions, note, change, source, model, error). One LLM attempt, rules plan on failure."""
    from .weekly import _capture

    if llm_client is not None:
        system = load_plan_prompt()
        started = time.monotonic()
        result: LLMResult | None = None
        try:
            result = await asyncio.wait_for(
                llm_client.complete(system, packet), timeout=config.LLM_TOTAL_TIMEOUT_S
            )
            sessions, note, change = check_plan(
                result.text, f, budget_km=budget_km, budget_count=budget_count
            )
        except Exception as exc:
            error = f"{type(exc).__name__}: {exc}"[:500]
            logger.warning("planner llm failed user=%s week=%s: %s", user_id, f.week_start, error)
            _capture(
                user_id,
                f.week_start,
                system,
                public_packet(packet),
                int((time.monotonic() - started) * 1000),
                result,
                error if result is None else None,
                span="week_plan",
            )
        else:
            _capture(
                user_id,
                f.week_start,
                system,
                public_packet(packet),
                int((time.monotonic() - started) * 1000),
                result,
                None,
                span="week_plan",
            )
            return sessions, note, change or None, "llm", config.LLM_MODEL, None
    else:
        error = None
    sessions = fallback_plan(f, budget_km=budget_km, budget_count=budget_count)
    return sessions, None, None, "fallback", None, error


# --- sync --------------------------------------------------------------------


def _done_session(d: dict[str, Any]) -> dict[str, Any]:
    s = _session(d["date"], "steady" if d["hard"] else "easy", d["km"], d["pace"], "", "", "done")
    s["run_id"] = d["run_id"]
    return s


async def sync_plan(
    db: AsyncSession,
    user_id: Any,
    tz: str | None,
    *,
    llm_client: LLMClient | None = None,
    allow_llm: bool = True,
    force: bool = False,
    reason: str | None = None,
    now: datetime | None = None,
) -> WeekPlan | None:
    """Bring this week's plan up to date. Writes a plan on the first call of the week and
    replans at most once a day after a miss. ``allow_llm=False`` only ticks off runs."""
    await db.execute(
        text("select pg_advisory_xact_lock(hashtext(:k))"), {"k": f"week_plan:{user_id}"}
    )
    runs = list(
        (await db.scalars(select(Run).where(Run.user_id == user_id).order_by(Run.started_at))).all()
    )
    profile = await db.get(RunnerProfile, user_id)
    # Onboarding answers are enough for a first plan before any runs.
    if not runs and profile is None:
        return None
    zone = valid_tz(tz) or next((r.tz for r in reversed(runs) if valid_tz(r.tz)), None) or "UTC"
    now = now or datetime.now(UTC)
    ws = local_week(now, zone)
    row = await db.get(WeekPlan, (user_id, ws))
    prev = await db.scalar(
        select(WeekPlan)
        .where(WeekPlan.user_id == user_id, WeekPlan.week_start < ws)
        .order_by(WeekPlan.week_start.desc())
        .limit(1)
    )
    prev_count = prev.original_count if prev else await _coach_runs_per_week(db, user_id)
    surveys = list(
        (
            await db.scalars(
                select(RunSurvey).where(
                    RunSurvey.user_id == user_id,
                    RunSurvey.created_at >= now - timedelta(days=FEEL_DAYS + 7),
                )
            )
        ).all()
    )
    f = facts(runs, zone, now, prev_count, surveys=surveys, profile=profile)
    if row is not None:
        match_runs(row, f)
    if row is None:
        why = "new"
    elif force or reason:
        why = reason or "regenerate"
    elif row.needs_replan and row.replanned_on != f.today:
        why = "missed" if any(s["status"] == "missed" for s in row.sessions) else "check_in"
    else:
        return row
    if not allow_llm:
        return row

    old: list[dict[str, Any]] = list(row.sessions) if row is not None else []
    if row is None:
        keep = [_done_session(d) for d in f.done]
    else:
        keep = [s for s in old if s["status"] in ("done", "missed")]
    budget_km: float | None = None
    budget_count: int | None = None
    if why in ("missed", "check_in"):
        left = [s for s in old if s["status"] in ("planned", "missed")]
        budget_km = round(sum(float(s["km"]) for s in left), 1)
        budget_count = len(left)
    goals = await _goals(db, user_id, runs)
    report = await _report(db, user_id, ws)
    packet = plan_packet(f, why, goals, report, keep, budget_km, budget_count)
    if llm_client is None:
        llm_client = plan_llm_client()
    sessions, note, change, source, model, error = await _write_plan(
        user_id, f, packet, llm_client, budget_km, budget_count
    )
    all_sessions = sorted([*keep, *sessions], key=lambda s: str(s["date"]))
    if row is None:
        count = len(all_sessions)
        if f.today > ws:
            # A first plan written mid-week only covers the days left; Consistency still
            # grades the whole week, so keep the usual weekly count.
            count = max(count, f.runs_per_week)
        row = WeekPlan(
            user_id=user_id,
            week_start=ws,
            tz=zone,
            sessions=all_sessions,
            original_count=count,
            history=[],
            needs_replan=False,
        )
        db.add(row)
    else:
        row.history = [
            *(row.history or []),
            {"at": now.isoformat(), "why": why, "sessions": old, "source": row.source},
        ]
        row.sessions = all_sessions
        if why == "regenerate":
            # New history can add runs to the week, never take them off the grade.
            row.original_count = max(row.original_count, len(all_sessions))
        row.replanned_on = f.today
        row.needs_replan = False
    row.note = note if note is not None else row.note
    row.change = change if why in ("missed", "check_in", "profile") else None
    if why == "profile" and change is None:
        row.change = "Replanned around your training preferences."
    if why == "check_in" and change is None:
        row.change = "Eased off the rest of the week after your check-in."
    if why == "missed" and change is None:
        dropped = (budget_count or 0) - len(sessions)
        row.change = (
            f"Missed a run, so {dropped} run{'s' if dropped != 1 else ''} dropped "
            "to keep rest days."
            if dropped > 0
            else "Missed a run, so the rest of the week has moved."
        )
    row.source, row.model, row.packet, row.error = source, model, packet, error
    row.tz = zone
    row.updated_at = now
    await db.flush()
    return row


def plan_out(row: WeekPlan | None, now: datetime | None = None) -> dict[str, Any] | None:
    if row is None:
        return None
    today = local_date(now or datetime.now(UTC), row.tz).isoformat()
    sessions = sorted(row.sessions, key=lambda s: str(s["date"]))
    nxt = next(
        (s["id"] for s in sessions if s["status"] == "planned" and str(s["date"]) >= today), None
    )
    return {
        "week_start": row.week_start.isoformat(),
        "tz": row.tz,
        "note": row.note,
        "change": row.change,
        "source": row.source,
        "original_count": row.original_count,
        "today": today,
        "sessions": [
            {
                **s,
                "weekday": WEEKDAYS[date.fromisoformat(str(s["date"])).weekday()],
                "is_today": s["date"] == today,
                "is_next": s["id"] == nxt,
            }
            for s in sessions
        ],
    }


async def planned_for(db: AsyncSession, run: Run) -> dict[str, Any] | None:
    """The session this run was meant to be, for the coach's planned-vs-did line."""
    tz = run.tz or "UTC"
    row = await db.get(WeekPlan, (run.user_id, local_week(run.started_at, tz)))
    if row is None:
        return None
    day = local_date(run.started_at, tz).isoformat()
    sessions = sorted(row.sessions, key=lambda s: str(s["date"]))
    for s in sessions:
        if s.get("run_id") == str(run.id):
            return s
    same = next((s for s in sessions if s["date"] == day and s["status"] != "done"), None)
    return same or next(
        (s for s in sessions if s["status"] == "planned" and str(s["date"]) > day), None
    )


async def _coach_runs_per_week(db: AsyncSession, user_id: Any) -> int | None:
    """Runs a week from the latest coach note that still carries one (before week plans)."""
    for payload in await db.scalars(
        select(CoachNote.payload)
        .where(CoachNote.user_id == user_id)
        .order_by(CoachNote.created_at.desc())
        .limit(20)
    ):
        freq = (payload or {}).get("frequency")
        rpw = freq.get("runs_per_week") if isinstance(freq, dict) else None
        if isinstance(rpw, int) and rpw > 0:
            return rpw
    return None


async def newest_import(db: AsyncSession, user_id: Any) -> datetime | None:
    newest: datetime | None = await db.scalar(
        select(func.max(Run.created_at)).where(Run.user_id == user_id, Run.source != "jogga")
    )
    return newest
