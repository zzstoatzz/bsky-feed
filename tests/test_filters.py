from src.spongemock_bsky_feed_generator.server.data_filter import is_spongebob_case

POSITIVE_CASES = [
    "tEsTiNg",
    "hElLoWoRlD",
    "aBcDeFgHiJ",
    "ThIsIsAlSoOk",
    "NoRmAl tEsTiNg WoRd",
    "tEsTiNg NoRmAl WoRd",
    "NoRmAl WoRd tEsTiNg",
    "This is a NoRmAlTeXt",
]

NEGATIVE_CASES = [
    "NoRmAl TeXt",
    "thIs Is a TeSt",
    "AAAAAAA",
    "aaaaaaa",
    "no alt here",
    "abcdefg",
    "ABCDEFG",
    "Hi",
    "aBcDeF",
    "AbCdEf",
    "http://example.com/tEsTiNgPaTh",
    "www.example.com/hElLoWoRlD",
    "youtu.be/ThIsIsAlSoOk",
    "mixedCASE but then aURL tEsTiNg.com/path",
    "macro: CUgjJmJtJwxLwt2GX3jM",
]


def test_positive_spongebob_cases():
    """Tests strings that should be identified as Spongebob case."""
    for case in POSITIVE_CASES:
        assert is_spongebob_case(case) is True, f"Expected '{case}' to be True"


def test_negative_spongebob_cases():
    """Tests strings that should NOT be identified as Spongebob case."""
    for case in NEGATIVE_CASES:
        assert is_spongebob_case(case) is False, f"Expected '{case}' to be False"


def test_url_rejection():
    assert is_spongebob_case("http://example.com/tEsTiNgPaTh") is False
    assert is_spongebob_case("check this www.example.com/hElLoWoRlD out") is False


def test_macro_rejection():
    assert is_spongebob_case("macro: CUgjJmJtJwxLwt2GX3jM") is False
