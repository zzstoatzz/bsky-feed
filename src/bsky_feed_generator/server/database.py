import os
from datetime import datetime
from pathlib import Path

import peewee

# Import settings from the new config location
from .config import settings

# Ensure the database directory exists
db_path = Path(settings.DATABASE_URI)
if db_path.name != settings.DATABASE_URI:  # True if DATABASE_URI includes a path
    db_parent_dir = db_path.parent
    if not db_parent_dir.exists():
        os.makedirs(db_parent_dir, exist_ok=True)

db = peewee.SqliteDatabase(settings.DATABASE_URI)


def configure_db():
    """Configure database with proper WAL settings"""
    db.connect(reuse_if_open=True)
    # Enable WAL mode for better concurrency
    db.execute_sql("PRAGMA journal_mode=WAL")
    # Set busy timeout to avoid lock errors
    db.execute_sql("PRAGMA busy_timeout=5000")
    # Ensure we read latest data
    db.execute_sql("PRAGMA read_uncommitted=1")
    # Auto-checkpoint at 1000 pages
    db.execute_sql("PRAGMA wal_autocheckpoint=1000")


class BaseModel(peewee.Model):
    class Meta:
        database = db


class Post(BaseModel):
    uri = peewee.CharField(index=True)
    cid = peewee.CharField()
    reply_parent = peewee.CharField(null=True, default=None)
    reply_root = peewee.CharField(null=True, default=None)
    indexed_at = peewee.DateTimeField(default=datetime.utcnow)


class SubscriptionState(BaseModel):
    service = peewee.CharField(unique=True)
    cursor = peewee.BigIntegerField()


# Configure and create tables
configure_db()
db.create_tables([Post, SubscriptionState], safe=True)
