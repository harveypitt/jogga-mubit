"""run intent mode

Revision ID: 0004_run_mode
Revises: 0003_run_source
Create Date: 2026-10-16
"""

import sqlalchemy as sa
from alembic import op

revision: str = "0004_run_mode"
down_revision: str | None = "0003_run_source"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("runs", sa.Column("mode", sa.Text(), nullable=True))


def downgrade() -> None:
    op.drop_column("runs", "mode")
