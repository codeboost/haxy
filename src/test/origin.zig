const std = @import("std");
const origin = @import("../origin.zig");

fn expectSame(value: []const u8, host: ?[]const u8) !void {
    if (!origin.sameOrigin(value, host)) {
        std.debug.print("expected Origin \"{s}\" to name Host \"{?s}\"\n", .{ value, host });
        return error.TestExpectedSameOrigin;
    }
}

fn expectForeign(value: []const u8, host: ?[]const u8) !void {
    if (origin.sameOrigin(value, host)) {
        std.debug.print("expected Origin \"{s}\" not to name Host \"{?s}\"\n", .{ value, host });
        return error.TestExpectedForeignOrigin;
    }
}

test "an origin names its own host and port" {
    try expectSame("http://127.0.0.1:5173", "127.0.0.1:5173");
    try expectSame("http://haxy.example", "haxy.example");
    try expectSame("https://haxy.example:8443", "haxy.example:8443");
}

test "another host or another port on the same host is another origin" {
    try expectForeign("http://evil.example", "haxy.example");
    try expectForeign("http://127.0.0.1:8080", "127.0.0.1:5173");
    try expectForeign("http://127.0.0.1", "127.0.0.1:5173");
    try expectForeign("http://localhost:5173", "127.0.0.1:5173");
    // a suffix or prefix of the host is not the host
    try expectForeign("http://evilhaxy.example", "haxy.example");
    try expectForeign("http://haxy.example.evil", "haxy.example");
}

test "an origin matches regardless of case" {
    try expectSame("http://Haxy.Example", "haxy.example");
    try expectSame("HTTPS://haxy.example", "HAXY.EXAMPLE");
}

test "a default port matches its absence, but only for its own scheme" {
    try expectSame("http://haxy.example", "haxy.example:80");
    try expectSame("http://haxy.example:80", "haxy.example");
    try expectSame("https://haxy.example:443", "haxy.example");
    try expectSame("https://haxy.example", "haxy.example:443");
    try expectForeign("https://haxy.example", "haxy.example:80");
    try expectForeign("http://haxy.example", "haxy.example:443");
    // a port is compared as written, so a padded one is another origin
    try expectForeign("http://haxy.example:080", "haxy.example:80");
}

test "the opaque origin a sandboxed page or a privacy policy sends is never the host's" {
    try expectForeign("null", "127.0.0.1:5173");
    try expectForeign("null", "null");
}

test "a malformed origin is refused" {
    for ([_][]const u8{
        "",
        "127.0.0.1:5173",
        "//127.0.0.1:5173",
        "http:/127.0.0.1:5173",
        "http://",
        "http://127.0.0.1:5173/",
        "http://127.0.0.1:5173/path",
        "http://127.0.0.1:5173?query",
        "http://127.0.0.1:5173#fragment",
        "http://user@127.0.0.1:5173",
        "ftp://127.0.0.1:5173",
        "ws://127.0.0.1:5173",
        "file://127.0.0.1:5173",
    }) |value| try expectForeign(value, "127.0.0.1:5173");
}

test "an origin with no host is refused even against an empty Host" {
    try expectForeign("http://:80", "");
    try expectForeign("http://:80", ":80");
    try expectForeign("http://:8080", ":8080");
    try expectForeign("http://", "");
}

test "a request with no Host header has no origin of its own" {
    try expectForeign("http://127.0.0.1:5173", null);
}

test "IPv6 hosts compare by their bracketed literal and port" {
    try expectSame("http://[::1]:5173", "[::1]:5173");
    try expectSame("http://[::1]", "[::1]:80");
    try expectSame("http://[::1]:80", "[::1]");
    try expectSame("http://[FE80::1]:8080", "[fe80::1]:8080");
    try expectForeign("http://[::1]:8080", "[::1]:5173");
    try expectForeign("http://[::2]:5173", "[::1]:5173");
    // an address ending in what looks like a default port is not a port
    try expectForeign("http://[::80]", "[::]");
}

test "a form write is checked only for methods that change state" {
    for ([_]std.http.Method{ .GET, .HEAD }) |method| {
        try std.testing.expect(origin.formWriteAllowed(.{ .method = method, .origin = "http://evil.example", .host = "haxy.example" }));
    }
    for ([_]std.http.Method{ .POST, .PUT, .PATCH, .DELETE, .OPTIONS }) |method| {
        try std.testing.expect(!origin.formWriteAllowed(.{ .method = method, .origin = "http://evil.example", .host = "haxy.example" }));
        try std.testing.expect(!origin.formWriteAllowed(.{ .method = method, .origin = "null", .host = "haxy.example" }));
        try std.testing.expect(origin.formWriteAllowed(.{ .method = method, .origin = "http://haxy.example", .host = "haxy.example" }));
    }
}

test "a form write without an Origin, as non-browser clients send, is allowed" {
    try std.testing.expect(origin.formWriteAllowed(.{ .method = .POST, .origin = null, .host = "haxy.example" }));
    try std.testing.expect(origin.formWriteAllowed(.{ .method = .POST, .origin = null, .host = null }));
}
