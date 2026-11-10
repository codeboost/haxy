//! the connection itself: refusals that answer without the body, keep-alive,
//! malformed bodies, and the harness's own response parser and cookie jar

const std = @import("std");
const h = @import("harness.zig");

const gpa = std.testing.allocator;

const missing_issue = "/alice:open/issue:0123456789abcdef0123456789abcdef";
const new_repo_fields: []const h.Field = &.{ .{ "name", "fresh" }, .{ "description", "" }, .{ "hash", "sha1" }, .{ "access", "public" } };

// a refusal answers before the body arrives and closes the connection, so a
// client that never sends its body does not hold the server up
fn expectPromptRefusal(r: *const h.Response, status: std.http.Status, text: []const u8) !void {
    // first, since a body read that fails would otherwise show only as a 500
    try r.expectBodyUnread();
    try r.expectStatus(status);
    try r.expectBody(text);
    try r.expectConnectionClose();
}

test "web: a logged-out form post is refused without reading its body" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();

    const r = try visitor.postWithheld("/home/repo/new", new_repo_fields);
    defer r.deinit();
    try expectPromptRefusal(r, .forbidden, "log in to make changes");
}

test "web: a logged-out upload is refused without reading the file" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();

    const r = try visitor.send(.{ .method = "POST", .path = missing_issue ++ "/attach", .body = "hello\n", .withhold_body = true, .headers = &.{
        .{ .name = "content-type", .value = "text/plain" },
        .{ .name = "x-attachment-name", .value = "notes.txt" },
    } });
    defer r.deinit();
    try expectPromptRefusal(r, .forbidden, "log in to make changes");
}

test "web: a form post above the user's role is refused without reading its body" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    const r = try carol.postWithheld("/alice:open/repo/settings", &.{ .{ "name", "mine" }, .{ "description", "" }, .{ "access", "public" } });
    defer r.deinit();
    try expectPromptRefusal(r, .forbidden, "you don't have permission to do that");
}

test "web: a form post to a private repo the user can't see is refused without reading its body" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    const r = try carol.postWithheld("/alice:secret/issues/new", &.{ .{ "title", "let me in" }, .{ "labels", "" }, .{ "description", "" } });
    defer r.deinit();
    try expectPromptRefusal(r, .not_found, "repo not found");
}

test "web: a form post to a repo that doesn't exist is refused without reading its body" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try alice.postWithheld("/alice:nothere/issues/new", &.{ .{ "title", "hello" }, .{ "labels", "" }, .{ "description", "" } });
    defer r.deinit();
    try expectPromptRefusal(r, .not_found, "repo not found");
}

test "web: a form post from another site is refused without reading its body" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try alice.postWith("/home/repo/new", new_repo_fields, .{
        .withhold_body = true,
        .headers = &.{.{ .name = "origin", .value = "http://elsewhere.test" }},
    });
    defer r.deinit();
    try expectPromptRefusal(r, .forbidden, "you don't have permission to do that");
}

// a form post that creates `fresh`, then the get of where it leads, on one connection
fn expectKeepAlive(delivery: h.Delivery) !void {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try h.encodeForm(&body.writer, new_repo_fields);
    const responses = try alice.sendAll(&.{
        .{ .method = "POST", .path = "/home/repo/new", .body = body.written() },
        .{ .path = "/alice:fresh", .headers = &.{.{ .name = "accept", .value = "application/json" }} },
    }, delivery);
    defer responses.deinit();
    try std.testing.expectEqual(2, responses.items.len);
    try responses.items[0].expectRedirect("/alice:fresh");
    try std.testing.expectEqual(null, responses.items[0].header("connection"));
    try responses.items[1].expectStatus(.ok);
    try responses.items[1].expectJsonHas("page.repo");
}

test "web: a form post and the get of its redirect share one connection" {
    try expectKeepAlive(.one_by_one);
}

test "web: a form post and the get of its redirect are both answered when they arrive together" {
    try expectKeepAlive(.buffered);
}

test "web: a request after a refusal on the same connection is not answered" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try h.encodeForm(&body.writer, new_repo_fields);
    const responses = try visitor.sendAll(&.{
        .{ .method = "POST", .path = "/home/repo/new", .body = body.written() },
        .{ .path = "/" },
    }, .one_by_one);
    defer responses.deinit();
    try std.testing.expectEqual(1, responses.items.len);
    try expectRefusalClosing(responses.items[0], .forbidden, "log in to make changes");
}

fn expectRefusalClosing(r: *const h.Response, status: std.http.Status, text: []const u8) !void {
    try r.expectStatus(status);
    try r.expectBody(text);
    try r.expectConnectionClose();
}

// a body of `len` bytes that names a repo, for the form size limit
fn longForm(len: usize) ![]u8 {
    const body = try gpa.alloc(u8, len);
    @memcpy(body[0.."name=".len], "name=");
    @memset(body["name=".len..], 'a');
    return body;
}

const Malformed = enum { bad_percent, too_long, short };

fn sendMalformed(c: *h.Client, kind: Malformed) !*h.Response {
    return switch (kind) {
        .bad_percent => c.send(.{ .method = "POST", .path = "/home/repo/new", .body = "name=%zz&description=&hash=sha1&access=public" }),
        .too_long => {
            const body = try longForm(64 * 1024 + 1);
            defer gpa.free(body);
            return c.send(.{ .method = "POST", .path = "/home/repo/new", .body = body });
        },
        .short => c.send(.{ .method = "POST", .path = "/home/repo/new", .body = "name=fresh&description=&hash=sha1&access=public", .headers = &.{.{ .name = "content-length", .value = "100" }} }),
    };
}

test "web: a form with invalid percent-encoding is a server error naming it" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try sendMalformed(&alice, .bad_percent);
    defer r.deinit();
    try r.expectStatus(.internal_server_error);
    try r.expectBody("InvalidPercentEncoding");
}

test "web: a form above 64 KiB is a server error naming it" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try sendMalformed(&alice, .too_long);
    defer r.deinit();
    try r.expectStatus(.internal_server_error);
    try r.expectBody("StreamTooLong");
}

// the form reader stops at the end of input without checking the declared
// length, at 66c1ab6 as now, so a client that closes early has its form taken
test "web: a form cut short by the client closing is taken as the whole form" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try sendMalformed(&alice, .short);
    defer r.deinit();
    try r.expectRedirect("/alice:fresh");
    const repo = try alice.follow(r);
    defer repo.deinit();
    try repo.expectStatus(.ok);
}

test "web: a refusal wins over a malformed body" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();

    for ([_]Malformed{ .bad_percent, .too_long, .short }) |kind| {
        errdefer std.debug.print("with a {t} body\n", .{kind});
        const r = try sendMalformed(&visitor, kind);
        defer r.deinit();
        try expectRefusalClosing(r, .forbidden, "log in to make changes");
    }
}

// the harness's own parsing, on handcrafted bytes

test "web: the harness reads a response and rejects what is not one" {
    {
        const r = try h.Response.parse("HTTP/1.1 200 OK\r\ncontent-length: 2\r\ncontent-length: 2\r\nx-a: 1\r\n\r\nhi", "", false);
        defer r.deinit();
        try r.expectStatus(.ok);
        try r.expectBody("hi");
    }
    {
        // a reason may be left out
        const r = try h.Response.parse("HTTP/1.1 204\r\ncontent-length: 0\r\n\r\n", "", false);
        defer r.deinit();
        try r.expectStatus(.no_content);
    }
    const cases = [_]struct { []const u8, anyerror }{
        .{ "HTTP/1.1 200 OK\r\ncontent-length: 2\r\ncontent-length: 3\r\n\r\nhi", error.TestConflictingContentLength },
        .{ "HTTP/1.1 200 OK\r\ncontent-length: 5\r\n\r\nhi", error.TestResponseTruncated },
        .{ "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nhi!", error.TestTrailingResponseBytes },
        .{ "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n", error.TestResponseTruncated },
        .{ "HTTP/1.1 200 OK\r\n\r\nhi", error.TestMissingContentLength },
        .{ "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n", error.TestUnsupportedTransferEncoding },
        .{ "HTTP/1.0 200 OK\r\ncontent-length: 0\r\n\r\n", error.TestBadStatusLine },
        .{ "HTTP/1.1 20 OK\r\ncontent-length: 0\r\n\r\n", error.TestBadStatusLine },
        .{ "HTTP/1.1 2x0 OK\r\ncontent-length: 0\r\n\r\n", error.TestBadStatusLine },
        .{ "HTTP/1.1 200OK\r\ncontent-length: 0\r\n\r\n", error.TestBadStatusLine },
        .{ "HTTP/1.1 999 OK\r\ncontent-length: 0\r\n\r\n", error.TestBadStatusLine },
        .{ "HTTP/1.1 200 OK\r\nbad name: x\r\ncontent-length: 0\r\n\r\n", error.TestBadHeader },
        .{ "HTTP/1.1 200 OK\r\n: x\r\ncontent-length: 0\r\n\r\n", error.TestBadHeader },
        .{ "HTTP/1.1 200 OK\r\nno-colon\r\ncontent-length: 0\r\n\r\n", error.TestBadHeader },
        .{ "HTTP/1.1 200 OK\r\ncontent-length: two\r\n\r\n", error.TestBadHeader },
    };
    for (cases) |case| {
        errdefer std.debug.print("parsing {s}\n", .{case[0]});
        try std.testing.expectError(case[1], h.Response.parse(case[0], "", false));
    }
}

// the cookie header the jar sends for `path`
fn expectCookies(c: *const h.Client, path: []const u8, expected: []const u8) !void {
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    try c.writeCookies(&line.writer, path);
    errdefer std.debug.print("cookies sent for {s}\n", .{path});
    try std.testing.expectEqualStrings(expected, line.written());
}

const nowhere: @import("../../web.zig").Host = .{ .local = .{ .path = "/nowhere", .repo_kind = .git } };

test "web: the harness's cookie jar scopes cookies by path" {
    var c = h.Client.init(nowhere);
    defer c.deinit();
    try c.keepCookie("a=1; Path=/a; HttpOnly", "/x");
    try expectCookies(&c, "/a", "a=1");
    try expectCookies(&c, "/a/b", "a=1");
    try expectCookies(&c, "/ab", "");
    try expectCookies(&c, "/", "");
    // an empty or relative path falls back to the request's directory
    try c.keepCookie("b=1; Path=", "/p/q");
    try c.keepCookie("c=1; Path=rel", "/p/q");
    try expectCookies(&c, "/p", "b=1; c=1");
    try expectCookies(&c, "/", "");
    // no path at all, from the root
    try c.keepCookie("d=1", "/top");
    try expectCookies(&c, "/elsewhere", "d=1");
}

test "web: the harness's cookie jar replaces by name and path and removes on max-age 0" {
    var c = h.Client.init(nowhere);
    defer c.deinit();
    try c.keepCookie("a=1; Path=/", "/");
    try c.keepCookie("a=2; Path=/", "/");
    try c.keepCookie("a=3; Path=/x", "/");
    // the longer path first
    try expectCookies(&c, "/x", "a=3; a=2");
    try c.keepCookie("a=; Path=/x; Max-Age=0", "/");
    try expectCookies(&c, "/x", "a=2");
    try c.keepCookie("a=; Path=/; Max-Age=-1", "/");
    try expectCookies(&c, "/x", "");
}

test "web: the harness keeps every set-cookie line of one response" {
    var c = h.Client.init(nowhere);
    defer c.deinit();
    const r = try h.Response.parse("HTTP/1.1 303 See Other\r\nset-cookie: a=1; Path=/\r\nlocation: /\r\nset-cookie: b=2; Path=/\r\ncontent-length: 0\r\n\r\n", "", false);
    defer r.deinit();
    try c.keepCookies(r, "/");
    try expectCookies(&c, "/", "a=1; b=2");
}
