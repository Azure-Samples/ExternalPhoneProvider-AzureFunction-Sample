import jwt
from jwt import PyJWKClient

from .config import read_config

_jwks_clients = {}


def _jwks_client(tenant_id):
    client = _jwks_clients.get(tenant_id)
    if client is None:
        client = PyJWKClient(f"https://login.microsoftonline.com/{tenant_id}/discovery/v2.0/keys")
        _jwks_clients[tenant_id] = client
    return client


def validate_token(authorization_header, config=None):
    config = read_config() if config is None else config
    require_auth = config["require_auth"]
    expected_client_id = config["expected_client_id"]
    env = config["env"]
    on_azure = bool(env.get("WEBSITE_INSTANCE_ID") or env.get("WEBSITE_HOSTNAME")
                    or env.get("WEBSITE_SITE_NAME"))
    if on_azure and (not require_auth or not (expected_client_id or "").strip()):
        return False, "auth misconfigured", None
    if not require_auth:
        return True, None, None

    audience = config["expected_audience"]
    tenant_id = config["tenant_id"]
    if not audience or not tenant_id:
        return False, "auth misconfigured", None

    if not authorization_header or not authorization_header.lower().startswith("bearer "):
        return False, "missing bearer token", None

    token = authorization_header[len("bearer "):].strip()
    if not token:
        return False, "missing bearer token", None
    try:
        signing_key = _jwks_client(tenant_id).get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            audience=audience,
            options={"verify_iss": False, "require": ["exp"]},
        )
        allowed_issuers = (
            (config["expected_issuer"],)
            if config["expected_issuer"]
            else (
                f"https://login.microsoftonline.com/{tenant_id}/v2.0",
                f"https://sts.windows.net/{tenant_id}/",
            )
        )
        if claims.get("iss") not in allowed_issuers:
            return False, "token validation failed", None

        # azp is the v2 caller claim, appid the v1 one.
        caller_id = claims.get("azp") or claims.get("appid")
        if expected_client_id:
            if not isinstance(caller_id, str) or caller_id.lower() != expected_client_id.lower():
                return False, "unexpected caller", None

        return True, None, claims.get("oid")
    except Exception:
        return False, "token validation failed", None
