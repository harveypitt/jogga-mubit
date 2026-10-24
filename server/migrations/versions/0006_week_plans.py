"""week plans

Revision ID: 0006_week_plans
Revises: 0005_report_cards
Create Date: 2026-10-24
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0006_week_plans"
down_revision: str | None = "0005_report_cards"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "week_plans",
        sa.Column(
            "user_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column("week_start", sa.Date(), primary_key=True),
        sa.Column("tz", sa.Text(), nullable=False),
        sa.Column("sessions", postgresql.JSONB(), nullable=False),
        sa.Column("original_count", sa.Integer(), nullable=False),
        sa.Column("note", sa.Text(), nullable=True),
        sa.Column("change", sa.Text(), nullable=True),
        sa.Column("source", sa.Text(), nullable=False),
        sa.Column("model", sa.Text(), nullable=True),
        sa.Column("packet", sa.Text(), nullable=True),
        sa.Column("error", sa.Text(), nullable=True),
        sa.Column("history", postgresql.JSONB(), server_default="[]", nullable=False),
        sa.Column("needs_replan", sa.Boolean(), server_default="false", nullable=False),
        sa.Column("replanned_on", sa.Date(), nullable=True),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
    )


def downgrade() -> None:
    op.drop_table("week_plans")
