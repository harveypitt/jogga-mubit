"""runs: source + external_id for imported history.

Revision ID: 0003_run_source
Revises: 0002_coach_telemetry
Create Date: 2026-10-02
"""

import sqlalchemy as sa
from alembic import op

revision: str = "0003_run_source"
down_revision: str = "0002_coach_telemetry"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("runs", sa.Column("source", sa.Text(), nullable=False, server_default="jogga"))
    op.add_column("runs", sa.Column("external_id", sa.Text(), nullable=True))
    op.create_index(
        "runs_user_source_external",
        "runs",
        ["user_id", "source", "external_id"],
        unique=True,
    )


def downgrade() -> None:
    op.drop_index("runs_user_source_external", table_name="runs")
    op.drop_column("runs", "external_id")
    op.drop_column("runs", "source")
