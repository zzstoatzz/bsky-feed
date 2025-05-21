import os
import sqlite3
import sys

db_path = "/data/feed_database.db"
print(f"Attempting to query {db_path}", flush=True)

if not os.path.exists(db_path):
    print(
        f"DATABASE_ERROR: Database file {db_path} not found.",
        file=sys.stderr,
        flush=True,
    )
    sys.exit(1)

try:
    # Connect in read-only mode to be safe
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    cur = con.cursor()
    print("Executing query: SELECT * FROM subscription_state;", flush=True)
    cur.execute("SELECT * FROM subscription_state;")
    rows = cur.fetchall()
    if not rows:
        print("RESULT: No data in subscription_state table.", flush=True)
    else:
        col_names = [desc[0] for desc in cur.description]
        print("COLUMNS:{}".format("|".join(col_names)), flush=True)
        for row_data in rows:
            print("ROW:{}".format("|".join(map(str, row_data))), flush=True)
    con.close()
    print("Query successful. Connection closed.", flush=True)
except sqlite3.OperationalError as e:
    print(f"SQLITE_OPERATIONAL_ERROR: {e}", file=sys.stderr, flush=True)
    if "unable to open database file" in str(e) or "no such table" in str(e):
        print(
            "Potential issue: DB file might exist but is not a valid SQLite DB or table is missing.",
            file=sys.stderr,
            flush=True,
        )
    sys.exit(1)
except sqlite3.Error as e:
    print(f"SQLITE_ERROR: {e}", file=sys.stderr, flush=True)
    sys.exit(1)
except Exception as e:
    print(f"UNEXPECTED_ERROR: {e}", file=sys.stderr, flush=True)
    sys.exit(1)
