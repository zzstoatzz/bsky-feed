from datetime import datetime

from bsky_feed_generator.server.config import settings
from bsky_feed_generator.server.database import Post

uri = settings.FEED_URI
CURSOR_EOF = "eof"


def handler(cursor: str | None, limit: int) -> dict:
    if not uri:
        return {"cursor": CURSOR_EOF, "feed": []}

    posts = (
        Post.select()
        .order_by(Post.cid.desc())
        .order_by(Post.indexed_at.desc())
        .limit(limit)
    )

    if cursor:
        if cursor == CURSOR_EOF:
            return {"cursor": CURSOR_EOF, "feed": []}
        cursor_parts = cursor.split("::")
        if len(cursor_parts) != 2:
            raise ValueError("Malformed cursor")

        indexed_at, cid = cursor_parts
        indexed_at = datetime.fromtimestamp(int(indexed_at) / 1000)
        posts = posts.where(
            ((Post.indexed_at == indexed_at) & (Post.cid < cid))  # type: ignore
            | (Post.indexed_at < indexed_at)  # type: ignore
        )

    feed = [{"post": post.uri} for post in posts]

    cursor = CURSOR_EOF
    last_post = posts[-1] if posts else None
    if last_post:
        cursor = f"{int(last_post.indexed_at.timestamp() * 1000)}::{last_post.cid}"

    return {"cursor": cursor, "feed": feed}
