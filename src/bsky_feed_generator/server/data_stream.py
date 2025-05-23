import time
from collections import defaultdict

from atproto import (
    CAR,
    AtUri,
    FirehoseSubscribeReposClient,
    firehose_models,
    models,
    parse_subscribe_repos_message,
)
from atproto.exceptions import FirehoseError

from bsky_feed_generator.server.database import SubscriptionState
from bsky_feed_generator.server.logger import logger

_INTERESTED_RECORDS = {
    models.AppBskyFeedLike: models.ids.AppBskyFeedLike,
    models.AppBskyFeedPost: models.ids.AppBskyFeedPost,
    models.AppBskyGraphFollow: models.ids.AppBskyGraphFollow,
}


def _get_ops_by_type(commit: models.ComAtprotoSyncSubscribeRepos.Commit) -> defaultdict:
    operation_by_type = defaultdict(lambda: {"created": [], "deleted": []})

    car = CAR.from_bytes(commit.blocks)  # type: ignore
    for op in commit.ops:
        if op.action == "update":
            # we are not interested in updates
            continue

        uri = AtUri.from_str(f"at://{commit.repo}/{op.path}")

        if op.action == "create":
            if not op.cid:
                continue

            create_info = {"uri": str(uri), "cid": str(op.cid), "author": commit.repo}

            record_raw_data = car.blocks.get(op.cid)
            if not record_raw_data:
                continue

            record = models.get_or_create(record_raw_data, strict=False)
            if record is None:  # unknown record (out of bsky lexicon)
                continue

            for record_type, record_nsid in _INTERESTED_RECORDS.items():
                if uri.collection == record_nsid and models.is_record_type(
                    record,  # type: ignore
                    record_type,
                ):
                    operation_by_type[record_nsid]["created"].append(
                        {"record": record, **create_info}
                    )
                    break

        if op.action == "delete":
            operation_by_type[uri.collection]["deleted"].append({"uri": str(uri)})

    return operation_by_type


def run(name, operations_callback, stream_stop_event=None):
    while stream_stop_event is None or not stream_stop_event.is_set():
        try:
            _run(name, operations_callback, stream_stop_event)
        except FirehoseError as e:
            # Always log the full error when it occurs, then attempt reconnect
            logger.error(
                f"Firehose error encountered: {e}. Attempting to reconnect...",
                exc_info=True,
            )
            # Add a small delay before retrying to prevent rapid-fire reconnection attempts on persistent issues
            if stream_stop_event:
                stream_stop_event.wait(
                    5
                )  # Wait 5 seconds before retrying, if stop_event is available
            else:
                time.sleep(5)
        except Exception as e:
            # Catch any other unexpected errors from _run to prevent the run loop from crashing
            logger.error(
                f"Unexpected critical error in firehose _run loop: {e}. Attempting to reconnect...",
                exc_info=True,
            )
            if stream_stop_event:
                stream_stop_event.wait(5)
            else:
                time.sleep(5)


def _run(name, operations_callback, stream_stop_event=None):
    state = SubscriptionState.get_or_none(SubscriptionState.service == name)

    params = None
    if state:
        params = models.ComAtprotoSyncSubscribeRepos.Params(cursor=state.cursor)
        logger.info(
            f"DATA_STREAM: Found existing state for service '{name}'. Using cursor: {state.cursor}"
        )
    else:
        logger.info(
            f"DATA_STREAM: No existing state found for service '{name}'. Will start with no cursor (from head)."
        )

    client = FirehoseSubscribeReposClient(params)

    def on_message_handler(message: firehose_models.MessageFrame) -> None:
        # stop on next message if requested
        if stream_stop_event and stream_stop_event.is_set():
            client.stop()
            return

        commit = parse_subscribe_repos_message(message)
        if not isinstance(commit, models.ComAtprotoSyncSubscribeRepos.Commit):
            return

        # update stored state every ~1k events
        if commit.seq % 1000 == 0:  # lower value could lead to performance issues
            logger.debug(f"Updated cursor for {name} to {commit.seq}")
            client.update_params(
                models.ComAtprotoSyncSubscribeRepos.Params(cursor=commit.seq)
            )
            # Atomically create or update the subscription state
            SubscriptionState.insert(service=name, cursor=commit.seq).on_conflict(
                conflict_target=(SubscriptionState.service,),  # service is unique
                action="UPDATE",
                update={SubscriptionState.cursor: commit.seq},
            ).execute()

        logger.debug(
            f"data_stream: Commit seq {commit.seq}, has blocks: {bool(commit.blocks)}"
        )
        if not commit.blocks:
            return
        try:
            operations_callback(_get_ops_by_type(commit))
        except Exception as e:
            logger.error(
                f"CRITICAL ERROR during operations_callback for commit seq {commit.seq}, repo {commit.repo}: {e}",
                exc_info=True,
            )
            # Optionally, re-raise or stop the client if errors are too frequent or severe
            # For now, logging the full traceback and continuing might allow us to see the problematic data
            # client.stop() # to stop the firehose on error

    client.start(on_message_handler)
