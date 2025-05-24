#!/usr/bin/env python3

import sqlite3


def delete_cursor():
    conn = sqlite3.connect("/data/feed_database.db")
    cursor = conn.cursor()

    # Delete the cursor entry
    cursor.execute(
        "DELETE FROM subscriptionstate WHERE service = 'did:web:feed.alternatebuild.dev'"
    )
    conn.commit()

    # Verify it's gone
    cursor.execute("SELECT COUNT(*) FROM subscriptionstate")
    count = cursor.fetchone()[0]

    print(f"Cursor deleted. Remaining entries: {count}")
    conn.close()


if __name__ == "__main__":
    delete_cursor()
