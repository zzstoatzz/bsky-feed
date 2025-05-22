import re

from atproto import models

from bsky_feed_generator.server.logger import logger

MIN_SPONGEBOB_LEN = 7
URL_RE = re.compile(r"https?://\S+|www\.\S+|[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/\S+")
HASHTAG_RE = re.compile(r"#\w+")


def _is_spongebob_word(s: str) -> bool:
    """
    Helper function to detect alternating case span in a single pass.
    Checks for patterns like 'aBaBaBa' or 'BaBaBaB'.
    """
    if (
        len(s) < MIN_SPONGEBOB_LEN
    ):  # Ensure consistency, though outer function already checks
        return False

    span_lower_first = 0  # Tracks 'aBaB...' pattern
    span_upper_first = 0  # Tracks 'BaBa...' pattern

    for char_code in [
        ord(c) for c in s
    ]:  # Iterate using ord for potential minor optimization
        # char.isalpha()
        is_alpha = (ord("a") <= char_code <= ord("z")) or (
            ord("A") <= char_code <= ord("Z")
        )

        if not is_alpha:
            span_lower_first = 0
            span_upper_first = 0
            continue

        # char.islower()
        current_char_is_lower = ord("a") <= char_code <= ord("z")

        # Pattern 1: Starts with lowercase (e.g., aBcDeFg)
        # Expectation: if span_lower_first is even, expect lower; if odd, expect upper.
        if current_char_is_lower == (span_lower_first % 2 == 0):
            span_lower_first += 1
        else:
            # Mismatch. Can current char start a new lower-first pattern?
            if current_char_is_lower:
                span_lower_first = 1
            else:
                span_lower_first = 0

        # Pattern 2: Starts with uppercase (e.g., AbCdEfG)
        # Expectation: if span_upper_first is even, expect upper; if odd, expect lower.
        if (not current_char_is_lower) == (
            span_upper_first % 2 == 0
        ):  # current_char_is_upper == (span_upper_first % 2 == 0)
            span_upper_first += 1
        else:
            # Mismatch. Can current char start a new upper-first pattern?
            if not current_char_is_lower:  # current_char_is_upper
                span_upper_first = 1
            else:
                span_upper_first = 0

        if (
            span_lower_first >= MIN_SPONGEBOB_LEN
            or span_upper_first >= MIN_SPONGEBOB_LEN
        ):
            return True

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
        if not word:  # Handles potential empty strings if there are multiple spaces
            continue

        # logger.debug(f"  spongebob_filter: Checking word: '{word}'") # Logged by _is_spongebob_word if needed

        # No need to check len(word) < MIN_SPONGEBOB_LEN here if _is_spongebob_word handles it robustly,
        # but the previous optimization in this loop was beneficial.
        # The _is_spongebob_word function now has its own length check at the start for safety/clarity,
        # but the primary check is still best here to avoid function call overhead for short words.
        if len(word) < MIN_SPONGEBOB_LEN:
            # logger.debug( # This logger was very helpful before, let's keep it but commented for now
            #     f"    spongebob_filter: Word '{word}' is too short (len: {len(word)}). Skipping."
            # )
            continue

        if _is_spongebob_word(word):  # Call the new single-pass function
            logger.debug(
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
