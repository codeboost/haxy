//! local mode's sync button, which trades events with the repo's remote

const std = @import("std");
const xit = @import("xit");
const h = @import("harness.zig");

const io = std.testing.io;
const gpa = std.testing.allocator;

fn addConfig(comptime kind: xit.repo.RepoKind, local: *const h.Local(kind), name: []const u8, value: []const u8) !void {
    var repo = try xit.repo.Repo(kind, h.Local(kind).repo_opts).open(io, gpa, .{ .path = local.path });
    defer repo.deinit(io, gpa);
    try repo.addConfig(io, gpa, .{ .name = name, .value = value });
}

fn addRemote(comptime kind: xit.repo.RepoKind, local: *const h.Local(kind), url: []const u8) !void {
    var repo = try xit.repo.Repo(kind, h.Local(kind).repo_opts).open(io, gpa, .{ .path = local.path });
    defer repo.deinit(io, gpa);
    try repo.addRemote(io, gpa, .{ .name = "origin", .value = url });
}

fn newIssue(c: *h.Client, title: []const u8) !void {
    const r = try c.post("/issues/new", &.{ .{ "title", title }, .{ "labels", "" }, .{ "description", "" } });
    defer r.deinit();
    try r.expectStatus(.see_other);
}

// the open issues' count, and that each of `titles` is among them
fn expectIssues(c: *h.Client, titles: []const []const u8) !void {
    const page = try c.getJson("/issues");
    defer page.deinit();
    try page.expectJson("page.repo.issues.open.count", @as(i64, @intCast(titles.len)));
    for (titles) |title| try page.expectBodyContains(title);
}

// a sync that failed with `failure`: the flash cookie carries it to /events,
// which shows it once
fn expectSyncFailure(browser: *h.Client, failure: []const u8, cookie: []const u8) !void {
    const r = try browser.post("/sync", &.{});
    defer r.deinit();
    try r.expectRedirect("/events");
    try std.testing.expectEqualStrings(cookie, browser.cookie("haxy_local_flash") orelse "(none)");
    const page = try browser.followJson(r);
    defer page.deinit();
    try page.expectStatus(.ok);
    try page.expectJson("session.sync_failure", failure);
    try std.testing.expectEqual(null, browser.cookie("haxy_local_flash"));
    const again = try browser.getJson("/events");
    defer again.deinit();
    try again.expectJson("session.sync_failure", null);
}

test "web: syncing a local repo with no remote lands on its events with the failure shown once" {
    var local = try h.Local(.git).init();
    defer local.deinit();
    var browser = local.client();
    defer browser.deinit();
    try expectSyncFailure(&browser, "RemoteNotFound", "sync:RemoteNotFound");
}

test "web: syncing with a remote that has no url shows that failure" {
    var local = try h.Local(.git).init();
    defer local.deinit();
    try addConfig(.git, &local, "remote.origin.pushurl", "/nowhere");
    var browser = local.client();
    defer browser.deinit();
    try expectSyncFailure(&browser, "UrlNotFound", "sync:UrlNotFound");
}

test "web: syncing with a remote url that can't be used shows the failure and keeps the local issues" {
    var local = try h.Local(.git).init();
    defer local.deinit();
    var gone = std.testing.tmpDir(.{});
    const base = try gone.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    const url = try std.Io.Dir.path.join(gpa, &.{ base, "nowhere" });
    defer gpa.free(url);
    gone.cleanup();
    // set directly: adding a remote checks that its url exists
    try addConfig(.git, &local, "remote.origin.url", url);
    var browser = local.client();
    defer browser.deinit();
    try newIssue(&browser, "kept here");

    try expectSyncFailure(&browser, "UnsupportedUrl", "sync:UnsupportedUrl");
    try expectIssues(&browser, &.{"kept here"});
}

fn expectSyncsBothWays(comptime kind: xit.repo.RepoKind) !void {
    var remote = try h.Local(kind).init();
    defer remote.deinit();
    var local = try h.Local(kind).init();
    defer local.deinit();
    try addRemote(kind, &local, remote.path);
    var here = local.client();
    defer here.deinit();
    var there = remote.client();
    defer there.deinit();
    try newIssue(&here, "from here");
    try newIssue(&there, "from there");

    const r = try here.post("/sync", &.{});
    defer r.deinit();
    try r.expectRedirect("/events");
    const cookies = try r.headerValues("set-cookie");
    try std.testing.expectEqual(1, cookies.len);
    try std.testing.expectEqualStrings("haxy_local_flash=; Path=/; Max-Age=0", cookies[0]);
    const page = try here.followJson(r);
    defer page.deinit();
    try page.expectJson("session.sync_failure", null);

    try expectIssues(&here, &.{ "from here", "from there" });
    try expectIssues(&there, &.{ "from here", "from there" });
}

test "web: syncing a local git repo with a file remote trades issues both ways" {
    try expectSyncsBothWays(.git);
}

test "web: syncing a local xit repo with a file remote trades issues both ways" {
    try expectSyncsBothWays(.xit);
}

test "web: a sync posted under another page of a local repo is not found" {
    var local = try h.Local(.git).init();
    defer local.deinit();
    var browser = local.client();
    defer browser.deinit();

    const r = try browser.post("/events/sync", &.{});
    defer r.deinit();
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("not found", r.body);
    try std.testing.expectEqual(null, browser.cookie("haxy_local_flash"));
}
