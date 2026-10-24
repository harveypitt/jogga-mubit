"""Selection and parsing helpers for Endomondo workout exports."""

import argparse
import ast
import json
import random
import statistics
from collections import defaultdict
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from .strava import ReplayRun, route_run

ENDO_PAUSE_GAP_S = 30.0
SEED = 20261023
MIN_INDEX_WORKOUTS = 40
CANDIDATE_COUNT = 30
MIN_VALID_WORKOUTS = 30
MAX_WORKOUTS_PER_RUNNER = 40
QUALIFYING_RUNNERS = 20
HOLDOUT_RUNNERS = 4


def workout_run(d: dict[str, Any]) -> ReplayRun | None:
    points: list[tuple[float, float, float | None, datetime | None]] = [
        (
            float(lat),
            float(lon),
            float(altitude) if altitude is not None else None,
            datetime.fromtimestamp(float(timestamp), UTC),
        )
        for timestamp, lat, lon, altitude in zip(
            d["timestamp"],
            d["latitude"],
            d["longitude"],
            d["altitude"],
            strict=True,
        )
    ]
    run = route_run(f"endo:{d['id']}", None, points, pause_gap_s=ENDO_PAUSE_GAP_S)
    if run is None or run.distance_m < 1000:
        return None
    pace = run.moving_s / (run.distance_m / 1000)
    if not 150 <= pace <= 900:
        return None
    return run


def read_workout(data_path: Path, off: int, length: int) -> dict[str, Any]:
    with data_path.open("rb") as data_file:
        data_file.seek(off)
        workout = ast.literal_eval(data_file.read(length).decode("utf-8"))
    if not isinstance(workout, dict):
        raise ValueError("workout line is not a dictionary")
    return workout


def _build_selection(data_path: Path, index_path: Path) -> tuple[dict[str, Any], dict[str, int]]:
    grouped: defaultdict[Any, list[dict[str, Any]]] = defaultdict(list)
    with index_path.open(encoding="utf-8") as index_file:
        for line in index_file:
            if line.strip():
                row = json.loads(line)
                grouped[row["u"]].append(row)

    eligible = sorted(user for user, rows in grouped.items() if len(rows) >= MIN_INDEX_WORKOUTS)
    candidates = random.Random(SEED).sample(eligible, CANDIDATE_COUNT)
    runners: list[dict[str, Any]] = []
    diagnostics = {"candidate_workouts": 0, "valid_workouts": 0, "rejected_workouts": 0}

    for user in candidates:
        valid: list[tuple[ReplayRun, dict[str, Any]]] = []
        for row in grouped[user]:
            diagnostics["candidate_workouts"] += 1
            run = workout_run(read_workout(data_path, row["off"], row["len"]))
            if run is None:
                diagnostics["rejected_workouts"] += 1
                continue
            diagnostics["valid_workouts"] += 1
            valid.append((run, row))
        valid.sort(key=lambda item: item[0].started_at)
        selected = valid[-MAX_WORKOUTS_PER_RUNNER:]
        if len(selected) < MIN_VALID_WORKOUTS:
            continue
        split = "holdout" if len(runners) < HOLDOUT_RUNNERS else "train"
        runners.append(
            {
                "user": user,
                "split": split,
                "workouts": [
                    {"id": row["id"], "off": row["off"], "len": row["len"]} for _, row in selected
                ],
            }
        )
        if len(runners) >= QUALIFYING_RUNNERS:
            break

    return {"seed": SEED, "pause_gap_s": ENDO_PAUSE_GAP_S, "runners": runners}, diagnostics


def select_runners(data_path: Path, index_path: Path) -> dict[str, Any]:
    selection, _ = _build_selection(data_path, index_path)
    return selection


def load_runner(data_path: Path, runner: dict[str, Any]) -> list[ReplayRun]:
    runs = [
        run
        for workout in runner["workouts"]
        if (run := workout_run(read_workout(data_path, workout["off"], workout["len"]))) is not None
    ]
    runs.sort(key=lambda run: run.started_at)
    return runs


def main() -> None:
    parser = argparse.ArgumentParser(prog="python -m jogga.replay.endomondo")
    parser.add_argument("--data", type=Path, required=True, help="Endomondo dict-literal data file")
    parser.add_argument("--index", type=Path, required=True, help="Endomondo run index")
    parser.add_argument("--out", type=Path, required=True, help="selection JSON output")
    args = parser.parse_args()

    selection, diagnostics = _build_selection(args.data, args.index)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(selection, indent=2) + "\n", encoding="utf-8")
    print(
        "candidate_workouts="
        f"{diagnostics['candidate_workouts']} valid={diagnostics['valid_workouts']} "
        f"rejected={diagnostics['rejected_workouts']}"
    )
    for runner in selection["runners"]:
        runs = load_runner(args.data, runner)
        km = [run.distance_m / 1000 for run in runs]
        pace = [run.moving_s / (run.distance_m / 1000) for run in runs]
        date_range = f"{runs[0].started_at.date()}..{runs[-1].started_at.date()}"
        print(
            f"{runner['split']} user={runner['user']} runs={len(runs)} "
            f"km_median={statistics.median(km):.2f} "
            f"pace_median_s_per_km={statistics.median(pace):.1f} "
            f"dates={date_range}"
        )
    print(f"selection={args.out}")


if __name__ == "__main__":
    main()
