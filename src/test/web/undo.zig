//! undoing a repo's transactions through the undo tab's forms

const std = @import("std");
const h = @import("harness.zig");

fn expectRefused(r: *const h.Response, status: std.http.Status, text: []const u8) !void {
    try r.expectStatus(status);
    if (std.mem.eql(u8, r.body, text)) return;
    r.describe();
    std.debug.print("expected the body \"{s}\"\n", .{text});
    return error.TestExpectedEqual;
}

// how many transactions the undo tab lists; the next one gets this index
fn historyCount(c: *h.Client, repo: []const u8) !i64 {
    var buf: [64]u8 = undefined;
    const page = try c.getJson(try std.fmt.bufPrint(&buf, "/{s}/undo", .{repo}));
    defer page.deinit();
    try page.expectStatus(.ok);
    const count = page.jsonAt("page.repo.undo.count") orelse {
        page.describe();
        return error.TestExpectedJson;
    };
    return count.integer;
}

fn openIssues(c: *h.Client) !i64 {
    const page = try c.getJson("/alice:open/issues");
    defer page.deinit();
    try page.expectStatus(.ok);
    return (page.jsonAt("page.repo.issues.open.count") orelse {
        page.describe();
        return error.TestExpectedJson;
    }).integer;
}

fn newIssue(c: *h.Client) !void {
    const r = try c.post("/alice:open/issues/new", &.{ .{ "title", "the roof leaks" }, .{ "labels", "" }, .{ "description", "" } });
    defer r.deinit();
    try r.expectStatus(.see_other);
}

fn undo(c: *h.Client, repo: []const u8, index: i64) !*h.Response {
    var buf: [64]u8 = undefined;
    return c.post(try std.fmt.bufPrint(&buf, "/{s}/undo/{d}/undo", .{ repo, index }), &.{});
}

fn expectUndoesAnIssue(comptime hash_kind: @import("xit").hash.HashKind) !void {
    const server = try h.Server.init(hash_kind);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const before = try historyCount(&alice, "alice:open");
    try newIssue(&alice);
    try std.testing.expectEqual(1, try openIssues(&alice));

    const r = try undo(&alice, "alice:open", before);
    defer r.deinit();
    try r.expectRedirect("/alice:open/undo");
    try std.testing.expectEqual(0, try openIssues(&alice));
}

test "web: an owner undoes the transactions an issue form made, and the issue is gone" {
    try expectUndoesAnIssue(.sha1);
}

test "web: an owner undoes an issue form's transactions in a sha256 repo" {
    try expectUndoesAnIssue(.sha256);
}

test "web: undoing an index that names no transaction is not found and changes nothing" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    try newIssue(&alice);

    const r = try undo(&alice, "alice:open", 9999);
    defer r.deinit();
    try expectRefused(r, .not_found, "repo not found");
    try std.testing.expectEqual(1, try openIssues(&alice));
}

test "web: the undo form with an index that is not a number, or overflows one, is not found" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    try newIssue(&alice);

    for ([_][]const u8{ "/alice:open/undo/first/undo", "/alice:open/undo/-1/undo", "/alice:open/undo/18446744073709551616/undo" }) |path| {
        const r = try alice.post(path, &.{});
        defer r.deinit();
        try expectRefused(r, .not_found, "repo not found");
    }
    try std.testing.expectEqual(1, try openIssues(&alice));
}

test "web: the undo form without an index is not found" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try alice.post("/alice:open/undo/undo", &.{});
    defer r.deinit();
    try expectRefused(r, .not_found, "repo not found");
}

test "web: a copy's history from before it was copied can't be undone" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    try h.commitOnBranch(server, server.open, "master", "README", "hello\n");
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    const copied = try carol.post("/home/repo/new", &.{
        .{ "name", "mine" }, .{ "description", "" }, .{ "hash", "sha1" }, .{ "access", "public" }, .{ "copy", "alice:open" },
    });
    defer copied.deinit();
    try copied.expectRedirect("/carol:mine");

    const r = try undo(&carol, "carol:mine", 0);
    defer r.deinit();
    try expectRefused(r, .not_found, "repo not found");
    const files = try carol.getJson("/carol:mine");
    defer files.deinit();
    try files.expectJson("page.repo.files.entries.0.name", "README");
}

test "web: undo is forbidden to a member, whatever the index" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();
    const before = try historyCount(&alice, "alice:open");
    try newIssue(&bob);

    for ([_]i64{ before, 9999 }) |index| {
        const r = try undo(&bob, "alice:open", index);
        defer r.deinit();
        try expectRefused(r, .forbidden, "you don't have permission to do that");
    }
    try std.testing.expectEqual(1, try openIssues(&alice));
}

test "web: undo is refused to a stranger, and to the logged out and a removed account's session even for a repo that does not exist" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const before = try historyCount(&alice, "alice:open");
    try newIssue(&alice);
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    var visitor = server.client();
    defer visitor.deinit();
    var dave = server.client();
    defer dave.deinit();
    try server.mintSession(&dave, server.dave);

    const stranger = try undo(&carol, "alice:open", before);
    defer stranger.deinit();
    try expectRefused(stranger, .forbidden, "you don't have permission to do that");
    for ([_]*h.Client{ &visitor, &dave }) |c| {
        for ([_][]const u8{ "alice:open", "alice:secret", "alice:nothing" }) |repo| {
            const r = try undo(c, repo, before);
            defer r.deinit();
            try expectRefused(r, .forbidden, "log in to make changes");
        }
    }
    try std.testing.expectEqual(1, try openIssues(&alice));
}

test "web: a stranger's undo of a private repo answers as for a repo that does not exist" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    for ([_][]const u8{ "alice:secret", "alice:nothing" }) |repo| {
        const r = try undo(&carol, repo, 0);
        defer r.deinit();
        try expectRefused(r, .not_found, "repo not found");
    }
}
