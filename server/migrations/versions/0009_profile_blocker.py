"""runner profile blocker and attribution

Revision ID: 0009_profile_blocker
Revises: 0008_runner_profiles
Create Date: 2026-10-24
"""

import sqlalchemy as sa
from alembic import op

revision: str = "0009_profile_blocker"
down_revision: str | None = "0008_runner_profiles"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("runner_profiles", sa.Column("blocker", sa.Text(), nullable=True))
    op.add_column("runner_profiles", sa.Column("heard_from", sa.Text(), nullable=True))


def downgrade() -> None:
    op.drop_column("runner_profiles", "heard_from")
    op.drop_column("runner_profiles", "blocker")
