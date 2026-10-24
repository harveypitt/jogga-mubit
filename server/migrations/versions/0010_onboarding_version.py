"""runner profile onboarding version

Revision ID: 0010_onboarding_version
Revises: 0009_profile_blocker
Create Date: 2026-10-24
"""

import sqlalchemy as sa
from alembic import op

revision: str = "0010_onboarding_version"
down_revision: str | None = "0009_profile_blocker"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "runner_profiles",
        sa.Column("onboarding_version", sa.Integer(), server_default="1", nullable=False),
    )


def downgrade() -> None:
    op.drop_column("runner_profiles", "onboarding_version")
