"""Validates the Entra JWT when EPP_REQUIRE_AUTH=true (aud/issuer/JWKS, RS256).
No-op pass-through otherwise — Easy Auth is the primary gate; this is the backstop."""
import os

import jwt
from jwt import PyJWKClient

_jwks_clients = {}


def _jwks_client(tenant_id):
    client = _jwks_clients.get(tenant_id)
    if client is None:
        client = PyJWKClient(f"https://login.microsoftonline.com/{tenant_id}/discovery/v2.0/keys")
        _jwks_clients[tenant_id] = client
    return client


def validate_token(authorization_header):
    """Returns (ok, reason, caller_object_id)."""
    if (os.environ.get("EPP_REQUIRE_AUTH") or "").lower() != "true":
        return True, None, None

    audience = os.environ.get("EPP_EXPECTED_AUDIENCE")
    tenant_id = os.environ.get("EPP_TENANT_ID")
    if not audience or not tenant_id:
        return False, "auth misconfigured", None

    if not authorization_header or not authorization_header.lower().startswith("bearer "):
        return False, "missing bearer token", None

    token = authorization_header[len("bearer "):].strip()
    try:
        signing_key = _jwks_client(tenant_id).get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            audience=audience,
            options={"verify_iss": False},
        )
        allowed_issuers = (
            (os.environ.get("EPP_EXPECTED_ISSUER"),)
            if os.environ.get("EPP_EXPECTED_ISSUER")
            else (
                f"https://login.microsoftonline.com/{tenant_id}/v2.0",
                f"https://sts.windows.net/{tenant_id}/",
            )
        )
        if claims.get("iss") not in allowed_issuers:
            return False, "token validation failed", None

        # azp is the v2 caller claim, appid the v1 one.
        expected_client_id = os.environ.get("EPP_EXPECTED_CLIENT_ID")
        if expected_client_id and (claims.get("azp") or claims.get("appid")) != expected_client_id:
            return False, "unexpected caller", None

        return True, None, claims.get("oid")
    except Exception:
        return False, "token validation failed", None
