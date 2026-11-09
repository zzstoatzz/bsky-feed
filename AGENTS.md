# agents

## live jetstream

never run `zeldi dev --live`, or anything else that holds a jetstream
connection, on nate's laptop or on heavypad. both sit on a home connection, and
a sustained firehose stream risks an ISP ban. replay
`testdata/jetstream.ndjson` with `--fixture` instead; `--live` runs only on
cellar.

## deploys

feed.zzstoatzz.io runs on cellar from a pinned commit of this repo; moving that
pin is the deploy (docs/deploy.md). confirm with nate before moving it to a
commit that changes the prod config or bumps zeldi.

## tests

`zig build test` runs everything and needs no network once zeldi is fetched.
