//! merging a patch into its target branch, as its commits or squashed

const std = @import("std");
const h = @import("harness.zig");
const p = @import("patches.zig");

// the newest commit message on master, as the repo's front page lists it
fn expectMasterTip(c: *h.Client, message: []const u8) !void {
    const r = try c.getJson("/alice:open");
    defer r.deinit();
    try r.expectJson("page.repo.changes.commits.commits.0.message", message);
}

fn expectMerged(c: *h.Client, page: []const u8, revision: []const u8) !void {
    const r = try c.getJson(page);
    defer r.deinit();
    try r.expectJson("page.repo.patches.open.count", 0);
    try r.expectJson("page.repo.patches.merged.count", 1);
    try r.expectJson("page.repo.patches.merged.items.0.record.event.status.merged.revision", revision);
}

fn expectStillOpen(c: *h.Client, page: []const u8) !void {
    const r = try c.getJson(page);
    defer r.deinit();
    try r.expectJson("page.repo.patches.open.count", 1);
    try r.expectJson("page.repo.patches.merged.count", 0);
}

fn mergeAs(c: *h.Client, page: []const u8, action: []const u8) !*h.Response {
    return c.post(try p.url(c, "{s}/{s}", .{ page, action }), &.{});
}

// a source branch with two commits touching two files, master one behind it
fn arrangeTwoCommits() !*h.Server {
    const server = try p.arrangePatches(.sha1);
    errdefer server.deinit();
    try h.commitOnBranch(server, server.open, "feature", "NOTES", "notes\n");
    return server;
}

// the first line of the file `name` on master, as the front page lists it
fn expectMasterFile(c: *h.Client, name: []const u8, line: []const u8) !void {
    const r = try c.getJson("/alice:open");
    defer r.deinit();
    const entries = (r.jsonAt("page.repo.files.entries") orelse {
        r.describe();
        return error.TestExpectedJson;
    }).array.items;
    for (entries) |entry| {
        if (!std.mem.eql(u8, entry.object.get("name").?.string, name)) continue;
        const lines = entry.object.get("lines").?.array.items;
        try std.testing.expect(lines.len != 0);
        try std.testing.expectEqualStrings(line, lines[0].string);
        return;
    }
    r.describe();
    std.debug.print("no file {s} on master\n", .{name});
    return error.TestExpectedFile;
}

fn expectMasterCommits(c: *h.Client, messages: []const []const u8) !void {
    const r = try c.getJson("/alice:open");
    defer r.deinit();
    const commits = (r.jsonAt("page.repo.changes.commits.commits") orelse {
        r.describe();
        return error.TestExpectedJson;
    }).array.items;
    try std.testing.expectEqual(messages.len, commits.len);
    for (messages, commits) |message, commit| try std.testing.expectEqualStrings(message, commit.object.get("message").?.string);
}

test "web: merging a patch brings each of its commits onto the target and shows it merged" {
    const server = try arrangeTwoCommits();
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const page = try p.newBranchPatch(&alice, "feature");
    try expectMasterCommits(&alice, &.{"repo"});
    const r = try mergeAs(&alice, page, "merge");
    defer r.deinit();
    try r.expectRedirect(page);
    try expectMerged(&alice, page, "source");
    try expectMasterCommits(&alice, &.{ "notes", "feature work", "repo" });
    try expectMasterFile(&alice, "README", "feature work");
    try expectMasterFile(&alice, "NOTES", "notes");
}

test "web: squashing a patch lands its commits as one, named after it" {
    const server = try arrangeTwoCommits();
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const page = try p.newBranchPatch(&alice, "feature");
    const r = try mergeAs(&alice, page, "squash");
    defer r.deinit();
    try r.expectRedirect(page);
    try expectMerged(&alice, page, "squash");
    try expectMasterCommits(&alice, &.{ "a fix", "repo" });
    try expectMasterFile(&alice, "README", "feature work");
    try expectMasterFile(&alice, "NOTES", "notes");
}

test "web: a patch on a sha256 repo merges" {
    const server = try p.arrangePatches(.sha256);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const page = try p.newBranchPatch(&alice, "feature");
    const r = try mergeAs(&alice, page, "merge");
    defer r.deinit();
    try r.expectRedirect(page);
    try expectMerged(&alice, page, "source");
    try expectMasterTip(&alice, "feature work");
}

test "web: a member merges into a protected branch, which a stranger cannot" {
    const server = try p.arrangePatches(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    {
        const r = try alice.post("/alice:open/repo/branches/protect", &.{.{ "name", "master" }});
        defer r.deinit();
        try r.expectRedirect("/alice:open/repo/branches");
    }

    const page = try p.newBranchPatch(&carol, "feature");
    {
        const r = try mergeAs(&carol, page, "merge");
        defer r.deinit();
        try r.expectStatus(.forbidden);
        try std.testing.expectEqualStrings("you don't have permission to do that", r.body);
    }
    try expectStillOpen(&alice, page);

    // members change protected branches only by merging a patch
    const r = try mergeAs(&bob, page, "merge");
    defer r.deinit();
    try r.expectRedirect(page);
    try expectMerged(&alice, page, "source");
    try expectMasterTip(&alice, "feature work");
}

test "web: merging or squashing logged out, as a removed account, as a stranger or on a hidden repo is refused" {
    const server = try p.arrangePatches(.sha1);
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

    const page = try p.newBranchPatch(&alice, "feature");
    for ([_][]const u8{ "merge", "squash" }) |action| {
        for ([_]*h.Client{ &visitor, &dave }) |c| {
            const r = try mergeAs(c, page, action);
            defer r.deinit();
            try r.expectStatus(.forbidden);
            try std.testing.expectEqualStrings("log in to make changes", r.body);
        }
        {
            const r = try mergeAs(&carol, page, action);
            defer r.deinit();
            try r.expectStatus(.forbidden);
            try std.testing.expectEqualStrings("you don't have permission to do that", r.body);
        }
        for ([_][]const u8{ "/alice:secret/patch:00000000000000000000000000000000", "/alice:nothing/patch:00000000000000000000000000000000" }) |target| {
            const r = try mergeAs(&carol, target, action);
            defer r.deinit();
            try r.expectStatus(.not_found);
            try std.testing.expectEqualStrings("repo not found", r.body);
        }
    }
    try expectStillOpen(&alice, page);
    try expectMasterTip(&alice, "repo");
}

fn expectConflict(action: []const u8) !void {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    try p.arrangeBranches(server, server.open);
    // master moves on and changes the same line
    try h.commitOnBranch(server, server.open, "master", "README", "other work\n");
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    try p.setPatchTab(&alice, "open", "public", "anybody");

    const page = try p.newBranchPatch(&alice, "feature");
    const r = try mergeAs(&alice, page, action);
    defer r.deinit();
    try r.expectStatus(.conflict);
    try std.testing.expectEqualStrings("merge conflict", r.body);
    try expectStillOpen(&alice, page);
    try expectMasterTip(&alice, "other work");
}

test "web: a patch that conflicts with its target is refused as a conflict, merged or squashed" {
    try expectConflict("merge");
    try expectConflict("squash");
}

fn expectStale(action: []const u8) !void {
    const server = try p.arrangePatches(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const page = try p.newBranchPatch(&alice, "feature");
    // the target moves after the patch's check was saved
    try h.commitOnBranch(server, server.open, "master", "OTHER", "elsewhere\n");
    const r = try mergeAs(&alice, page, action);
    defer r.deinit();
    try r.expectRedirect(page);
    try expectStillOpen(&alice, page);
    try expectMasterTip(&alice, "elsewhere");
}

test "web: a merge or squash whose check no longer matches the target reloads the patch unmerged" {
    try expectStale("merge");
    try expectStale("squash");
}

test "web: merging a patch twice fails the second time" {
    const server = try p.arrangePatches(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const page = try p.newBranchPatch(&alice, "feature");
    {
        const r = try mergeAs(&alice, page, "merge");
        defer r.deinit();
        try r.expectRedirect(page);
    }
    const r = try mergeAs(&alice, page, "squash");
    defer r.deinit();
    try r.expectStatus(.internal_server_error);
    try std.testing.expectEqualStrings("PatchAlreadyMerged", r.body);
    try expectMerged(&alice, page, "source");
}

test "web: merging a patch id that names no patch in a repo with no events is not found" {
    const server = try p.arrangePatches(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try alice.post("/alice:open/patch:00000000000000000000000000000000/merge", &.{});
    defer r.deinit();
    // differs from 66c1ab6: the repo's missing event history escaped the
    // handler as 500 "NotFound"; now 404. accepted as D2 in the http review
    // (codex-review-http-out.md, section 3)
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("event not found", r.body);
}

test "web: merging a patch id that names no patch in a repo with events is not found" {
    const server = try p.arrangePatches(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    {
        const r = try alice.post("/alice:open/issues/new", &.{ .{ "title", "an issue" }, .{ "labels", "" }, .{ "description", "" } });
        defer r.deinit();
        try r.expectStatus(.see_other);
    }
    const page = try p.newBranchPatch(&alice, "feature");

    const r = try alice.post("/alice:open/patch:00000000000000000000000000000000/merge", &.{});
    defer r.deinit();
    // differs from 66c1ab6: with events to read, the missing patch escaped
    // the handler as 500 "InvalidPatch"; now 404. accepted as D2 in the http
    // review (codex-review-http-out.md, section 3)
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("event not found", r.body);
    try expectStillOpen(&alice, page);
}

test "web: merging at a malformed patch id is not found" {
    const server = try p.arrangePatches(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try alice.post("/alice:open/patch:xyz/merge", &.{});
    defer r.deinit();
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("event not found", r.body);
}

test "web: a local host has no merge or squash route" {
    var local = try h.Local(.xit).init();
    defer local.deinit();
    var browser = local.client();
    defer browser.deinit();

    for ([_][]const u8{ "merge", "squash" }) |action| {
        const r = try browser.post(try p.url(&browser, "/patch:00000000000000000000000000000000/{s}", .{action}), &.{});
        defer r.deinit();
        try r.expectStatus(.method_not_allowed);
        try std.testing.expectEqualStrings("method not allowed", r.body);
    }
}
