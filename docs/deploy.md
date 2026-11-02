# deploy

the feeds run on zeldi as one fly machine, the `zeldi` app in `ord`: shared
cpu, 256 MB, and a 1 GB volume at `/data` for the cell sqlite files. it is the
only place the feeds hold a live jetstream connection. `fly deploy --remote-only` builds the image on
fly's builder, so the zig build never runs on a home machine.

the machine never stops on its own (`auto_stop_machines = "off"`): a stopped
machine is a feed that falls behind jetstream.

## next deploy

prod runs v9, zeldi `406f83f`. this pin is zeldi `6416511`, and the next
deploy carries:

- the feeds' databases move from `/data/cells/` to `/data/tenants/feeds/` at
  the first start, each checkpointed into itself and renamed whole; the log
  names every move, and a second start finds nothing to move. take a volume
  snapshot first (`fly volumes snapshots create <vol>`), so going back to
  `406f83f` is a restore, since that build only reads `/data/cells/`.
- the runner jails itself: its own mount, network, pid and ipc namespaces
  with only `/data/tenants/feeds` and its modules mounted, uid 100000, no
  capabilities, and a seccomp filter. `/proc/<runner>/status` shows
  `NoNewPrivs: 1` and `Seccomp: 2` on the jailed process.
- it runs in a `zeldi.feeds` cgroup in each of fly's v1 memory, pids and cpu
  hierarchies: 128 MiB, 64 threads, one cpu. the supervisor logs
  `runners run without cgroup limits` if it couldn't set them.

nothing about the cells, their egress or their config changes. after the
deploy, every cell should show `disabled` false and `traps`,
`inbox_rejected`, `backoff_rejected` and `reinstantiations` at 0, and
`zeldi cells 9090` lists the feeds runner under `runners`.

## before a deploy

`zig build test` runs the cells on the jetstream fixture and the mirrors
against a local stand-in, so it never reaches a real https origin. v6 (zeldi
`be26d5b`) passed it and still aborted in prod on the mirrors' first poll of
api.graze.social, in tls setup the tests never ran. so a deploy also runs the
image it will ship, on this machine, against the fixture and the real https
origins, and goes ahead only if that holds:

1. build and push the image on fly's builder without deploying it, under a
   label of its own:
   `fly deploy --remote-only --build-only --push --image-label gate-<sha> -a zeldi`
2. `fly auth docker`, then run it on the fixture instead of jetstream (the
   mirrors still make their real https GETs to api.graze.social; that is plain
   https, not a firehose, so it is fine on a home network):
   ```bash
   docker run --rm -d --name zeldi-gate --platform linux/amd64 -p 18080:8080 \
     -v "$PWD/testdata:/testdata:ro" registry.fly.io/zeldi:gate-<sha> \
     /app/zig-out/bin/zeldi dev --fixture /testdata/jetstream.ndjson \
     --listen 0.0.0.0 --data /tmp/data --config zeldi.json --operator-port 9090
   ```
3. after the mirrors' first poll (a minute covers `poll_ms`),
   `docker exec zeldi-gate /app/zig-out/bin/zeldi cells 9090` must show every
   cell with `disabled` false and `traps`,
   `inbox_rejected`, `backoff_rejected` and `reinstantiations` at 0, each mirror
   with calls past its first, and `docker logs zeldi-gate` no `panic` and no
   egress refusal. then `docker rm -f zeldi-gate`.
4. deploy that same image, so prod runs what was checked:
   `fly deploy --image registry.fly.io/zeldi:gate-<sha> -a zeldi`

record `fly releases -a zeldi` and the running image first, so a rollback is
`fly deploy --image <that image> -a zeldi`.

## secrets

serving a feed needs no credentials. getFeedSkeleton is a public read, the did
document is public, and the feed records that point here live on whichever
account published them. so the design is three tiers, and the machine only ever
sees the middle one.

**public config, in the image.** `zeldi.json` holds
the cells, their routes, and each cell's config: the hostname, the service did,
and the at-uris of the feeds. a feed published by any account joins by adding
its uri there; its record's `did` field names `did:web:feed.zzstoatzz.io`, and
nothing about the publishing account reaches the host.

**machine secrets, as fly secrets.** only values the process itself uses, like
the bucket keys phase 1 needs (`fly storage create` sets those). none exist
today. account passwords never go here.

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

the old `PASSWORD` fly secret on `bsky-feed` still exists until that app is
decommissioned; nothing here reads it.

cells cannot read the environment at all: the guest imports are `sql_exec`,
`sql_query`, `log`, `now`, `set_alarm`, and `subscribe`, with no WASI, and the
only outside input a cell gets is its own config. a fly
secret on the machine is not reachable from cell code. if a future cell needs a
credential of its own, the host hands it over by cell name through a new
import, so one cell never sees another's.

feeds that personalize by viewer verify the requester's service-auth jwt
against the signing key in that viewer's did document. those are public keys,
so that needs no secret either.

## cutover

the spongebob feed record already points at `did:web:feed.zzstoatzz.io`, so
moving it means moving that hostname, with no record write:

1. issue a cert for `feed.zzstoatzz.io` on `zeldi` before moving anything
   (`fly certs add`, validated through the `_acme-challenge` CNAME).
2. point the `feed.zzstoatzz.io` CNAME at `zeldi.fly.dev` in cloudflare.
3. roll back by pointing it at `bsky-feed.fly.dev` again, which keeps running
   until zeldi has served for a while.

once `bsky-feed` is retired, its `PASSWORD` fly secret is an app password
sitting on a server that never needed it, so revoke it rather than move it.
