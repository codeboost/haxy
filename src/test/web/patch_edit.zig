//! editing a patch, its draft, and closing and reopening it

const std = @import("std");
const evt = @import("../../event.zig");
const h = @import("harness.zig");
const p = @import("patches.zig");

const erin_author: evt.CommitAuthor = .{ .name = "erin", .email = "erin@example.test" };

fn edit(c: *h.Client, page: []const u8, title: []const u8, labels: []const u8, description: []const u8, target_branch: []const u8) !*h.Response {
    return c.post(try p.url(c, "{s}/edit", .{page}), &.{
        .{ "title", title }, .{ "labels", labels }, .{ "description", description }, .{ "target_branch", target_branch },
    });
}

fn expectOpenPatch(c: *h.Client, page: []const u8, title: []const u8, target_branch: []const u8) !void {
    const r = try c.getJson(page);
    defer r.deinit();
    try r.expectJson("page.repo.patches.open.count", 1);
    try r.expectJson("page.repo.patches.open.items.0.record.event.title", title);
    try r.expectJson("page.repo.patches.open.items.0.record.event.target_branch", target_branch);
}

// ---- edit

test "web: editing a patch replaces its title, labels, description and target branch" {
    const server = try p.arrangePatches(.sha1);
    defer server.deinit();
    try h.commitOnBranch(server, server.open, "release", "RELEASE", "release\n");
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const page = try p.newBranchPatch(&alice, "feature");
    const r = try edit(&alice, page, "renamed", "x y", "one\r\ntwo", "release");
    defer r.deinit();
    try r.expectRedirect(page);
    const shown = try alice.followJson(r);
    defer shown.deinit();
    try shown.expectJson("page.repo.patches.open.items.0.record.event.title", "renamed");
    try shown.expectJson("page.repo.patches.open.items.0.record.event.labels", "x y");
    try shown.expectJson("page.repo.patches.open.items.0.record.event.description", "one\ntwo");
    try shown.expectJson("page.repo.patches.open.items.0.record.event.target_branch", "release");
    try shown.expectJson("page.repo.patches.open.items.0.record.event.source_branch", "feature");
}

test "web: a patch is edited by its author, another member and an owner, but not by a stranger" {
    const server = try p.arrangePatches(.sha1);
    defer server.deinit();
    _ = try server.createUser(erin_author);
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var erin = try server.clientAs("erin");
    defer erin.deinit();

    // carol, a stranger to the repo, opened it where anybody may
    const page = try p.newBranchPatch(&carol, "feature");
    for ([_]struct { c: *h.Client, title: []const u8 }{
        .{ .c = &carol, .title = "by carol" }, .{ .c = &bob, .title = "by bob" }, .{ .c = &alice, .title = "by alice" },
    }) |case| {
        const r = try edit(case.c, page, case.title, "", "", "master");
        defer r.deinit();
        try r.expectRedirect(page);
        try expectOpenPatch(&alice, page, case.title, "master");
    }

    const r = try edit(&erin, page, "by erin", "", "", "master");
    defer r.deinit();
    try r.expectStatus(.forbidden);
    try std.testing.expectEqualStrings("you don't have permission to do that", r.body);
    try expectOpenPatch(&alice, page, "by alice", "master");
}

test "web: a stranger's blank-title edit comes back as a form failure, the fields being checked before authorship" {
    const server = try p.arrangePatches(.sha1);
    defer server.deinit();
    _ = try server.createUser(erin_author);
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var erin = try server.clientAs("erin");
    defer erin.deinit();

    const page = try p.newBranchPatch(&alice, "feature");
    const form = try p.expectPatchFailure(&erin, try p.url(&erin, "{s}/edit", .{page}), try p.url(&erin, "{s}/edit", .{page}), &.{
        .{ "title", "" }, .{ "labels", "" }, .{ "description", "" }, .{ "target_branch", "master" },
    }, "required_title", .{ .title = "", .labels = "", .description = "", .target_branch = "master", .source_branch = "", .source_kind = "fork" });
    defer form.deinit();
    try expectOpenPatch(&alice, page, "a fix", "master");
}

// one failed edit of alice's branch patch, after which it is unchanged
fn expectEditFailure(target_branch: []const u8, title: []const u8, failure: []const u8) !void {
    const server = try p.arrangePatches(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const page = try p.newBranchPatch(&alice, "feature");
    const form_path = try p.url(&alice, "{s}/edit", .{page});
    const form = try p.expectPatchFailure(&alice, form_path, form_path, &.{
        .{ "title", title }, .{ "labels", "l1 l2" }, .{ "description", "one\r\ntwo" }, .{ "target_branch", target_branch },
    }, failure, .{ .title = title, .labels = "l1 l2", .description = "one\ntwo", .target_branch = target_branch, .source_branch = "", .source_kind = "fork" });
    defer form.deinit();
    try expectOpenPatch(&alice, page, "a fix", "master");
}

test "web: a patch edit without a title comes back with every field" {
    try expectEditFailure("master", " ", "required_title");
}

test "web: a patch edit onto a target branch that does not exist comes back with every field" {
    try expectEditFailure("nope", "renamed", "invalid_target_branch");
}

test "web: a patch edit onto its own source branch comes back with every field" {
    try expectEditFailure("feature", "renamed", "same_branch");
}

test "web: a patch edit with an overlong label goes back to the form with no feedback" {
    const server = try p.arrangePatches(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const page = try p.newBranchPatch(&alice, "feature");
    var long: [65]u8 = undefined;
    @memset(&long, 'x');
    const r = try edit(&alice, page, "renamed", &long, "", "master");
    defer r.deinit();
    try r.expectRedirect(try p.url(&alice, "{s}/edit", .{page}));
    try std.testing.expectEqual(null, alice.cookie("haxy_form_flash"));
    try expectOpenPatch(&alice, page, "a fix", "master");
}

test "web: a draft's author edits it in place" {
    const server = try p.arrangePatches(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const page = try p.newDraft(&alice);
    const r = try edit(&alice, page, "renamed draft", "wip", "more", "master");
    defer r.deinit();
    try r.expectRedirect(page);
    const shown = try alice.followJson(r);
    defer shown.deinit();
    try shown.expectJson("page.repo.patches.drafts.count", 1);
    try shown.expectJson("page.repo.patches.drafts.items.0.record.event.title", "renamed draft");
    try shown.expectJson("page.repo.patches.drafts.items.0.record.event.labels", "wip");
    try shown.expectJson("page.repo.patches.drafts.items.0.record.event.description", "more");
    try shown.expectJson("page.repo.patches.open.count", 0);
}

test "web: another member editing someone's draft finds no such patch" {
    const server = try p.arrangePatches(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();

    const page = try p.newDraft(&alice);
    const r = try edit(&bob, page, "by bob", "", "", "master");
    defer r.deinit();
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("patch not found", r.body);
    try p.expectCount(&alice, page, "page.repo.patches.drafts.count", 1);
    const shown = try alice.getJson(page);
    defer shown.deinit();
    try shown.expectJson("page.repo.patches.drafts.items.0.record.event.title", "a draft");
}

// ---- close and reopen

fn setStatus(c: *h.Client, page: []const u8, action: []const u8) !*h.Response {
    return c.post(try p.url(c, "{s}/{s}", .{ page, action }), &.{});
}

fn expectLists(c: *h.Client, page: []const u8, open: i64, closed: i64, merged: i64) !void {
    const r = try c.getJson(page);
    defer r.deinit();
    try r.expectJson("page.repo.patches.open.count", open);
    try r.expectJson("page.repo.patches.closed.count", closed);
    try r.expectJson("page.repo.patches.merged.count", merged);
}

test "web: closing a patch moves it to the closed list, and reopening brings it back" {
    const server = try p.arrangePatches(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const page = try p.newBranchPatch(&alice, "feature");
    {
        const r = try setStatus(&alice, page, "close");
        defer r.deinit();
        try r.expectRedirect(page);
    }
    try expectLists(&alice, page, 0, 1, 0);
    {
        const shown = try alice.getJson(page);
        defer shown.deinit();
        try shown.expectJsonHas("page.repo.patches.closed.items.0.record.event.status.closed");
    }
    const r = try setStatus(&alice, page, "open");
    defer r.deinit();
    try r.expectRedirect(page);
    try expectLists(&alice, page, 1, 0, 0);
    const shown = try alice.getJson(page);
    defer shown.deinit();
    try shown.expectJson("page.repo.patches.open.items.0.record.event.title", "a fix");
}

test "web: a patch is closed by its author and a member, but not by a stranger or a visitor" {
    const server = try p.arrangePatches(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    var visitor = server.client();
    defer visitor.deinit();

    const alices = try p.newBranchPatch(&alice, "feature");
    {
        const r = try setStatus(&carol, alices, "close");
        defer r.deinit();
        try r.expectStatus(.forbidden);
        try std.testing.expectEqualStrings("you don't have permission to do that", r.body);
    }
    {
        const r = try setStatus(&visitor, alices, "close");
        defer r.deinit();
        try r.expectStatus(.forbidden);
        try std.testing.expectEqualStrings("log in to make changes", r.body);
    }
    try expectLists(&alice, alices, 1, 0, 0);
    {
        const r = try setStatus(&bob, alices, "close");
        defer r.deinit();
        try r.expectRedirect(alices);
    }
    try expectLists(&alice, alices, 0, 1, 0);

    const carols = try p.newBranchPatch(&carol, "feature");
    const r = try setStatus(&carol, carols, "close");
    defer r.deinit();
    try r.expectRedirect(carols);
    try expectLists(&alice, carols, 0, 2, 0);
}

test "web: closing a merged patch fails and leaves it merged" {
    const server = try p.arrangePatches(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const page = try p.newBranchPatch(&alice, "feature");
    {
        const r = try setStatus(&alice, page, "merge");
        defer r.deinit();
        try r.expectRedirect(page);
    }
    try expectLists(&alice, page, 0, 0, 1);
    // the event layer refuses to change a merged patch's status, and the
    // handler lets that out as it did at 66c1ab6
    const r = try setStatus(&alice, page, "close");
    defer r.deinit();
    try r.expectStatus(.internal_server_error);
    try std.testing.expectEqualStrings("PatchAlreadyMerged", r.body);
    try expectLists(&alice, page, 0, 0, 1);
}

test "web: a local patch is closed and reopened" {
    var local = try h.Local(.xit).init();
    defer local.deinit();
    try p.localBranch(.xit, &local, "feature");
    var browser = local.client();
    defer browser.deinit();

    const page = blk: {
        const r = try browser.post("/patches/new", &.{
            .{ "title", "a fix" }, .{ "labels", "" }, .{ "description", "" }, .{ "target_branch", "master" }, .{ "source_branch", "feature" },
        });
        defer r.deinit();
        break :blk try p.location(&browser, r);
    };
    {
        const r = try setStatus(&browser, page, "close");
        defer r.deinit();
        try r.expectRedirect(page);
    }
    try expectLists(&browser, page, 0, 1, 0);
    const r = try setStatus(&browser, page, "open");
    defer r.deinit();
    try r.expectRedirect(page);
    try expectLists(&browser, page, 1, 0, 0);
}
