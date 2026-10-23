"""Runtime configuration from environment variables."""

import os
import re
from typing import Literal
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit


def db_url(raw: str, driver: Literal["asyncpg", "psycopg2"]) -> str:
    """Normalise a libpq-style URL for the given SQLAlchemy driver.

    Accepts postgres://, postgresql:// and postgresql+<driver>:// schemes and
    maps the SSL query param: libpq's ``sslmode`` -> asyncpg's ``ssl`` or
    vice versa. Other params, credentials and host/port/db are preserved.
    """
    parts = urlsplit(raw)
    query = parse_qsl(parts.query, keep_blank_values=True)
    if driver == "asyncpg":
        query = [("ssl" if key == "sslmode" else key, value) for key, value in query]
    else:
        query = [("sslmode" if key == "ssl" else key, value) for key, value in query]
    return urlunsplit(parts._replace(scheme=f"postgresql+{driver}", query=urlencode(query)))


DATABASE_URL = db_url(
    os.environ.get("DATABASE_URL", "postgresql://localhost:5432/jogga"), "asyncpg"
)
APPLE_BUNDLE_ID = os.environ.get("JOGGA_APPLE_BUNDLE_ID", "co.aliveindustries.jogga")
DEV_AUTH = os.environ.get("JOGGA_DEV_AUTH") == "1"
POSTHOG_PROJECT_TOKEN = os.environ.get("POSTHOG_PROJECT_TOKEN") or None
POSTHOG_HOST = os.environ.get("POSTHOG_HOST", "https://eu.i.posthog.com")
_OPENROUTER_KEY_RE = re.compile(r"^sk-or-[A-Za-z0-9-]+$")
_raw_openrouter_key = os.environ.get("OPENROUTER_API_KEY")
OPENROUTER_API_KEY = _raw_openrouter_key.strip() if _raw_openrouter_key else None
# Set-but-broken key (whitespace tolerated, anything else disables the LLM so
# we fall back instead of 401ing on every request). Never log the value.
if OPENROUTER_API_KEY:
    OPENROUTER_KEY_MALFORMED = _OPENROUTER_KEY_RE.match(OPENROUTER_API_KEY) is None
    if OPENROUTER_KEY_MALFORMED:
        OPENROUTER_API_KEY = None
else:
    OPENROUTER_KEY_MALFORMED = False

OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
MUBIT_API_KEY = (os.environ.get("MUBIT_API_KEY") or "").strip() or None
MUBIT_URL = os.environ.get("JOGGA_MUBIT_URL") or (
    "https://api.mubit.ai/compat/openrouter/v1/chat/completions"
)
LLM_MODEL = os.environ.get("JOGGA_LLM_MODEL", "deepseek/deepseek-v4.1-flash")
LLM_MAX_TOKENS = int(os.environ.get("JOGGA_LLM_MAX_TOKENS") or 20000)
_raw_reasoning = (os.environ.get("JOGGA_LLM_REASONING") or "").strip().lower()
# Unrecognised values are ignored (flagged so main.py can warn at startup).
LLM_REASONING_INVALID = _raw_reasoning not in ("", "on", "off")
LLM_REASONING = "" if LLM_REASONING_INVALID else _raw_reasoning
LLM_TIMEOUT_S = float(os.environ.get("JOGGA_LLM_TIMEOUT_S") or 40)
LLM_TOTAL_TIMEOUT_S = float(os.environ.get("JOGGA_LLM_TOTAL_TIMEOUT_S") or 50)
LLM_ATTEMPTS = int(os.environ.get("JOGGA_LLM_ATTEMPTS") or 2)
LLM_MIN_RETRY_S = 10.0
LLM_TEMPERATURE = float(os.environ.get("JOGGA_LLM_TEMPERATURE") or 0.2)
