"""Coach: LLM via OpenRouter with deterministic heuristic fallback."""

import asyncio
import json
import logging
import re
import time
from dataclasses import dataclass
from functools import lru_cache
from importlib import resources
from typing import Any, Protocol

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from . import config
from .fitness import fmt_dur, parse_pace, riegel, run_shape
from .models import CoachNote, Run, Target
from .packet import _pace_s_per_km, _primary_distance, build_packet, fit_runs, fit_source
from .posthog import get_posthog_client
from .schemas import (
    STANDARD_DISTANCES,
    CoachOutput,
    DistanceStats,
    Frequency,
    LLMCoachOutput,
    NextRun,
    Pacing,
    RunKind,
    Shape,
)
from .stats import distance_stats

DISTANCE_LABELS = {"5k": "5K", "10k": "10K", "half": "half marathon", "marathon": "marathon"}

logger = logging.getLogger(__name__)


def load_system_prompt() -> str:
    """Load the authored system prompt verbatim."""
    return resources.files("jogga").joinpath("prompts/coach_system.md").read_text(encoding="utf-8")


@lru_cache(maxsize=1)
def load_response_schema() -> dict[str, Any]:
    """The authored json_schema object sent as response_format."""
    raw = resources.files("jogga").joinpath("prompts/coach_schema.json").read_text(encoding="utf-8")
    schema: dict[str, Any] = json.loads(raw)
    return schema


SHAPE_TO_PACING: dict[Shape, Pacing] = {
    "faded": "positive",
    "sped_up": "negative",
    "steady": "even",
    "uneven": "erratic",
}


def _half_up(n: float) -> float:
    """Round to the nearest 0.5 km."""
    return round(n * 2) / 2


def _count_word(n: int) -> str:
    return {1: "once", 2: "twice"}.get(n, f"{n} times")


def _fmt_pace(s_per_km: float) -> str:
    s = int(round(s_per_km))
    return f"{s // 60}:{s % 60:02d}/km"


def _fmt_time(seconds: float) -> str:
    s = int(round(seconds))
    if s < 3600:
        return f"{s // 60}:{s % 60:02d}"
    return f"{s // 3600}:{s % 3600 // 60:02d}:{s % 60:02d}"


async def heuristic_coach(
    db: AsyncSession, run: Run, *, previous_note: CoachNote | None
) -> CoachOutput:
    """Deterministic fallback coach, exactly as specified."""
    pacing = SHAPE_TO_PACING[run_shape(run.splits)]
    stats = await distance_stats(
        db, run.user_id, run.started_at, exclude_run_id=run.id, before=run.started_at
    )

    target_rows = (
        await db.execute(
            select(Target.distance, Target.target_s).where(Target.user_id == run.user_id)
        )
    ).all()
    targets = {distance: target_s for distance, target_s in target_rows}

    history = (
        await db.scalars(
            select(Run)
            .where(Run.user_id == run.user_id, Run.started_at <= run.started_at)
            .order_by(Run.started_at.desc(), Run.id.desc())
        )
    ).all()
    recent = fit_runs(history, run.started_at)
    src = fit_source(history, run.started_at)

    primary = _primary_distance(run.distance_m)
    recent_best: float | None = None
    if primary is not None:
        recent_best = min(
            (r.efforts[primary] for r in recent if r.id != run.id and primary in (r.efforts or {})),
            default=None,
        )

    if not targets:
        avg_pace = _pace_s_per_km(run.distance_m, run.moving_s)
        pace = avg_pace + 30
        next_run = NextRun(
            km=5.0,
            pace=pace,
            kind="easy",
            detail=f"Easy 5 km at {_fmt_pace(pace)}.",
            why="No target set yet, so keep it comfortable and build the habit.",
        )
        frequency = Frequency(
            runs_per_week=3,
            note="Set a target and I will tune how often you should run.",
        )
        feedback = _feedback(pacing, run, primary, stats, recent_best)
        return CoachOutput(feedback=feedback, pacing=pacing, next=next_run, frequency=frequency)

    # Goal: target distance with the largest relative gap between current ability
    # (fitness-predicted time, else pb) and target.
    def gap(distance: str) -> float:
        km = STANDARD_DISTANCES[distance] / 1000.0
        s = stats.get(distance)
        if src is not None:
            current = riegel(src[3], src[2], km)
        elif s is not None and s.best_s is not None:
            current = s.best_s
        else:
            return float("inf")
        return float((current - targets[distance]) / targets[distance])

    goal = max(targets, key=gap)
    goal_m = STANDARD_DISTANCES[goal]
    goal_target = targets[goal]
    goal_gap = gap(goal)
    target_pace = goal_target / (goal_m / 1000.0)

    prev_kind: str | None = None
    if previous_note is not None:
        nxt = previous_note.payload.get("next")
        if isinstance(nxt, dict) and isinstance(nxt.get("kind"), str):
            prev_kind = nxt["kind"]

    kind: RunKind
    if prev_kind == "easy":
        km = _half_up(min(goal_m / 1000.0, 5.0) * 0.8)
        pace = int(round(target_pace + 5))
        kind = "tempo"
        detail = f"Tempo {km:g} km at {_fmt_pace(pace)}."
        why = f"Quality work moves you toward your {DISTANCE_LABELS[goal]} target."
    else:
        km = _half_up(goal_m / 1000.0 * 0.8)
        pace = int(round(target_pace + 60))
        kind = "easy"
        detail = f"Easy {km:g} km at {_fmt_pace(pace)}."
        why = "Easy volume builds the base your target needs."
    pace = max(pace, int(round(target_pace - 10)))
    next_run = NextRun(km=km, pace=pace, kind=kind, detail=detail, why=why)

    goal_stats = stats.get(goal)
    n4w = goal_stats.count_4w if goal_stats else 0
    if goal_gap <= 0.03:
        runs_per_week = 3
        note = (
            f"You've run {DISTANCE_LABELS[goal]} {_count_word(n4w)} in 4 weeks; "
            "aim for 3 runs a week."
        )
    else:
        runs_per_week = 4
        extra = "; add one easy run" if goal_gap > 0.08 else ""
        note = (
            f"You've run {DISTANCE_LABELS[goal]} {_count_word(n4w)} in 4 weeks; "
            f"aim for 4 runs a week{extra}."
        )
    frequency = Frequency(runs_per_week=runs_per_week, note=note)

    feedback = _feedback(pacing, run, primary, stats, recent_best)
    return CoachOutput(feedback=feedback, pacing=pacing, next=next_run, frequency=frequency)


def _feedback(
    pacing: str,
    run: Run,
    primary: str | None,
    stats: dict[str, DistanceStats],
    recent_best: float | None,
) -> str:
    """One sentence from pacing plus one comparing the effort to pb or recent form."""
    pacing_sentence = {
        "even": "You paced this run evenly.",
        "positive": "You faded slightly through the second half.",
        "negative": "You finished faster than you started.",
        "erratic": "Your pace jumped around between kilometres.",
    }[pacing]
    compare = "Keep logging runs and I will track the trend."
    if primary and primary in run.efforts:
        effort = run.efforts[primary]
        label = DISTANCE_LABELS[primary]
        s = stats.get(primary)
        if s is not None and s.best_s is not None and effort <= s.best_s:
            compare = f"That {_fmt_time(effort)} {label} is your best yet."
        elif recent_best is not None and effort <= recent_best:
            compare = f"That {_fmt_time(effort)} {label} is your fastest in recent weeks."
        elif recent_best is not None:
            compare = (
                f"The {_fmt_time(effort)} {label} effort was "
                f"{fmt_dur(effort - recent_best)} off your recent best of {_fmt_time(recent_best)}."
            )
    return f"{pacing_sentence} {compare}"


@dataclass
class LLMResult:
    """Assistant text plus provider usage telemetry."""

    text: str
    prompt_tokens: int | None
    completion_tokens: int | None
    cost_usd: float | None
    generation_id: str | None
    request_id: str | None = None


def _capture_generation(
    run: Run,
    system: str,
    packet: str,
    latency_ms: int,
    *,
    result: LLMResult | None = None,
    error: str | None = None,
) -> None:
    """Capture one OpenRouter request as an AI Observability generation."""
    posthog_client = get_posthog_client()
    if posthog_client is None:
        return

    properties: dict[str, Any] = {
        "$ai_trace_id": str(run.id),
        "$ai_session_id": None,
        "$ai_span_name": "coach_completion",
        "$ai_model": config.LLM_MODEL,
        "$ai_provider": "openrouter",
        "$ai_latency": latency_ms / 1000,
        "$ai_request_url": config.OPENROUTER_URL,
        "$ai_temperature": config.LLM_TEMPERATURE,
        "$ai_max_tokens": config.LLM_MAX_TOKENS,
        "$ai_input": [
            {"role": "system", "content": system},
            {"role": "user", "content": packet},
        ],
    }
    if result is None:
        properties["$ai_is_error"] = True
        properties["$ai_error"] = error
    else:
        properties["$ai_output_choices"] = [{"role": "assistant", "content": result.text}]
        if result.prompt_tokens is not None:
            properties["$ai_input_tokens"] = result.prompt_tokens
        if result.completion_tokens is not None:
            properties["$ai_output_tokens"] = result.completion_tokens
        if result.cost_usd is not None:
            properties["$ai_total_cost_usd"] = result.cost_usd
            properties["$ai_cost_passthrough"] = True

    posthog_client.capture(
        "$ai_generation", distinct_id=str(run.user_id).upper(), properties=properties
    )


class LLMClient(Protocol):
    """Minimal async client interface so tests can inject a fake."""

    async def complete(self, system: str, user: str) -> LLMResult:
        """Return the assistant result for the packet."""
        ...


class OpenRouterClient:
    """OpenAI-compatible chat completions via OpenRouter or Mubit."""

    def __init__(
        self,
        api_key: str,
        model: str,
        http: httpx.AsyncClient | None = None,
        url: str | None = None,
    ) -> None:
        self._api_key = api_key
        self._model = model
        self._http = http
        self._url = url or config.OPENROUTER_URL

    async def complete(self, system: str, user: str) -> LLMResult:
        if self._http is not None:
            return await self._complete(self._http, system, user)
        async with httpx.AsyncClient(timeout=config.LLM_TIMEOUT_S) as client:
            return await self._complete(client, system, user)

    async def _complete(self, http: httpx.AsyncClient, system: str, user: str) -> LLMResult:
        resp = await http.post(
            self._url,
            headers={
                "Authorization": f"Bearer {self._api_key}",
                "X-OpenRouter-Title": "Jogga",
            },
            json=request_body(self._model, system, user),
        )
        if resp.status_code >= 400:
            raise RuntimeError(f"OpenRouter {resp.status_code}: {resp.text[:300]}")
        body = resp.json()
        choice = body["choices"][0]
        content: Any = choice["message"]["content"]
        if not isinstance(content, str):
            if choice.get("finish_reason") == "length":
                raise ValueError("OpenRouter response hit max_tokens before any content")
            raise ValueError("OpenRouter response content is not a string")
        usage = body.get("usage") or {}
        generation_id = body.get("id")
        cost = usage.get("cost")
        return LLMResult(
            text=content,
            prompt_tokens=usage.get("prompt_tokens"),
            completion_tokens=usage.get("completion_tokens"),
            cost_usd=float(cost) if isinstance(cost, int | float) else None,
            generation_id=generation_id if isinstance(generation_id, str) else None,
            request_id=resp.headers.get("x-middleware-request-id"),
        )


def request_body(model: str, system: str, user: str) -> dict[str, Any]:
    """Chat-completions body: structured outputs, strict providers, usage."""
    body: dict[str, Any] = {
        "model": model,
        "max_tokens": config.LLM_MAX_TOKENS,
        "temperature": config.LLM_TEMPERATURE,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "response_format": {"type": "json_schema", "json_schema": load_response_schema()},
        "provider": {"require_parameters": True},
        "usage": {"include": True},
    }
    if config.LLM_REASONING == "off":
        body["reasoning"] = {"enabled": False}
    elif config.LLM_REASONING == "on":
        body["reasoning"] = {"enabled": True}
    return body


def _clean_text(s: str) -> str:
    """No em dashes in user-facing text: fold them into commas."""
    s = re.sub(r"\s*—\s*", ", ", s)
    s = re.sub(r",\s*,", ",", s)
    s = re.sub(r",([.!])", r"\1", s)
    return s


def parse_coach_output(text: str, pacing: Pacing) -> CoachOutput:
    """Extract, validate and normalise the structured LLM response.

    The pacing label is server-computed from the splits and passed in.
    """
    start = text.find("{")
    end = text.rfind("}")
    if start < 0 or end <= start:
        raise ValueError("no JSON object in response")
    llm = LLMCoachOutput.model_validate(json.loads(text[start : end + 1]))
    pace = parse_pace(llm.next.pace)
    if not 120 <= pace <= 1200:
        raise ValueError(f"pace {pace} s/km out of range")
    if not 0 < llm.next.km <= 50:
        raise ValueError(f"km {llm.next.km} out of range")
    went_well = _clean_text(llm.went_well)
    work_on = _clean_text(llm.work_on)
    result = _clean_text(llm.result)
    return CoachOutput(
        feedback=f"{went_well.strip()} {work_on.strip()} {result.strip()}".strip(),
        pacing=pacing,
        next=NextRun(
            km=llm.next.km,
            pace=pace,
            kind=llm.next.kind,
            detail=_clean_text(llm.next.detail),
            why=_clean_text(llm.next.why),
        ),
        frequency=Frequency(
            runs_per_week=max(1, min(7, llm.frequency.runs_per_week)),
            note=_clean_text(llm.frequency.note),
        ),
        went_well=went_well,
        work_on=work_on,
        result=result,
    )


async def coach_run(
    db: AsyncSession,
    run: Run,
    *,
    llm_client: LLMClient | None = None,
) -> CoachNote:
    """Run the coach for a run and store the note. LLM -> heuristic on any failure."""
    previous = await db.scalar(
        select(CoachNote)
        .where(CoachNote.user_id == run.user_id, CoachNote.run_id != run.id)
        .order_by(CoachNote.created_at.desc())
        .limit(1)
    )

    if llm_client is None:
        if config.MUBIT_API_KEY:
            llm_client = OpenRouterClient(
                config.MUBIT_API_KEY, config.LLM_MODEL, url=config.MUBIT_URL
            )
        elif config.OPENROUTER_API_KEY:
            llm_client = OpenRouterClient(config.OPENROUTER_API_KEY, config.LLM_MODEL)

    output: CoachOutput | None = None
    source = "heuristic"
    model: str | None = None
    packet: str | None = None
    error: str | None = None
    latency_ms: int | None = None
    prompt_tokens: int | None = None
    completion_tokens: int | None = None
    cost_usd: float | None = None
    generation_id: str | None = None
    if llm_client is not None:
        packet = await build_packet(db, run)
        system = load_system_prompt()
        started = time.monotonic()
        deadline = started + config.LLM_TOTAL_TIMEOUT_S
        for attempt in range(1, config.LLM_ATTEMPTS + 1):
            attempt_started = time.monotonic()
            result: LLMResult | None = None
            try:
                result = await asyncio.wait_for(
                    llm_client.complete(system, packet),
                    timeout=min(config.LLM_TIMEOUT_S, deadline - time.monotonic()),
                )
                attempt_latency_ms = int(round((time.monotonic() - attempt_started) * 1000))
                _capture_generation(run, system, packet, attempt_latency_ms, result=result)
                parsed_output = parse_coach_output(
                    result.text, SHAPE_TO_PACING[run_shape(run.splits)]
                )
            except Exception as exc:
                attempt_latency_ms = int(round((time.monotonic() - attempt_started) * 1000))
                error = f"{type(exc).__name__}: {exc}"[:500]
                if result is None:
                    _capture_generation(run, system, packet, attempt_latency_ms, error=error)
                logger.warning(
                    "coach llm failed run=%s attempt=%d/%d: %s",
                    run.id,
                    attempt,
                    config.LLM_ATTEMPTS,
                    error,
                    exc_info=True,
                )
                if (
                    attempt >= config.LLM_ATTEMPTS
                    or deadline - time.monotonic() < config.LLM_MIN_RETRY_S
                ):
                    break
                continue

            output = parsed_output
            source = "llm"
            error = None
            model = config.LLM_MODEL
            prompt_tokens = result.prompt_tokens
            completion_tokens = result.completion_tokens
            cost_usd = result.cost_usd
            generation_id = result.generation_id
            latency_ms = int(round((time.monotonic() - started) * 1000))
            logger.info(
                "coach llm ok run=%s model=%s tokens=%s/%s cost=$%.4f latency=%dms "
                "gen=%s mubit=%s",
                run.id,
                model,
                prompt_tokens,
                completion_tokens,
                cost_usd or 0.0,
                latency_ms,
                generation_id,
                result.request_id,
            )
            break
        if latency_ms is None and error is not None:
            latency_ms = int(round((time.monotonic() - started) * 1000))
    elif not config.MUBIT_API_KEY and not config.OPENROUTER_API_KEY:
        error = "malformed api key" if config.OPENROUTER_KEY_MALFORMED else "no api key"

    existing = await db.get(CoachNote, run.id)
    if output is None and existing is not None and existing.source == "llm":
        logger.warning("coach llm failed run=%s; keeping the existing llm note", run.id)
        return existing
    if output is None:
        output = await heuristic_coach(db, run, previous_note=previous)

    if existing is not None:
        await db.delete(existing)
        await db.flush()
    note = CoachNote(
        run_id=run.id,
        user_id=run.user_id,
        source=source,
        model=model,
        payload=output.model_dump(),
        prompt_tokens=prompt_tokens,
        completion_tokens=completion_tokens,
        cost_usd=cost_usd,
        latency_ms=latency_ms,
        generation_id=generation_id,
        error=error,
        packet=packet,
    )
    db.add(note)
    await db.flush()
    return note
