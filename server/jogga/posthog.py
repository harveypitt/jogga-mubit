"""PostHog client configuration for the FastAPI application."""

import atexit

from posthog import Posthog

from . import config

posthog_client: Posthog | None = None


def initialize_posthog() -> Posthog | None:
    """Construct the process-wide PostHog client when it is configured."""
    global posthog_client

    if not config.POSTHOG_PROJECT_TOKEN:
        return None

    if posthog_client is None:
        posthog_client = Posthog(
            project_api_key=config.POSTHOG_PROJECT_TOKEN,
            host=config.POSTHOG_HOST,
            enable_exception_autocapture=True,
        )
        atexit.register(posthog_client.shutdown)
    return posthog_client


def get_posthog_client() -> Posthog | None:
    """Return the shared PostHog client initialized during application startup."""
    return posthog_client
