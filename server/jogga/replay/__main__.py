"""python -m jogga.replay --export DIR --coach {heuristic,openrouter,mubit,mubit-norecord} --out DIR

Replays a Strava export into a throwaway database, oldest run first, as if each run had
just been logged in the app (mode "free": nobody was following a Jogga plan). After each
insert the coach runs exactly as in production, so it only ever sees earlier runs.
"""

import argparse
import asyncio
import json
import statistics
import uuid
from collections import defaultdict
from pathlib import Path
from typing import Any

from sqlalchemy import text
from sqlalchemy.engine import make_url
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from .. import config
from ..coach import LLMClient, OpenRouterClient, coach_run
from ..fitness import parse_pace
from ..models import Base, Run, Target, User
from ..packet import build_packet
from ..schemas import STANDARD_DISTANCES
from .endomondo import load_runner
from .grade import grade
from .strava import ReplayRun, load_export

DEFAULT_DB = "postgresql+asyncpg://localhost:5432/jogga_replay"


def _client(coach: str) -> LLMClient | None:
    if coach == "mubit":
        if not config.MUBIT_API_KEY:
            raise SystemExit("MUBIT_API_KEY is not set")
        return OpenRouterClient(config.MUBIT_API_KEY, config.LLM_MODEL, url=config.MUBIT_URL)
    if coach == "mubit-norecord":
        if not config.MUBIT_API_KEY:
            raise SystemExit("MUBIT_API_KEY is not set")
        return OpenRouterClient(
            config.MUBIT_API_KEY,
            config.LLM_MODEL,
            url=config.MUBIT_URL,
            extra_headers={"x-middleware-record": "off"},
        )
    if coach == "openrouter":
        if not config.OPENROUTER_API_KEY:
            raise SystemExit("OPENROUTER_API_KEY is not set")
        return OpenRouterClient(config.OPENROUTER_API_KEY, config.LLM_MODEL)
    config.MUBIT_API_KEY = None
    config.OPENROUTER_API_KEY = None
    return None


def _target(spec: str) -> tuple[str, int]:
    distance, _, t = spec.partition("=")
    if distance not in STANDARD_DISTANCES:
        raise argparse.ArgumentTypeError(f"unknown distance {distance!r}")
    parts = [int(x) for x in t.split(":")]
    seconds = parts[0] * 3600 + parts[1] * 60 + parts[2] if len(parts) == 3 else parse_pace(t)
    return distance, seconds


async def _ensure_db(url: str) -> None:
    u = make_url(url)
    admin = create_async_engine(u.set(database="postgres"), isolation_level="AUTOCOMMIT")
    async with admin.connect() as conn:
        exists = await conn.scalar(
            text("SELECT 1 FROM pg_database WHERE datname = :n"), {"n": u.database}
        )
        if not exists:
            await conn.execute(text(f'CREATE DATABASE "{u.database}"'))
    await admin.dispose()


def regrade(out: Path) -> None:
    """Re-grade saved notes without calling the coach again."""
    rows = [json.loads(line) for line in (out / "notes.jsonl").read_text().splitlines()]
    previous = json.loads((out / "summary.json").read_text())
    for row in rows:
        row["checks"] = grade(json.dumps(row["packet"]), row["note"], row["source"])
    with (out / "notes.jsonl").open("w") as f:
        for row in rows:
            f.write(json.dumps(row) + "\n")
    multi_runner = "by_split" in previous or any("runner" in row for row in rows)
    summary = _summary(
        rows,
        previous["export"],
        previous["coach"],
        multi_runner=multi_runner,
        holdout_coach=previous.get("holdout_coach"),
    )
    summary["model"] = previous["model"]
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary["checks"], indent=2))


async def replay(args: argparse.Namespace) -> None:
    multi_runner = args.endomondo is not None
    if multi_runner:
        selection = json.loads(args.endomondo.read_text(encoding="utf-8"))
        runner_specs: list[dict[str, Any]] = []
        for runner in selection["runners"]:
            runs = load_runner(args.data, runner)
            if args.limit > 0:
                runs = runs[: args.limit]
            runner_specs.append(
                {
                    "user": runner["user"],
                    "split": runner["split"],
                    "runs": runs,
                    "coach": args.holdout_coach if runner["split"] == "holdout" else args.coach,
                }
            )
        counts = {
            "runners": len(runner_specs),
            "workouts": sum(len(runner["runs"]) for runner in runner_specs),
        }
        coach_names = {runner["coach"] for runner in runner_specs}
        clients: dict[str, LLMClient | None] = {}
        for name in ("mubit", "mubit-norecord", "openrouter"):
            if name in coach_names:
                clients[name] = _client(name)
        if "heuristic" in coach_names:
            _client("heuristic")
            clients["heuristic"] = None
        for runner in runner_specs:
            runner["client"] = clients[runner["coach"]]
    else:
        runs, counts = load_export(args.export)
        if args.limit:
            runs = runs[: args.limit]
        runner_specs = [{"user": None, "split": None, "runs": runs, "coach": args.coach}]
        runner_specs[0]["client"] = _client(args.coach)

    await _ensure_db(args.db)
    engine = create_async_engine(args.db)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)
    factory = async_sessionmaker(engine, expire_on_commit=False)

    args.out.mkdir(parents=True, exist_ok=True)

    semaphore = asyncio.Semaphore(args.concurrency if multi_runner else 1)

    async def replay_runner(spec: dict[str, Any]) -> list[dict[str, Any]]:
        async with semaphore:
            async with factory() as db:
                display_name = f"Endomondo {spec['user']}" if multi_runner else "Replay runner"
                user = User(display_name=display_name)
                db.add(user)
                await db.flush()
                for distance, seconds in args.target:
                    db.add(Target(user_id=user.id, distance=distance, target_s=seconds))
                await db.commit()

                rows_for_runner: list[dict[str, Any]] = []
                runner_runs: list[ReplayRun] = spec["runs"]
                for i, r in enumerate(runner_runs):
                    run = Run(
                        id=uuid.uuid4(),
                        user_id=user.id,
                        started_at=r.started_at,
                        distance_m=r.distance_m,
                        moving_s=r.moving_s,
                        elapsed_s=r.elapsed_s,
                        gain_m=r.gain_m,
                        loss_m=r.loss_m,
                        splits=r.splits,
                        efforts=r.efforts,
                        source="jogga",
                        mode="free",
                        external_id=r.external_id,
                    )
                    db.add(run)
                    await db.flush()
                    packet = await build_packet(db, run)
                    note = await coach_run(db, run, llm_client=spec["client"])
                    await db.commit()
                    payload: dict[str, Any] = dict(note.payload)
                    checks = grade(packet, payload, note.source)
                    row: dict[str, Any] = {
                        "i": i,
                        "external_id": r.external_id,
                        "date": r.started_at.isoformat(),
                        "km": round(r.distance_m / 1000.0, 2),
                        "pace_s": round(r.moving_s / (r.distance_m / 1000.0), 1),
                        "from_route": r.from_route,
                        "source": note.source,
                        "model": note.model,
                        "latency_ms": note.latency_ms,
                        "cost_usd": note.cost_usd,
                        "error": note.error,
                        "checks": checks,
                        "note": payload,
                        "packet": json.loads(packet),
                    }
                    if multi_runner:
                        row["runner"] = spec["user"]
                        row["split"] = spec["split"]
                    rows_for_runner.append(row)
                    failed = [k for k, v in checks.items() if v is False]
                    if multi_runner:
                        print(
                            f"[{i + 1}/{len(runner_runs)}] runner={spec['user']} "
                            f"{r.started_at.date()} {row['km']:>5} km "
                            f"{note.source:<9} {payload['next']['kind']:<9} "
                            f"{'ok' if not failed else 'FAIL ' + ','.join(failed)}",
                            flush=True,
                        )
                    else:
                        print(
                            f"[{i + 1}/{len(runner_runs)}] {r.started_at.date()} "
                            f"{row['km']:>5} km {note.source:<9} {payload['next']['kind']:<9} "
                            f"{'ok' if not failed else 'FAIL ' + ','.join(failed)}",
                            flush=True,
                        )
                return rows_for_runner

    rows_by_runner = await asyncio.gather(*(replay_runner(spec) for spec in runner_specs))
    rows = [row for runner_rows in rows_by_runner for row in runner_rows]
    await engine.dispose()

    if multi_runner:
        rows.sort(key=lambda row: (row["runner"], row["i"]))
    with (args.out / "notes.jsonl").open("w") as f:
        for row in rows:
            f.write(json.dumps(row) + "\n")
    summary = _summary(
        rows,
        counts,
        args.coach,
        multi_runner=multi_runner,
        holdout_coach=args.holdout_coach if multi_runner else None,
    )
    (args.out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


def _check_rates(rows: list[dict[str, Any]]) -> dict[str, dict[str, float | int]]:
    tally: dict[str, list[int]] = defaultdict(lambda: [0, 0])
    for row in rows:
        for k, v in row["checks"].items():
            if v is not None:
                tally[k][0] += int(v)
                tally[k][1] += 1
    return {k: {"pass": p, "of": n, "rate": round(p / n, 3)} for k, (p, n) in tally.items()}


def _summary(
    rows: list[dict[str, Any]],
    counts: dict[str, Any],
    coach: str,
    *,
    multi_runner: bool = False,
    holdout_coach: str | None = None,
) -> dict[str, Any]:
    model_used = coach != "heuristic" or (multi_runner and holdout_coach != "heuristic")
    summary_forecast = _forecast_scores(rows)
    latencies = [r["latency_ms"] for r in rows if r["source"] == "llm" and r["latency_ms"]]
    summary: dict[str, Any] = {
        "coach": coach,
        "model": config.LLM_MODEL if model_used else None,
        "export": counts,
        "notes": len(rows),
        "checks": _check_rates(rows),
        "forecast": summary_forecast,
        "llm_latency_ms_median": sorted(latencies)[len(latencies) // 2] if latencies else None,
        "cost_usd": round(sum(r["cost_usd"] or 0.0 for r in rows), 4),
    }
    if multi_runner:
        by_split: dict[str, Any] = {}
        for split, split_coach in (("train", coach), ("holdout", holdout_coach)):
            split_rows = [row for row in rows if row["split"] == split]
            by_split[split] = {
                "coach": split_coach,
                "notes": len(split_rows),
                "checks": _check_rates(split_rows),
                "forecast": _forecast_scores(split_rows),
                "cost_usd": round(sum(row["cost_usd"] or 0.0 for row in split_rows), 4),
            }
        runner_notes: defaultdict[str, int] = defaultdict(int)
        for row in rows:
            runner_notes[str(row["runner"])] += 1
        summary["holdout_coach"] = holdout_coach
        summary["by_split"] = by_split
        summary["runners"] = dict(sorted(runner_notes.items()))
    return summary


def _forecast_scores(rows: list[dict[str, Any]]) -> dict[str, Any] | None:
    """Mean absolute error of each forecast against the run actually logged next.

    The coach's own forecast is compared with two baselines that need no model:
    repeat the last run, and the median of the last five runs.
    """
    groups: defaultdict[Any, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        groups[row.get("runner")].append(row)
    errors: dict[str, dict[str, list[float]]] = defaultdict(lambda: {"km": [], "pace_s": []})
    for group in groups.values():
        for i, row in enumerate(group[:-1]):
            actual = group[i + 1]
            fc = row["note"].get("forecast")
            if not fc or "pace_s" not in actual:
                continue
            history = group[max(0, i - 4) : i + 1]
            guesses = {
                "coach": (fc["km"], fc["pace"]),
                "last_run": (row["km"], row["pace_s"]),
                "median_last_5": (
                    statistics.median(h["km"] for h in history),
                    statistics.median(h["pace_s"] for h in history),
                ),
            }
            for name, (km, pace) in guesses.items():
                errors[name]["km"].append(abs(km - actual["km"]))
                errors[name]["pace_s"].append(abs(pace - actual["pace_s"]))
    if not errors:
        return None
    return {
        "n": len(errors["coach"]["km"]),
        "mae": {
            name: {k: round(statistics.mean(v), 2) for k, v in e.items()}
            for name, e in errors.items()
        },
    }


def main() -> None:
    p = argparse.ArgumentParser(prog="python -m jogga.replay")
    source = p.add_mutually_exclusive_group()
    source.add_argument("--export", type=Path, help="unzipped Strava export folder")
    source.add_argument("--endomondo", type=Path, help="Endomondo runner selection JSON")
    p.add_argument(
        "--data",
        type=Path,
        default=Path.home() / "endomondo" / "endomondoHR_proper.json",
        help="Endomondo dict-literal data file",
    )
    p.add_argument(
        "--coach",
        choices=["heuristic", "openrouter", "mubit", "mubit-norecord"],
        default="heuristic",
    )
    p.add_argument(
        "--holdout-coach",
        choices=["heuristic", "openrouter", "mubit", "mubit-norecord"],
        default="mubit-norecord",
        help="coach used for holdout Endomondo runners",
    )
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--db", default=DEFAULT_DB, help="throwaway database (dropped and recreated)")
    p.add_argument("--limit", type=int, default=0, help="only the first N runs")
    p.add_argument("--concurrency", type=int, default=4, help="maximum concurrent runners")
    p.add_argument("--target", type=_target, action="append", default=[], help="e.g. 5k=25:00")
    p.add_argument("--regrade", action="store_true", help="re-grade --out without coaching")
    args = p.parse_args()
    if args.regrade:
        regrade(args.out)
    elif args.export is None and args.endomondo is None:
        p.error("--export or --endomondo is required unless --regrade")
    elif args.concurrency < 1:
        p.error("--concurrency must be at least 1")
    else:
        asyncio.run(replay(args))


if __name__ == "__main__":
    main()
