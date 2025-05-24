import signal
import sys
import threading

from flask import Flask, jsonify, request

from bsky_feed_generator.server import data_stream
from bsky_feed_generator.server.algos import algos
from bsky_feed_generator.server.config import settings
from bsky_feed_generator.server.data_filter import operations_callback
from bsky_feed_generator.server.database import db

app = Flask(__name__)


@app.before_request
def before_request():
    """Ensure fresh database connection for each request"""
    if db.is_closed():
        db.connect()


@app.teardown_request
def teardown_request(exception=None):
    """Close database connection after each request"""
    if not db.is_closed():
        db.close()


stream_stop_event = threading.Event()
stream_thread = threading.Thread(
    target=data_stream.run,
    args=(
        settings.SERVICE_DID,
        operations_callback,
        stream_stop_event,
    ),
)
stream_thread.start()


def sigint_handler(*_):
    print("Stopping data stream...")
    stream_stop_event.set()
    sys.exit(0)


signal.signal(signal.SIGINT, sigint_handler)


@app.route("/")
def index():
    return "ATProto Feed Generator powered by The AT Protocol SDK for Python (https://github.com/MarshalX/atproto)."


@app.route("/.well-known/did.json", methods=["GET"])
def did_json():
    service_did = settings.SERVICE_DID
    hostname = settings.HOSTNAME
    if not service_did or not service_did.endswith(str(hostname)):
        return "", 404

    return jsonify(
        {
            "@context": ["https://www.w3.org/ns/did/v1"],
            "id": service_did,
            "service": [
                {
                    "id": "#bsky_fg",
                    "type": "BskyFeedGenerator",
                    "serviceEndpoint": f"https://{hostname}",
                }
            ],
        }
    )


@app.route("/xrpc/app.bsky.feed.describeFeedGenerator", methods=["GET"])
def describe_feed_generator():
    feeds = [{"uri": uri} for uri in algos.keys()]
    response = {
        "encoding": "application/json",
        "body": {"did": settings.SERVICE_DID, "feeds": feeds},
    }
    return jsonify(response)


@app.route("/xrpc/app.bsky.feed.getFeedSkeleton", methods=["GET"])
def get_feed_skeleton():
    feed_param = request.args.get("feed", default=None, type=str)
    if feed_param is None:
        return "Feed parameter missing", 400

    algo = algos.get(feed_param)
    if not algo:
        return "Unsupported algorithm", 400

    # Example of how to check auth if giving user-specific results:
    """
    from server.auth import AuthorizationError, validate_auth
    try:
        requester_did = validate_auth(request)
    except AuthorizationError:
        return 'Unauthorized', 401
    """

    try:
        cursor = request.args.get("cursor", default=None, type=str)
        limit = request.args.get("limit", default=20, type=int)
        body = algo(cursor, limit)
    except ValueError:
        return "Malformed cursor", 400

    return jsonify(body)


@app.route("/debug/posts", methods=["GET"])
def debug_posts():
    import sqlite3
    from datetime import datetime

    from bsky_feed_generator.server.database import Post

    # Get posts via Peewee ORM
    posts = (
        Post.select()
        .order_by(Post.indexed_at.desc())
        .order_by(Post.cid.desc())
        .limit(10)
    )

    orm_results = []
    for p in posts:
        orm_results.append(
            {"uri": p.uri, "indexed_at": p.indexed_at.isoformat(), "cid": p.cid}
        )

    # Get posts via direct SQL for comparison
    direct_conn = sqlite3.connect(settings.DATABASE_URI)
    direct_cursor = direct_conn.cursor()
    direct_cursor.execute(
        "SELECT uri, indexed_at, cid FROM post ORDER BY indexed_at DESC, cid DESC LIMIT 10"
    )
    sql_results = []
    for row in direct_cursor.fetchall():
        sql_results.append({"uri": row[0], "indexed_at": row[1], "cid": row[2]})

    # Get WAL status
    wal_status = direct_cursor.execute("PRAGMA wal_checkpoint").fetchone()
    journal_mode = direct_cursor.execute("PRAGMA journal_mode").fetchone()
    total_sql = direct_cursor.execute("SELECT COUNT(*) FROM post").fetchone()[0]

    direct_conn.close()

    return jsonify(
        {
            "server_time": datetime.utcnow().isoformat(),
            "total_posts_orm": Post.select().count(),
            "total_posts_sql": total_sql,
            "journal_mode": journal_mode[0] if journal_mode else None,
            "wal_checkpoint_result": wal_status,
            "orm_results": orm_results,
            "sql_results": sql_results,
            "mismatch": orm_results != sql_results,
        }
    )
