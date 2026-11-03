# builds zeldi.json from graze's feed list, recorded once with
#   curl 'https://public.api.bsky.app/xrpc/app.bsky.feed.getActorFeeds?actor=did:plc:i6y3jdklpvkjvynvsrnqfdoq&limit=100'
# into testdata/graze/actor-feeds.json (trimmed to uri, did, displayName). run
#   jq --argjson all false -f zeldi.jq testdata/graze/actor-feeds.json > zeldi.json
# from this directory. `mirrored` is what the app serves; add a line to mirror
# another feed. `--argjson all true` mirrors every state, national, desk,
# newsroom and vote feed in the list instead.

def publisher: "did:plc:xbtmt2zjwlrfegqvch7fboei";
def spongebob: "at://\(publisher)/app.bsky.feed.generator/n8";

# source rkey -> our rkey and poll interval
def mirrored: {
  "races-natl": {rkey: "live-natl", poll_ms: 30000},
  "desk-natl": {rkey: "live-desk", poll_ms: 30000},
  "races-mi": {rkey: "live-mi", poll_ms: 60000}
};

def national: {"races-natl": "live-natl", "desk-natl": "live-desk", "news-natl": "live-news", "elect-natl": "live-vote"};
def everything($src):
  if national[$src] then {rkey: national[$src], poll_ms: 30000}
  elif ($src | test("^races-[a-z]{2}$")) then {rkey: ("live-" + ($src | ltrimstr("races-"))), poll_ms: 60000}
  else null end;

[.feeds[]
  | (.uri | split("/") | last) as $src
  | (if $all then everything($src) else mirrored[$src] end) as $m
  | select($m != null)
  | $m + {source: .uri, endpoint: ("https://" + (.did | ltrimstr("did:web:")))}]
| sort_by([.poll_ms, .rkey]) as $mirrors
| {
    cells: (
      [
        {
          name: "feed:front",
          wasm: "zig-out/cells/feeds-front.wasm",
          front: true,
          config: {
            hostname: "feed.zzstoatzz.io",
            feeds: ([{uri: spongebob, cell: "feed:spongebob"}]
              + [$mirrors[] | {uri: "at://\(publisher)/app.bsky.feed.generator/\(.rkey)", cell: "feed:\(.rkey)"}])
          }
        },
        {
          name: "feed:spongebob",
          wasm: "zig-out/cells/spongebob.wasm",
          config: {hostname: "feed.zzstoatzz.io", feeds: [spongebob]}
        }
      ]
      + [$mirrors[] | {
          name: "feed:\(.rkey)",
          wasm: "zig-out/cells/feeds-mirror.wasm",
          egress: [{origin: .endpoint, headers: {"user-agent": "zeldi feeds (+https://feed.zzstoatzz.io)"}}],
          config: {
            feed: "at://\(publisher)/app.bsky.feed.generator/\(.rkey)",
            source: .source,
            endpoint: .endpoint,
            poll_ms: .poll_ms
          }
        }]
    ),
    routes: [{prefix: "/", cell: "feed:front"}]
  }
