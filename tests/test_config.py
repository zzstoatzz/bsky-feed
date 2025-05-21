from typing import Any

import pytest
from pydantic import ValidationError

# Assuming your Settings class is in this path
# Adjust the import path if your project structure is different
from spongemock_bsky_feed_generator.server.config import Settings


def test_hostname_strips_single_quotes(monkeypatch):
    monkeypatch.setenv("HANDLE", "testhandle.bsky.social")
    monkeypatch.setenv("PASSWORD", "testpassword")
    monkeypatch.setenv("HOSTNAME", "'test.example.com'")
    settings = Settings()
    assert settings.HOSTNAME == "test.example.com"


def test_hostname_strips_double_quotes(monkeypatch):
    monkeypatch.setenv("HANDLE", "testhandle.bsky.social")
    monkeypatch.setenv("PASSWORD", "testpassword")
    monkeypatch.setenv("HOSTNAME", '"test.example.com"')
    settings = Settings()
    assert settings.HOSTNAME == "test.example.com"


def test_hostname_no_quotes(monkeypatch):
    monkeypatch.setenv("HANDLE", "testhandle.bsky.social")
    monkeypatch.setenv("PASSWORD", "testpassword")
    monkeypatch.setenv("HOSTNAME", "test.example.com")
    settings = Settings()
    assert settings.HOSTNAME == "test.example.com"


def test_hostname_empty_quotes(monkeypatch):
    monkeypatch.setenv("HANDLE", "testhandle.bsky.social")
    monkeypatch.setenv("PASSWORD", "testpassword")
    monkeypatch.setenv(
        "HOSTNAME", "''"
    )  # Pydantic might raise error or it becomes empty string
    with pytest.raises(
        ValidationError
    ):  # Assuming empty string is not a valid hostname
        Settings()


def test_hostname_single_quote_char(monkeypatch):
    # Test if HOSTNAME is just a single quote (should likely fail validation or be handled)
    monkeypatch.setenv("HANDLE", "testhandle.bsky.social")
    monkeypatch.setenv("PASSWORD", "testpassword")
    monkeypatch.setenv("HOSTNAME", "'")
    with pytest.raises(ValidationError):  # Assuming single quote is not valid
        Settings()


def test_service_did_derivation_with_normalized_hostname(monkeypatch):
    monkeypatch.setenv("HANDLE", "testhandle.bsky.social")
    monkeypatch.setenv("PASSWORD", "testpassword")
    monkeypatch.setenv("HOSTNAME", "'test.example.com'")
    settings = Settings()
    assert settings.HOSTNAME == "test.example.com"  # Verifies normalization happened
    assert settings.SERVICE_DID == "did:web:test.example.com"


def test_service_did_explicitly_set(monkeypatch):
    monkeypatch.setenv("HANDLE", "testhandle.bsky.social")
    monkeypatch.setenv("PASSWORD", "testpassword")
    monkeypatch.setenv("HOSTNAME", "test.example.com")
    monkeypatch.setenv("SERVICE_DID", "did:web:explicit.example.com")
    settings = Settings()
    assert settings.SERVICE_DID == "did:web:explicit.example.com"


def test_missing_required_fields_raises_validation_error(monkeypatch):
    # Ensure no .env file values are loaded for this test
    def mock_dotenv_call(self_ignored) -> dict[str, Any | None]:
        return {}

    monkeypatch.setattr(
        "pydantic_settings.sources.DotEnvSettingsSource.__call__", mock_dotenv_call
    )

    # No HOSTNAME, HANDLE, or PASSWORD in the environment either
    monkeypatch.delenv("HANDLE", raising=False)
    monkeypatch.delenv("PASSWORD", raising=False)
    monkeypatch.delenv("HOSTNAME", raising=False)

    with pytest.raises(ValidationError):
        Settings()


# Basic tests for boolean normalization
def test_boolean_true_strips_quotes(monkeypatch):
    monkeypatch.setenv("HANDLE", "testhandle.bsky.social")
    monkeypatch.setenv("PASSWORD", "testpassword")
    monkeypatch.setenv("HOSTNAME", "test.example.com")
    monkeypatch.setenv("ACCEPTS_INTERACTIONS", "'true'")
    settings = Settings()
    assert settings.ACCEPTS_INTERACTIONS is True


def test_boolean_false_strips_quotes(monkeypatch):
    monkeypatch.setenv("HANDLE", "testhandle.bsky.social")
    monkeypatch.setenv("PASSWORD", "testpassword")
    monkeypatch.setenv("HOSTNAME", "test.example.com")
    monkeypatch.setenv("ACCEPTS_INTERACTIONS", '"false"')
    settings = Settings()
    assert settings.ACCEPTS_INTERACTIONS is False


def test_boolean_no_quotes(monkeypatch):
    monkeypatch.setenv("HANDLE", "testhandle.bsky.social")
    monkeypatch.setenv("PASSWORD", "testpassword")
    monkeypatch.setenv("HOSTNAME", "test.example.com")
    monkeypatch.setenv("ACCEPTS_INTERACTIONS", "true")
    settings = Settings()
    assert settings.ACCEPTS_INTERACTIONS is True


# Placeholder for settings that have defaults
def test_default_listen_port(monkeypatch):
    monkeypatch.setenv("HANDLE", "testhandle.bsky.social")
    monkeypatch.setenv("PASSWORD", "testpassword")
    monkeypatch.setenv("HOSTNAME", "test.example.com")
    settings = Settings()
    assert settings.LISTEN_PORT == 8080
    assert str(settings.LISTEN_HOST) == "0.0.0.0"
    assert settings.LOG_LEVEL == "INFO"
