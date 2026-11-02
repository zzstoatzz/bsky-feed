"""recompute filter_verdicts.json with bsky-feed's python filter.

run from a checkout of this repo at 75aea27, the last commit with the python
generator:
    PYTHONPATH=. uv run python <bsky-feed>/cells/testdata/verdicts.py
"""

import json
from pathlib import Path
from types import SimpleNamespace

from example_custom_filters import spongebob_filter

path = Path(__file__).with_name("filter_verdicts.json")
cases = [text for text, _ in json.loads(path.read_text())]
rows = [json.dumps([t, bool(spongebob_filter(SimpleNamespace(text=t), {}))]) for t in cases]
path.write_text("[\n" + ",\n".join(rows) + "\n]\n")
