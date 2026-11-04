const std = @import("std");
const api = @import("../api.zig");
const session = @import("../api/session.zig");

const nonce_a = "0123456789abcdef0123456789abcdef";
const nonce_b = "fedcba9876543210fedcba9876543210";

fn expectSessionJson(expected: []const u8, body: session.Body) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try session.writeBody(&out.writer, body);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "an anonymous viewer is null and carries only the CSRF token" {
    try expectSessionJson(
        \\{"viewer":null,"csrf_token":"tok"}
    , .{ .viewer = null, .csrf_token = "tok" });
}

test "a logged-in viewer is named, and nothing secret is serialized" {
    try expectSessionJson(
        \\{"viewer":{"name":"alice"},"csrf_token":"tok"}
    , .{ .viewer = .{ .name = "alice" }, .csrf_token = "tok" });
}

test "the CSRF token is fixed for a browser's nonce and differs between nonces" {
    const a1 = session.csrfToken(nonce_a);
    const a2 = session.csrfToken(nonce_a);
    const b = session.csrfToken(nonce_b);
    try std.testing.expectEqualStrings(&a1, &a2);
    try std.testing.expect(!std.mem.eql(u8, &a1, &b));
    // the token never reveals the HttpOnly nonce it is bound to
    try std.testing.expect(std.mem.indexOf(u8, &a1, nonce_a) == null);
}

test "a same-origin write carrying its browser's token is allowed" {
    const token = session.csrfToken(nonce_a);
    try std.testing.expectEqual(session.WriteCheck.allowed, session.checkWrite(.{
        .origin = "http://127.0.0.1:5173",
        .host = "127.0.0.1:5173",
        .token = &token,
        .nonce = nonce_a,
    }));
}

test "a write from a non-browser client without an Origin still needs the token" {
    const token = session.csrfToken(nonce_a);
    try std.testing.expectEqual(session.WriteCheck.allowed, session.checkWrite(.{ .origin = null, .host = "haxy.test", .token = &token, .nonce = nonce_a }));
    try std.testing.expectEqual(session.WriteCheck.missing_token, session.checkWrite(.{ .origin = null, .host = "haxy.test", .token = null, .nonce = nonce_a }));
}

test "a write from a foreign origin is rejected even with a valid token" {
    const token = session.csrfToken(nonce_a);
    for ([_][]const u8{
        "http://evil.example",
        // another port on the same host is another origin
        "http://127.0.0.1:8080",
        // the scheme-relative and opaque forms browsers send for sandboxed pages
        "null",
        "127.0.0.1:5173",
    }) |origin| {
        try std.testing.expectEqual(session.WriteCheck.foreign_origin, session.checkWrite(.{
            .origin = origin,
            .host = "127.0.0.1:5173",
            .token = &token,
            .nonce = nonce_a,
        }));
    }
}

test "an origin matches its host regardless of case and default ports" {
    const token = session.csrfToken(nonce_a);
    const pairs = [_][2][]const u8{
        .{ "http://Haxy.Example", "haxy.example" },
        .{ "http://haxy.example", "haxy.example:80" },
        .{ "https://haxy.example:443", "haxy.example" },
    };
    for (pairs) |pair| {
        try std.testing.expectEqual(session.WriteCheck.allowed, session.checkWrite(.{ .origin = pair[0], .host = pair[1], .token = &token, .nonce = nonce_a }));
    }
    // a default port only matches its own scheme
    try std.testing.expectEqual(session.WriteCheck.foreign_origin, session.checkWrite(.{ .origin = "https://haxy.example", .host = "haxy.example:80", .token = &token, .nonce = nonce_a }));
}

test "a write without a token, or with another browser's token, is rejected" {
    const other = session.csrfToken(nonce_b);
    const origin = "http://127.0.0.1:5173";
    const host = "127.0.0.1:5173";
    try std.testing.expectEqual(session.WriteCheck.missing_token, session.checkWrite(.{ .origin = origin, .host = host, .token = null, .nonce = nonce_a }));
    try std.testing.expectEqual(session.WriteCheck.missing_token, session.checkWrite(.{ .origin = origin, .host = host, .token = "", .nonce = nonce_a }));
    try std.testing.expectEqual(session.WriteCheck.bad_token, session.checkWrite(.{ .origin = origin, .host = host, .token = &other, .nonce = nonce_a }));
    // a browser that never fetched a token has no nonce to bind one to
    try std.testing.expectEqual(session.WriteCheck.bad_token, session.checkWrite(.{ .origin = origin, .host = host, .token = &other, .nonce = null }));
    // nor does a malformed nonce cookie
    try std.testing.expectEqual(session.WriteCheck.bad_token, session.checkWrite(.{ .origin = origin, .host = host, .token = &other, .nonce = "../sessions" }));
}

test "a write with no Host header is rejected when it names an Origin" {
    const token = session.csrfToken(nonce_a);
    try std.testing.expectEqual(session.WriteCheck.foreign_origin, session.checkWrite(.{ .origin = "http://127.0.0.1:5173", .host = null, .token = &token, .nonce = nonce_a }));
}

fn expectLoginInvalid(content_type: ?[]const u8, body: []const u8, expected_fields: []const api.FieldError) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    switch (try session.parseLogin(arena.allocator(), content_type, body)) {
        .credentials => return error.TestExpectedInvalid,
        .invalid => |err| {
            try std.testing.expectEqual(api.ErrorCode.validation, err.code);
            try std.testing.expect(err.message.len > 0);
            try std.testing.expectEqual(expected_fields.len, err.field_errors.len);
            for (expected_fields, err.field_errors) |expected, actual| {
                try std.testing.expectEqualStrings(expected.field, actual.field);
                try std.testing.expect(actual.message.len > 0);
            }
        },
    }
}

test "a login request reads the username and password from a JSON object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try session.parseLogin(arena.allocator(), "application/json; charset=utf-8",
        \\{"username":"alice","password":"p@ss word"}
    );
    try std.testing.expectEqualStrings("alice", result.credentials.username);
    try std.testing.expectEqualStrings("p@ss word", result.credentials.password);
}

test "a login request names each missing field" {
    try expectLoginInvalid("application/json", "{}", &.{
        .{ .field = "username", .message = "" },
        .{ .field = "password", .message = "" },
    });
    try expectLoginInvalid("application/json",
        \\{"username":"alice","password":""}
    , &.{.{ .field = "password", .message = "" }});
    try expectLoginInvalid("application/json",
        \\{"username":"  ","password":"x"}
    , &.{.{ .field = "username", .message = "" }});
}

test "a login request that isn't a JSON object is a validation error without field errors" {
    try expectLoginInvalid("application/json", "not json", &.{});
    try expectLoginInvalid("application/json", "[\"alice\"]", &.{});
    try expectLoginInvalid("application/json",
        \\{"username":7,"password":"x"}
    , &.{});
    // a form post (which a foreign page can send without a preflight) is refused
    try expectLoginInvalid("application/x-www-form-urlencoded", "username=alice&password=x", &.{});
    try expectLoginInvalid(null,
        \\{"username":"alice","password":"x"}
    , &.{});
}
