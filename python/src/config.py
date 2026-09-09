import os


def read_config(env=None):
    env = os.environ if env is None else env
    return {
        "decryption_key_pem": env.get("EPP_DECRYPTION_KEY_PEM") or "",
        "expected_key_id": env.get("EPP_ENCRYPTION_KEY_ID"),
        "provider_name": (env.get("EPP_PROVIDER_NAME") or "").strip().lower(),
        "provider_endpoint": env.get("EPP_PROVIDER_ENDPOINT"),
        "provider_timeout_ms": env.get("EPP_PROVIDER_TIMEOUT_MS"),
        "env": env,  # Preserve raw adapter settings and the injected environment.
    }