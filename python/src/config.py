import os


def read_config(env=None):
    env = os.environ if env is None else env
    return {
        "expected_audience": (env.get("EPP_EXPECTED_AUDIENCE") or "").strip(),
        "expected_client_id": (env.get("EPP_EXPECTED_CLIENT_ID") or "").strip(),
        "expected_issuer": (env.get("EPP_EXPECTED_ISSUER") or "").strip(),
        "tenant_id": (env.get("EPP_TENANT_ID") or "").strip(),
        "require_auth": (env.get("EPP_REQUIRE_AUTH") or "").strip().lower() == "true",
        "decryption_key_pem": env.get("EPP_DECRYPTION_KEY_PEM") or "",
        "expected_key_id": env.get("EPP_ENCRYPTION_KEY_ID"),
        "provider_name": (env.get("EPP_PROVIDER_NAME") or "").strip().lower(),
        "provider_endpoint": env.get("EPP_PROVIDER_ENDPOINT"),
        "provider_timeout_ms": env.get("EPP_PROVIDER_TIMEOUT_MS"),
        "env": env,  # Preserve raw adapter settings and the injected environment.
    }