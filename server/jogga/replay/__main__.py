"""python -m jogga.replay --export DIR --coach {heuristic,openrouter,mubit} --out DIR

Replays a Strava export into a throwaway database, oldest run first, as if each run had
just been logged in the app (mode "free": nobody was following a Jogga plan). After each
insert the coach runs exactly as in production, so it only ever sees earlier runs.
"""

import argparse
import asyncio
import json
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
from .grade import grade
from .strava import load_export

DEFAULT_DB = "postgresql+asyncpg://localhost:5432/jogga_replay"


def _client(coach: str) -> LLMClient | None:
    if coach == "mubit":
        if not config.MUBIT_API_KEY:
            raise SystemExit("MUBIT_API_KEY is not set")
        return OpenRouterClient(config.MUBIT_API_KEY, config.LLM_MODEL, url=config.MUBIT_URL)
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
    summary = _summary(rows, previous["export"], previous["coach"])
    summary["model"] = previous["model"]
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary["checks"], indent=2))


async def replay(args: argparse.Namespace) -> None:
    runs, counts = load_export(args.export)
    if args.limit:
        runs = runs[: args.limit]
    client = _client(args.coach)
    await _ensure_db(args.db)
    engine = create_async_engine(args.db)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)
    factory = async_sessionmaker(engine, expire_on_commit=False)

    args.out.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, Any]] = []
    async with factory() as db:
        user = User(display_name="Replay runner")
        db.add(user)
        await db.flush()
        for distance, seconds in args.target:
            db.add(Target(user_id=user.id, distance=distance, target_s=seconds))
        await db.commit()

        for i, r in enumerate(runs):
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
            note = await coach_run(db, run, llm_client=client)
            await db.commit()
            payload: dict[str, Any] = dict(note.payload)
            checks = grade(packet, payload, note.source)
            row: dict[str, Any] = {
                "i": i,
                "external_id": r.external_id,
                "date": r.started_at.isoformat(),
                "km": round(r.distance_m / 1000.0, 2),
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
            rows.append(row)
            failed = [k for k, v in checks.items() if v is False]
            print(
                f"[{i + 1}/{len(runs)}] {r.started_at.date()} {row['km']:>5} km "
                f"{note.source:<9} {payload['next']['kind']:<9} "
                f"{'ok' if not failed else 'FAIL ' + ','.join(failed)}",
                flush=True,
            )
    await engine.dispose()

    with (args.out / "notes.jsonl").open("w") as f:
        for row in rows:
            f.write(json.dumps(row) + "\n")
    summary = _summary(rows, counts, args.coach)
    (args.out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


def _summary(rows: list[dict[str, Any]], counts: dict[str, int], coach: str) -> dict[str, Any]:
    tally: dict[str, list[int]] = defaultdict(lambda: [0, 0])
    for row in rows:
        for k, v in row["checks"].items():
            if v is not None:
                tally[k][0] += int(v)
                tally[k][1] += 1
    latencies = [r["latency_ms"] for r in rows if r["source"] == "llm" and r["latency_ms"]]
    return {
        "coach": coach,
        "model": config.LLM_MODEL if coach != "heuristic" else None,
        "export": counts,
        "notes": len(rows),
        "checks": {k: {"pass": p, "of": n, "rate": round(p / n, 3)} for k, (p, n) in tally.items()},
        "llm_latency_ms_median": sorted(latencies)[len(latencies) // 2] if latencies else None,
        "cost_usd": round(sum(r["cost_usd"] or 0.0 for r in rows), 4),
    }


def main() -> None:
    p = argparse.ArgumentParser(prog="python -m jogga.replay")
    p.add_argument("--export", type=Path, help="unzipped Strava export folder")
    p.add_argument("--coach", choices=["heuristic", "openrouter", "mubit"], default="heuristic")
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--db", default=DEFAULT_DB, help="throwaway database (dropped and recreated)")
    p.add_argument("--limit", type=int, default=0, help="only the first N runs")
    p.add_argument("--target", type=_target, action="append", default=[], help="e.g. 5k=25:00")
    p.add_argument("--regrade", action="store_true", help="re-grade --out without coaching")
    args = p.parse_args()
    if args.regrade:
        regrade(args.out)
    elif args.export is None:
        p.error("--export is required unless --regrade")
    else:
        asyncio.run(replay(args))


main()
