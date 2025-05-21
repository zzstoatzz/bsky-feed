from collections.abc import Callable
from ipaddress import IPv4Address
from pathlib import Path
from typing import Any, ClassVar

from atproto_client.models.string_formats import AtUri, Handle, RecordKey
from pydantic import Field, ImportString, SecretStr, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config: ClassVar[SettingsConfigDict] = SettingsConfigDict(
        env_file=".env", extra="ignore"
    )

    # --- Core Required Settings (must be in .env or environment as uppercase) ---
    HANDLE: Handle = Field(default=..., description="your bluesky handle")
    PASSWORD: SecretStr = Field(default=..., description="your bluesky password")
    HOSTNAME: str = Field(
        default=...,
        description="your hostname",
        min_length=1,
        pattern=r"^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$",
    )
    FEED_URI: AtUri | None = None  # Server needs this set; publisher outputs it.

    # --- Optional Server Settings with Defaults ---
    SERVICE_DID: str | None = None
    LISTEN_HOST: IPv4Address = IPv4Address("0.0.0.0")
    LISTEN_PORT: int = 8080
    LOG_LEVEL: str = "INFO"

    # --- Feed Behavior Settings ---
    IGNORE_ARCHIVED_POSTS: bool = False
    IGNORE_REPLY_POSTS: bool = False
    CUSTOM_FILTER_FUNCTION: ImportString[Callable[..., bool]] | None = Field(
        default=None,
        description="Optional path to a custom filter function (e.g., 'my_module.my_filter_func') to decide post inclusion. The function should accept (record, created_post) and return bool.",
    )

    # --- Settings for publishing script ---
    RECORD_NAME: RecordKey = Field(default=..., description="record name of the feed")
    DISPLAY_NAME: str = Field(default=..., description="display name of the feed")
    FEED_DESCRIPTION: str | None = Field(
        default=None, description="description of the feed"
    )
    AVATAR_PATH: Path | None = Field(
        default=None, description="path to an image file for the feed avatar"
    )
    FEED_URI_OUTPUT_FILE: Path = Field(
        default_factory=lambda: Path(".bsky_feed_uri"),
        description="path to a file where the feed URI will be saved",
    )

    # Optional: For features like accepting interactions or video feeds, if needed by publisher
    ACCEPTS_INTERACTIONS: bool = False
    IS_VIDEO_FEED: bool = False

    # --- Database Settings ---
    DATABASE_URI: str = "feed_database.db"  # For tests, can be set to ":memory:"

    @field_validator("HOSTNAME", mode="before")
    @classmethod
    def _strip_quotes_from_hostname(cls, v: Any) -> Any:
        if isinstance(v, str):
            v_stripped = v.strip()
            if (v_stripped.startswith("'") and v_stripped.endswith("'")) or (
                v_stripped.startswith('"') and v_stripped.endswith('"')
            ):
                if len(v_stripped) > 1:  # Ensure it's not just ' or "
                    return v_stripped[1:-1]
        return v

    @field_validator(
        "IGNORE_ARCHIVED_POSTS",
        "IGNORE_REPLY_POSTS",
        "ACCEPTS_INTERACTIONS",
        "IS_VIDEO_FEED",
        mode="before",
    )
    @classmethod
    def _normalize_boolean_env_value(cls, v: Any) -> Any:
        if isinstance(v, str):
            v_lower = v.lower().strip()
            if (v_lower.startswith("'") and v_lower.endswith("'")) or (
                v_lower.startswith('"') and v_lower.endswith('"')
            ):
                return v_lower[1:-1]
        return v

    @field_validator("SERVICE_DID", mode="before")
    @classmethod
    def derive_service_did(cls, v: Any, info: Any) -> str | None:
        if v:
            return v
        values_data = info.data
        # Ensure HOSTNAME is accessed case-insensitively from data if needed, though Pydantic handles this
        # For direct access here, better to rely on Pydantic populating it correctly first.
        # If HOSTNAME is a field, Pydantic ensures it's in values_data if provided.
        hostname = values_data.get("HOSTNAME") or values_data.get("hostname")
        if hostname:
            return f"did:web:{hostname}"
        return None


settings = Settings()

if settings.CUSTOM_FILTER_FUNCTION:
    print(f"INFO: Loading custom filter function: {settings.CUSTOM_FILTER_FUNCTION}")
