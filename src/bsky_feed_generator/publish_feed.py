import os

from atproto import Client, models

from bsky_feed_generator.server.config import settings


def main():
    client = Client()
    client.login(settings.HANDLE, settings.PASSWORD.get_secret_value())
    me = client.me
    assert me is not None and me.did is not None, "Failed to login"

    feed_did = settings.SERVICE_DID
    if not feed_did:
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

    response = client.com.atproto.repo.put_record(
        models.ComAtprotoRepoPutRecord.Data(
            repo=me.did,
            collection=models.ids.AppBskyFeedGenerator,
            rkey=settings.RECORD_NAME,
            record=models.AppBskyFeedGenerator.Record(
                did=feed_did,
                display_name=settings.DISPLAY_NAME,
                description=settings.FEED_DESCRIPTION,
                avatar=avatar_blob,
                accepts_interactions=settings.ACCEPTS_INTERACTIONS,
                created_at=client.get_current_time_iso(),
                content_mode=(
                    "app.bsky.feed.defs#contentModeVideo"
                    if settings.IS_VIDEO_FEED
                    else None
                ),
            ),
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
                f"Important: For the server to use this feed, set FEED_URI='{feed_uri_str}' in your .env file or environment."
            )
        except OSError as e:
            print(f"Error saving feed URI to {settings.FEED_URI_OUTPUT_FILE}: {e}")


if __name__ == "__main__":
    main()
