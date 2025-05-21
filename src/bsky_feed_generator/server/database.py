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


if db.is_closed():
    db.connect()
    db.create_tables([Post, SubscriptionState], safe=True)
