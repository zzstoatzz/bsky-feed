import datetime
import logging
from collections import defaultdict

from atproto import models

from bsky_feed_generator.server.config import settings
from bsky_feed_generator.server.database import Post, db

logger = logging.getLogger(__name__)


def is_archive_post(record: "models.AppBskyFeedPost.Record") -> bool:
    # Sometimes users will import old posts from Twitter/X which con flood a feed with
    # old posts. Unfortunately, the only way to test for this is to look an old
    # created_at date. However, there are other reasons why a post might have an old
    # date, such as firehose or firehose consumer outages. It is up to you, the feed
    # creator to weigh the pros and cons, amd and optionally include this function in
    # your filter conditions, and adjust the threshold to your liking.
    #
    # See https://github.com/MarshalX/bluesky-feed-generator/pull/21

    archived_threshold = datetime.timedelta(days=1)
    created_at = datetime.datetime.fromisoformat(record.created_at)
    now = datetime.datetime.now(datetime.timezone.utc)

    return now - created_at > archived_threshold


def should_ignore_post(created_post: dict) -> bool:
    record = created_post["record"]
    uri = created_post["uri"]

    if settings.IGNORE_ARCHIVED_POSTS and is_archive_post(record):
        logger.debug(f"Ignoring archived post: {uri}")
        return True

    if settings.IGNORE_REPLY_POSTS and record.reply:
        logger.debug(f"Ignoring reply post: {uri}")
        return True

    return False


def operations_callback(ops: defaultdict) -> None:
    # Ensure we have a fresh connection for database operations
    if not db.is_closed():
        db.close()
    db.connect()

    try:
        posts_to_create = []
        for created_post in ops[models.ids.AppBskyFeedPost]["created"]:
            record = created_post["record"]

            ignored = should_ignore_post(created_post)
            if ignored:
                continue

            post_passes_custom_filter = False

            if settings.CUSTOM_FILTER_FUNCTION:
                custom_filter_function = settings.CUSTOM_FILTER_FUNCTION
                assert custom_filter_function is not None
                function_name = custom_filter_function.__name__ or "unknown"
                try:
                    if custom_filter_function(record, created_post):
                        post_passes_custom_filter = True
                    else:
                        logger.debug(
                            f"Post {created_post['uri']} excluded by custom filter: {function_name}"
                        )
                        continue
                except Exception as e:
                    logger.error(
                        f"Error executing custom filter {function_name} for post {created_post['uri']}: {e}"
                    )
                    continue  # Skip post if custom filter errors
            else:
                # No custom filter configured. By default, this means the post is not included by this logic path.
                # If you want to include all posts that pass should_ignore_post when no custom filter is set,
                # you would set post_passes_custom_filter = True here.
                logger.debug(
                    "No CUSTOM_FILTER_FUNCTION configured. Post will not be added by custom logic."
                )
                continue

            if not post_passes_custom_filter:
                continue

            # Post passed all filters, prepare it for creation
            reply_root = reply_parent = None
            if record.reply:
                reply_root = record.reply.root.uri
                reply_parent = record.reply.parent.uri

            post_dict = {
                "uri": created_post["uri"],
                "cid": created_post["cid"],
                "reply_parent": reply_parent,
                "reply_root": reply_root,
                "text": record.text,  # TODO: Remove text before saving to DB, as it's not in the model
            }
            posts_to_create.append(post_dict)

        posts_to_delete = ops[models.ids.AppBskyFeedPost]["deleted"]
        if posts_to_delete:
            post_uris_to_delete = [post["uri"] for post in posts_to_delete]
            Post.delete().where(Post.uri.in_(post_uris_to_delete))  # type: ignore
            logger.debug(f"Deleted from feed: {len(post_uris_to_delete)}")

        if posts_to_create:
            logger.debug(f"Adding {len(posts_to_create)} posts to feed.")
            for post_dict_to_log in posts_to_create:
                logger.info(
                    f"Post: {post_dict_to_log['uri']} with text: {
                        post_dict_to_log.get('text', '<Text not available>')
                    }"
                )

            with db.atomic():
                for post_dict_for_db in posts_to_create:
                    db_insert_dict = post_dict_for_db.copy()
                    db_insert_dict.pop(
                        "text"
                    )  # TODO: Remove text before saving to DB, as it's not in the model
                    Post.create(**db_insert_dict)
    finally:
        # Always close the connection after operations
        if not db.is_closed():
            db.close()
