"""Report-card storage, weekly close and the one LLM call per closed week."""

import asyncio
import json
import logging
import re
import time
from datetime import UTC, date, datetime, timedelta
from datetime import time as dtime
from functools import lru_cache
from importlib import resources
from typing import Any

from sqlalchemy import select, text
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from . import config
from .coach import LLMClient, LLMResult, OpenRouterClient
from .models import CoachNote, ReportCard, Run, Target, WeekPlan
from .posthog import get_posthog_client
from .report_card import CATEGORIES, Context, Week, grade_weeks
from .schemas import ReportSummary
from .weeks import local_week, valid_tz, week_end
from .weeks import zone as zone_of

logger = logging.getLogger(__name__)

# Runs can still land in a closed week (offline uploads) for this long.
LATE_RUN_WINDOW = timedelta(hours=72)
MAX_HEADLINE_WORDS = 10
MAX_SUMMARY_WORDS = 45
MAX_ACTION_WORDS = 20

FALLBACK: dict[str, tuple[str, str, str]] = {
    "consistency": (
        "A week to build the habit",
        "You got some running in. Next week is about showing up for every run in the plan.",
        "Put next week's runs in your calendar now and keep each one short if you need to.",
    ),
    "pacing": (
        "Good work, now even it out",
        "The running is there. Starting a little slower will help you finish stronger.",
        "Run the first kilometre of each run slower than feels natural.",
    ),
    "balance": (
        "Ease off between the hard days",
        "You worked hard this week. More of your running should feel easy.",
        "Keep one hard session next week and make every other run conversational.",
    ),
    "load": (
        "A steadier week comes next",
        "Your distance moved a lot compared with recent weeks. Steady weeks build fitness safely.",
        "Keep next week's distance close to your recent weekly average.",
    ),
    "progress": (
        "Steady week, keep building",
        "Your fitness is holding. A small dose of quality will help it move again.",
        "Add one short session of faster running next week and keep the rest easy.",
    ),
}


def load_report_prompt() -> str:
    return resources.files("jogga").joinpath("prompts/report_system.md").read_text(encoding="utf-8")


@lru_cache(maxsize=1)
def load_report_schema() -> dict[str, Any]:
    raw = (
        resources.files("jogga").joinpath("prompts/report_schema.json").read_text(encoding="utf-8")
    )
    schema: dict[str, Any] = json.loads(raw)
    return schema


def fallback_summary(focus: str) -> dict[str, Any]:
    headline, summary, action = FALLBACK[focus]
    return {
        "headline": headline,
        "summary": summary,
        "focus": {"category": focus, "action": action},
    }


# --- packet + validation -----------------------------------------------------


def report_packet(week: Week, prev: Week | None) -> str:
    g = {c: [week.rows[c].grade, week.rows[c].metric] for c in CATEGORIES}
    body: dict[str, Any] = {
        "wk": week.week_start.isoformat(),
        "n": len(week.runs),
        "km": week.km,
        "plan": week.recommended,
        "mix": week.sessions,
        "g": g,
        "prev": {c: prev.rows[c].grade for c in CATEGORIES} if prev else None,
        "focus": week.focus(),
        "runs": week.run_table,
        "tgt": week.target,
    }
    return json.dumps(body, separators=(",", ":"), ensure_ascii=False)


_NUMBER = re.compile(r"\d+(?:[.:]\d+)*")
_GRADE_LETTER = re.compile(r"\b[BCD]\b|\ban A\b")
_CADENCE_TARGET = re.compile(r"\d+\s*(?:spm|steps? (?:per|a|/) ?min)", re.IGNORECASE)


def _words(s: str) -> int:
    return len(s.split())


def parse_report_summary(raw: str, packet: str, focus: str) -> ReportSummary:
    """Validate the LLM text against the packet; raises ValueError on any breach."""
    out = ReportSummary.model_validate_json(raw)
    out.headline = out.headline.strip().rstrip(".")
    out.summary = out.summary.strip()
    out.focus.action = out.focus.action.strip()
    if out.focus.category != focus:
        raise ValueError(f"focus {out.focus.category} != {focus}")
    for name, value, limit in (
        ("headline", out.headline, MAX_HEADLINE_WORDS),
        ("summary", out.summary, MAX_SUMMARY_WORDS),
        ("action", out.focus.action, MAX_ACTION_WORDS),
    ):
        if not value:
            raise ValueError(f"{name} is empty")
        if _words(value) > limit:
            raise ValueError(f"{name} has {_words(value)} words (max {limit})")
        if "—" in value or "!" in value:
            raise ValueError(f"{name} has an em dash or exclamation mark")
        if _GRADE_LETTER.search(value) or re.search(r"\bgrade", value, re.IGNORECASE):
            raise ValueError(f"{name} mentions a grade")
        if _CADENCE_TARGET.search(value):
            raise ValueError(f"{name} sets a cadence target")
        for n in _NUMBER.findall(value):
            if n not in packet:
                raise ValueError(f"{name} uses {n}, not in the packet")
    return out


# --- loading -----------------------------------------------------------------


async def load_context(
    db: AsyncSession, user_id: Any, tz: str | None, now: datetime | None = None
) -> Context:
    runs = list(
        (await db.scalars(select(Run).where(Run.user_id == user_id).order_by(Run.started_at))).all()
    )
    zone = valid_tz(tz) or next((r.tz for r in reversed(runs) if valid_tz(r.tz)), None) or "UTC"
    plan_rows = (
        await db.execute(
            select(Run.started_at, CoachNote.payload)
            .join(Run, Run.id == CoachNote.run_id)
            .where(CoachNote.user_id == user_id)
            .order_by(Run.started_at)
        )
    ).all()
    plans = []
    for at, payload in plan_rows:
        rpw = ((payload or {}).get("frequency") or {}).get("runs_per_week")
        if isinstance(rpw, int) and rpw > 0:
            plans.append((at, rpw))
    # A week plan sets that week's planned runs (as it stood on Monday, never a cut-down replan).
    for week_start, plan_tz, count in (
        await db.execute(
            select(WeekPlan.week_start, WeekPlan.tz, WeekPlan.original_count).where(
                WeekPlan.user_id == user_id
            )
        )
    ).all():
        starts = datetime.combine(week_start, dtime(), zone_of(plan_tz))
        plans.append((starts - timedelta(microseconds=1), count))
    plans.sort(key=lambda p: p[0])
    targets = dict(
        (
            await db.execute(
                select(Target.distance, Target.target_s).where(Target.user_id == user_id)
            )
        )
        .tuples()
        .all()
    )
    return Context(runs=runs, tz=zone, now=now or datetime.now(UTC), plans=plans, targets=targets)


def report_llm_client() -> LLMClient | None:
    schema = load_report_schema()
    if config.MUBIT_API_KEY:
        return OpenRouterClient(
            config.MUBIT_API_KEY, config.LLM_MODEL, url=config.MUBIT_URL, response_schema=schema
        )
    if config.OPENROUTER_API_KEY:
        return OpenRouterClient(config.OPENROUTER_API_KEY, config.LLM_MODEL, response_schema=schema)
    return None


def _capture(
    user_id: Any,
    week: date,
    system: str,
    packet: str,
    latency_ms: int,
    result: LLMResult | None,
    error: str | None,
    span: str = "report_card_summary",
) -> None:
    client = get_posthog_client()
    if client is None:
        return
    props: dict[str, Any] = {
        "$ai_trace_id": f"{span}:{user_id}:{week.isoformat()}",
        "$ai_span_name": span,
        "$ai_model": config.LLM_MODEL,
        "$ai_provider": "openrouter",
        "$ai_latency": latency_ms / 1000,
        "$ai_input": [{"role": "system", "content": system}, {"role": "user", "content": packet}],
    }
    if result is None:
        props["$ai_is_error"] = True
        props["$ai_error"] = error
    else:
        props["$ai_output_choices"] = [{"role": "assistant", "content": result.text}]
        if result.prompt_tokens is not None:
            props["$ai_input_tokens"] = result.prompt_tokens
        if result.completion_tokens is not None:
            props["$ai_output_tokens"] = result.completion_tokens
        if result.cost_usd is not None:
            props["$ai_total_cost_usd"] = result.cost_usd
            props["$ai_cost_passthrough"] = True
    client.capture("$ai_generation", distinct_id=str(user_id).upper(), properties=props)


async def write_summary(
    user_id: Any, week: Week, prev: Week | None, llm_client: LLMClient | None
) -> tuple[dict[str, Any], str, str | None, str, str | None]:
    """(summary, source, model, packet, error). One LLM attempt, fallback on any failure."""
    packet = report_packet(week, prev)
    focus = week.focus()
    if llm_client is None:
        return fallback_summary(focus), "fallback", None, packet, None
    system = load_report_prompt()
    started = time.monotonic()
    result: LLMResult | None = None
    try:
        result = await asyncio.wait_for(
            llm_client.complete(system, packet), timeout=config.LLM_TOTAL_TIMEOUT_S
        )
        parsed = parse_report_summary(result.text, packet, focus)
    except Exception as exc:
        error = f"{type(exc).__name__}: {exc}"[:500]
        logger.warning(
            "report card llm failed user=%s week=%s: %s", user_id, week.week_start, error
        )
        _capture(
            user_id,
            week.week_start,
            system,
            packet,
            _ms(started),
            result,
            error if result is None else None,
        )
        return fallback_summary(focus), "fallback", None, packet, error
    _capture(user_id, week.week_start, system, packet, _ms(started), result, None)
    return parsed.model_dump(), "llm", config.LLM_MODEL, packet, None


def _ms(started: float) -> int:
    return int(round((time.monotonic() - started) * 1000))


# --- storage -----------------------------------------------------------------


async def _lock(db: AsyncSession, user_id: Any) -> None:
    """Serialise report-card writes per user so a week only ever gets one LLM call."""
    await db.execute(
        text("select pg_advisory_xact_lock(hashtext(:k))"), {"k": f"report_card:{user_id}"}
    )


async def _upsert(db: AsyncSession, values: dict[str, Any], update: list[str]) -> None:
    stmt = insert(ReportCard).values(**values)
    await db.execute(
        stmt.on_conflict_do_update(
            index_elements=[ReportCard.user_id, ReportCard.week_start],
            set_={k: stmt.excluded[k] for k in [*update, "updated_at"]},
        )
    )


def _values(user_id: Any, week: Week, tz: str, status: str) -> dict[str, Any]:
    return {
        "user_id": user_id,
        "week_start": week.week_start,
        "tz": tz,
        "status": status,
        "grades": week.grades_json(),
        "composite": week.composite,
        "updated_at": datetime.now(UTC),
    }


async def refresh_live(db: AsyncSession, user_id: Any, tz: str | None) -> None:
    """Recompute and store this week's live card. No LLM."""
    ctx = await load_context(db, user_id, tz)
    this_week = local_week(ctx.now, ctx.tz)
    weeks = grade_weeks(ctx, since=this_week)
    week = weeks.get(this_week)
    if week is None:
        return
    await _lock(db, user_id)
    await _upsert(db, _values(user_id, week, ctx.tz, "live"), ["tz", "grades", "composite"])


async def backfill(db: AsyncSession, user_id: Any, tz: str | None) -> int:
    """Deterministic closed cards for every past week with runs; never calls the LLM.

    Leaves weeks that already have a summary alone.
    """
    ctx = await load_context(db, user_id, tz)
    this_week = local_week(ctx.now, ctx.tz)
    weeks = grade_weeks(ctx, through=this_week - timedelta(weeks=1))
    await _lock(db, user_id)
    summarised = set(
        await db.scalars(
            select(ReportCard.week_start).where(
                ReportCard.user_id == user_id, ReportCard.summary.is_not(None)
            )
        )
    )
    n = 0
    now = datetime.now(UTC)
    for start, week in weeks.items():
        if not week.runs or start in summarised:
            continue
        values = _values(user_id, week, ctx.tz, "closed") | {"closed_at": now, "source": "backfill"}
        await _upsert(db, values, ["tz", "status", "grades", "composite", "closed_at", "source"])
        n += 1
    return n


async def close_last_week(
    db: AsyncSession, ctx: Context, weeks: dict[date, Week], llm_client: LLMClient | None
) -> ReportCard | None:
    """Close the most recent finished week on first read after local Monday.

    Writes the summary once (one LLM call). A run landing within LATE_RUN_WINDOW
    of the week ending regrades it; the summary is kept if the focus still
    matches, otherwise it falls back to the deterministic text.
    """
    user_id = ctx.runs[0].user_id if ctx.runs else None
    last = local_week(ctx.now, ctx.tz) - timedelta(weeks=1)
    week = weeks.get(last)
    if user_id is None or week is None or not week.runs:
        return None
    await _lock(db, user_id)
    card = await db.get(ReportCard, (user_id, last), populate_existing=True)
    imported_only = week.recorded == 0
    if card is not None and card.status == "closed" and card.summary is not None:
        late = any(
            r.created_at is not None
            and card.closed_at is not None
            and r.created_at > card.closed_at
            for r in week.runs
        )
        if late and ctx.now <= week_end(last, ctx.tz) + LATE_RUN_WINDOW:
            card.grades = week.grades_json()
            card.composite = week.composite
            focus = card.summary.get("focus")
            if not isinstance(focus, dict) or focus.get("category") != week.focus():
                card.summary = fallback_summary(week.focus())
                card.source = "fallback"
                card.model = None
            card.closed_at = ctx.now
        return card
    prev = weeks.get(last - timedelta(weeks=1))
    prev = prev if prev is not None and prev.runs else None
    values = _values(user_id, week, ctx.tz, "closed") | {"closed_at": ctx.now}
    if imported_only:
        values |= {"source": "backfill"}
        await _upsert(db, values, ["tz", "status", "grades", "composite", "closed_at", "source"])
    else:
        summary, source, model, packet, error = await write_summary(user_id, week, prev, llm_client)
        values |= {
            "summary": summary,
            "source": source,
            "model": model,
            "packet": packet,
            "error": error,
        }
        await _upsert(
            db,
            values,
            [
                "tz",
                "status",
                "grades",
                "composite",
                "closed_at",
                "summary",
                "source",
                "model",
                "packet",
                "error",
            ],
        )
    return await db.get(ReportCard, (user_id, last), populate_existing=True)


# --- output ------------------------------------------------------------------


def card_out(week: Week, tz: str, card: ReportCard | None = None) -> dict[str, Any]:
    """The API shape for a week. ``card`` supplies the stored summary for closed weeks."""
    if not week.runs:
        kind = "rest"
    elif week.recorded == 0:
        kind = "imported"
    else:
        kind = "report"
    grades = card.grades if card is not None and card.status == "closed" else week.grades_json()
    return {
        "week_start": week.week_start.isoformat(),
        "week_end": (week.week_start + timedelta(days=6)).isoformat(),
        "tz": tz,
        "status": "live" if week.live else "closed",
        "kind": kind,
        "runs": len(week.runs),
        "km": week.km,
        "recommended": week.recommended,
        "sessions": week.sessions,
        "rows": [grades[c] for c in CATEGORIES],
        "focus": week.focus() if week.runs else None,
        "summary": card.summary if card is not None else None,
        "source": card.source if card is not None else None,
        "closed_at": card.closed_at.isoformat() if card is not None and card.closed_at else None,
    }
