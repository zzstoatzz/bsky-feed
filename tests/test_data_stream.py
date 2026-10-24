from atproto_client import models

from bsky_feed_generator.server import config
from bsky_feed_generator.server.data_filter import operations_callback
from bsky_feed_generator.server.data_stream import _subscribe_url, get_ops_by_type
from bsky_feed_generator.server.database import Post, db
from example_custom_filters import spongebob_filter  # type: ignore

POST = models.ids.AppBskyFeedPost


def _commit(operation: str, record: dict | None = None, collection: str = POST) -> dict:
    commit = {
        "rev": "3mylzo65ql22y",
        "operation": operation,
        "collection": collection,
        "rkey": "3myei5n6qby2q",
    }
    if record is not None:
        commit["record"] = record
        commit["cid"] = "bafyreidf6liifxlxhibhreke7onkwchfuqeaixbebiyooiiy4bzaxeszwy"
    return {
        "did": "did:plc:author",
        "time_us": 1792800000000000,
        "kind": "commit",
        "commit": commit,
    }


def test_create_post_with_reply_and_image_parses_into_a_record():
    event = _commit(
        "create",
        {
            "$type": POST,
            "text": "sPoNgEmOcK",
            "createdAt": "2026-10-24T06:00:00.000Z",
            "langs": ["en"],
            "reply": {
                "root": {"uri": "at://did:plc:a/app.bsky.feed.post/1", "cid": "bafyroot"},
                "parent": {"uri": "at://did:plc:a/app.bsky.feed.post/2", "cid": "bafyparent"},
            },
            "embed": {
                "$type": "app.bsky.embed.images",
                "images": [
                    {
                        "alt": "",
                        "image": {
                            "$type": "blob",
                            "ref": {"$link": "bafkreigh2akiscaildc"},
                            "mimeType": "image/jpeg",
                            "size": 1234,
                        },
                    }
                ],
            },
        },
    )

    ops = get_ops_by_type(event)

    assert ops is not None
    (created,) = ops[POST]["created"]
    assert created["uri"] == "at://did:plc:author/app.bsky.feed.post/3myei5n6qby2q"
    assert created["author"] == "did:plc:author"
    assert created["record"].text == "sPoNgEmOcK"
    assert created["record"].reply.root.uri == "at://did:plc:a/app.bsky.feed.post/1"


def test_delete_post_becomes_a_deleted_op():
    ops = get_ops_by_type(_commit("delete"))

    assert ops is not None
    assert ops[POST]["deleted"] == [
        {"uri": "at://did:plc:author/app.bsky.feed.post/3myei5n6qby2q"}
    ]
    assert ops[POST]["created"] == []


def test_updates_other_collections_and_non_commit_events_are_skipped():
    assert get_ops_by_type(_commit("update", {"$type": POST, "text": "x", "createdAt": "2026-10-24T06:00:00Z"})) is None
    assert get_ops_by_type(_commit("create", {"$type": "app.bsky.feed.like"}, collection="app.bsky.feed.like")) is None
    assert get_ops_by_type({"did": "did:plc:author", "time_us": 1, "kind": "identity"}) is None


def test_subscribe_url_filters_to_posts_and_resumes_from_cursor(monkeypatch):
    monkeypatch.setattr(config.settings, "JETSTREAM_URL", "wss://jet.example/subscribe")

    assert _subscribe_url(None) == "wss://jet.example/subscribe?wantedCollections=app.bsky.feed.post"
    assert _subscribe_url(42) == "wss://jet.example/subscribe?wantedCollections=app.bsky.feed.post&cursor=42"


def test_jetstream_events_flow_through_the_filter_and_deletes_remove_rows(tmp_path, monkeypatch):
    monkeypatch.setattr(config.settings, "CUSTOM_FILTER_FUNCTION", spongebob_filter)
    monkeypatch.setattr(config.settings, "IGNORE_ARCHIVED_POSTS", False)
    monkeypatch.setattr(config.settings, "IGNORE_REPLY_POSTS", False)
    db.init(str(tmp_path / "feed.db"))
    db.connect()
    db.create_tables([Post])
    db.close()

    operations_callback(
        get_ops_by_type(
            _commit("create", {"$type": POST, "text": "tEsTiNg", "createdAt": "2026-10-24T06:00:00Z"})
        )
    )
    assert Post.select().count() == 1

    operations_callback(get_ops_by_type(_commit("delete")))
    assert Post.select().count() == 0
