import pytest

from src.credential_failure import CredentialResolutionError, credential_failure


@pytest.mark.parametrize("code,expected", [
    ("70025", "federated_credential_missing"),
    ("70021", "federated_credential_mismatch"),
    ("700016", "provider_application_not_found"),
])
def test_wrapped_error_keeps_only_allowlisted_diagnostics(code, expected):
    sdk = ValueError(f"AADSTS{code}: PRIVATE-ASSERTION PRIVATE-TOKEN PRIVATE-RESPONSE")
    wrapper = RuntimeError("wrapper")
    wrapper.__cause__ = sdk
    failure = credential_failure(wrapper, "provider_token_exchange")
    assert failure.diagnostic.credential_stage == "provider_token_exchange"
    assert failure.diagnostic.credential_failure == expected
    assert failure.diagnostic.aadsts_code == code
    assert str(failure) == "provider credential unavailable"
    assert failure.__cause__ is None and failure.__context__ is None
    assert "PRIVATE" not in repr(failure) + repr(failure.__dict__)


def test_structured_codes_take_precedence_and_unknown_codes_remain_unknown():
    sdk = ValueError("AADSTS700016: PRIVATE")
    sdk.error_response = {"error_codes": [70025]}
    wrapper = ValueError("AADSTS700016: PRIVATE")
    wrapper.__cause__ = sdk
    assert credential_failure(wrapper, "provider_token_exchange").diagnostic.credential_failure == "federated_credential_missing"
    for message in ("PRIVATE", "70025", "AADSTS999999: PRIVATE", "AADSTS700211: PRIVATE", "AADSTS70025suffix"):
        failure = credential_failure(ValueError(message), "provider_token_exchange")
        assert failure.diagnostic.credential_failure == "credential_unavailable"
        assert failure.diagnostic.aadsts_code is None
    unsafe = CredentialResolutionError("PRIVATE-STAGE", "PRIVATE-CAUSE", "PRIVATE-CODE")
    assert (unsafe.diagnostic.credential_stage, unsafe.diagnostic.credential_failure,
            unsafe.diagnostic.aadsts_code) == ("unknown", "credential_unavailable", None)


def test_cycles_are_bounded_and_classified_identity_failure_is_not_reinterpreted():
    sdk = ValueError("PRIVATE")
    sdk.__cause__ = sdk
    assert credential_failure(sdk).diagnostic.aadsts_code is None
    identity = credential_failure(ValueError("AADSTS700016: PRIVATE"), "managed_identity")
    assert identity.diagnostic.credential_failure == "credential_unavailable"
    wrapper = ValueError("wrapper")
    wrapper.__cause__ = identity
    assert credential_failure(wrapper, "provider_token_exchange") is identity
