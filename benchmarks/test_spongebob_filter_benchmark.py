import os
import sys

import pytest
from atproto import models

project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if project_root not in sys.path:
    sys.path.insert(0, project_root)

from example_custom_filters import spongebob_filter  # noqa

test_cases = [
    pytest.param("sPoNgEbObTeXt", True, id="Simple positive"),
    pytest.param("tHiSiSaLtErNaTiNgCaSe", True, id="Longer positive"),
    pytest.param("aBcDeFg", True, id="Lower first positive (min len)"),
    pytest.param("AbCdEfG", True, id="Upper first positive (min len)"),
    pytest.param("lOwErUpPeRlOwErUpPeRlOwEr", True, id="Lower first long"),
    pytest.param("uPpErLoWeRuPpErLoWeRuPpEr", True, id="Upper first long"),
    pytest.param(
        "http://example.com sPoNgEbObTeXt #hashtag", True, id="With URL and hashtag"
    ),
    pytest.param("test123aBcDeFgHi", True, id="Spongebob after numbers"),
    pytest.param("aBcDeFgHi123test", True, id="Spongebob before numbers"),
    pytest.param("word,aLtErNaTeS", True, id="Spongebob after punctuation"),
    pytest.param(
        "This is some normal text with oNeSpOnGeWoRd hidden.",
        True,
        id="Many words, one Spongebob",
    ),
    pytest.param("!!aBcDeFg", True, id="Leading non-alpha"),
    pytest.param("aBcDeFg!!", True, id="Trailing non-alpha"),
    pytest.param("--aBcDeFg--", True, id="Spongebob between non-alpha"),
    pytest.param("short", False, id="Simple negative (short)"),
    pytest.param("alllowercase", False, id="Simple negative (all lower)"),
    pytest.param("ALLUPPERCASE", False, id="Simple negative (all upper)"),
    pytest.param(
        "MiXeDcAsEnOtAltErNaTiNg", True, id="Mixed not alternating (now True)"
    ),
    pytest.param(
        "http://example.com test #hashtag", False, id="URL and hashtag, no spongebob"
    ),
    pytest.param("http://example.com #hashtag", False, id="Only URL and hashtag"),
    pytest.param("macro:sPoNgEbObTeXt", False, id="Starts with macro:"),
    pytest.param("", False, id="Empty string"),
    pytest.param(None, False, id="None text"),
    pytest.param("aBcDeF", False, id="Alternating but too short (6)"),
    pytest.param("a", False, id="Alternating but too short (1)"),
    pytest.param("test aBcDeF test", False, id="Word aBcDeF word (too short)"),
    pytest.param("aBcD123eFgHi", False, id="Numbers in middle of Spongebob"),
    pytest.param("!!! %%% $$$", False, id="All non-alpha"),
    pytest.param(
        "This is a very long string of normal text without any Spongebob casing anywhere in the entire sentence.",
        False,
        id="Long string, no Spongebob",
    ),
    pytest.param(
        "a an a of to in it is be as at so we he by or on do if me my up",
        False,
        id="Many short non-Spongebob words",
    ),
    pytest.param("aBcDeFGhIjK", False, id="Almost Spongebob but one char breaks"),
    pytest.param("AaAaAa", False, id="Tricky case: AaAaAa (len 6)"),
    pytest.param("AaAaAaA", True, id="Tricky case: AaAaAaA (len 7)"),
    pytest.param("aAaAaA", False, id="Tricky case: aAaAaA (len 6)"),
    pytest.param("aAaAaAa", True, id="Tricky case: aAaAaAa (len 7)"),
]

DUMMY_CREATED_AT = "2023-01-01T00:00:00Z"
dummy_created_post = {"uri": "dummy_uri", "cid": "dummy_cid", "author": "dummy_author"}


@pytest.mark.parametrize("text_content, expected_result", test_cases)
def test_spongebob_case(text_content, expected_result, benchmark):
    # pytest-benchmark will run this multiple times and collect stats

    # Prepare the record for the filter
    record_text_for_constructor = "" if text_content is None else text_content
    try:
        current_record = models.AppBskyFeedPost.Record(
            text=record_text_for_constructor, created_at=DUMMY_CREATED_AT
        )
    except Exception as e:
        pytest.fail(f"Failed to create Record for text '{text_content}': {e}")

    # Benchmark the filter function
    # The result of spongebob_filter will be returned by benchmark()
    actual_result = benchmark(spongebob_filter, current_record, dummy_created_post)

    # Assert correctness
    assert actual_result == expected_result, f"Failed for text: '{text_content}'"
