"""runner profiles (onboarding)

Revision ID: 0008_runner_profiles
Revises: 0007_run_surveys
Create Date: 2026-10-25
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0008_runner_profiles"
down_revision: str | None = "0007_run_surveys"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "runner_profiles",
        sa.Column(
            "user_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column("goal", sa.Text(), nullable=True),
        sa.Column("race_date", sa.Date(), nullable=True),
        sa.Column("days", postgresql.JSONB(), server_default="[]", nullable=False),
        sa.Column("runs_per_week", sa.Integer(), nullable=True),
        sa.Column("experience", sa.Text(), nullable=True),
        sa.Column("usual_week_km", sa.Float(), nullable=True),
        sa.Column("dislikes", postgresql.JSONB(), server_default="[]", nullable=False),
        sa.Column("niggles", sa.Text(), nullable=True),
        sa.Column("consent", sa.Boolean(), server_default="false", nullable=False),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
    )


def downgrade() -> None:
    op.drop_table("runner_profiles")
