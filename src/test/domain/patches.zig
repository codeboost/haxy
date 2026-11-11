const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const Server = fixture.Server;

const alices: fixture.Id = @splat(0xa1);
const alices_hex = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
const bobs: fixture.Id = @splat(0xb1);
const bobs_hex = "b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1";

test "domain: ListPatches lists a repo's patches by view and GetPatch reads one" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    try server.addEvent(server.open, Server.alice_author, alices, .{ .patch = .{ .title = "a patch", .description = "why", .labels = "fix", .target_branch = "master" } });
    try server.addDraft(server.open, server.bob, Server.bob_author, bobs);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);

    const open = try (domain.ListPatches{ .repo = "alice:open", .view = .open }).run(&bob);
    try std.testing.expectEqual(1, open.count);
    try std.testing.expectEqualStrings(alices_hex, open.items[0].id);
    try std.testing.expectEqual(0, (try (domain.ListPatches{ .repo = "alice:open", .view = .merged }).run(&bob)).count);

    // a draft shows only to the user who started it
    const drafts = try (domain.ListPatches{ .repo = "alice:open", .view = .drafts }).run(&bob);
    try std.testing.expectEqual(1, drafts.count);
    try std.testing.expectEqualStrings(bobs_hex, drafts.items[0].id);
    try std.testing.expect(drafts.items[0].draft);
    var carol = try server.ctx(&arena, server.carol);
    try std.testing.expectEqual(0, (try (domain.ListPatches{ .repo = "alice:open", .view = .drafts }).run(&carol)).count);

    const entry = try (domain.GetPatch{ .repo = "alice:open", .id = alices_hex }).run(&bob);
    try std.testing.expectEqualStrings("a patch", entry.record.event.title);
    try std.testing.expectEqualStrings("why", entry.record.event.description);
    try std.testing.expectEqualStrings("master", entry.record.event.target_branch);
    const draft = try (domain.GetPatch{ .repo = "alice:open", .id = bobs_hex }).run(&bob);
    try std.testing.expectEqualStrings("a draft", draft.record.event.title);
    try std.testing.expectError(error.NotFound, (domain.GetPatch{ .repo = "alice:open", .id = bobs_hex }).run(&carol));
    try std.testing.expectError(error.NotFound, (domain.GetPatch{ .repo = "alice:open", .id = "22222222222222222222222222222222" }).run(&bob));

    // a tab that is off doesn't exist
    try server.setTabs(server.open, .read, .read, null);
    try std.testing.expectError(error.NotFound, (domain.ListPatches{ .repo = "alice:open" }).run(&bob));
}

fn expectLocalBranchPatch(comptime kind: hx.xit.repo.RepoKind, comptime hash_kind: hx.xit.hash.HashKind) !void {
    var local = try fixture.Local(kind, hash_kind).init();
    defer local.deinit();
    try local.commitBranch("feature", "feature\n");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    const created = try (domain.CreateThread{ .repo = "", .kind = .patch, .title = "a feature", .labels = "new", .body = "adds it", .target_branch = "master", .source_branch = "feature" }).run(&ctx);
    const open = try (domain.ListPatches{ .repo = "" }).run(&ctx);
    try std.testing.expectEqual(1, open.count);
    try std.testing.expectEqualStrings(&created.id, open.items[0].id);
    const entry = try (domain.GetPatch{ .repo = "", .id = &created.id }).run(&ctx);
    try std.testing.expectEqualStrings("a feature", entry.record.event.title);
    try std.testing.expectEqualStrings("new", entry.record.event.labels);
    try std.testing.expectEqualStrings("adds it", entry.record.event.description);
    try std.testing.expectEqualStrings("feature", entry.record.event.source_branch.?);
    try std.testing.expectEqualStrings("master", entry.record.event.target_branch);
    try std.testing.expect(entry.record.event.revision != null);
}

test "domain: CreateThread opens a branch patch in a local git or xit repo" {
    try expectLocalBranchPatch(.git, .sha1);
    try expectLocalBranchPatch(.git, .sha256);
    try expectLocalBranchPatch(.xit, .sha1);
    try expectLocalBranchPatch(.xit, .sha256);
}

fn expectLocalBranchPatchFailures(comptime kind: hx.xit.repo.RepoKind, comptime hash_kind: hx.xit.hash.HashKind) !void {
    var local = try fixture.Local(kind, hash_kind).init();
    defer local.deinit();
    try local.commitBranch("feature", "feature\n");
    try local.commitOrphan("orphan");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    const cases = [_]struct { expected: anyerror, title: []const u8 = "t", labels: []const u8 = "", target: []const u8 = "master", source: []const u8 = "feature" }{
        .{ .expected = error.InvalidTitle, .title = " " },
        .{ .expected = error.InvalidLabels, .labels = "ok " ++ @as([65]u8, @splat('x')) },
        .{ .expected = error.InvalidSourceBranch, .source = "missing" },
        .{ .expected = error.InvalidSourceBranch, .source = "" },
        .{ .expected = error.InvalidTargetBranch, .target = "missing" },
        .{ .expected = error.SameBranch, .source = "master" },
        .{ .expected = error.UnrelatedBranches, .source = "orphan" },
    };
    for (cases) |case| {
        try std.testing.expectError(case.expected, (domain.CreateThread{ .repo = "", .kind = .patch, .title = case.title, .labels = case.labels, .target_branch = case.target, .source_branch = case.source }).run(&ctx));
    }
    // nothing was written
    try std.testing.expectEqual(0, (try (domain.ListPatches{ .repo = "" }).run(&ctx)).count);
}

test "domain: CreateThread refuses a branch patch with bad fields or branches" {
    try expectLocalBranchPatchFailures(.git, .sha1);
    try expectLocalBranchPatchFailures(.xit, .sha256);
}

fn expectServerBranchPatch(comptime hash_kind: hx.xit.hash.HashKind) !void {
    const server = try Server.init(hash_kind);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    try server.commitBranch(server.open, "feature", "feature\n");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var carol = try server.ctx(&arena, server.carol);

    const created = try (domain.CreateThread{ .repo = "alice:open", .kind = .patch, .title = "a feature", .target_branch = "master", .source_branch = "feature" }).run(&carol);
    const entry = try (domain.GetPatch{ .repo = "alice:open", .id = &created.id }).run(&carol);
    try std.testing.expectEqualStrings("a feature", entry.record.event.title);
    try std.testing.expectEqualStrings("carol@example.test", entry.record.author_email.?);
    try std.testing.expectEqual(.clean, entry.mergeability.source);
}

test "domain: CreateThread opens a branch patch on a server and checks its mergeability" {
    try expectServerBranchPatch(.sha1);
    try expectServerBranchPatch(.sha256);
}

test "domain: CreateThread for a patch needs a login, the tab's role and a repo the user can see" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    try server.commitBranch(server.open, "feature", "feature\n");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const patch = domain.CreateThread{ .repo = "alice:open", .kind = .patch, .title = "t", .target_branch = "master", .source_branch = "feature" };

    for ([_]?fixture.Id{ server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.LoginRequired, patch.run(&ctx));
        var draft = patch;
        draft.source_branch = null;
        try std.testing.expectError(error.LoginRequired, draft.run(&ctx));
    }
    var carol = try server.ctx(&arena, server.carol);
    var secret = patch;
    secret.repo = "alice:secret";
    try std.testing.expectError(error.NotFound, secret.run(&carol));
    // only writers may open patches
    try server.setTabs(server.open, .read, .read, .write);
    try std.testing.expectError(error.Forbidden, patch.run(&carol));
    var bob = try server.ctx(&arena, server.bob);
    try std.testing.expectEqual(0, (try (domain.ListPatches{ .repo = "alice:open" }).run(&bob)).count);
    // a tab that is off doesn't exist
    try server.setTabs(server.open, .read, .read, null);
    try std.testing.expectError(error.NotFound, patch.run(&bob));
}

fn expectDraftCreate(comptime hash_kind: hx.xit.hash.HashKind) !void {
    const server = try Server.init(hash_kind);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);

    for ([_][]const u8{ "missing", "" }) |target_branch| {
        try std.testing.expectError(error.InvalidTargetBranch, (domain.CreateThread{ .repo = "alice:open", .kind = .patch, .title = "t", .target_branch = target_branch }).run(&bob));
    }
    const created = try (domain.CreateThread{ .repo = "alice:open", .kind = .patch, .title = "a draft", .labels = "wip", .body = "soon", .target_branch = "master" }).run(&bob);
    const drafts = try (domain.ListPatches{ .repo = "alice:open", .view = .drafts }).run(&bob);
    try std.testing.expectEqual(1, drafts.count);
    try std.testing.expectEqualStrings(&created.id, drafts.items[0].id);
    try std.testing.expect(drafts.items[0].draft);
    try std.testing.expectEqualStrings("a draft", drafts.items[0].record.event.title);
    try std.testing.expectEqualStrings("wip", drafts.items[0].record.event.labels);
    try std.testing.expectEqualStrings("soon", drafts.items[0].record.event.description);
    try std.testing.expectEqual(0, (try (domain.ListPatches{ .repo = "alice:open" }).run(&bob)).count);
}

test "domain: CreateThread starts a server draft in a fork and checks its target branch" {
    try expectDraftCreate(.sha1);
    try expectDraftCreate(.sha256);
}

test "domain: CreateThread starts no draft in local mode" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);
    try std.testing.expectError(error.UnavailableHere, (domain.CreateThread{ .repo = "", .kind = .patch, .title = "a patch", .target_branch = "master" }).run(&ctx));
}

fn expectPublish(comptime hash_kind: hx.xit.hash.HashKind) !void {
    const server = try Server.init(hash_kind);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);

    const created = try (domain.CreateThread{ .repo = "alice:open", .kind = .patch, .title = "a draft", .body = "soon", .target_branch = "master" }).run(&bob);
    try (domain.PublishPatch{ .repo = "alice:open", .patch_id = &created.id }).run(&bob);
    try std.testing.expectEqual(0, (try (domain.ListPatches{ .repo = "alice:open", .view = .drafts }).run(&bob)).count);
    var carol = try server.ctx(&arena, server.carol);
    const open = try (domain.ListPatches{ .repo = "alice:open" }).run(&carol);
    try std.testing.expectEqual(1, open.count);
    try std.testing.expectEqualStrings(&created.id, open.items[0].id);
    try std.testing.expectEqualStrings("a draft", open.items[0].record.event.title);
    try std.testing.expectEqualStrings("bob@example.test", open.items[0].record.author_email.?);
    try std.testing.expect(!open.items[0].draft);
}

test "domain: PublishPatch moves a draft from the drafts to the open patches" {
    try expectPublish(.sha1);
    try expectPublish(.sha256);
}

test "domain: PublishPatch publishes only the acting user's draft and needs a login and the tab's role" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    try server.addDraft(server.open, server.bob, Server.bob_author, bobs);
    const carols: fixture.Id = @splat(0xc1);
    try server.addDraft(server.open, server.carol, Server.carol_author, carols);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for ([_]?fixture.Id{ server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.LoginRequired, (domain.PublishPatch{ .repo = "alice:open", .patch_id = bobs_hex }).run(&ctx));
    }
    var carol = try server.ctx(&arena, server.carol);
    // someone else's draft is nothing to publish
    try std.testing.expectError(error.NotFound, (domain.PublishPatch{ .repo = "alice:open", .patch_id = bobs_hex }).run(&carol));
    for ([_][]const u8{ "22222222222222222222222222222222", "not an id" }) |id| {
        try std.testing.expectError(error.NotFound, (domain.PublishPatch{ .repo = "alice:open", .patch_id = id }).run(&carol));
    }
    try std.testing.expectError(error.NotFound, (domain.PublishPatch{ .repo = "alice:secret", .patch_id = bobs_hex }).run(&carol));
    // only writers may publish once the tab takes writers
    try server.setTabs(server.open, .read, .read, .write);
    try std.testing.expectError(error.Forbidden, (domain.PublishPatch{ .repo = "alice:open", .patch_id = "c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1" }).run(&carol));

    var bob = try server.ctx(&arena, server.bob);
    try std.testing.expectEqual(0, (try (domain.ListPatches{ .repo = "alice:open" }).run(&bob)).count);
    try std.testing.expectEqual(1, (try (domain.ListPatches{ .repo = "alice:open", .view = .drafts }).run(&bob)).count);
}

test "domain: PublishPatch is server only" {
    var local = try fixture.Local(.xit, .sha1).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);
    try std.testing.expectError(error.UnavailableHere, (domain.PublishPatch{ .repo = "", .patch_id = bobs_hex }).run(&ctx));
}

fn expectDraftLifecycle(comptime hash_kind: hx.xit.hash.HashKind) !void {
    const server = try Server.init(hash_kind);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    // before the draft, so its fork copies the branch
    try server.commitBranch(server.open, "feature", "feature\n");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);

    const created = try (domain.CreateThread{ .repo = "alice:open", .kind = .patch, .title = "a feature", .target_branch = "master" }).run(&bob);
    try std.testing.expectEqual(1, (try (domain.ListPatches{ .repo = "alice:open", .view = .drafts }).run(&bob)).count);
    const id = try evt.parseEventId(&created.id);
    try server.pushDraft(server.bob, Server.bob_author, id, "feature");

    try (domain.PublishPatch{ .repo = "alice:open", .patch_id = &created.id }).run(&bob);
    try std.testing.expectEqual(0, (try (domain.ListPatches{ .repo = "alice:open", .view = .drafts }).run(&bob)).count);
    try std.testing.expectEqual(1, (try (domain.ListPatches{ .repo = "alice:open" }).run(&bob)).count);

    var alice = try server.ctx(&arena, server.alice);
    try (domain.MergePatch{ .repo = "alice:open", .patch_id = &created.id, .mode = .source }).run(&alice);
    try std.testing.expectEqual(0, (try (domain.ListPatches{ .repo = "alice:open" }).run(&alice)).count);
    const merged = try (domain.ListPatches{ .repo = "alice:open", .view = .merged }).run(&alice);
    try std.testing.expectEqual(1, merged.count);
    try std.testing.expectEqualStrings(&created.id, merged.items[0].id);
    try std.testing.expectEqual(.merged, merged.items[0].record.event.status.kind());
    // the merged patch's fork is gone
    const fork_path = try hx.fork.forkPath(arena.allocator(), server.users_dir, &server.bob, &id);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, fork_path, .{}));
}

test "domain: a fork draft goes from drafts to open to merged" {
    try expectDraftLifecycle(.sha1);
    try expectDraftLifecycle(.sha256);
}

test "domain: MergePatch refuses a conflicting patch and merges nothing" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    try server.commitBranch(server.open, "clash", "clash\n");
    try server.commitBranch(server.open, "master", "master\n");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);

    const created = try (domain.CreateThread{ .repo = "alice:open", .kind = .patch, .title = "clashes", .target_branch = "master", .source_branch = "clash" }).run(&bob);
    for ([_]domain.MergePatch.Mode{ .source, .squash }) |mode| {
        try std.testing.expectError(error.MergeConflict, (domain.MergePatch{ .repo = "alice:open", .patch_id = &created.id, .mode = mode }).run(&bob));
    }
    try std.testing.expectEqual(1, (try (domain.ListPatches{ .repo = "alice:open" }).run(&bob)).count);
    try std.testing.expectEqual(0, (try (domain.ListPatches{ .repo = "alice:open", .view = .merged }).run(&bob)).count);
    try std.testing.expectEqual(.conflict, domain.classify(error.MergeConflict).kind);
}

test "domain: MergePatch squashes a branch patch and needs a login, the write role and a known patch" {
    const server = try Server.init(.sha256);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    try server.commitBranch(server.open, "feature", "feature\n");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var carol = try server.ctx(&arena, server.carol);
    const created = try (domain.CreateThread{ .repo = "alice:open", .kind = .patch, .title = "a feature", .target_branch = "master", .source_branch = "feature" }).run(&carol);
    const merge = domain.MergePatch{ .repo = "alice:open", .patch_id = &created.id, .mode = .squash };

    for ([_]?fixture.Id{ server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.LoginRequired, merge.run(&ctx));
    }
    // the patch's author reads the repo, but merging takes writers
    try std.testing.expectError(error.Forbidden, merge.run(&carol));
    var bob = try server.ctx(&arena, server.bob);
    for ([_][]const u8{ "22222222222222222222222222222222", "not an id" }) |id| {
        try std.testing.expectError(error.NotFound, (domain.MergePatch{ .repo = "alice:open", .patch_id = id }).run(&bob));
    }
    try std.testing.expectError(error.NotFound, (domain.MergePatch{ .repo = "alice:secret", .patch_id = &created.id }).run(&carol));
    try std.testing.expectEqual(0, (try (domain.ListPatches{ .repo = "alice:open", .view = .merged }).run(&bob)).count);

    try merge.run(&bob);
    const entry = try (domain.GetPatch{ .repo = "alice:open", .id = &created.id }).run(&bob);
    try std.testing.expectEqual(.squash, entry.record.event.status.merged.revision);
}

test "domain: MergePatch is server only" {
    var local = try fixture.Local(.xit, .sha1).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);
    try std.testing.expectError(error.UnavailableHere, (domain.MergePatch{ .repo = "", .patch_id = alices_hex }).run(&ctx));
}

test "domain: a merge whose fork removal fails is classified as changed" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    try server.commitBranch(server.open, "feature", "feature\n");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);
    const created = try (domain.CreateThread{ .repo = "alice:open", .kind = .patch, .title = "a feature", .target_branch = "master" }).run(&bob);
    try server.pushDraft(server.bob, Server.bob_author, try evt.parseEventId(&created.id), "feature");
    try (domain.PublishPatch{ .repo = "alice:open", .patch_id = &created.id }).run(&bob);

    // without its forker's user repo, the fork's record can't be removed
    const user_repo_path = try evt.userRepoPath(arena.allocator(), server.users_dir, &server.bob);
    try std.Io.Dir.cwd().deleteTree(std.testing.io, user_repo_path);
    var alice = try server.ctx(&arena, server.alice);
    const result = blk: {
        // the expected failure logs a warning
        const log_level = std.testing.log_level;
        std.testing.log_level = .err;
        defer std.testing.log_level = log_level;
        break :blk (domain.MergePatch{ .repo = "alice:open", .patch_id = &created.id }).run(&alice);
    };
    try std.testing.expectError(error.MergedForkKept, result);
    const failure = domain.classify(error.MergedForkKept);
    try std.testing.expectEqual(.internal, failure.kind);
    try std.testing.expect(failure.changed);

    // the merge itself committed
    try std.testing.expectEqual(1, (try (domain.ListPatches{ .repo = "alice:open", .view = .merged }).run(&alice)).count);
}

fn expectDraftRemove(comptime hash_kind: hx.xit.hash.HashKind) !void {
    const server = try Server.init(hash_kind);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    try server.addDraft(server.open, server.bob, Server.bob_author, bobs);
    try server.addEvent(server.open, Server.alice_author, alices, .{ .patch = .{ .title = "a patch", .description = "", .labels = "", .target_branch = "master" } });
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);

    try std.testing.expectEqual(.draft, try (domain.RemoveThread{ .repo = "alice:open", .kind = .patch, .thread_id = bobs_hex }).run(&bob));
    try std.testing.expectEqual(0, (try (domain.ListPatches{ .repo = "alice:open", .view = .drafts }).run(&bob)).count);
    const fork_path = try hx.fork.forkPath(arena.allocator(), server.users_dir, &server.bob, &bobs);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, fork_path, .{}));

    // a published patch is a thread
    try std.testing.expectEqual(.thread, try (domain.RemoveThread{ .repo = "alice:open", .kind = .patch, .thread_id = alices_hex }).run(&bob));
    try std.testing.expectEqual(0, (try (domain.ListPatches{ .repo = "alice:open" }).run(&bob)).count);
}

test "domain: RemoveThread removes the acting user's draft with its fork" {
    try expectDraftRemove(.sha1);
    try expectDraftRemove(.sha256);
}

test "domain: MergePatch refuses a closed, merged or never pushed patch" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    try server.commitBranch(server.open, "feature", "feature\n");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);

    const branch = try (domain.CreateThread{ .repo = "alice:open", .kind = .patch, .title = "a feature", .target_branch = "master", .source_branch = "feature" }).run(&bob);
    try (domain.SetThreadStatus{ .repo = "alice:open", .kind = .patch, .thread_id = &branch.id, .status = .closed }).run(&bob);
    try std.testing.expectError(error.PatchClosed, (domain.MergePatch{ .repo = "alice:open", .patch_id = &branch.id }).run(&bob));
    try (domain.SetThreadStatus{ .repo = "alice:open", .kind = .patch, .thread_id = &branch.id, .status = .open }).run(&bob);
    try (domain.MergePatch{ .repo = "alice:open", .patch_id = &branch.id }).run(&bob);
    try std.testing.expectError(error.PatchAlreadyMerged, (domain.MergePatch{ .repo = "alice:open", .patch_id = &branch.id }).run(&bob));

    // a draft published before any push has no revision to merge
    const draft = try (domain.CreateThread{ .repo = "alice:open", .kind = .patch, .title = "unpushed", .target_branch = "master" }).run(&bob);
    try (domain.PublishPatch{ .repo = "alice:open", .patch_id = &draft.id }).run(&bob);
    try std.testing.expectError(error.PatchNotPushed, (domain.MergePatch{ .repo = "alice:open", .patch_id = &draft.id }).run(&bob));
    try std.testing.expectEqual(1, (try (domain.ListPatches{ .repo = "alice:open" }).run(&bob)).count);
}

const Backing = enum { branch, fork };

fn expectMergeMoves(backing: Backing, mode: domain.MergePatch.Mode) !void {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    try server.commitBranch(server.open, "feature", "feature\n");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);

    const created = switch (backing) {
        .branch => try (domain.CreateThread{ .repo = "alice:open", .kind = .patch, .title = "a feature", .target_branch = "master", .source_branch = "feature" }).run(&bob),
        .fork => blk: {
            const draft = try (domain.CreateThread{ .repo = "alice:open", .kind = .patch, .title = "a feature", .target_branch = "master" }).run(&bob);
            try server.pushDraft(server.bob, Server.bob_author, try evt.parseEventId(&draft.id), "feature");
            try (domain.PublishPatch{ .repo = "alice:open", .patch_id = &draft.id }).run(&bob);
            break :blk draft;
        },
    };
    const before = (try server.readBranch(server.open, "master")) orelse return error.TestExpectedBranch;
    const feature = (try server.readBranch(server.open, "feature")) orelse return error.TestExpectedBranch;
    try (domain.MergePatch{ .repo = "alice:open", .patch_id = &created.id, .mode = mode }).run(&bob);
    const after = (try server.readBranch(server.open, "master")) orelse return error.TestExpectedBranch;
    try std.testing.expect(!std.mem.eql(u8, before, after));
    // a source merge fast-forwards to the branch; a squash makes a commit of its own
    switch (mode) {
        .source => try std.testing.expectEqualStrings(feature, after),
        .squash => try std.testing.expect(!std.mem.eql(u8, feature, after)),
    }
    const entry = try (domain.GetPatch{ .repo = "alice:open", .id = &created.id }).run(&bob);
    try std.testing.expectEqual(mode == .squash, entry.record.event.status.merged.revision == .squash);
}

test "domain: MergePatch moves the target branch for branch and fork patches in both modes" {
    try expectMergeMoves(.branch, .source);
    try expectMergeMoves(.branch, .squash);
    try expectMergeMoves(.fork, .source);
    try expectMergeMoves(.fork, .squash);
}
