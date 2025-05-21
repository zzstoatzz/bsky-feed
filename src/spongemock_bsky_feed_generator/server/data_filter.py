import datetime
import logging
import re
from collections import defaultdict

from atproto import models

from spongemock_bsky_feed_generator.server.config import settings
from spongemock_bsky_feed_generator.server.database import Post, db

logger = logging.getLogger(__name__)


MIN_SPONGEBOB_LEN = 7
URL_RE = re.compile(r"https?://\S+|www\.\S+|[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/\S+")


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
    now = datetime.datetime.now(datetime.UTC)

    return now - created_at > archived_threshold


def _alt_span(s: str, lower_first: bool) -> bool:
    span = 0
    for ch in s:
        if not ch.isalpha():
            span = 0
            continue
        expect_lower = (span % 2 == 0) == lower_first
        if ch.islower() if expect_lower else ch.isupper():
            span += 1
            if span >= MIN_SPONGEBOB_LEN:
                return True
        else:
            span = 1 if (ch.islower() if lower_first else ch.isupper()) else 0
    return False


def is_spongebob_case(text: str) -> bool:
    if text.lower().startswith("macro:"):
        return False  # If the entire text starts with "macro:", disregard it

    for word in URL_RE.sub("", text).split():
        if not word:  # Skip empty words that might result from sub
            continue
        if _alt_span(word, True) or _alt_span(word, False):
            return True
    return False


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
    # Here we can filter, process, run ML classification, etc.
    # After our feed alg we can save posts into our DB
    # Also, we should process deleted posts to remove them from our DB and keep it in sync

    # for example, let's create our custom feed that will contain all posts that contains 'python' related text

    posts_to_create = []
    for created_post in ops[models.ids.AppBskyFeedPost]["created"]:
        # author = created_post["author"]
        record = created_post["record"]

        # inlined_text = record.text.replace("\n", " ")

        if should_ignore_post(created_post):
            continue

        if is_spongebob_case(record.text):
            reply_root = reply_parent = None
            if record.reply:
                reply_root = record.reply.root.uri
                reply_parent = record.reply.parent.uri

            post_dict = {
                "uri": created_post["uri"],
                "cid": created_post["cid"],
                "reply_parent": reply_parent,
                "reply_root": reply_root,
                "text": record.text,
            }
            posts_to_create.append(post_dict)

    posts_to_delete = ops[models.ids.AppBskyFeedPost]["deleted"]
    if posts_to_delete:
        post_uris_to_delete = [post["uri"] for post in posts_to_delete]
        Post.delete().where(Post.uri.in_(post_uris_to_delete))  # type: ignore
        logger.debug(f"Deleted from feed: {len(post_uris_to_delete)}")

    if posts_to_create:
        # Log here before creating, including matched text for clarity
        logger.info(f"Adding {len(posts_to_create)} posts to Spongebob feed.")
        for post_dict in posts_to_create:
            text = post_dict.pop("text")
            logger.info(f"Post: {post_dict['uri']}")
            logger.info(f"Text: {text}")
            logger.info("---\n")
        with db.atomic():
            for post_dict in posts_to_create:
                Post.create(**post_dict)
