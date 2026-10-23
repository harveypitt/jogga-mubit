"""coach_notes: LLM telemetry columns.

Revision ID: 0002_coach_telemetry
Revises: 0001_initial
Create Date: 2026-09-30
"""

import sqlalchemy as sa
from alembic import op

revision: str = "0002_coach_telemetry"
down_revision: str = "0001_initial"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("coach_notes", sa.Column("prompt_tokens", sa.Integer(), nullable=True))
    op.add_column("coach_notes", sa.Column("completion_tokens", sa.Integer(), nullable=True))
    op.add_column("coach_notes", sa.Column("cost_usd", sa.Float(), nullable=True))
    op.add_column("coach_notes", sa.Column("latency_ms", sa.Integer(), nullable=True))
    op.add_column("coach_notes", sa.Column("generation_id", sa.Text(), nullable=True))
    op.add_column("coach_notes", sa.Column("error", sa.Text(), nullable=True))
    op.add_column("coach_notes", sa.Column("packet", sa.Text(), nullable=True))


def downgrade() -> None:
    op.drop_column("coach_notes", "packet")
    op.drop_column("coach_notes", "error")
    op.drop_column("coach_notes", "generation_id")
    op.drop_column("coach_notes", "latency_ms")
    op.drop_column("coach_notes", "cost_usd")
    op.drop_column("coach_notes", "completion_tokens")
    op.drop_column("coach_notes", "prompt_tokens")
