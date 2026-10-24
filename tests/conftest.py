import os

# config.Settings() runs at import time and requires these
for key, value in {
    "HANDLE": "test.bsky.social",
    "PASSWORD": "test-password",
    "HOSTNAME": "feed.example.com",
    "RECORD_NAME": "test",
    "DISPLAY_NAME": "test feed",
    "DATABASE_URI": ":memory:",
}.items():
    os.environ.setdefault(key, value)
