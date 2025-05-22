import datetime
import logging
from collections import defaultdict
from unittest.mock import patch

import pytest
from atproto_client import models

from bsky_feed_generator.server import config
from bsky_feed_generator.server.data_filter import operations_callback
from example_custom_filters import (  # type: ignore
    spongebob_filter as example_spongebob_filter,
)


# Helper to create mock post data
def _create_mock_post(
    text: str | None, reply: bool = False, is_archived: bool = False
) -> dict:
    uri = f"at://did:plc:test/app.bsky.feed.post/{text[:10] if text else 'none'}"
    cid = "test_cid"

    reply_ref_obj = None
    if reply:
        # Use models.ComAtprotoRepoStrongRef.Main for reply references
        # This model expects cid and uri
        reply_ref_obj = models.AppBskyFeedPost.ReplyRef(
            root=models.ComAtprotoRepoStrongRef.Main(uri="root_uri", cid="root_cid"),
            parent=models.ComAtprotoRepoStrongRef.Main(
                uri="parent_uri", cid="parent_cid"
            ),
        )

    record_instance = models.AppBskyFeedPost.Record(
        text=text if text is not None else "",
        created_at=(
            datetime.datetime.now(datetime.timezone.utc)
            - datetime.timedelta(days=2 if is_archived else 0)
        ).isoformat(),
        reply=reply_ref_obj,
    )

    return {
        "uri": uri,
        "cid": cid,
        "author": "did:plc:test_author",
        "record": record_instance,
    }


@pytest.fixture
def mock_db_operations():
    with (
        patch("src.bsky_feed_generator.server.data_filter.Post.create") as mock_create,
        patch("src.bsky_feed_generator.server.data_filter.Post.delete") as mock_delete,
    ):
        yield mock_create, mock_delete


# --- Tests for Spongebob filter via CUSTOM_FILTER_FUNCTION ---
def test_custom_spongebob_filter_positive_case(monkeypatch, mock_db_operations, caplog):
    mock_create, _ = mock_db_operations
    monkeypatch.setattr(
        "src.bsky_feed_generator.server.data_filter.settings",
        config.Settings(
            CUSTOM_FILTER_FUNCTION=example_spongebob_filter,
            IGNORE_ARCHIVED_POSTS=False,
            IGNORE_REPLY_POSTS=False,
        ),
    )

    ops = defaultdict(lambda: defaultdict(list))
    # Directly use the single positive test case string
    ops[models.ids.AppBskyFeedPost]["created"].append(_create_mock_post("tEsTiNg"))

    caplog.set_level(logging.DEBUG, logger="example_custom_filters")
    caplog.set_level(logging.DEBUG, logger="bsky_feed_generator.server.data_filter")

    operations_callback(ops)

    mock_create.assert_called_once()


def test_custom_spongebob_filter_negative_case(  # Renamed for clarity
    monkeypatch, mock_db_operations, caplog
):
    mock_create, _ = mock_db_operations
    monkeypatch.setattr(
        "src.bsky_feed_generator.server.data_filter.settings",
        config.Settings(
            CUSTOM_FILTER_FUNCTION=example_spongebob_filter,
            IGNORE_ARCHIVED_POSTS=False,
            IGNORE_REPLY_POSTS=False,
        ),
    )

    ops = defaultdict(lambda: defaultdict(list))
    # Directly use the single negative test case string
    ops[models.ids.AppBskyFeedPost]["created"].append(_create_mock_post("normal text"))

    caplog.set_level(logging.DEBUG, logger="example_custom_filters")
    operations_callback(ops)
    mock_create.assert_not_called()


# --- Tests for general filter behavior ---


def test_no_custom_filter_configured(monkeypatch, mock_db_operations):
    mock_create, _ = mock_db_operations
    monkeypatch.setattr(
        "src.bsky_feed_generator.server.data_filter.settings",
        config.Settings(
            CUSTOM_FILTER_FUNCTION=None,
            IGNORE_ARCHIVED_POSTS=False,
            IGNORE_REPLY_POSTS=False,
        ),
    )

    ops = defaultdict(lambda: defaultdict(list))
    ops[models.ids.AppBskyFeedPost]["created"].append(
        _create_mock_post("Any text here")
    )

    operations_callback(ops)
    mock_create.assert_not_called()  # Because no filter means no inclusion by default


def test_custom_filter_is_reply_and_ignored(monkeypatch, mock_db_operations):
    mock_create, _ = mock_db_operations
    # Patch attributes on the actual imported settings instance
    monkeypatch.setattr(
        config.settings, "CUSTOM_FILTER_FUNCTION", example_spongebob_filter
    )
    monkeypatch.setattr(config.settings, "IGNORE_ARCHIVED_POSTS", False)
    monkeypatch.setattr(config.settings, "IGNORE_REPLY_POSTS", True)

    ops = defaultdict(lambda: defaultdict(list))
    # This text would normally pass the spongebob filter
    ops[models.ids.AppBskyFeedPost]["created"].append(
        _create_mock_post("tEsTiNg RePlY", reply=True)
    )

    operations_callback(ops)
    mock_create.assert_not_called()  # Ignored due to being a reply


def test_custom_filter_is_archived_and_ignored(monkeypatch, mock_db_operations):
    mock_create, _ = mock_db_operations
    # Patch attributes on the actual imported settings instance
    monkeypatch.setattr(
        config.settings, "CUSTOM_FILTER_FUNCTION", example_spongebob_filter
    )
    monkeypatch.setattr(config.settings, "IGNORE_ARCHIVED_POSTS", True)
    monkeypatch.setattr(config.settings, "IGNORE_REPLY_POSTS", False)

    ops = defaultdict(lambda: defaultdict(list))
    # This text would normally pass the spongebob filter
    ops[models.ids.AppBskyFeedPost]["created"].append(
        _create_mock_post("tEsTiNg ArChIvEd", is_archived=True)
    )

    operations_callback(ops)
    mock_create.assert_not_called()  # Ignored due to being archived


# Store the globally defined raising_filter_func to ensure it's consistently available
# and can be cleaned up if necessary, though pytest usually handles test scope well.
_test_raising_filter_func = None


def get_raising_filter_func():
    global _test_raising_filter_func
    if _test_raising_filter_func is None:

        def raising_filter_func(record, created_post):
            raise ValueError("Intentional filter error")

        _test_raising_filter_func = raising_filter_func
    return _test_raising_filter_func


def test_custom_filter_error_handling(monkeypatch, mock_db_operations, caplog):
    mock_create, _ = mock_db_operations

    current_raising_filter = get_raising_filter_func()
    # Patch attributes on the actual imported settings instance
    monkeypatch.setattr(
        config.settings, "CUSTOM_FILTER_FUNCTION", current_raising_filter
    )
    monkeypatch.setattr(config.settings, "IGNORE_ARCHIVED_POSTS", False)
    monkeypatch.setattr(config.settings, "IGNORE_REPLY_POSTS", False)

    ops = defaultdict(lambda: defaultdict(list))
    ops[models.ids.AppBskyFeedPost]["created"].append(
        _create_mock_post("Text that would pass a normal filter")
    )

    # Ensure caplog captures logs from the specific logger used in data_filter.py
    import logging  # Make sure logging is imported in the test file

    caplog.set_level(logging.ERROR, logger="bsky_feed_generator.server.data_filter")
    # The with caplog.at_level might be redundant now, or can be kept for local module INFO/DEBUG if needed
    # with caplog.at_level("ERROR"):
    operations_callback(ops)

    mock_create.assert_not_called()
    assert (
        f"Error executing custom filter {current_raising_filter.__name__}"
        in caplog.text
    )
    assert "Intentional filter error" in caplog.text


def test_invalid_custom_filter_path(monkeypatch, mock_db_operations, caplog):
    mock_create, _ = mock_db_operations

    # Patch attributes on the actual imported settings instance
    monkeypatch.setattr(config.settings, "CUSTOM_FILTER_FUNCTION", None)
    # Ensure other settings are at their defaults or non-interfering values for this test
    monkeypatch.setattr(config.settings, "IGNORE_ARCHIVED_POSTS", False)
    monkeypatch.setattr(config.settings, "IGNORE_REPLY_POSTS", False)

    ops = defaultdict(lambda: defaultdict(list))
    ops[models.ids.AppBskyFeedPost]["created"].append(_create_mock_post("Any text"))

    # Check for the "No CUSTOM_FILTER_FUNCTION configured" debug message
    # The logger in data_filter.py is logging.getLogger(__name__)
    # which is 'bsky_feed_generator.server.data_filter'
    caplog.set_level(logging.DEBUG, logger="bsky_feed_generator.server.data_filter")
    operations_callback(ops)

    mock_create.assert_not_called()
    assert "No CUSTOM_FILTER_FUNCTION configured" in caplog.text


# Example of how you might test deleted posts (if logic becomes more complex)
# def test_deleted_posts_are_removed(mock_db_operations):
#     _, mock_delete = mock_db_operations
#     ops = defaultdict(lambda: defaultdict(list))
#     ops[models.ids.AppBskyFeedPost]["deleted"].append({"uri": "at://deleted_uri_1"})
#     ops[models.ids.AppBskyFeedPost]["deleted"].append({"uri": "at://deleted_uri_2"})

#     operations_callback(ops)
#     mock_delete.assert_called_once()
#     # Further assertions can be made on the arguments to mock_delete.call_args
#     # For example, checking if Post.uri.in_() was called with the correct URIs.
#     # This requires more detailed Peewee query mocking if you want to inspect the .where() clause.


# Make sure to remove the old test functions if they are no longer relevant
# del test_positive_spongebob_cases, test_negative_spongebob_cases, test_url_rejection, test_macro_rejection
