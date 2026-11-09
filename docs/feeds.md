# feeds

how the cells fit together.

## the front cell

the feeds app runs behind its front cell since 2026-11-01 (`cells/front.zig`):
it answers the directory page, the did document, and describeFeedGenerator for
every feed on the host, and calls the feed's own cell for getFeedSkeleton.
spongebob's responses through it match what spongebob gave alone, byte for
byte except the two listings, which now name every feed; the e2e test
checks that on one sqlite file.
