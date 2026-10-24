import json
import time
from collections import defaultdict
from urllib.parse import urlencode

from atproto import models
from websockets.exceptions import WebSocketException
from websockets.sync.client import connect

from bsky_feed_generator.server.config import settings
from bsky_feed_generator.server.database import SubscriptionState
from bsky_feed_generator.server.logger import logger

_WANTED_COLLECTION = models.ids.AppBskyFeedPost

# store the cursor every ~10s of stream time
_CURSOR_SAVE_INTERVAL_US = 10_000_000


def _state_key(name: str) -> str:
    # jetstream cursors are unix microseconds, not relay seqs, so they can't
    # share a row with the old firehose cursor
    return f"{name}#jetstream"


def get_ops_by_type(event: dict) -> defaultdict | None:
    """Translate one jetstream event into the ops shape operations_callback expects."""
    if event.get("kind") != "commit":
        return None
    commit = event.get("commit") or {}
    collection = commit.get("collection")
    if collection != _WANTED_COLLECTION:
        return None

    operation_by_type = defaultdict(lambda: {"created": [], "deleted": []})
    did = event["did"]
    uri = f"at://{did}/{collection}/{commit['rkey']}"

    operation = commit.get("operation")
    if operation == "create":
        raw_record = commit.get("record")
        cid = commit.get("cid")
        if not raw_record or not cid:
            return None
        record = models.get_or_create(raw_record, strict=False)
        if record is None or not models.is_record_type(
            record,  # type: ignore
            models.AppBskyFeedPost,
        ):
            return None
        operation_by_type[collection]["created"].append(
            {"record": record, "uri": uri, "cid": cid, "author": did}
        )
    elif operation == "delete":
        operation_by_type[collection]["deleted"].append({"uri": uri})
    else:
        return None

    return operation_by_type


def _subscribe_url(cursor: int | None) -> str:
    params: list[tuple[str, str | int]] = [("wantedCollections", _WANTED_COLLECTION)]
    if cursor is not None:
        params.append(("cursor", cursor))
    return f"{settings.JETSTREAM_URL}?{urlencode(params)}"


def _save_cursor(name: str, cursor: int) -> None:
    SubscriptionState.insert(service=_state_key(name), cursor=cursor).on_conflict(
        conflict_target=(SubscriptionState.service,),
        action="UPDATE",
        update={SubscriptionState.cursor: cursor},
    ).execute()


def run(name, operations_callback, stream_stop_event=None):
    while stream_stop_event is None or not stream_stop_event.is_set():
        try:
            _run(name, operations_callback, stream_stop_event)
        except (WebSocketException, OSError) as e:
            logger.error(f"Jetstream connection error: {e}. Reconnecting...", exc_info=True)
        except Exception as e:
            logger.error(
                f"Unexpected critical error in jetstream _run loop: {e}. Reconnecting...",
                exc_info=True,
            )
        if stream_stop_event:
            stream_stop_event.wait(5)
        else:
            time.sleep(5)


def _run(name, operations_callback, stream_stop_event=None):
    state = SubscriptionState.get_or_none(SubscriptionState.service == _state_key(name))
    cursor = state.cursor if state else None
    logger.info(f"DATA_STREAM: connecting to {settings.JETSTREAM_URL} (cursor={cursor})")

    last_saved = cursor or 0
    with connect(_subscribe_url(cursor), max_size=None, open_timeout=30) as ws:
        for message in ws:
            if stream_stop_event and stream_stop_event.is_set():
                return

            event = json.loads(message)
            time_us = event.get("time_us")

            ops = get_ops_by_type(event)
            if ops is not None:
                try:
                    operations_callback(ops)
                except Exception as e:
                    logger.error(
                        f"CRITICAL ERROR during operations_callback for {event.get('did')} at {time_us}: {e}",
                        exc_info=True,
                    )

            if time_us and time_us - last_saved >= _CURSOR_SAVE_INTERVAL_US:
                _save_cursor(name, time_us)
                last_saved = time_us
