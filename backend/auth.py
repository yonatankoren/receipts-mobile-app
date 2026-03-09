"""
Google access-token authentication for FastAPI.

Verifies the OAuth2 access token that the Flutter app sends in the
Authorization header by calling Google's tokeninfo endpoint.

This works reliably with Android Google Sign-In without requiring
any extra configuration (serverClientId, etc.).
"""

import logging
from typing import Optional

import requests
from fastapi import Header, HTTPException

logger = logging.getLogger(__name__)


def verify_access_token(token: str) -> dict:
    """
    Verify a Google OAuth2 access token via Google's tokeninfo endpoint.

    Returns the token payload (including 'email') on success.
    Raises ValueError on any verification failure.
    """
    resp = requests.get(
        "https://oauth2.googleapis.com/tokeninfo",
        params={"access_token": token},
        timeout=5,
    )

    if resp.status_code != 200:
        raise ValueError(f"Token verification failed (HTTP {resp.status_code})")

    payload = resp.json()

    # Ensure the token has an email — confirms it's a real user token
    if not payload.get("email"):
        raise ValueError("Token has no associated email")

    return payload


async def require_auth(
    authorization: Optional[str] = Header(default=None),
) -> str:
    """
    FastAPI dependency — extracts and verifies the Bearer token.

    Returns the authenticated user's email address (for logging / traceability).
    Raises HTTP 401 if the token is missing or invalid.
    """
    if not authorization:
        raise HTTPException(status_code=401, detail="Missing Authorization header")

    parts = authorization.split(" ", 1)
    if len(parts) != 2 or parts[0].lower() != "bearer":
        raise HTTPException(
            status_code=401,
            detail="Authorization header must be: Bearer <token>",
        )

    token = parts[1]

    try:
        payload = verify_access_token(token)
    except (ValueError, Exception) as e:
        logger.warning(f"Auth: token verification failed — {e}")
        raise HTTPException(status_code=401, detail=f"Invalid token: {e}")

    email = payload.get("email", "unknown")
    logger.info(f"Auth: verified user {email}")
    return email
