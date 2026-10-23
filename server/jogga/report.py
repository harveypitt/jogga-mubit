"""Recent coach-note telemetry. Run as `python -m jogga.report [--limit N]`."""

import argparse
import asyncio

from sqlalchemy import select

from .db import SessionFactory
from .models import CoachNote


async def _report(limit: int) -> None:
    async with SessionFactory() as db:
        notes = (
            await db.scalars(select(CoachNote).order_by(CoachNote.created_at.desc()).limit(limit))
        ).all()

    llm_count = 0
    heuristic_count = 0
    costs: list[float] = []
    for note in notes:
        tokens = (
            f"{note.prompt_tokens}/{note.completion_tokens}"
            if note.prompt_tokens is not None
            else "-"
        )
        cost = f"${note.cost_usd:.4f}" if note.cost_usd is not None else "-"
        latency = f"{note.latency_ms}ms" if note.latency_ms is not None else "-"
        error = note.error or "-"
        print(
            f"{note.created_at:%Y-%m-%d %H:%M} {str(note.run_id)[:8]} {note.source:<9} "
            f"{note.model or '-'} tok={tokens} cost={cost} lat={latency} err={error}"
        )
        if note.source == "llm":
            llm_count += 1
            if note.cost_usd is not None:
                costs.append(note.cost_usd)
        else:
            heuristic_count += 1

    total = sum(costs)
    mean = total / len(costs) if costs else 0.0
    print(
        f"totals: llm={llm_count} heuristic={heuristic_count} "
        f"cost=${total:.4f} mean=${mean:.4f}/llm"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Recent coach-note telemetry")
    parser.add_argument("--limit", type=int, default=20)
    args = parser.parse_args()
    asyncio.run(_report(args.limit))


if __name__ == "__main__":
    main()
