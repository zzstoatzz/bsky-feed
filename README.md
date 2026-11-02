# bsky-feed

my bluesky feeds, served as cells on [zeldi](https://tangled.org/zzstoatzz.io/zeldi): the spongebob feed (alternating-case posts from jetstream) and mirrors of [graze](https://graze.social)'s midterms feeds, behind one feed generator. this repo began as a python feed generator built on [MarshalX's template](https://github.com/MarshalX/bluesky-feed-generator); that version is in the history.

**live:** [feed.zzstoatzz.io](https://feed.zzstoatzz.io)

## install

requires zig 0.17.0. zeldi is fetched by the build and pinned in `build.zig.zon`.

```sh
git clone https://github.com/zzstoatzz/bsky-feed
cd bsky-feed
zig build
```

## use

```sh
zig-out/bin/zeldi dev --config zeldi.json --fixture testdata/jetstream.ndjson
curl localhost:8080/                    # the feed directory
```

`--fixture` replays a recorded jetstream capture. `--live` connects to jetstream instead; never use it on a home network, where a sustained firehose stream risks an ISP ban.

## design

- **the app owns its deploy, zeldi owns the runtime** — cells build against zeldi's sdk as a zig dependency, and this repo ships the zeldi binary with its own app config.
- **one cell per feed, one front cell for the generator** — each feed keeps its own sqlite and sees one event at a time; the front answers the did document, describeFeedGenerator and the directory, and routes skeleton requests by feed uri.
- **the machine holds no account credentials** — serving a feed is a public read; the app password that writes feed records stays on the laptop.

## develop

```sh
zig build test                          # filter parity with the python version, and the e2e on the fixture
zig build e2e                           # just the e2e: paging, restart resume, 64 cells, the front, the mirrors
fly deploy --remote-only                # build on fly's builder and roll the one machine
```

## docs

the [docs](https://github.com/zzstoatzz/bsky-feed/tree/main/docs) directory holds the deploy, its secrets, and how feed records get published.

## license

[MIT](https://github.com/zzstoatzz/bsky-feed/blob/main/LICENSE)
