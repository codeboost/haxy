//! protecting branches and choosing the default one through the web forms

const std = @import("std");
const h = @import("harness.zig");

// branch names whose url-encoding takes 512 and 513 bytes: each "é" is two
// bytes that encode as six, each "x" encodes as itself. a ref's path holds 512
// bytes in xit, so the names must stay short raw.
const long_512 = repeat("é", 80) ++ repeat("x", 32);
const long_513 = long_512 ++ "x";
const long_512_encoded = repeat("%C3%A9", 80) ++ repeat("x", 32);
const long_513_encoded = long_512_encoded ++ "x";

fn repeat(comptime text: []const u8, comptime times: usize) []const u8 {
    comptime var out: []const u8 = "";
    inline for (0..times) |_| out = out ++ text;
    return out;
}

fn expectRefused(r: *const h.Response, status: std.http.Status, text: []const u8) !void {
    try r.expectStatus(status);
    if (std.mem.eql(u8, r.body, text)) return;
    r.describe();
    std.debug.print("expected the body \"{s}\"\n", .{text});
    return error.TestExpectedEqual;
}

// the protected branches the branches page lists
fn expectProtected(r: *const h.Response, expected: []const []const u8) !void {
    const names = r.jsonAt("page.repo.settings.branches.names") orelse {
        r.describe();
        return error.TestExpectedJson;
    };
    const same = names.array.items.len == expected.len and for (names.array.items, expected) |a, e| {
        if (!std.mem.eql(u8, a.string, e)) break false;
    } else true;
    if (same) return;
    r.describe();
    std.debug.print("expected the protected branches:", .{});
    for (expected) |name| std.debug.print(" \"{s}\"", .{name});
    std.debug.print("\n", .{});
    return error.TestExpectedEqual;
}

// a master with a commit and each of `branches` started from it with one of its own
fn arrangeBranches(server: *const h.Server, branches: []const []const u8) !void {
    try h.commitOnBranch(server, server.open, "master", "README", "hello\n");
    for (branches) |branch| try h.commitOnBranch(server, server.open, branch, "README", "on a branch\n");
}

fn protect(c: *h.Client, repo: []const u8, branch: []const u8) !*h.Response {
    var buf: [128]u8 = undefined;
    return c.post(try std.fmt.bufPrint(&buf, "/{s}/repo/branches/protect", .{repo}), &.{.{ "name", branch }});
}

fn setDefault(c: *h.Client, repo: []const u8, branch: []const u8) !*h.Response {
    var buf: [128]u8 = undefined;
    return c.post(try std.fmt.bufPrint(&buf, "/{s}/repo/branches/default", .{repo}), &.{.{ "name", branch }});
}

// the row form, which names the branch url-encoded in the url
fn unprotect(c: *h.Client, repo: []const u8, encoded_branch: []const u8) !*h.Response {
    const path = try std.fmt.allocPrint(std.testing.allocator, "/{s}/repo/branches/branch:{s}/unprotect", .{ repo, encoded_branch });
    defer std.testing.allocator.free(path);
    return c.post(path, &.{});
}

test "web: an owner protects a branch, which the branches page then lists" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    try arrangeBranches(server, &.{"feature"});
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try protect(&alice, "alice:open", "feature");
    defer r.deinit();
    try r.expectRedirect("/alice:open/repo/branches");
    const page = try alice.followJson(r);
    defer page.deinit();
    try expectProtected(page, &.{"feature"});
}

test "web: branches named with a slash, a percent sign and multi-byte characters are protected and unprotected" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    const names = [_][]const u8{ "team/feature", "100%", "café-ünï" };
    const encoded = [_][]const u8{ "team%2Ffeature", "100%25", "caf%C3%A9-%C3%BCn%C3%AF" };
    try arrangeBranches(server, &names);
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    for (names) |name| {
        const r = try protect(&alice, "alice:open", name);
        defer r.deinit();
        try r.expectRedirect("/alice:open/repo/branches");
    }
    const all = try alice.getJson("/alice:open/repo/branches");
    defer all.deinit();
    try expectProtected(all, &names);

    for (encoded) |value| {
        const r = try unprotect(&alice, "alice:open", value);
        defer r.deinit();
        try r.expectRedirect("/alice:open/repo/branches");
    }
    const none = try alice.getJson("/alice:open/repo/branches");
    defer none.deinit();
    try expectProtected(none, &.{});
}

test "web: a branch whose encoded name is 512 bytes is protected and unprotected, and one of 513 is too long" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    const name_512 = long_512;
    const name_513 = long_513;
    // the 513 one is never created: any repo page fails on a branch whose
    // name can't route, and the length is checked before the branch is looked up
    try arrangeBranches(server, &.{name_512});
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const too_long = try protect(&alice, "alice:open", name_513);
    defer too_long.deinit();
    try too_long.expectRedirect("/alice:open/repo/branches");
    const form = try alice.followJson(too_long);
    defer form.deinit();
    try form.expectJson("session.form_feedback.repo_branches.failure", "too_long");
    try form.expectJson("session.form_feedback.repo_branches.name", name_513);
    try form.expectJson("session.form_feedback.repo_branches.default", false);
    try expectProtected(form, &.{});

    const fits_r = try protect(&alice, "alice:open", name_512);
    defer fits_r.deinit();
    try fits_r.expectRedirect("/alice:open/repo/branches");
    const listed = try alice.followJson(fits_r);
    defer listed.deinit();
    try expectProtected(listed, &.{name_512});

    const removed = try unprotect(&alice, "alice:open", long_512_encoded);
    defer removed.deinit();
    try removed.expectRedirect("/alice:open/repo/branches");
    const none = try alice.getJson("/alice:open/repo/branches");
    defer none.deinit();
    try expectProtected(none, &.{});
}

test "web: a 513-byte encoded branch can't be the default either" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    const name_513 = long_513;
    try arrangeBranches(server, &.{});
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try setDefault(&alice, "alice:open", name_513);
    defer r.deinit();
    try r.expectRedirect("/alice:open/repo/branches");
    const form = try alice.followJson(r);
    defer form.deinit();
    try form.expectJson("session.form_feedback.repo_branches.failure", "too_long");
    try form.expectJson("session.form_feedback.repo_branches.default", true);
    try form.expectJson("page.repo.settings.branches.default_branch", "master");
}

test "web: the unprotect row form with a branch too long for its url is not found" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try unprotect(&alice, "alice:open", long_513_encoded);
    defer r.deinit();
    try expectRefused(r, .not_found, "repo not found");
}

test "web: protecting a protected branch comes back as already added, keeping the name" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    try arrangeBranches(server, &.{"feature"});
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const first = try protect(&alice, "alice:open", "feature");
    defer first.deinit();
    try first.expectRedirect("/alice:open/repo/branches");

    const r = try protect(&alice, "alice:open", "feature");
    defer r.deinit();
    try r.expectRedirect("/alice:open/repo/branches");
    const form = try alice.followJson(r);
    defer form.deinit();
    try form.expectJson("session.form_feedback.repo_branches.failure", "already_added");
    try form.expectJson("session.form_feedback.repo_branches.name", "feature");
    try form.expectJson("session.form_feedback.repo_branches.default", false);
    try expectProtected(form, &.{"feature"});
}

test "web: protecting a branch that does not exist comes back as not found" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    try arrangeBranches(server, &.{});
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try protect(&alice, "alice:open", "no/such");
    defer r.deinit();
    try r.expectRedirect("/alice:open/repo/branches");
    const form = try alice.followJson(r);
    defer form.deinit();
    try form.expectJson("session.form_feedback.repo_branches.failure", "not_found");
    try form.expectJson("session.form_feedback.repo_branches.name", "no/such");
    try expectProtected(form, &.{});
}

test "web: protecting more than fifty branches comes back as too many" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var names: [51][]const u8 = undefined;
    var bufs: [51][8]u8 = undefined;
    for (&names, &bufs, 0..) |*name, *buf, i| name.* = try std.fmt.bufPrint(buf, "b{d}", .{i});
    try arrangeBranches(server, &names);
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    for (names[0..50]) |name| {
        const r = try protect(&alice, "alice:open", name);
        defer r.deinit();
        try r.expectRedirect("/alice:open/repo/branches");
    }
    const r = try protect(&alice, "alice:open", "b50");
    defer r.deinit();
    try r.expectRedirect("/alice:open/repo/branches");
    const form = try alice.followJson(r);
    defer form.deinit();
    try form.expectJson("session.form_feedback.repo_branches.failure", "too_many");
    try form.expectJson("session.form_feedback.repo_branches.name", "b50");
}

test "web: unprotecting a branch that isn't protected changes nothing and still lands on the list" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    try arrangeBranches(server, &.{ "feature", "other" });
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const first = try protect(&alice, "alice:open", "feature");
    defer first.deinit();
    try first.expectRedirect("/alice:open/repo/branches");

    for ([_][]const u8{ "other", "no-such" }) |name| {
        const r = try unprotect(&alice, "alice:open", name);
        defer r.deinit();
        try r.expectRedirect("/alice:open/repo/branches");
    }
    const page = try alice.getJson("/alice:open/repo/branches");
    defer page.deinit();
    try expectProtected(page, &.{"feature"});
}

test "web: the unprotect form without a branch in its url is not found" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try alice.post("/alice:open/repo/branches/unprotect", &.{});
    defer r.deinit();
    try expectRefused(r, .not_found, "repo not found");
}

test "web: an owner makes a branch the default, which the branches page then shows" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    try arrangeBranches(server, &.{"team/next"});
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try setDefault(&alice, "alice:open", "team/next");
    defer r.deinit();
    try r.expectRedirect("/alice:open/repo/branches");
    const page = try alice.followJson(r);
    defer page.deinit();
    try page.expectJson("page.repo.settings.branches.default_branch", "team/next");
    // a default branch is not a protected one
    try expectProtected(page, &.{});
}

test "web: an owner makes a branch of a sha256 repo the default" {
    const server = try h.Server.init(.sha256);
    defer server.deinit();
    try arrangeBranches(server, &.{"feature"});
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try setDefault(&alice, "alice:open", "feature");
    defer r.deinit();
    try r.expectRedirect("/alice:open/repo/branches");
    const page = try alice.followJson(r);
    defer page.deinit();
    try page.expectJson("page.repo.settings.branches.default_branch", "feature");
    try page.expectJson("page.repo.settings.hash_kind", "sha256");
}

test "web: making a branch that does not exist the default comes back as not found from the default form" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    try arrangeBranches(server, &.{});
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try setDefault(&alice, "alice:open", "nowhere");
    defer r.deinit();
    try r.expectRedirect("/alice:open/repo/branches");
    const form = try alice.followJson(r);
    defer form.deinit();
    try form.expectJson("session.form_feedback.repo_branches.failure", "not_found");
    try form.expectJson("session.form_feedback.repo_branches.name", "nowhere");
    try form.expectJson("session.form_feedback.repo_branches.default", true);
    try form.expectJson("page.repo.settings.branches.default_branch", "master");
}

// every branch form, refused with `status` and `text`: protect and default
// with a branch that would come back as not found, unprotect naming feature
fn expectEveryFormRefused(c: *h.Client, repo: []const u8, status: std.http.Status, text: []const u8) !void {
    const p = try protect(c, repo, "nowhere");
    defer p.deinit();
    try expectRefused(p, status, text);
    const d = try setDefault(c, repo, "nowhere");
    defer d.deinit();
    try expectRefused(d, status, text);
    const u = try unprotect(c, repo, "feature");
    defer u.deinit();
    try expectRefused(u, status, text);
}

// feature protected by alice, so a refused unprotect has something to leave
fn arrangeProtected(server: *const h.Server) !void {
    try arrangeBranches(server, &.{"feature"});
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const r = try protect(&alice, "alice:open", "feature");
    defer r.deinit();
    try r.expectRedirect("/alice:open/repo/branches");
}

fn expectUnchanged(server: *const h.Server) !void {
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const page = try alice.getJson("/alice:open/repo/branches");
    defer page.deinit();
    try expectProtected(page, &.{"feature"});
    try page.expectJson("page.repo.settings.branches.default_branch", "master");
}

test "web: every branch form is refused to the logged out and a removed account's session, even for a repo that does not exist" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    try arrangeProtected(server);
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
    try expectUnchanged(server);
}

test "web: every branch form is forbidden to a stranger and a member, whatever the form says" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    try arrangeProtected(server);
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();

    try expectEveryFormRefused(&carol, "alice:open", .forbidden, "you don't have permission to do that");
    // bob is a member of both repos
    for ([_][]const u8{ "alice:open", "alice:secret" }) |repo| {
        try expectEveryFormRefused(&bob, repo, .forbidden, "you don't have permission to do that");
    }
    try expectUnchanged(server);
}

test "web: a stranger's branch forms for a private repo answer as for a repo that does not exist" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    for ([_][]const u8{ "alice:secret", "alice:nothing" }) |repo| {
        try expectEveryFormRefused(&carol, repo, .not_found, "repo not found");
    }
}
