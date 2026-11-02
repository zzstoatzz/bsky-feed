//! the directory at `/`: one row per served feed, linked out to bluesky. the
//! cell renders uris and links; the script fills names and avatars from the
//! public appview, so the page still works when that call fails.

const std = @import("std");
const Writer = std.Io.Writer;

pub fn write(w: *Writer, hostname: []const u8, feeds: []const []const u8) Writer.Error!void {
    try w.writeAll(head);
    try w.print("<h1>{f}</h1>\n<p class=\"sub\">feeds i run on zeldi: zig cells on wasm, each with its own sqlite.</p>\n<ul>\n", .{escaped(hostname)});
    var listed: usize = 0;
    for (feeds) |uri| {
        const at = AtUri.parse(uri) orelse continue;
        try w.print(
            \\<li data-uri="{f}"><a href="https://bsky.app/profile/{f}/feed/{f}">
            \\<span class="avatar"></span><span class="text"><span class="name">{f}</span><span class="desc"></span><code>{f}</code></span>
            \\</a></li>
            \\
        , .{ escaped(uri), escaped(at.did), escaped(at.rkey), escaped(at.rkey), escaped(uri) });
        listed += 1;
    }
    if (listed == 0) try w.writeAll("<li class=\"empty\">no feeds yet</li>\n");
    try w.writeAll(tail);
}

pub const AtUri = struct {
    did: []const u8,
    collection: []const u8,
    rkey: []const u8,

    /// `at://<did>/<collection>/<rkey>` and nothing else.
    pub fn parse(uri: []const u8) ?AtUri {
        if (!std.mem.startsWith(u8, uri, "at://")) return null;
        var it = std.mem.splitScalar(u8, uri["at://".len..], '/');
        const at: AtUri = .{
            .did = it.next() orelse return null,
            .collection = it.next() orelse return null,
            .rkey = it.next() orelse return null,
        };
        if (it.next() != null or at.did.len == 0 or at.rkey.len == 0) return null;
        return at;
    }
};

fn escaped(s: []const u8) std.fmt.Alt([]const u8, writeEscaped) {
    return .{ .data = s };
}

fn writeEscaped(s: []const u8, w: *Writer) Writer.Error!void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(c),
    };
}

const head =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\<meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1">
    \\<title>feeds</title>
    \\<style>
    \\:root { --bg: #fbfbfa; --fg: #1c1c1a; --muted: #6b6b66; --line: #e4e4e0; --hover: #f1f1ee; color-scheme: light dark; }
    \\@media (prefers-color-scheme: dark) { :root { --bg: #161615; --fg: #ececea; --muted: #9a9a94; --line: #2c2c2a; --hover: #1f1f1d; } }
    \\* { box-sizing: border-box; }
    \\body { margin: 0; background: var(--bg); color: var(--fg); font: 16px/1.45 system-ui, -apple-system, sans-serif; }
    \\main { max-width: 40rem; margin: 0 auto; padding: 3rem 1rem; }
    \\h1 { font-size: 1.1rem; font-weight: 600; margin: 0; }
    \\.sub { color: var(--muted); margin: .25rem 0 2rem; }
    \\ul { list-style: none; margin: 0; padding: 0; border-top: 1px solid var(--line); }
    \\li { border-bottom: 1px solid var(--line); }
    \\li.empty { padding: 1rem 0; color: var(--muted); }
    \\li a { display: flex; gap: .875rem; align-items: flex-start; padding: 1rem .5rem; color: inherit; text-decoration: none; min-height: 44px; }
    \\li a:hover, li a:focus-visible { background: var(--hover); }
    \\.avatar { flex: none; width: 2.75rem; height: 2.75rem; border-radius: .5rem; background: var(--line) center / cover; }
    \\.text { display: flex; flex-direction: column; min-width: 0; }
    \\.name { font-weight: 600; }
    \\.desc { color: var(--muted); white-space: pre-line; }
    \\.desc:empty { display: none; }
    \\code { font: .75rem/1.4 ui-monospace, monospace; color: var(--muted); overflow-wrap: anywhere; margin-top: .25rem; }
    \\footer { margin-top: 2rem; color: var(--muted); font-size: .875rem; }
    \\footer a { color: inherit; }
    \\</style>
    \\</head>
    \\<body>
    \\<main>
    \\
;

const tail =
    \\</ul>
    \\<footer>source: <a href="https://tangled.org/zzstoatzz.io/zeldi">tangled.org/zzstoatzz.io/zeldi</a></footer>
    \\</main>
    \\<script>
    \\const rows = [...document.querySelectorAll("li[data-uri]")];
    \\if (rows.length) {
    \\  const q = rows.map((r) => "feeds=" + encodeURIComponent(r.dataset.uri)).join("&");
    \\  fetch("https://public.api.bsky.app/xrpc/app.bsky.feed.getFeedGenerators?" + q)
    \\    .then((r) => (r.ok ? r.json() : { feeds: [] }))
    \\    .then(({ feeds }) => {
    \\      for (const f of feeds) {
    \\        const row = rows.find((r) => r.dataset.uri === f.uri);
    \\        if (!row) continue;
    \\        row.querySelector(".name").textContent = f.displayName;
    \\        row.querySelector(".desc").textContent = f.description ?? "";
    \\        if (f.avatar) row.querySelector(".avatar").style.backgroundImage = `url("${f.avatar}")`;
    \\      }
    \\    })
    \\    .catch(() => {});
    \\}
    \\</script>
    \\</body>
    \\</html>
    \\
;
