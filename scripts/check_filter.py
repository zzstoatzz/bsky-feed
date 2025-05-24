"""Check which posts in the database would pass the spongebob filter"""

import os
import sqlite3
import sys
from datetime import datetime, timezone

if os.path.exists("/app"):
    sys.path.insert(0, "/app")
else:
    # Local development
    sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "."))

from example_custom_filters import spongebob_filter
from bsky_feed_generator.server.database import db

def main():
    print("=== Checking Posts Against SpongeBob Filter ===\n")
    
    db_path = (
        "/data/feed_database.db"
        if os.path.exists("/data/feed_database.db")
        else db.database
    )
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()
    
    # Get recent posts with text
    rows = cur.execute("""
        SELECT indexed_at, uri 
        FROM post 
        ORDER BY indexed_at DESC 
        LIMIT 50
    """).fetchall()
    
    print(f"Checking {len(rows)} most recent posts...")
    
    passing_posts = []
    for indexed_at, uri in rows:
        # Create a minimal record object for the filter
        record = type('obj', (object,), {
            'text': f"tEsT pOsT tHaT sHoUlD pAsS",  # We can't get the actual text from DB
            'reply': None
        })
        
        # For this test, let's just show the posts
        post_time = datetime.fromisoformat(indexed_at + "+00:00")
        age = (datetime.now(timezone.utc) - post_time).total_seconds() / 3600
        print(f"{indexed_at} ({age:.1f}h ago) - {uri}")
        
        if age < 1:  # Posts from last hour
            passing_posts.append((indexed_at, uri))
    
    print(f"\n{len(passing_posts)} posts from the last hour")
    print("\nNote: We can't check the actual text from the database schema.")
    print("The SpongeBob filter requires text with aLtErNaTiNg CaSe (min 7 chars).")
    
    conn.close()

if __name__ == "__main__":
    main()