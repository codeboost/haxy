//! granting, revoking, promoting and demoting a repo's members through the web forms

const std = @import("std");
const h = @import("harness.zig");

fn expectRefused(r: *const h.Response, status: std.http.Status, text: []const u8) !void {
    try r.expectStatus(status);
    if (std.mem.eql(u8, r.body, text)) return;
    r.describe();
    std.debug.print("expected the body \"{s}\"\n", .{text});
    return error.TestExpectedEqual;
}

// the members list's rows as "name role", in the order the page lists them
fn expectRows(r: *const h.Response, expected: []const []const u8) !void {
    const rows = r.jsonAt("page.repo.settings.members.rows") orelse {
        r.describe();
        return error.TestExpectedJson;
    };
    var actual: std.ArrayList([]const u8) = .empty;
    defer {
        for (actual.items) |row| std.testing.allocator.free(row);
        actual.deinit(std.testing.allocator);
    }
    for (rows.array.items) |row| try actual.append(std.testing.allocator, try std.fmt.allocPrint(std.testing.allocator, "{s} {s}", .{ row.object.get("name").?.string, row.object.get("role").?.string }));
    const same = actual.items.len == expected.len and for (actual.items, expected) |a, e| {
        if (!std.mem.eql(u8, a, e)) break false;
    } else true;
    if (same) return;
    std.debug.print("expected the members:", .{});
    for (expected) |row| std.debug.print(" \"{s}\"", .{row});
    std.debug.print("\ngot:", .{});
    for (actual.items) |row| std.debug.print(" \"{s}\"", .{row});
    std.debug.print("\n", .{});
    return error.TestExpectedEqual;
}

fn grant(c: *h.Client, repo: []const u8, name: []const u8) !*h.Response {
    var buf: [128]u8 = undefined;
    return c.post(try std.fmt.bufPrint(&buf, "/{s}/repo/members/grant", .{repo}), &.{.{ "name", name }});
}

// a row form, which names the user in the url and posts no body
fn rowAction(c: *h.Client, repo: []const u8, user: []const u8, action: []const u8) !*h.Response {
    var buf: [128]u8 = undefined;
    return c.post(try std.fmt.bufPrint(&buf, "/{s}/repo/members/user:{s}/{s}", .{ repo, user, action }), &.{});
}

test "web: an owner adds a member, who then sees the private repo" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    const r = try grant(&alice, "alice:secret", "carol");
    defer r.deinit();
    try r.expectRedirect("/alice:secret/repo/members");
    const list = try alice.followJson(r);
    defer list.deinit();
    try expectRows(list, &.{ "carol write", "bob write" });

    const seen = try carol.get("/alice:secret");
    defer seen.deinit();
    try seen.expectStatus(.ok);
}

test "web: adding an unknown user comes back once as not found with the name kept, and nothing changes" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try grant(&alice, "alice:open", "nobody-here");
    defer r.deinit();
    try r.expectRedirect("/alice:open/repo/members");
    const form = try alice.followJson(r);
    defer form.deinit();
    try form.expectJson("session.form_feedback.repo_members.failure", "not_found");
    try form.expectJson("session.form_feedback.repo_members.name", "nobody-here");
    try expectRows(form, &.{"bob write"});

    // the flash is consumed by the first page that shows it
    const again = try alice.getJson("/alice:open/repo/members");
    defer again.deinit();
    try again.expectJson("session.form_feedback", null);
}

test "web: adding a removed account comes back as not found" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try grant(&alice, "alice:open", "dave");
    defer r.deinit();
    try r.expectRedirect("/alice:open/repo/members");
    const form = try alice.followJson(r);
    defer form.deinit();
    try form.expectJson("session.form_feedback.repo_members.failure", "not_found");
    try form.expectJson("session.form_feedback.repo_members.name", "dave");
}

test "web: adding a member or the creator again comes back as already added" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    for ([_][]const u8{ "bob", "alice" }) |name| {
        const r = try grant(&alice, "alice:open", name);
        defer r.deinit();
        try r.expectRedirect("/alice:open/repo/members");
        const form = try alice.followJson(r);
        defer form.deinit();
        try form.expectJson("session.form_feedback.repo_members.failure", "already_added");
        try form.expectJson("session.form_feedback.repo_members.name", name);
        try expectRows(form, &.{"bob write"});
    }
}

test "web: an owner takes a member's role away, and the private repo is hidden from them" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();

    const r = try rowAction(&alice, "alice:secret", "bob", "revoke");
    defer r.deinit();
    try r.expectRedirect("/alice:secret/repo/members");
    const list = try alice.followJson(r);
    defer list.deinit();
    try expectRows(list, &.{});

    const hidden = try bob.get("/alice:secret");
    defer hidden.deinit();
    try hidden.expectStatus(.not_found);
}

test "web: a promoted member may change the repo's settings, and once demoted may not" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();
    const settings: []const h.Field = &.{
        .{ "name", "open" },              .{ "description", "by bob" }, .{ "access", "public" },
        .{ "discuss_role", "anybody" }, .{ "issue_role", "anybody" }, .{ "patch_role", "nobody" },
    };

    const promoted = try rowAction(&alice, "alice:open", "bob", "promote");
    defer promoted.deinit();
    try promoted.expectRedirect("/alice:open/repo/members");
    const list = try alice.followJson(promoted);
    defer list.deinit();
    try expectRows(list, &.{"bob owner"});
    const changed = try bob.post("/alice:open/repo/settings", settings);
    defer changed.deinit();
    try changed.expectRedirect("/alice:open/repo/settings");

    const demoted = try rowAction(&alice, "alice:open", "bob", "demote");
    defer demoted.deinit();
    try demoted.expectRedirect("/alice:open/repo/members");
    const after = try alice.followJson(demoted);
    defer after.deinit();
    try expectRows(after, &.{"bob write"});
    const refused = try bob.post("/alice:open/repo/settings", settings);
    defer refused.deinit();
    try expectRefused(refused, .forbidden, "you don't have permission to do that");
}

test "web: an owner who demotes or removes themself lands on the repo's files" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();

    for ([_][]const u8{ "demote", "revoke" }) |action| {
        const promoted = try rowAction(&alice, "alice:open", "bob", "promote");
        defer promoted.deinit();
        try promoted.expectRedirect("/alice:open/repo/members");

        const r = try rowAction(&bob, "alice:open", "bob", action);
        defer r.deinit();
        try r.expectRedirect("/alice:open");
        // and is no owner any more
        const members = try bob.post("/alice:open/repo/members/grant", &.{.{ "name", "carol" }});
        defer members.deinit();
        try expectRefused(members, .forbidden, "you don't have permission to do that");
        if (std.mem.eql(u8, action, "revoke")) {
            const regrant = try grant(&alice, "alice:open", "bob");
            defer regrant.deinit();
            try regrant.expectRedirect("/alice:open/repo/members");
        }
    }
}

test "web: a row form naming no member, or no user, is not found" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    // carol exists but holds no role; nobody-here does not exist
    for ([_][]const u8{ "revoke", "promote", "demote" }) |action| {
        for ([_][]const u8{ "carol", "nobody-here" }) |user| {
            const r = try rowAction(&alice, "alice:open", user, action);
            defer r.deinit();
            try expectRefused(r, .not_found, "repo not found");
        }
        var buf: [64]u8 = undefined;
        const unnamed = try alice.post(try std.fmt.bufPrint(&buf, "/alice:open/repo/members/{s}", .{action}), &.{});
        defer unnamed.deinit();
        try expectRefused(unnamed, .not_found, "repo not found");
    }
    const list = try alice.getJson("/alice:open/repo/members");
    defer list.deinit();
    try expectRows(list, &.{"bob write"});
}

// every members form, refused with `status` and `text`: the add form with a
// name that would come back as not found, the row forms naming bob
fn expectEveryFormRefused(c: *h.Client, repo: []const u8, status: std.http.Status, text: []const u8) !void {
    const added = try grant(c, repo, "nobody-here");
    defer added.deinit();
    try expectRefused(added, status, text);
    for ([_][]const u8{ "revoke", "promote", "demote" }) |action| {
        const r = try rowAction(c, repo, "bob", action);
        defer r.deinit();
        expectRefused(r, status, text) catch |err| {
            std.debug.print("refusing {s}\n", .{action});
            return err;
        };
    }
}

test "web: every members form is refused to the logged out and a removed account's session, even for a repo that does not exist" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();
    var dave = server.client();
    defer dave.deinit();
    try server.mintSession(&dave, server.dave);

    for ([_]*h.Client{ &visitor, &dave }) |c| {
        for ([_][]const u8{ "alice:open", "alice:secret", "alice:nothing" }) |repo| {
            try expectEveryFormRefused(c, repo, .forbidden, "log in to make changes");
        }
    }
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const list = try alice.getJson("/alice:open/repo/members");
    defer list.deinit();
    try expectRows(list, &.{"bob write"});
}

test "web: every members form is forbidden to a stranger and a member, whatever the form says" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();

    try expectEveryFormRefused(&carol, "alice:open", .forbidden, "you don't have permission to do that");
    // bob is a member of both repos
    for ([_][]const u8{ "alice:open", "alice:secret" }) |repo| {
        try expectEveryFormRefused(&bob, repo, .forbidden, "you don't have permission to do that");
    }
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const list = try alice.getJson("/alice:open/repo/members");
    defer list.deinit();
    try expectRows(list, &.{"bob write"});
}

test "web: a stranger's members forms for a private repo answer as for a repo that does not exist" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    for ([_][]const u8{ "alice:secret", "alice:nothing" }) |repo| {
        try expectEveryFormRefused(&carol, repo, .not_found, "repo not found");
    }
}
