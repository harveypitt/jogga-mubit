"""Jogga FastAPI application."""

import logging
import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import timedelta
from typing import Annotated

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse
from sqlalchemy import delete, func, select, tuple_
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from . import config
from .auth import (
    create_session,
    current_user,
    hash_token,
    user_for_apple_sub,
    verify_apple_identity_token,
)
from .coach import coach_run
from .db import get_session
from .models import CoachNote, Run, Session, Target, User
from .posthog import get_posthog_client, initialize_posthog
from .schemas import (
    STANDARD_DISTANCES,
    AuthIn,
    CoachNoteOut,
    CoachOutput,
    DevAuthIn,
    ImportSource,
    RunImportIn,
    RunImportOut,
    RunIn,
    RunOut,
    Split,
    TargetIn,
    UserOut,
)
from .stats import distance_stats

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
logger = logging.getLogger(__name__)

# An imported run this close to a recorded one is the same run logged twice.
IMPORT_MATCH_WINDOW = timedelta(minutes=3)
IMPORT_MATCH_DISTANCE = 0.05


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    if config.OPENROUTER_KEY_MALFORMED:
        logger.error("OPENROUTER_API_KEY is set but malformed; LLM coach disabled")
    elif not config.OPENROUTER_API_KEY:
        logger.warning("OPENROUTER_API_KEY not set; heuristic coach only")
    else:
        logger.info("LLM coach: %s", config.LLM_MODEL)
    if config.LLM_REASONING_INVALID:
        logger.warning("invalid JOGGA_LLM_REASONING (want on|off); reasoning unset")
    posthog_client = initialize_posthog()
    try:
        yield
    finally:
        if posthog_client is not None:
            posthog_client.flush()  # type: ignore[no-untyped-call]


app = FastAPI(title="Jogga", lifespan=lifespan)

DB = Annotated[AsyncSession, Depends(get_session)]
Authed = Annotated[User, Depends(current_user)]


@app.exception_handler(Exception)
async def capture_unhandled_exception(_: Request, exc: Exception) -> JSONResponse:
    """Send uncaught application exceptions to PostHog before returning a 500."""
    posthog_client = get_posthog_client()
    if posthog_client is not None:
        posthog_client.capture_exception(exc)
    return JSONResponse(status_code=500, content={"detail": "Internal Server Error"})


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/auth/apple")
async def auth_apple(body: AuthIn, db: DB) -> dict[str, object]:
    try:
        sub = await verify_apple_identity_token(body.identity_token)
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=401, detail="invalid identity token") from exc
    user = await user_for_apple_sub(db, sub, body.name)
    token = await create_session(db, user)
    await db.commit()
    return {"token": token, "user": UserOut.model_validate(user)}


@app.post("/auth/dev")
async def auth_dev(body: DevAuthIn, db: DB) -> dict[str, object]:
    if not config.DEV_AUTH:
        raise HTTPException(status_code=404, detail="not found")
    user = User(display_name=body.name)
    db.add(user)
    await db.flush()
    token = await create_session(db, user)
    await db.commit()
    return {"token": token, "user": UserOut.model_validate(user)}


@app.get("/me")
async def me(user: Authed, db: DB) -> dict[str, object]:
    rows = (
        await db.execute(select(Target.distance, Target.target_s).where(Target.user_id == user.id))
    ).all()
    stats = await distance_stats(db, user.id)
    return {
        "user": UserOut.model_validate(user),
        "targets": {distance: target_s for distance, target_s in rows},
        "stats": {k: v.model_dump() for k, v in stats.items()},
    }


@app.put("/targets/{distance}")
async def put_target(distance: str, body: TargetIn, user: Authed, db: DB) -> dict[str, int]:
    if distance not in STANDARD_DISTANCES:
        raise HTTPException(status_code=422, detail="unknown distance")
    stmt = (
        insert(Target)
        .values(user_id=user.id, distance=distance, target_s=body.target_s)
        .on_conflict_do_update(
            index_elements=["user_id", "distance"], set_={"target_s": body.target_s}
        )
    )
    await db.execute(stmt)
    await db.commit()
    return {"target_s": body.target_s}


@app.delete("/targets/{distance}")
async def delete_target(distance: str, user: Authed, db: DB) -> dict[str, bool]:
    await db.execute(delete(Target).where(Target.user_id == user.id, Target.distance == distance))
    await db.commit()
    return {"deleted": True}


def _run_out(run: Run) -> RunOut:
    return RunOut(
        id=run.id,
        started_at=run.started_at,
        distance_m=run.distance_m,
        moving_s=run.moving_s,
        elapsed_s=run.elapsed_s,
        gain_m=run.gain_m,
        loss_m=run.loss_m,
        splits=[Split.model_validate(s) for s in run.splits],
        efforts=run.efforts,
        source=run.source,
        mode=run.mode,
        external_id=run.external_id,
    )


def _note_out(note: CoachNote | None) -> CoachNoteOut | None:
    if note is None:
        return None
    return CoachNoteOut(
        source=note.source,
        model=note.model,
        payload=CoachOutput.model_validate(note.payload),
        created_at=note.created_at,
    )


@app.post("/runs")
async def post_run(body: RunIn, user: Authed, db: DB) -> dict[str, object]:
    values = {
        "id": body.id,
        "user_id": user.id,
        "started_at": body.started_at,
        "distance_m": body.distance_m,
        "moving_s": body.moving_s,
        "elapsed_s": body.elapsed_s,
        "gain_m": body.gain_m,
        "loss_m": body.loss_m,
        "splits": [s.model_dump() for s in body.splits],
        "efforts": body.efforts,
        "mode": body.mode,
    }
    update = {k: v for k, v in values.items() if k not in ("id", "user_id")}
    stmt = insert(Run).values(**values)
    update_columns = tuple_(*(getattr(Run, key) for key in update))
    excluded_columns = tuple_(*(getattr(stmt.excluded, key) for key in update))
    result = await db.execute(
        stmt.on_conflict_do_update(
            index_elements=["id"],
            set_=update,
            where=(Run.user_id == user.id) & update_columns.is_distinct_from(excluded_columns),
        ).returning(Run.id)
    )
    changed = result.scalar_one_or_none() is not None
    run = await db.scalar(select(Run).where(Run.id == body.id, Run.user_id == user.id))
    if run is None:
        raise HTTPException(status_code=409, detail="run id belongs to another user")
    if not changed:
        existing = await db.get(CoachNote, run.id)
        if existing is not None and existing.source == "llm":
            await db.commit()
            return {"run": _run_out(run), "coach": _note_out(existing)}
    note = await coach_run(db, run)
    await db.commit()
    return {"run": _run_out(run), "coach": _note_out(note)}


@app.post("/runs/import")
async def import_runs(body: RunImportIn, user: Authed, db: DB) -> RunImportOut:
    """Store imported history without coaching it. Idempotent per external id."""
    external_ids = [r.external_id for r in body.runs]
    existing: dict[str, uuid.UUID] = {
        ext: rid
        for ext, rid in (
            await db.execute(
                select(Run.external_id, Run.id).where(
                    Run.user_id == user.id,
                    Run.source == body.source,
                    Run.external_id.in_(external_ids),
                )
            )
        ).all()
        if ext is not None
    }
    recorded = (
        await db.execute(
            select(Run.started_at, Run.distance_m).where(
                Run.user_id == user.id, Run.source == "jogga"
            )
        )
    ).all()
    taken = set(await db.scalars(select(Run.id).where(Run.id.in_([r.id for r in body.runs]))))

    ids: dict[str, uuid.UUID] = {}
    skipped: list[str] = []
    imported = 0
    for r in body.runs:
        if r.external_id in existing:
            ids[r.external_id] = existing[r.external_id]
            continue
        if r.external_id in ids or r.external_id in skipped:
            continue
        if any(
            abs(started - r.started_at) <= IMPORT_MATCH_WINDOW
            and abs(distance - r.distance_m) <= IMPORT_MATCH_DISTANCE * max(distance, r.distance_m)
            for started, distance in recorded
        ):
            skipped.append(r.external_id)
            continue
        run_id = r.id if r.id not in taken else uuid.uuid4()
        taken.add(run_id)
        db.add(
            Run(
                id=run_id,
                user_id=user.id,
                started_at=r.started_at,
                distance_m=r.distance_m,
                moving_s=r.moving_s,
                elapsed_s=r.elapsed_s,
                gain_m=r.gain_m,
                loss_m=r.loss_m,
                splits=[s.model_dump() for s in r.splits],
                efforts=r.efforts,
                source=body.source,
                external_id=r.external_id,
            )
        )
        ids[r.external_id] = run_id
        imported += 1
    await db.commit()
    return RunImportOut(imported=imported, ids=ids, skipped=skipped)


@app.delete("/runs")
async def delete_imported_runs(source: ImportSource, user: Authed, db: DB) -> dict[str, int]:
    result = await db.execute(delete(Run).where(Run.user_id == user.id, Run.source == source))
    await db.commit()
    return {"deleted": result.rowcount or 0}


@app.get("/runs")
async def list_runs(user: Authed, db: DB, limit: int = 50) -> list[RunOut]:
    runs = (
        await db.scalars(
            select(Run).where(Run.user_id == user.id).order_by(Run.started_at.desc()).limit(limit)
        )
    ).all()
    return [_run_out(r) for r in runs]


@app.get("/runs/{run_id}")
async def get_run(run_id: uuid.UUID, user: Authed, db: DB) -> dict[str, object]:
    run = await db.scalar(select(Run).where(Run.id == run_id, Run.user_id == user.id))
    if run is None:
        raise HTTPException(status_code=404, detail="run not found")
    note = await db.scalar(select(CoachNote).where(CoachNote.run_id == run.id))
    return {"run": _run_out(run), "coach": _note_out(note)}


@app.delete("/runs/{run_id}")
async def delete_run(run_id: uuid.UUID, user: Authed, db: DB) -> dict[str, bool]:
    # Idempotent on purpose: client retries always see 200.
    result = await db.execute(delete(Run).where(Run.id == run_id, Run.user_id == user.id))
    await db.commit()
    return {"deleted": (result.rowcount or 0) > 0}


@app.get("/coach/latest")
async def coach_latest(user: Authed, db: DB) -> CoachNoteOut | None:
    note = await db.scalar(
        select(CoachNote)
        .where(CoachNote.user_id == user.id)
        .order_by(CoachNote.created_at.desc())
        .limit(1)
    )
    return _note_out(note)


@app.post("/coach/replan")
async def coach_replan(user: Authed, db: DB) -> CoachNoteOut | None:
    """Re-coach the latest run so the next-run plan reflects newly imported history.

    At most one LLM call per import: once the latest run's note is newer than
    the newest imported run, the existing note is returned as is.
    """
    run = await db.scalar(
        select(Run)
        .where(Run.user_id == user.id)
        .order_by(Run.started_at.desc(), Run.id.desc())
        .limit(1)
    )
    if run is None:
        return None
    note = await db.get(CoachNote, run.id)
    newest_import = await db.scalar(
        select(func.max(Run.created_at)).where(Run.user_id == user.id, Run.source != "jogga")
    )
    if note is not None and (newest_import is None or note.created_at >= newest_import):
        return _note_out(note)
    note = await coach_run(db, run)
    await db.commit()
    await db.refresh(note)
    return _note_out(note)


@app.delete("/auth/session")
async def sign_out(
    db: DB,
    user: Authed,
    authorization: Annotated[str | None, Header()] = None,
) -> dict[str, bool]:
    if authorization:
        token = authorization.removeprefix("Bearer ").strip()
        await db.execute(delete(Session).where(Session.token_hash == hash_token(token)))
        await db.commit()
    return {"deleted": True}
