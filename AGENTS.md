# agents

## live jetstream

never run `zeldi dev --live`, or anything else that holds a jetstream
connection, on nate's laptop or on heavypad. both sit on a home connection, and
a sustained firehose stream risks an ISP ban. replay
`testdata/jetstream.ndjson` with `--fixture` instead; `--live` runs only on the
fly machine.

## deploys

`fly deploy` here rolls feed.zzstoatzz.io. confirm with nate before a deploy
that changes the prod config or bumps zeldi.

## tests

`zig build test` runs everything and needs no network once zeldi is fetched.
