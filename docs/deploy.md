# deploy

the feeds run as the `feeds` tenant on [cellar](https://tangled.org/zzstoatzz.io/cellar),
one Fly machine that hosts several apps' zeldi cells. cellar pins a commit of
this repository, builds the cells from it, and reads `zeldi.json` for the
tenant; its front process sends `feed.zzstoatzz.io` to zeldi with the host
intact. this repository has no deploy of its own: a change ships when cellar's
pin moves to its commit and cellar deploys.

cellar's zeldi runs with `--live`, so the cells hold the only jetstream
connection, and their stores sync to R2, so a new machine starts from them.

## before a deploy

1. `zig build test` passes at the commit.
2. every app on cellar builds against the same zeldi, and cellar's build stops
   when they disagree, so bumping zeldi here means bumping it in the others.
3. move the `feeds` pin in cellar's `pins.json` and deploy cellar as its readme
   says.
4. every feed answers:
   ```bash
   curl -s -o /dev/null -w "%{http_code}\n" \
     "https://feed.zzstoatzz.io/xrpc/app.bsky.feed.getFeedSkeleton?feed=at://did:plc:xbtmt2zjwlrfegqvch7fboei/app.bsky.feed.generator/n8"
   ```
   rolling back is moving the pin back and deploying again.

## secrets

serving a feed needs no credentials. getFeedSkeleton is a public read, the did
document is public, and the feed records that point here live on whichever
account published them. so the design is three tiers, and the machine only ever
sees the middle one.

**public config, in this repository.** `zeldi.json` holds
the cells, their routes, and each cell's config: the hostname, the service did,
and the at-uris of the feeds. a feed published by any account joins by adding
its uri there; its record's `did` field names `did:web:feed.zzstoatzz.io`, and
nothing about the publishing account reaches the host.

**machine secrets, on cellar.** only values the host itself uses, like the
bucket token cellar's zeldi syncs cell stores to R2 with. account passwords
never go there.

**publishing credentials, per account, off the machine.** an app password is
only needed to write or update an `app.bsky.feed.generator` record, which is a
step run from the laptop when a feed is created or its name or avatar changes.
each account gets its own app password, made for that purpose, so revoking one
touches one account. they live in the sops store
(`~/tangled.org/zzstoatzz.io/secrets/prod.yaml`) under that account's
`atproto.<account>` entry, with the handle's dots as dashes. zzstoatzz.io's is
`atproto.zzstoatzz-io.app-password`, named "zeldi publish". the
`atproto-app-password` skill makes or rotates one.

`publish.py` resolves the publishing account's PDS from its did and logs in
there, so the one-liner needs only the handle and the password from sops:

```bash
HANDLE=zzstoatzz.io PASSWORD="$(sops decrypt --extract '["atproto"]["zzstoatzz-io"]["app-password"]' ~/tangled.org/zzstoatzz.io/secrets/prod.yaml)" ./publish.py --publish
```

writing a value into the store with `sops set --value-stdin` takes JSON, so a
bare password has to be quoted first: `| jq -R . |` works, and `jq -Rj` does
not, because `-j` strips the quotes again and sops answers "Value for --set is
not valid JSON".

cells cannot read the environment: the only outside input a cell gets is its
own config and the origins its egress grants allow. a secret on the machine is
not reachable from cell code.

feeds that personalize by viewer verify the requester's service-auth jwt
against the signing key in that viewer's did document. those are public keys,
so that needs no secret either.
