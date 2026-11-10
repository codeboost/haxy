//! subscribing to and muting threads, and the notifications they bring

const std = @import("std");
const h = @import("harness.zig");

const gpa = std.testing.allocator;

fn expectRefused(r: *const h.Response, status: std.http.Status, text: []const u8) !void {
    try r.expectStatus(status);
    if (std.mem.eql(u8, r.body, text)) return;
    r.describe();
    std.debug.print("expected the body \"{s}\"\n", .{text});
    return error.TestExpectedEqual;
}

// `r` is a page that loaded, whose array at `path` holds `len` items
fn expectArrayLen(r: *const h.Response, path: []const u8, len: usize) !void {
    try r.expectStatus(.ok);
    if (r.jsonAt(path)) |value| if (value == .array and value.array.items.len == len) return;
    r.describe();
    std.debug.print("expected an array of {d} at \"{s}\"\n", .{ len, path });
    return error.TestExpectedEqual;
}

const rows = "page.home.user_notifications.rows";

// `c` opens an issue in `repo` through the form; returns its url, owned by the caller
fn openIssue(c: *h.Client, repo: []const u8, title: []const u8) ![]u8 {
    var buf: [128]u8 = undefined;
    const r = try c.post(try std.fmt.bufPrint(&buf, "/{s}/issues/new", .{repo}), &.{ .{ "title", title }, .{ "labels", "" }, .{ "description", "it leaks" } });
    defer r.deinit();
    try r.expectStatus(.see_other);
    return gpa.dupe(u8, r.header("location").?);
}

// `c` comments on the thread at `url` through the form
fn comment(c: *h.Client, url: []const u8, body: []const u8) !void {
    var buf: [256]u8 = undefined;
    const r = try c.post(try std.fmt.bufPrint(&buf, "{s}/new", .{url}), &.{.{ "body", body }});
    defer r.deinit();
    try r.expectStatus(.see_other);
}

fn notify(c: *h.Client, url: []const u8, action: []const u8) !*h.Response {
    var buf: [256]u8 = undefined;
    return c.post(try std.fmt.bufPrint(&buf, "{s}/{s}", .{ url, action }), &.{});
}

// the notify button `c` sees on the only open issue of the thread page `url`
fn expectNotifyAction(c: *h.Client, url: []const u8, action: []const u8) !void {
    const page = try c.getJson(url);
    defer page.deinit();
    try page.expectStatus(.ok);
    try page.expectJson("page.repo.issues.open.items.0.notify_action", action);
}

// `c`'s notifications: how many unread, and how many listed
fn expectInbox(c: *h.Client, unread: i64, listed: usize) !void {
    const page = try c.getJson("/home/user");
    defer page.deinit();
    try expectArrayLen(page, rows, listed);
    try page.expectJson("session.unread_notifs", unread);
}

// ---- the notifications page

test "web: a comment on a user's issue reaches their notifications, which opening the issue marks read" {
    try expectNotificationRead(.sha1);
}

test "web: a comment on a user's issue in a sha256 repo reaches their notifications, which opening the issue marks read" {
    try expectNotificationRead(.sha256);
}

fn expectNotificationRead(comptime hash_kind: @import("xit").hash.HashKind) !void {
    const server = try h.Server.init(hash_kind);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();
    const issue = try openIssue(&alice, "alice:open", "the roof leaks");
    defer gpa.free(issue);
    try expectInbox(&alice, 0, 0);

    try comment(&bob, issue, "me too");
    const inbox = try alice.getJson("/home/user");
    defer inbox.deinit();
    try inbox.expectJson("session.unread_notifs", 1);
    try inbox.expectJson(rows ++ ".0.title", "the roof leaks");
    try inbox.expectJson(rows ++ ".0.url", issue);
    try inbox.expectJson(rows ++ ".0.identity", "alice:open");
    try inbox.expectJson(rows ++ ".0.unread", true);
    // the commenter is not notified of his own comment
    try expectInbox(&bob, 0, 0);

    const opened = try alice.get(issue);
    defer opened.deinit();
    try opened.expectStatus(.ok);
    const read = try alice.getJson("/home/user");
    defer read.deinit();
    try read.expectJson("session.unread_notifs", 0);
    try read.expectJson(rows ++ ".0.unread", false);
}

test "web: a logged-out visitor opening the issue leaves its notification unread" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();
    const issue = try openIssue(&alice, "alice:open", "the roof leaks");
    defer gpa.free(issue);
    try comment(&bob, issue, "me too");

    var visitor = server.client();
    defer visitor.deinit();
    const opened = try visitor.getJson(issue);
    defer opened.deinit();
    try opened.expectStatus(.ok);
    // bob, a participant now too, opening it marks only his own
    const bob_opened = try bob.getJson(issue);
    defer bob_opened.deinit();
    try expectInbox(&alice, 1, 1);
}

test "web: muting a thread dismisses its notification and stops new ones" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();
    const issue = try openIssue(&alice, "alice:open", "the roof leaks");
    defer gpa.free(issue);
    try comment(&bob, issue, "me too");
    try expectInbox(&alice, 1, 1);

    const r = try notify(&alice, issue, "mute");
    defer r.deinit();
    try r.expectRedirect(issue);
    try expectInbox(&alice, 0, 0);
    try expectNotifyAction(&alice, issue, "subscribe");

    try comment(&bob, issue, "still leaking");
    try expectInbox(&alice, 0, 0);
}

test "web: subscribing to a thread brings its new comments to a stranger" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    const issue = try openIssue(&alice, "alice:open", "the roof leaks");
    defer gpa.free(issue);
    try expectNotifyAction(&carol, issue, "subscribe");

    const r = try notify(&carol, issue, "subscribe");
    defer r.deinit();
    try r.expectRedirect(issue);
    try expectNotifyAction(&carol, issue, "mute");
    try expectInbox(&carol, 0, 0);

    try comment(&alice, issue, "fixed tomorrow");
    try expectInbox(&carol, 1, 1);
}

test "web: subscribing again, or after muting, leaves the thread subscribed" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();
    const issue = try openIssue(&alice, "alice:open", "the roof leaks");
    defer gpa.free(issue);

    for ([_][]const u8{ "subscribe", "mute", "subscribe", "subscribe" }) |action| {
        const r = try notify(&alice, issue, action);
        defer r.deinit();
        try r.expectRedirect(issue);
    }
    try expectNotifyAction(&alice, issue, "mute");
    try comment(&bob, issue, "me too");
    try expectInbox(&alice, 1, 1);
}

test "web: subscribing and muting are refused to the logged out and a removed account's session" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const issue = try openIssue(&alice, "alice:open", "the roof leaks");
    defer gpa.free(issue);
    var visitor = server.client();
    defer visitor.deinit();
    var dave = server.client();
    defer dave.deinit();
    try server.mintSession(&dave, server.dave);

    for ([_]*h.Client{ &visitor, &dave }) |c| for ([_][]const u8{ "subscribe", "mute" }) |action| {
        const r = try notify(c, issue, action);
        defer r.deinit();
        try expectRefused(r, .forbidden, "log in to make changes");
    };
    // alice, the author, is still subscribed
    try expectNotifyAction(&alice, issue, "mute");
}

test "web: a stranger subscribing or muting in a private repo gets the answer for a repo that does not exist" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    const issue = try openIssue(&alice, "alice:secret", "a hidden leak");
    defer gpa.free(issue);
    const id = issue["/alice:secret/".len..];

    var buf: [256]u8 = undefined;
    const missing = try notify(&carol, try std.fmt.bufPrint(&buf, "/alice:nothing/{s}", .{id}), "subscribe");
    defer missing.deinit();
    const secret = try notify(&carol, issue, "subscribe");
    defer secret.deinit();
    const muted = try notify(&carol, issue, "mute");
    defer muted.deinit();
    try expectRefused(missing, .not_found, "repo not found");
    try expectRefused(secret, .not_found, "repo not found");
    try expectRefused(muted, .not_found, "repo not found");

    // the refused subscription brings carol nothing
    var bob = try server.clientAs("bob");
    defer bob.deinit();
    try comment(&bob, issue, "seen");
    try expectInbox(&carol, 0, 0);
}

test "web: subscribing to a url that names no thread is not found" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const issue = try openIssue(&alice, "alice:open", "the roof leaks");
    defer gpa.free(issue);

    var buf: [256]u8 = undefined;
    for ([_][]const u8{
        "/alice:open/issue:zz",
        "/alice:open/issues",
        "/alice:open",
        try std.fmt.bufPrint(&buf, "{s}/comment:00000000000000000000000000000000", .{issue}),
    }) |url| {
        const r = try notify(&alice, url, "subscribe");
        defer r.deinit();
        try expectRefused(r, .not_found, "event not found");
    }
}

test "web: subscribing to a thread that does not exist is not found" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    // differs from 66c1ab6: there the handler wrote a notify entry for any
    // well-formed thread id and answered 303. accepted in docs/reviews/04-phase3-codex.md
    // (deviation A: no notification entries for nonexistent targets).
    const r = try notify(&alice, "/alice:open/issue:00000000000000000000000000000000", "subscribe");
    defer r.deinit();
    try expectRefused(r, .not_found, "event not found");
}

test "web: a stranger may subscribe to and mute a thread whose tab is for members only" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    const issue = try openIssue(&alice, "alice:open", "the roof leaks");
    defer gpa.free(issue);
    const settings = try alice.post("/alice:open/repo/settings", &.{
        .{ "name", "open" },            .{ "description", "" },       .{ "access", "public" },
        .{ "discuss_role", "anybody" }, .{ "issue_role", "members" }, .{ "patch_role", "nobody" },
    });
    defer settings.deinit();
    try settings.expectRedirect("/alice:open/repo/settings");

    // the notify forms are authorized as a read of the repo, not a post to the tab
    const subscribed = try notify(&carol, issue, "subscribe");
    defer subscribed.deinit();
    try subscribed.expectRedirect(issue);
    try expectNotifyAction(&carol, issue, "mute");
    const muted = try notify(&carol, issue, "mute");
    defer muted.deinit();
    try muted.expectRedirect(issue);
    try expectNotifyAction(&carol, issue, "subscribe");
}

// ---- local mode

test "web: subscribing and muting do not exist in local mode" {
    var local = try h.Local(.xit).init();
    defer local.deinit();
    var browser = local.client();
    defer browser.deinit();

    const created = try browser.post("/issues/new", &.{ .{ "title", "the roof leaks" }, .{ "labels", "" }, .{ "description", "" } });
    defer created.deinit();
    try created.expectStatus(.see_other);
    const issue = created.header("location").?;

    for ([_][]const u8{ "subscribe", "mute" }) |action| {
        const r = try notify(&browser, issue, action);
        defer r.deinit();
        try expectRefused(r, .method_not_allowed, "method not allowed");
    }
}
