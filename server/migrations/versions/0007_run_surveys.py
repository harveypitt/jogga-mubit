"""run surveys

Revision ID: 0007_run_surveys
Revises: 0006_week_plans
Create Date: 2026-10-24
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0007_run_surveys"
down_revision: str | None = "0006_week_plans"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "run_surveys",
        sa.Column(
            "run_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("runs.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column(
            "user_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("difficulty", sa.Text(), nullable=True),
        sa.Column("coaching", sa.Text(), nullable=True),
        sa.Column("injury", sa.Boolean(), server_default="false", nullable=False),
        sa.Column("injury_area", sa.Text(), nullable=True),
        sa.Column("injury_severity", sa.Text(), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
    )
    op.create_index("ix_run_surveys_user_id", "run_surveys", ["user_id"])


def downgrade() -> None:
    op.drop_index("ix_run_surveys_user_id", table_name="run_surveys")
    op.drop_table("run_surveys")
