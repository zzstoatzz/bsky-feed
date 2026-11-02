//! port of bsky-feed's spongebob_filter (example_custom_filters.py).
//!
//! python runs two re.sub passes (urls, then hashtags) and then scans each
//! whitespace-split word for 7 alternating-case ascii letters. splitting only
//! resets the scan, which every non-letter already does, so the scan here
//! runs over the whole stripped text.

const std = @import("std");

pub const min_len = 7;

pub fn matches(gpa: std.mem.Allocator, text: []const u8) error{OutOfMemory}!bool {
    if (text.len == 0) return false;
    if (text.len >= 6 and std.ascii.eqlIgnoreCase(text[0..6], "macro:")) return false;

    const buf = try gpa.alloc(u8, text.len * 2);
    defer gpa.free(buf);
    const no_urls = stripUrls(text, buf[0..text.len]);
    const stripped = stripHashtags(no_urls, buf[text.len..]);
    return hasAlternatingRun(stripped);
}

/// the single-pass state machine from _is_spongebob_word, over bytes.
/// non-ascii bytes are non-letters, as their code points are in python.
pub fn hasAlternatingRun(s: []const u8) bool {
    var lower_first: usize = 0;
    var upper_first: usize = 0;
    for (s) |c| {
        const is_lower = c >= 'a' and c <= 'z';
        const is_upper = c >= 'A' and c <= 'Z';
        if (!is_lower and !is_upper) {
            lower_first = 0;
            upper_first = 0;
            continue;
        }
        if (is_lower == (lower_first % 2 == 0)) {
            lower_first += 1;
        } else {
            lower_first = if (is_lower) 1 else 0;
        }
        if (is_upper == (upper_first % 2 == 0)) {
            upper_first += 1;
        } else {
            upper_first = if (is_upper) 1 else 0;
        }
        if (lower_first >= min_len or upper_first >= min_len) return true;
    }
    return false;
}

/// URL_RE.sub("", text) for r"https?://\S+|www\.\S+|[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/\S+".
/// every alternative ends in a greedy \S+, so a match runs to the end of its token.
pub fn stripUrls(s: []const u8, out: []u8) []u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (urlAt(s, i)) {
            i = tokenEnd(s, i);
            continue;
        }
        out[n] = s[i];
        n += 1;
        i += 1;
    }
    return out[0..n];
}

/// HASHTAG_RE.sub("", text) for r"#\w+".
pub fn stripHashtags(s: []const u8, out: []u8) []u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '#') {
            var j = i + 1;
            while (j < s.len) {
                const w = wordCharLen(s, j);
                if (w == 0) break;
                j += w;
            }
            if (j > i + 1) {
                i = j;
                continue;
            }
        }
        out[n] = s[i];
        n += 1;
        i += 1;
    }
    return out[0..n];
}

fn urlAt(s: []const u8, i: usize) bool {
    const rest = s[i..];
    if (std.mem.startsWith(u8, rest, "http")) {
        var j: usize = 4;
        if (j < rest.len and rest[j] == 's') j += 1;
        if (std.mem.startsWith(u8, rest[j..], "://") and nonSpaceAt(s, i + j + 3)) return true;
    }
    if (std.mem.startsWith(u8, rest, "www.") and nonSpaceAt(s, i + 4)) return true;
    return domainPathAt(s, i);
}

/// [a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/\S+ starting at i. '.' and letters are in the
/// leading class, so the '/' must end the maximal class run, and the tld is the
/// letters after the run's last non-letter.
fn domainPathAt(s: []const u8, i: usize) bool {
    var e = i;
    while (e < s.len and isHostChar(s[e])) e += 1;
    if (e == i or e >= s.len or s[e] != '/' or !nonSpaceAt(s, e + 1)) return false;
    var k = e;
    while (k > i and std.ascii.isAlphabetic(s[k - 1])) k -= 1;
    if (k == i) return false;
    const dot = k - 1;
    return s[dot] == '.' and dot > i and e - k >= 2;
}

fn isHostChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '.' or c == '-';
}

fn nonSpaceAt(s: []const u8, i: usize) bool {
    return i < s.len and spaceLen(s, i) == 0;
}

fn tokenEnd(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len and spaceLen(s, i) == 0) i += 1;
    return i;
}

/// byte length of the python-\s code point at s[i], or 0 if it is not whitespace.
pub fn spaceLen(s: []const u8, i: usize) usize {
    const c = s[i];
    if (c < 0x80) return switch (c) {
        '\t', '\n', 0x0b, 0x0c, '\r', 0x1c...0x1f, ' ' => 1,
        else => 0,
    };
    const cp = decode(s, i) orelse return 0;
    return switch (cp.value) {
        0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => cp.len,
        else => 0,
    };
}

/// byte length of the python-\w code point at s[i], or 0. non-ascii code
/// points count as word characters except whitespace, punctuation, symbol,
/// and emoji blocks, which approximates str.isalnum() closely enough for a
/// filter that only looks at ascii letters.
fn wordCharLen(s: []const u8, i: usize) usize {
    const c = s[i];
    if (c < 0x80) return if (std.ascii.isAlphanumeric(c) or c == '_') 1 else 0;
    const cp = decode(s, i) orelse return 0;
    if (spaceLen(s, i) != 0) return 0;
    const word = switch (cp.value) {
        0xaa, 0xb2, 0xb3, 0xb5, 0xb9, 0xba, 0xbc...0xbe => true,
        0x80...0xa9, 0xab...0xb1, 0xb4, 0xb6...0xb8, 0xbb, 0xbf, 0xd7, 0xf7 => false,
        0x0300...0x036f => false,
        0x2000...0x2bff, 0x2e00...0x2e7f => false,
        0x3000...0x3004, 0x3008...0x3020, 0x3030 => false,
        0xfe00...0xfe0f, 0xfe30...0xfe4f => false,
        0xff00...0xff0f, 0xff1a...0xff20, 0xff3b...0xff40, 0xff5b...0xff65 => false,
        0x1f000...0x1faff, 0xe0000...0xe007f => false,
        else => true,
    };
    return if (word) cp.len else 0;
}

const CodePoint = struct { value: u21, len: usize };

fn decode(s: []const u8, i: usize) ?CodePoint {
    const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return null;
    if (i + len > s.len) return null;
    const value = std.unicode.utf8Decode(s[i .. i + len]) catch return null;
    return .{ .value = value, .len = len };
}
