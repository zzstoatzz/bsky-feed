from ipaddress import IPv4Address
from pathlib import Path
from typing import Any, ClassVar

from atproto_client.models.string_formats import AtUri, Handle, RecordKey
from pydantic import Field, IPvAnyAddress, SecretStr, field_validator
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

    # --- Optional Server Settings with Defaults (env vars are uppercase) ---
    # Pydantic will match these case-insensitively, but we define them as uppercase for clarity
    SERVICE_DID: str | None = None
    LISTEN_HOST: IPvAnyAddress = IPv4Address("0.0.0.0")
    LISTEN_PORT: int = 8080
    LOG_LEVEL: str = "INFO"

    # --- Feed Behavior Settings (Server, env vars are uppercase) ---
    IGNORE_ARCHIVED_POSTS: bool = False
    IGNORE_REPLY_POSTS: bool = False

    # --- Settings for publishing script (env vars are uppercase) ---
    RECORD_NAME: RecordKey = "spongemock"  # Default record name for the feed
    DISPLAY_NAME: str = "SpOnGeMoCk"  # Default display name for the feed
    FEED_DESCRIPTION: str | None = Field(
        default=None, description="description of the feed"
    )
    AVATAR_PATH: Path | None = Field(
        default=None, description="path to an image file for the feed avatar"
    )
    FEED_URI_OUTPUT_FILE: Path = Path(
        ".bsky_feed_uri"
    )  # File where publish_feed.py saves the URI

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
