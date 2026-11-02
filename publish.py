#!/usr/bin/env -S uv run --script --quiet
# /// script
# requires-python = ">=3.12"
# dependencies = ["atproto"]
# ///
"""
write the app.bsky.feed.generator records for the mirror feeds in zeldi.json.

prints the records and writes nothing unless --publish is given. run from the
laptop, never the machine:

    ./publish.py
    HANDLE=zzstoatzz.io PASSWORD=<app password> ./publish.py --publish

spongebob's record (n8) already exists and is left alone.
"""

import json
import os
import sys
from pathlib import Path

here = Path(__file__).parent
config = json.loads((here / "zeldi.json").read_text())
graze = json.loads((here / "testdata/graze/actor-feeds.json").read_text())
graze_names = {f["uri"]: f["displayName"] for f in graze["feeds"]}

front = next(c for c in config["cells"] if c.get("front"))
hostname = front["config"]["hostname"]
mirrors = {c["name"]: c["config"] for c in config["cells"] if c["wasm"].endswith("feeds-mirror.wasm")}

records = []
for feed in front["config"]["feeds"]:
    mirror = mirrors.get(feed["cell"])
    if mirror is None:
        continue
    name = graze_names[mirror["source"]]
    records.append(
        (
            feed["uri"].rsplit("/", 1)[1],
            {
                "$type": "app.bsky.feed.generator",
                "did": f"did:web:{hostname}",
                "displayName": name,
                "description": f"{name} from graze, newest first, mirrored by zeldi | https://{hostname}",
            },
        )
    )

if "--publish" not in sys.argv:
    for rkey, record in records:
        print(rkey, json.dumps(record))
    sys.exit(0)

from atproto import Client, IdResolver

publisher = front["config"]["feeds"][0]["uri"].split("/")[2]
pds = IdResolver().did.resolve_atproto_data(publisher).pds
print(f"{publisher} at {pds}")
client = Client(pds)
client.login(os.environ["HANDLE"], os.environ["PASSWORD"])
for rkey, record in records:
    record["createdAt"] = client.get_current_time_iso()
    response = client.com.atproto.repo.put_record(
        {"repo": client.me.did, "collection": "app.bsky.feed.generator", "rkey": rkey, "record": record}
    )
    print(f"published: {response.uri}")
