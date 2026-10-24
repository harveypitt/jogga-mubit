"""SQLAlchemy models for the Jogga schema."""

import uuid
from datetime import date, datetime

from sqlalchemy import Boolean, Date, DateTime, Float, ForeignKey, Index, Integer, Text, func
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    """Declarative base."""


class User(Base):
    """A signed-in runner."""

    __tablename__ = "users"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    apple_sub: Mapped[str | None] = mapped_column(Text, unique=True)
    display_name: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class Session(Base):
    """Opaque bearer token, stored as a sha256 hash."""

    __tablename__ = "sessions"

    token_hash: Mapped[str] = mapped_column(Text, primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE")
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class Target(Base):
    """A user's goal time for a standard distance."""

    __tablename__ = "targets"

    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    distance: Mapped[str] = mapped_column(Text, primary_key=True)
    target_s: Mapped[int] = mapped_column(Integer)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class Run(Base):
    """A recorded or imported run, upserted by its client-generated id."""

    __tablename__ = "runs"
    __table_args__ = (
        Index("runs_user_started", "user_id", "started_at"),
        Index("runs_user_source_external", "user_id", "source", "external_id", unique=True),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE")
    )
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    distance_m: Mapped[float] = mapped_column(Float)
    moving_s: Mapped[float] = mapped_column(Float)
    elapsed_s: Mapped[float] = mapped_column(Float)
    gain_m: Mapped[float] = mapped_column(Float)
    loss_m: Mapped[float] = mapped_column(Float)
    splits: Mapped[list[dict[str, float]]] = mapped_column(JSONB)
    efforts: Mapped[dict[str, float]] = mapped_column(JSONB)
    # "jogga" for runs recorded in the app; "strava" for imported history.
    source: Mapped[str] = mapped_column(Text, server_default="jogga")
    mode: Mapped[str | None] = mapped_column(Text, nullable=True)
    # IANA zone of the device that uploaded the run; weeks are bucketed in it.
    tz: Mapped[str | None] = mapped_column(Text, nullable=True)
    external_id: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class CoachNote(Base):
    """Coach output for a run, either LLM- or heuristic-sourced."""

    __tablename__ = "coach_notes"

    run_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("runs.id", ondelete="CASCADE"), primary_key=True
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE")
    )
    source: Mapped[str] = mapped_column(Text)
    model: Mapped[str | None] = mapped_column(Text)
    payload: Mapped[dict[str, object]] = mapped_column(JSONB)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    # LLM telemetry (null for heuristic-only paths).
    prompt_tokens: Mapped[int | None] = mapped_column(Integer)
    completion_tokens: Mapped[int | None] = mapped_column(Integer)
    cost_usd: Mapped[float | None] = mapped_column(Float)
    latency_ms: Mapped[int | None] = mapped_column(Integer)
    generation_id: Mapped[str | None] = mapped_column(Text)
    error: Mapped[str | None] = mapped_column(Text)
    packet: Mapped[str | None] = mapped_column(Text)


class ReportCard(Base):
    """Weekly report card: server-computed grades plus, once closed, an LLM summary."""

    __tablename__ = "report_cards"

    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    week_start: Mapped[date] = mapped_column(Date, primary_key=True)
    tz: Mapped[str] = mapped_column(Text)
    # "live" while the week is running, "closed" once it has ended.
    status: Mapped[str] = mapped_column(Text)
    grades: Mapped[dict[str, object]] = mapped_column(JSONB)
    summary: Mapped[dict[str, object] | None] = mapped_column(JSONB)
    model: Mapped[str | None] = mapped_column(Text)
    source: Mapped[str | None] = mapped_column(Text)
    # Internal only (experiments, Mubit evals); never shown to the runner.
    composite: Mapped[float | None] = mapped_column(Float)
    packet: Mapped[str | None] = mapped_column(Text)
    error: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )
    closed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class WeekPlan(Base):
    """This week's planned sessions: written by the planner LLM, checked by the server."""

    __tablename__ = "week_plans"

    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    week_start: Mapped[date] = mapped_column(Date, primary_key=True)
    tz: Mapped[str] = mapped_column(Text)
    # [{id, date, kind, km, pace, detail, why, status, run_id, moved_from}], by date.
    sessions: Mapped[list[dict[str, object]]] = mapped_column(JSONB)
    # Sessions in the week's first plan; Consistency grades against this, never a cut-down replan.
    original_count: Mapped[int] = mapped_column(Integer)
    note: Mapped[str | None] = mapped_column(Text)
    change: Mapped[str | None] = mapped_column(Text)
    source: Mapped[str] = mapped_column(Text)
    model: Mapped[str | None] = mapped_column(Text)
    packet: Mapped[str | None] = mapped_column(Text)
    error: Mapped[str | None] = mapped_column(Text)
    # Earlier versions of ``sessions`` with why they were replaced.
    history: Mapped[list[dict[str, object]]] = mapped_column(JSONB, server_default="[]")
    needs_replan: Mapped[bool] = mapped_column(Boolean, server_default="false")
    replanned_on: Mapped[date | None] = mapped_column(Date)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class RunSurvey(Base):
    """How a run felt, from the post-run check-in. Health data: never sent to analytics."""

    __tablename__ = "run_surveys"

    run_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("runs.id", ondelete="CASCADE"), primary_key=True
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    difficulty: Mapped[str | None] = mapped_column(Text)
    coaching: Mapped[str | None] = mapped_column(Text)
    injury: Mapped[bool] = mapped_column(Boolean, server_default="false")
    injury_area: Mapped[str | None] = mapped_column(Text)
    injury_severity: Mapped[str | None] = mapped_column(Text)
    notes: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class RunnerProfile(Base):
    """Onboarding answers: goal, when they can run and what to avoid. The planner treats
    days, runs a week and dislikes as hard rules."""

    __tablename__ = "runner_profiles"

    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    goal: Mapped[str | None] = mapped_column(Text)
    race_date: Mapped[date | None] = mapped_column(Date)
    # Weekdays they can run, 0 = Monday.
    days: Mapped[list[int]] = mapped_column(JSONB, server_default="[]")
    runs_per_week: Mapped[int | None] = mapped_column(Integer)
    experience: Mapped[str | None] = mapped_column(Text)
    usual_week_km: Mapped[float | None] = mapped_column(Float)
    dislikes: Mapped[list[str]] = mapped_column(JSONB, server_default="[]")
    niggles: Mapped[str | None] = mapped_column(Text)
    # What usually stops them running; sets the planner's tone.
    blocker: Mapped[str | None] = mapped_column(Text)
    heard_from: Mapped[str | None] = mapped_column(Text)
    consent: Mapped[bool] = mapped_column(Boolean, server_default="false")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )
