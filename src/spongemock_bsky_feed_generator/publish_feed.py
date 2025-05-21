import os

from atproto import Client, models

from spongemock_bsky_feed_generator.server.config import settings


def main():
    client = Client()
    client.login(settings.HANDLE, settings.PASSWORD.get_secret_value())
    assert client.me is not None, "Failed to login"

    feed_did = settings.SERVICE_DID
    # service_did is derived in the Settings class if not set and HOSTNAME is available.
    # Pydantic raises an error if HOSTNAME is missing and SERVICE_DID isn't provided & can't be derived.
    if not feed_did:
        # This path should ideally not be hit if HOSTNAME is correctly set.
        print("Error: Service DID could not be determined. Ensure HOSTNAME is set.")
        return

    avatar_blob = None
    if settings.AVATAR_PATH:
        if os.path.exists(settings.AVATAR_PATH):
            with open(settings.AVATAR_PATH, "rb") as f:
                avatar_data = f.read()
                avatar_blob = client.upload_blob(avatar_data).blob
        else:
            print(
                f"Warning: Avatar path specified but not found: {settings.AVATAR_PATH}"
            )

    record = models.AppBskyFeedGenerator.Record(
        did=feed_did,
        display_name=settings.DISPLAY_NAME,
        description=settings.FEED_DESCRIPTION,
        avatar=avatar_blob,
        accepts_interactions=settings.ACCEPTS_INTERACTIONS,
        created_at=client.get_current_time_iso(),
    )
    if settings.IS_VIDEO_FEED:
        if hasattr(record, "content_mode"):  # Check if direct field exists
            record.content_mode = "app.bsky.feed.defs#contentModeVideo"
        # If content_mode doesn't exist, and labels are needed:
        # else:
        #     record.labels = models.AppBskyFeedGenerator.RecordLabels(
        #         values= [models.AppBskyFeedGenerator.RecordLabelValue(val="app.bsky.feed.defs#contentModeVideo")]
        #     )
        # The exact way to set video mode might need checking against current atproto SDK.
        # For now, being conservative. If your model has a simple `content_mode` string, it will be used.

    response = client.com.atproto.repo.put_record(
        models.ComAtprotoRepoPutRecord.Data(
            repo=client.me.did,
            collection=models.ids.AppBskyFeedGenerator,
            rkey=settings.RECORD_NAME,
            record=record,
        )
    )

    feed_uri_str = response.uri
    print("Successfully published!")
    print(f"Feed URI: {feed_uri_str}")

    if settings.FEED_URI_OUTPUT_FILE:
        try:
            with open(settings.FEED_URI_OUTPUT_FILE, "w") as f:
                f.write(feed_uri_str)
            print(f"Feed URI saved to: {settings.FEED_URI_OUTPUT_FILE}")
            print(
                f"Important: For the server to use this feed, set FEED_URI='{feed_uri_str}' in your .env file or environment (no SPONGE_ prefix needed if you removed it from Settings config)."
            )
        except OSError as e:  # Changed from IOError for Python 3
            print(f"Error saving feed URI to {settings.FEED_URI_OUTPUT_FILE}: {e}")


if __name__ == "__main__":
    main()
