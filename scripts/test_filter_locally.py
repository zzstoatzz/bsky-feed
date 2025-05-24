#!/usr/bin/env python3

from atproto_client.models import AppBskyFeedPost

from example_custom_filters import spongebob_filter


def test_filter_with_test_post():
    # Test the exact text from our recent test posts
    test_texts = [
        "ThIs Is A tEsT pOsT fOr CuRsOr DeBuGgInG - 20:38:25",
        "ThIs Is A tEsT pOsT fOr CuRsOr DeBuGgInG - 20:25:50",
        "tHiS iS a TeSt PoSt",
        "This is a TEST post for CuRsOr DeBuGgInG - 20:24:57",
    ]

    for text in test_texts:
        print(f"\nTesting: '{text}'")

        # Create a mock record
        record = AppBskyFeedPost.Record(
            text=text, created_at="2025-05-24T01:38:25.000Z"
        )

        # Create mock created_post
        created_post = {
            "uri": "at://did:plc:65sucjiel52gefhcdcypynsr/app.bsky.feed.post/test",
            "cid": "test_cid",
            "author": "did:plc:65sucjiel52gefhcdcypynsr",
        }

        try:
            result = spongebob_filter(record, created_post)
            print(f"  Filter result: {result}")
            if result:
                print("  ✅ SHOULD be added to feed")
            else:
                print("  ❌ Would NOT be added to feed")
        except Exception as e:
            print(f"  ERROR: {e}")


if __name__ == "__main__":
    test_filter_with_test_post()
