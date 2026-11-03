# feeds

how the cells fit together.

## the front cell

the feeds app runs behind its front cell since 2026-11-01 (`cells/front.zig`):
it answers the directory page, the did document, and describeFeedGenerator for
every feed on the host, and calls the feed's own cell for getFeedSkeleton.
spongebob's responses through it match what spongebob gave alone, byte for
byte except the two listings, which now name every feed; the e2e test
checks that on one sqlite file.

## mirror feeds

`cells/mirror.zig` is a second cell kind in the feeds app: it mirrors
another generator's skeleton with `fetch`, keeps each post with when it
first saw it (48 hours), and serves them newest first. the first three mirror
graze's midterms feeds (`races-natl`, `desk-natl`, `races-mi` as `live-natl`,
`live-desk`, `live-mi`). `zeldi.jq` builds the app config from
graze's recorded feed list, so another mirror is one line there.

to stay light on the source, each cell polls page 1 only (page 2 only when
nothing on page 1 was seen before), spreads its first poll across its
interval, backs off exponentially to 10 minutes while the source fails, and
the host enforces any Retry-After. national feeds poll every 30 s and states
every 60 s, so the three come to about 0.08 requests a second. measured
locally against the recorded pages: front and spongebob alone 21 MB RSS, with
the three mirrors 31 MB, and about 2.2 MB more per mirror after that (55
mirrors: 147 MB).

