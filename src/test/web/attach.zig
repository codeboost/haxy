//! attaching files to threads, serving them back and removing them

const std = @import("std");
const h = @import("harness.zig");
const p = @import("patches.zig");

const missing_id = "00000000000000000000000000000000";

// upload `bytes` as the file `name` to the thread page `page`, as the page's
// script does: the body is the file and a header names it
fn upload(c: *h.Client, page: []const u8, name: ?[]const u8, bytes: []const u8) !*h.Response {
    return c.send(.{ .method = "POST", .path = try p.url(c, "{s}/attach", .{page}), .body = bytes, .headers = &.{
        .{ .name = "x-attachment-name", .value = name },
        .{ .name = "content-type", .value = "application/octet-stream" },
    } });
}

fn newIssue(c: *h.Client, base: []const u8) ![]const u8 {
    const r = try c.post(try p.url(c, "{s}/issues/new", .{base}), &.{ .{ "title", "an issue" }, .{ "labels", "" }, .{ "description", "" } });
    defer r.deinit();
    return p.location(c, r);
}

// the id of the first attachment the issue page lists, read from its snapshot
fn firstAttachment(c: *h.Client, page: []const u8) ![]const u8 {
    const r = try c.getJson(page);
    defer r.deinit();
    const id = r.jsonAt("page.repo.issues.open.items.0.attachments.0.id") orelse {
        r.describe();
        return error.TestExpectedAttachment;
    };
    return c.arena.allocator().dupe(u8, id.string);
}

fn expectAttachmentCount(c: *h.Client, page: []const u8, expected: usize) !void {
    const r = try c.getJson(page);
    defer r.deinit();
    const attachments = r.jsonAt("page.repo.issues.open.items.0.attachments") orelse {
        r.describe();
        return error.TestExpectedJson;
    };
    try std.testing.expectEqual(expected, attachments.array.items.len);
}

test "web: an attached file is listed on its issue and served back with its bytes as a download" {
    // differs from 66c1ab6: serving an attachment freed its encoded name with
    // the wrong length, which the test allocator aborts on; fixed in
    // sendAttachment. the parity run needs that one-line fix applied first
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const page = try newIssue(&alice, "/alice:open");
    const r = try upload(&alice, page, "notes.txt", "hello bytes");
    defer r.deinit();
    try r.expectStatus(.no_content);
    try std.testing.expectEqual(null, r.header("location"));
    try std.testing.expectEqualStrings("", r.body);

    const shown = try alice.getJson(page);
    defer shown.deinit();
    try shown.expectJson("page.repo.issues.open.items.0.attachments.0.name", "notes.txt");

    const id = try firstAttachment(&alice, page);
    const file = try alice.get(try p.url(&alice, "/alice:open/attachment:{s}", .{id}));
    defer file.deinit();
    try file.expectStatus(.ok);
    try std.testing.expectEqualStrings("hello bytes", file.body);
    try std.testing.expectEqualStrings("application/octet-stream", file.header("content-type").?);
    try std.testing.expectEqualStrings("attachment; filename*=UTF-8''notes.txt", file.header("content-disposition").?);
    try std.testing.expectEqualStrings("nosniff", file.header("x-content-type-options").?);
}

test "web: an attached image is served inline as its type, and a page as opaque bytes" {
    // differs from 66c1ab6: serving an attachment freed its encoded name with
    // the wrong length, which the test allocator aborts on; fixed in
    // sendAttachment. the parity run needs that one-line fix applied first
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const page = try newIssue(&alice, "/alice:open");
    for ([_]struct { name: []const u8, content_type: []const u8, disposition: []const u8 }{
        .{ .name = "shot.PNG", .content_type = "image/png", .disposition = "inline; filename*=UTF-8''shot.PNG" },
        .{ .name = "page.html", .content_type = "application/octet-stream", .disposition = "attachment; filename*=UTF-8''page.html" },
    }) |case| {
        {
            const r = try upload(&alice, page, case.name, "<script>x</script>");
            defer r.deinit();
            try r.expectStatus(.no_content);
        }
        // the newest is listed last
        const shown = try alice.getJson(page);
        defer shown.deinit();
        const attachments = shown.jsonAt("page.repo.issues.open.items.0.attachments").?.array.items;
        const newest = attachments[attachments.len - 1].object;
        try std.testing.expectEqualStrings(case.name, newest.get("name").?.string);
        const file = try alice.get(try p.url(&alice, "/alice:open/attachment:{s}", .{newest.get("id").?.string}));
        defer file.deinit();
        try file.expectStatus(.ok);
        try std.testing.expectEqualStrings(case.content_type, file.header("content-type").?);
        try std.testing.expectEqualStrings(case.disposition, file.header("content-disposition").?);
        try std.testing.expectEqualStrings("nosniff", file.header("x-content-type-options").?);
    }
}

test "web: a sha256 repo's attachment is served back" {
    // differs from 66c1ab6: serving an attachment freed its encoded name with
    // the wrong length, which the test allocator aborts on; fixed in
    // sendAttachment. the parity run needs that one-line fix applied first
    const server = try h.Server.init(.sha256);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const page = try newIssue(&alice, "/alice:open");
    const r = try upload(&alice, page, "notes.txt", "sha256 bytes");
    defer r.deinit();
    try r.expectStatus(.no_content);
    const id = try firstAttachment(&alice, page);
    const file = try alice.get(try p.url(&alice, "/alice:open/attachment:{s}", .{id}));
    defer file.deinit();
    try std.testing.expectEqualStrings("sha256 bytes", file.body);
}

test "web: a private repo's attachment is served to a member but not to a stranger or a visitor" {
    // differs from 66c1ab6: serving an attachment freed its encoded name with
    // the wrong length, which the test allocator aborts on; fixed in
    // sendAttachment. the parity run needs that one-line fix applied first
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    var visitor = server.client();
    defer visitor.deinit();

    const page = try newIssue(&alice, "/alice:secret");
    {
        const r = try upload(&alice, page, "notes.txt", "secret bytes");
        defer r.deinit();
        try r.expectStatus(.no_content);
    }
    const id = try firstAttachment(&alice, page);
    const path = try p.url(&alice, "/alice:secret/attachment:{s}", .{id});

    const member = try bob.get(path);
    defer member.deinit();
    try std.testing.expectEqualStrings("secret bytes", member.body);

    // as a missing attachment would be answered
    for ([_]*h.Client{ &carol, &visitor }) |c| {
        for ([_][]const u8{ path, "/alice:secret/attachment:" ++ missing_id }) |target| {
            const r = try c.get(target);
            defer r.deinit();
            try r.expectStatus(.not_found);
            try std.testing.expectEqualStrings("attachment not found", r.body);
        }
    }
}

test "web: an attachment id that names nothing is not found" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try alice.get("/alice:open/attachment:" ++ missing_id);
    defer r.deinit();
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("attachment not found", r.body);
}

test "web: an upload without a name, with a bad name, empty, too large or with no length is refused" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const page = try newIssue(&alice, "/alice:open");
    const attach = try p.url(&alice, "{s}/attach", .{page});
    for ([_]struct { name: ?[]const u8, body: ?[]const u8, status: std.http.Status, text: []const u8 }{
        .{ .name = null, .body = "x", .status = .bad_request, .text = "attachment needs a name" },
        .{ .name = "a%2Fb", .body = "x", .status = .bad_request, .text = "invalid attachment name" },
        .{ .name = "..", .body = "x", .status = .bad_request, .text = "invalid attachment name" },
        .{ .name = "notes.txt", .body = "", .status = .bad_request, .text = "attachment is empty" },
        // no body sends no content-length
        .{ .name = "notes.txt", .body = null, .status = .length_required, .text = "attachments must declare a content length" },
    }) |case| {
        const r = try alice.send(.{ .method = "POST", .path = attach, .body = case.body, .headers = &.{
            .{ .name = "x-attachment-name", .value = case.name },
        } });
        defer r.deinit();
        try r.expectStatus(case.status);
        try std.testing.expectEqualStrings(case.text, r.body);
    }

    // a declared length past the limit is refused before any of the body is read
    // one byte past the limit 66c1ab6 set: 10 * 1024 * 1024
    const too_large = "10485761";
    const r = try alice.send(.{ .method = "POST", .path = attach, .body = "x", .headers = &.{
        .{ .name = "x-attachment-name", .value = "notes.txt" },
        .{ .name = "content-length", .value = too_large },
    } });
    defer r.deinit();
    try r.expectStatus(.payload_too_large);
    try std.testing.expectEqualStrings("attachment is too large", r.body);

    try expectAttachmentCount(&alice, page, 0);
}

test "web: a stranger cannot attach to someone's issue, whatever the upload says" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    const page = try newIssue(&alice, "/alice:open");
    // a missing name would be refused as a bad request for someone allowed
    for ([_]?[]const u8{ "notes.txt", null }) |name| {
        const r = try upload(&carol, page, name, "x");
        defer r.deinit();
        try r.expectStatus(.forbidden);
        try std.testing.expectEqualStrings("you don't have permission to do that", r.body);
    }
    try expectAttachmentCount(&alice, page, 0);
}

test "web: attaching logged out, as a removed account or on a hidden repo is refused" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var visitor = server.client();
    defer visitor.deinit();
    var dave = server.client();
    defer dave.deinit();
    try server.mintSession(&dave, server.dave);
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    const page = try newIssue(&alice, "/alice:open");
    for ([_]*h.Client{ &visitor, &dave }) |c| {
        const r = try upload(c, page, "notes.txt", "x");
        defer r.deinit();
        try r.expectStatus(.forbidden);
        try std.testing.expectEqualStrings("log in to make changes", r.body);
    }
    for ([_][]const u8{ "/alice:secret/issue:" ++ missing_id, "/alice:nothing/issue:" ++ missing_id }) |target| {
        const r = try upload(&carol, target, "notes.txt", "x");
        defer r.deinit();
        try r.expectStatus(.not_found);
        try std.testing.expectEqualStrings("repo not found", r.body);
    }
    try expectAttachmentCount(&alice, page, 0);
}

test "web: attaching to an issue that does not exist finds no target" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try upload(&alice, "/alice:open/issue:" ++ missing_id, "notes.txt", "x");
    defer r.deinit();
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("attachment target not found", r.body);
}

test "web: attaching to a url that names no thread finds no target" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try upload(&alice, "/alice:open/issues", "notes.txt", "x");
    defer r.deinit();
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("attachment target not found", r.body);
}

test "web: attaching to a comment's id names no thread to attach to" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try upload(&alice, "/alice:open/comment:" ++ missing_id, "notes.txt", "x");
    defer r.deinit();
    try r.expectStatus(.not_found);
    // differs from 66c1ab6: a kind with no tab was answered "repo not found";
    // now "attachment target not found". accepted as deviation G in
    // docs/reviews/04-phase3-codex.md
    try std.testing.expectEqualStrings("attachment target not found", r.body);
}

test "web: removing an attachment returns to its issue, which no longer lists it, and stops serving it" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const page = try newIssue(&alice, "/alice:open");
    {
        const r = try upload(&alice, page, "notes.txt", "hello");
        defer r.deinit();
        try r.expectStatus(.no_content);
    }
    const id = try firstAttachment(&alice, page);
    const r = try alice.post(try p.url(&alice, "{s}/attachment:{s}/remove", .{ page, id }), &.{});
    defer r.deinit();
    try r.expectRedirect(page);
    try expectAttachmentCount(&alice, page, 0);
    const file = try alice.get(try p.url(&alice, "/alice:open/attachment:{s}", .{id}));
    defer file.deinit();
    try file.expectStatus(.not_found);
    try std.testing.expectEqualStrings("attachment not found", file.body);
}

test "web: a stranger cannot remove someone's attachment" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    const page = try newIssue(&alice, "/alice:open");
    {
        const r = try upload(&alice, page, "notes.txt", "hello");
        defer r.deinit();
        try r.expectStatus(.no_content);
    }
    const id = try firstAttachment(&alice, page);
    const r = try carol.post(try p.url(&carol, "{s}/attachment:{s}/remove", .{ page, id }), &.{});
    defer r.deinit();
    try r.expectStatus(.forbidden);
    try std.testing.expectEqualStrings("you don't have permission to do that", r.body);
    try expectAttachmentCount(&alice, page, 1);
}

test "web: removing an attachment that does not exist is not found" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const page = try newIssue(&alice, "/alice:open");
    const r = try alice.post(try p.url(&alice, "{s}/attachment:" ++ missing_id ++ "/remove", .{page}), &.{});
    defer r.deinit();
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("event not found", r.body);
}

test "web: a local issue takes an attachment, serves it back and lets it be removed, on xit and git" {
    // differs from 66c1ab6: serving an attachment freed its encoded name with
    // the wrong length, which the test allocator aborts on; fixed in
    // sendAttachment. the parity run needs that one-line fix applied first
    try expectLocalAttachment(.xit);
    try expectLocalAttachment(.git);
}

fn expectLocalAttachment(comptime kind: @import("xit").repo.RepoKind) !void {
    var local = try h.Local(kind).init();
    defer local.deinit();
    var browser = local.client();
    defer browser.deinit();

    const page = try newIssue(&browser, "");
    {
        const r = try upload(&browser, page, "notes.txt", "local bytes");
        defer r.deinit();
        try r.expectStatus(.no_content);
    }
    const id = try firstAttachment(&browser, page);
    {
        const file = try browser.get(try p.url(&browser, "/attachment:{s}", .{id}));
        defer file.deinit();
        try file.expectStatus(.ok);
        try std.testing.expectEqualStrings("local bytes", file.body);
    }
    const r = try browser.post(try p.url(&browser, "{s}/attachment:{s}/remove", .{ page, id }), &.{});
    defer r.deinit();
    try r.expectRedirect(page);
    try expectAttachmentCount(&browser, page, 0);
}

test "web: an upload of exactly the size limit is accepted and served whole" {
    // differs from 66c1ab6: serving an attachment freed its encoded name with
    // the wrong length, which the test allocator aborts on; fixed in
    // sendAttachment. the parity run needs that one-line fix applied first
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    // the limit 66c1ab6 set: 10 * 1024 * 1024
    const bytes = try std.testing.allocator.alloc(u8, 10 * 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    for (bytes, 0..) |*b, i| b.* = @truncate(i *% 7);

    const page = try newIssue(&alice, "/alice:open");
    {
        const r = try upload(&alice, page, "big.bin", bytes);
        defer r.deinit();
        try r.expectStatus(.no_content);
    }
    const shown = try alice.getJson(page);
    defer shown.deinit();
    try shown.expectJson("page.repo.issues.open.items.0.attachments.0.name", "big.bin");
    const id = try firstAttachment(&alice, page);
    const file = try alice.get(try p.url(&alice, "/alice:open/attachment:{s}", .{id}));
    defer file.deinit();
    try file.expectStatus(.ok);
    try std.testing.expectEqualStrings("10485760", file.header("content-length").?);
    try std.testing.expect(std.mem.eql(u8, bytes, file.body));
}

test "web: an upload whose body is shorter than its declared length is not attached" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const page = try newIssue(&alice, "/alice:open");
    const r = try alice.send(.{ .method = "POST", .path = try p.url(&alice, "{s}/attach", .{page}), .body = "abc", .headers = &.{
        .{ .name = "x-attachment-name", .value = "notes.txt" },
        .{ .name = "content-length", .value = "10" },
    } });
    defer r.deinit();
    // the body's end escapes the handler as it did at 66c1ab6, where the
    // same event code read the upload
    try r.expectStatus(.internal_server_error);
    try std.testing.expectEqualStrings("EndOfStream", r.body);
    try expectAttachmentCount(&alice, page, 0);
}
