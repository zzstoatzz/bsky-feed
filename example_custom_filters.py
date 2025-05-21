import logging
import re

from atproto import models

logger = logging.getLogger(__name__)


MIN_SPONGEBOB_LEN = 7
URL_RE = re.compile(r"https?://\S+|www\.\S+|[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/\S+")
HASHTAG_RE = re.compile(r"#\w+")


def _alt_span(s: str, lower_first: bool) -> bool:
    """Helper function to detect alternating case span."""
    logger.debug(f"_alt_span: input='{s}', lower_first={lower_first}")
    span = 0
    for i, ch in enumerate(s):
        if not ch.isalpha():
            logger.debug(
                f"  _alt_span: Char '{ch}' at {i} is not alpha. Resetting span from {span} to 0."
            )
            span = 0
            continue

        expect_lower = (span % 2 == 0) == lower_first
        logger.debug(
            f"  _alt_span: Char '{ch}' at {i}: current_span={span}, expect_lower={expect_lower}"
        )

        if ch.islower() if expect_lower else ch.isupper():
            span += 1
            logger.debug(f"    _alt_span: Match! New span: {span}")
            if span >= MIN_SPONGEBOB_LEN:
                logger.debug(
                    f"    _alt_span: Span {span} >= {MIN_SPONGEBOB_LEN}. Returning True."
                )
                return True
        else:
            logger.debug(
                f"    _alt_span: No match. Was expecting lower: {expect_lower}, got lower: {ch.islower()}"
            )
            # If the current char could start a new sequence of the same lower_first type, set span to 1
            if (
                ch.islower() if lower_first else ch.isupper()
            ):  # Check if current char matches the initial expectation for a new span
                logger.debug(
                    f"      _alt_span: Current char '{ch}' could start new span. Resetting span from {span} to 1."
                )
                span = 1
            else:
                logger.debug(
                    f"      _alt_span: Current char '{ch}' cannot start new span. Resetting span from {span} to 0."
                )
                span = 0
    logger.debug(f"_alt_span: Returning False for '{s}' (final span: {span})")
    return False


def spongebob_filter(record: models.AppBskyFeedPost.Record, created_post: dict) -> bool:
    """
    Custom filter to include posts that contain Spongebob-like alternating case text.

    Args:
        record: The post record containing text and other data.
        created_post: A dictionary with post metadata (uri, cid, author).

    Returns:
        True if the post should be included, False otherwise.
    """
    text = record.text
    logger.debug(f"spongebob_filter: Input text: '{text}'")

    if not text:
        logger.debug("spongebob_filter: Text is None or empty. Returning False.")
        return False

    if text.lower().startswith("macro:"):
        logger.debug("spongebob_filter: Text starts with 'macro:'. Returning False.")
        return False

    text_without_urls = URL_RE.sub("", text)
    logger.debug(f"  spongebob_filter: Text without URLs: '{text_without_urls}'")

    text_without_hashtags_or_urls = HASHTAG_RE.sub("", text_without_urls)
    logger.debug(
        f"  spongebob_filter: Text without URLs or hashtags: '{text_without_hashtags_or_urls}'"
    )

    for word in text_without_hashtags_or_urls.split():
        if not word:
            continue
        logger.debug(f"  spongebob_filter: Checking word: '{word}'")
        if _alt_span(word, True) or _alt_span(word, False):
            logger.info(
                f"spongebob_filter: Word '{word}' IS Spongebob case. Returning True."
            )
            return True

    logger.debug(
        "spongebob_filter: No Spongebob case found in any word. Returning False."
    )
    return False


# Example of another filter you could add to this file for testing or use:
# def another_example_filter(record: models.AppBskyFeedPost.Record, created_post: dict) -> bool:
#     """Includes posts containing the word 'test' only if they are not replies."""
#     if record.reply:
#         return False
#     if record.text and "test" in record.text.lower():
#         return True
#     return False
