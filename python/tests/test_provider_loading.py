import os
import shutil
import subprocess
import sys
from pathlib import Path
from unittest.mock import Mock

import pytest

import src.dispatch as dispatch_module
from src.dispatch import ProviderRegistry


def test_explicit_registry_keeps_injected_adapters_without_loading(monkeypatch):
    load = Mock(side_effect=AssertionError("default loader must not run"))
    monkeypatch.setattr(dispatch_module, "load_provider", load)
    adapter = Mock(manifest={"id": "Custom"})
    registry = ProviderRegistry([adapter])
    assert registry.get("CUSTOM") is adapter
    assert registry.get(None) is None
    assert registry.get("soprano") is None
    assert ProviderRegistry([]).get("soprano") is None
    load.assert_not_called()


# A fresh interpreter cannot reuse adapters imported by the other test modules.
_PROBE = """
import io
import json
import logging
import os
import socket
import sys
from pathlib import Path
from unittest.mock import Mock, call

import azure.functions as func
import requests
from jwcrypto import jwe, jwk

socket.socket.connect = Mock(side_effect=AssertionError("network forbidden"))
socket.getaddrinfo = Mock(side_effect=AssertionError("network forbidden"))
logs = io.StringIO()
logging.basicConfig(stream=logs, level=logging.INFO)
selected, available = sys.argv[1], sys.argv[2] == "True"
os.environ.update(EPP_PROVIDER_NAME=selected.upper(), EPP_PROVIDER_ENDPOINT="https://provider.example")
upstream = Mock(status_code=202, json=Mock(return_value={
    "status": "ENROUTE" if selected == "soprano" else {"code": 290},
    "messages": [{"status": {"groupName": "PENDING"}}], "id": "test-message",
}))
requests.request = Mock(return_value=upstream)
from src.secrets import SecretResolver
SecretResolver.resolve = Mock(return_value="test-key")

import function_app
import src.dispatch as dispatch_module
from src import providers

assert Path(function_app.__file__).resolve() == Path.cwd() / "function_app.py"
assert Path(dispatch_module.__file__).resolve() == Path.cwd() / "src" / "dispatch.py"
assert not any(name.startswith("src.providers.") for name in sys.modules)
functions = function_app.app.get_functions()
assert len(functions) == 1 and functions[0].get_function_name() == "send_otp"
handler = functions[0].get_user_function()
lookup = Mock(wraps=function_app._registry.get)
function_app._registry.get = lookup
imports = Mock(wraps=providers.importlib.import_module)
providers.importlib.import_module = imports
function_app._engine.token_acquirer = Mock()

key = jwk.JWK.generate(kty="RSA", size=2048)
function_app._key_provider = Mock(return_value=key.export_to_pem(private_key=True, password=None).decode())
context = {"nonce": "test-nonce", "phoneNumber": "+15551234567", "message": "Your code is 123456"}
token = jwe.JWE(json.dumps(context).encode(), protected={"alg": "RSA-OAEP-256", "enc": "A256GCM"})
token.add_recipient(key)
envelope = {"type": "microsoft.mfa.otpDeliver.v1", "channel": 1, "mode": 1,
            "encryptedDeliveryContext": token.serialize(compact=True)}

def invoke(payload):
    raw = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
    return handler(func.HttpRequest(method="POST", url="/api/SendOtp", headers={}, params={}, body=raw))

for invalid in (b"{", {**envelope, "channel": "invalid"}):
    assert invoke(invalid).status_code == 400
response = invoke({**envelope, "mode": 2, "channel": 2})
assert response.status_code == 200 and json.loads(response.get_body())["nonce"] == context["nonce"]
lookup.assert_not_called()
imports.assert_not_called()
SecretResolver.resolve.assert_not_called()
requests.request.assert_not_called()

for unknown in ("", "unknown", "../../../", "src.providers.soprano"):
    os.environ["EPP_PROVIDER_NAME"] = unknown
    response = invoke(envelope)
    assert response.status_code == 400
    assert json.loads(response.get_body())["error"] == "provider_delivery_failed"
imports.assert_not_called()
SecretResolver.resolve.assert_not_called()
requests.request.assert_not_called()

os.environ["EPP_PROVIDER_NAME"] = selected.upper()
response = invoke(envelope)
result = json.loads(response.get_body())
if available:
    assert response.status_code == 200 and result["nonce"] == context["nonce"]
    requests.request.assert_called_once()
    upstream.close.assert_called_once()
    assert SecretResolver.resolve.call_count == (2 if selected in ("soprano", "telesign") else 1)
    imports.assert_called_once_with("src.providers." + selected)
    assert {name for name in sys.modules if name.startswith("src.providers.")} == {"src.providers." + selected}
else:
    assert response.status_code == 502 and result["error"] == "provider_delivery_failed"
    assert "nonce" not in result
    request = dispatch_module.DispatchRequest(context["phoneNumber"], context["message"], "sms", "message", "correlation", "en-US")
    status, body = function_app._engine.dispatch(request, "request")
    assert status == 502 and body["reason"] == "provider unavailable" and body["outcome"] == "Fail"
    assert imports.call_args_list == [call("src.providers." + selected)] * 2
    SecretResolver.resolve.assert_not_called()
    requests.request.assert_not_called()
    for private in ("PRIVATE-PROVIDER-ERROR", "PRIVATE_PROVIDER_ERROR", "private_dependency"):
        assert private not in json.dumps(body) + response.get_body().decode() + logs.getvalue()
function_app._engine.token_acquirer.acquire.assert_not_called()
socket.socket.connect.assert_not_called()
socket.getaddrinfo.assert_not_called()
assert not any(value in logs.getvalue() for value in context.values())
print("isolated provider loading verified")
"""


@pytest.mark.parametrize("layout", [
    "soprano", "infobip", "telesign", "sinch", "absent",
    "missing-dependency", "broken-import", "invalid-source",
])
def test_isolated_app_indexes_evaluates_and_loads_only_selected_provider(tmp_path, layout):
    root = Path(__file__).resolve().parents[1]
    provider_ids = ("soprano", "infobip", "telesign", "sinch")
    available = layout in provider_ids
    selected = layout if available else "soprano"
    shutil.copy2(root / "function_app.py", tmp_path / "function_app.py")
    omitted = [name + ".py" for name in provider_ids if name != layout]
    shutil.copytree(root / "src", tmp_path / "src", ignore=shutil.ignore_patterns("__pycache__", *omitted))
    broken_source = {
        "missing-dependency": "from .private_dependency import value\n",
        "broken-import": "raise RuntimeError('PRIVATE-PROVIDER-ERROR')\n",
        "invalid-source": "def PRIVATE_PROVIDER_ERROR(\n",
    }.get(layout)
    if broken_source:
        (tmp_path / "src/providers/soprano.py").write_text(broken_source, encoding="utf-8")
    for name in provider_ids:
        if name != selected or layout == "absent":
            assert not (tmp_path / "src/providers" / (name + ".py")).exists()
    # Only OS essentials reach the child: no local settings, credential environment or repo import path.
    env = {name: os.environ[name] for name in ("SYSTEMROOT", "WINDIR", "PATH", "TEMP", "TMP") if name in os.environ}
    env.update(PYTHONPATH=str(tmp_path), PYTHONNOUSERSITE="1", PYTHONDONTWRITEBYTECODE="1")
    result = subprocess.run([sys.executable, "-c", _PROBE, selected, str(available)],
                            cwd=tmp_path, env=env, capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stdout.strip() == "isolated provider loading verified"