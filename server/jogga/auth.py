"""Session auth and Sign in with Apple token verification."""

import asyncio
import hashlib
import secrets
import uuid
from collections.abc import AsyncIterator
from typing import Annotated

import jwt
from fastapi import Depends, Header, HTTPException
from jwt import PyJWKClient
from posthog import identify_context
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from . import config
from .db import get_session
from .models import Session, User
from .posthog import get_posthog_client

APPLE_KEYS_URL = "https://appleid.apple.com/auth/keys"
APPLE_ISSUER = "https://appleid.apple.com"

jwks_client = PyJWKClient(APPLE_KEYS_URL, cache_keys=True)


def hash_token(token: str) -> str:
    """Sha256 hex digest of a bearer token."""
    return hashlib.sha256(token.encode()).hexdigest()


async def create_session(db: AsyncSession, user: User) -> str:
    """Create an opaque bearer token for a user."""
    token = secrets.token_urlsafe(32)
    db.add(Session(token_hash=hash_token(token), user_id=user.id))
    await db.flush()
    return token


async def current_user(
    db: Annotated[AsyncSession, Depends(get_session)],
    authorization: Annotated[str | None, Header()] = None,
) -> AsyncIterator[User]:
    """Resolve the bearer token and bind its user to the request context."""
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    token_hash = hash_token(authorization.removeprefix("Bearer ").strip())
    user_id = await db.scalar(select(Session.user_id).where(Session.token_hash == token_hash))
    if user_id is None:
        raise HTTPException(status_code=401, detail="invalid token")
    user = await db.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=401, detail="invalid token")

    posthog_client = get_posthog_client()
    if posthog_client is None:
        yield user
        return

    with posthog_client.new_context(fresh=True):  # type: ignore[no-untyped-call]
        identify_context(str(user.id))
        yield user


def _verify_apple_identity_token(identity_token: str) -> str:
    """Blocking verification against Apple's (cached) JWKS; return the subject."""
    key = jwks_client.get_signing_key_from_jwt(identity_token).key
    claims = jwt.decode(
        identity_token,
        key,
        algorithms=["RS256"],
        audience=config.APPLE_BUNDLE_ID,
        issuer=APPLE_ISSUER,
    )
    sub = claims.get("sub")
    if not isinstance(sub, str) or not sub:
        raise HTTPException(status_code=401, detail="identity token has no subject")
    return sub


async def verify_apple_identity_token(identity_token: str) -> str:
    """Verify an Apple identity token off the event loop."""
    return await asyncio.to_thread(_verify_apple_identity_token, identity_token)


async def user_for_apple_sub(db: AsyncSession, sub: str, name: str | None) -> User:
    """Find or create the user for an Apple subject."""
    user = await db.scalar(select(User).where(User.apple_sub == sub))
    if user is None:
        user = User(id=uuid.uuid4(), apple_sub=sub, display_name=name)
        db.add(user)
        await db.flush()
    elif name and user.display_name != name:
        user.display_name = name
    return user
