//! the reads' runOpen, called on a repo the caller opened once, as page
//! composition will

const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const rp = hx.xit.repo;
const fixture = @import("fixture.zig");

const io = std.testing.io;
const allocator = std.testing.allocator;
const Server = fixture.Server;

const issue_id: fixture.Id = @splat(0x11);
const issue_hex = "11111111111111111111111111111111";
const discussion_id: fixture.Id = @splat(0x22);
const discussion_hex = "22222222222222222222222222222222";

test "domain: lists: every read runs on a server repo opened once" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    try server.commitBranch(server.open, "feature", "feature\n");
    try server.addEvent(server.open, Server.alice_author, issue_id, .{ .issue = .{ .title = "an issue", .description = "", .labels = "" } });
    try server.addEvent(server.open, Server.alice_author, discussion_id, .{ .discuss = .{ .title = "a talk", .description = "", .labels = "" } });
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.bob);
    const patch = try (domain.CreateThread{ .repo = "alice:open", .kind = .patch, .title = "a feature", .target_branch = "master", .source_branch = "feature" }).run(&ctx);

    const resolved = (try domain.resolveRepo(&ctx, "alice:open")) orelse return error.TestExpectedRepo;
    var any_repo = try rp.AnyRepo(.xit, .{}).open(io, allocator, resolved.source.localInitOpts());
    defer any_repo.deinit(io, allocator);
    switch (any_repo) {
        inline else => |*repo| {
            const opts = repo.self_repo_opts;
            {
                const window = try (domain.ListIssues{ .repo = "alice:open" }).runOpen(&ctx, .xit, opts, repo, resolved);
                try std.testing.expectEqual(1, window.count);
                try std.testing.expectEqualStrings(issue_hex, window.items[0].id);
                // the notify buttons are set as by run
                try std.testing.expect(window.items[0].notify_action != null);
            }
            {
                const entry = try (domain.GetIssue{ .repo = "alice:open", .id = issue_hex }).runOpen(&ctx, .xit, opts, repo, resolved);
                try std.testing.expectEqualStrings("an issue", entry.record.event.title);
            }
            {
                const window = try (domain.ListDiscussions{ .repo = "alice:open" }).runOpen(&ctx, .xit, opts, repo, resolved);
                try std.testing.expectEqual(1, window.count);
                try std.testing.expectEqualStrings(discussion_hex, window.items[0].id);
            }
            {
                const entry = try (domain.GetDiscussion{ .repo = "alice:open", .id = discussion_hex }).runOpen(&ctx, .xit, opts, repo, resolved);
                try std.testing.expectEqualStrings("a talk", entry.record.event.title);
            }
            {
                const window = try (domain.ListPatches{ .repo = "alice:open" }).runOpen(&ctx, .xit, opts, repo, resolved);
                try std.testing.expectEqual(1, window.count);
                try std.testing.expectEqualStrings(&patch.id, window.items[0].id);
            }
            {
                const entry = try (domain.GetPatch{ .repo = "alice:open", .id = &patch.id }).runOpen(&ctx, .xit, opts, repo, resolved);
                try std.testing.expectEqualStrings("a feature", entry.record.event.title);
            }
            {
                // newest first: the patch with the branch revision it
                // captured, in one write, then the discussion and the issue
                const window = try (domain.ListEvents{ .repo = "alice:open" }).runOpen(&ctx, .xit, opts, repo, resolved);
                try std.testing.expectEqual(4, window.count);
                const patch_first = window.events[0].kind == .patch;
                try std.testing.expectEqualStrings(&patch.id, window.events[if (patch_first) 0 else 1].id);
                try std.testing.expectEqual(.patchrev, window.events[if (patch_first) 1 else 0].kind);
                try std.testing.expectEqualStrings(discussion_hex, window.events[2].id);
                try std.testing.expectEqualStrings(issue_hex, window.events[3].id);
            }
            // a missing id is still not found
            try std.testing.expectError(error.NotFound, (domain.GetIssue{ .repo = "alice:open", .id = discussion_hex }).runOpen(&ctx, .xit, opts, repo, resolved));
        },
    }
}

test "domain: lists: runOpen checks the tab and the role itself" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addEvent(server.open, Server.alice_author, issue_id, .{ .issue = .{ .title = "an issue", .description = "", .labels = "" } });
    try server.addEvent(server.open, Server.alice_author, discussion_id, .{ .discuss = .{ .title = "a talk", .description = "", .labels = "" } });
    // the discussion tab off; the patch tab is off already
    try server.setTabs(server.open, null, .read, null);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    // a reader of the public repo
    var ctx = try server.ctx(&arena, server.carol);

    const resolved = (try domain.resolveRepo(&ctx, "alice:open")) orelse return error.TestExpectedRepo;
    var any_repo = try rp.AnyRepo(.xit, .{}).open(io, allocator, resolved.source.localInitOpts());
    defer any_repo.deinit(io, allocator);
    switch (any_repo) {
        inline else => |*repo| {
            const opts = repo.self_repo_opts;
            // the issue tab is on, so its reads answer
            _ = try (domain.ListIssues{ .repo = "alice:open" }).runOpen(&ctx, .xit, opts, repo, resolved);
            try std.testing.expectError(error.NotFound, (domain.ListDiscussions{ .repo = "alice:open" }).runOpen(&ctx, .xit, opts, repo, resolved));
            try std.testing.expectError(error.NotFound, (domain.GetDiscussion{ .repo = "alice:open", .id = discussion_hex }).runOpen(&ctx, .xit, opts, repo, resolved));
            try std.testing.expectError(error.NotFound, (domain.ListPatches{ .repo = "alice:open" }).runOpen(&ctx, .xit, opts, repo, resolved));
            try std.testing.expectError(error.NotFound, (domain.GetPatch{ .repo = "alice:open", .id = issue_hex }).runOpen(&ctx, .xit, opts, repo, resolved));
            // the history needs write access
            try std.testing.expectError(error.NotFound, (domain.ListEvents{ .repo = "alice:open" }).runOpen(&ctx, .xit, opts, repo, resolved));
        },
    }
}

fn expectLocalRunOpen(comptime kind: rp.RepoKind, comptime hash_kind: hx.xit.hash.HashKind) !void {
    var local = try fixture.Local(kind, hash_kind).init();
    defer local.deinit();
    try local.addEvent(Server.alice_author, issue_id, .{ .issue = .{ .title = "an issue", .description = "", .labels = "" } });
    try local.addEvent(Server.alice_author, discussion_id, .{ .discuss = .{ .title = "a talk", .description = "", .labels = "" } });
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    const resolved = (try domain.resolveRepo(&ctx, "")) orelse return error.TestExpectedRepo;
    const Local = fixture.Local(kind, hash_kind);
    var repo = try rp.Repo(kind, Local.repo_opts).open(io, allocator, resolved.source.localInitOpts());
    defer repo.deinit(io, allocator);

    const issues = try (domain.ListIssues{ .repo = "" }).runOpen(&ctx, kind, Local.repo_opts, &repo, resolved);
    try std.testing.expectEqualStrings(issue_hex, issues.items[0].id);
    const entry = try (domain.GetIssue{ .repo = "", .id = issue_hex }).runOpen(&ctx, kind, Local.repo_opts, &repo, resolved);
    try std.testing.expectEqualStrings("an issue", entry.record.event.title);
    const discussions = try (domain.ListDiscussions{ .repo = "" }).runOpen(&ctx, kind, Local.repo_opts, &repo, resolved);
    try std.testing.expectEqualStrings(discussion_hex, discussions.items[0].id);
    const talk = try (domain.GetDiscussion{ .repo = "", .id = discussion_hex }).runOpen(&ctx, kind, Local.repo_opts, &repo, resolved);
    try std.testing.expectEqualStrings("a talk", talk.record.event.title);
    const patches = try (domain.ListPatches{ .repo = "" }).runOpen(&ctx, kind, Local.repo_opts, &repo, resolved);
    try std.testing.expectEqual(0, patches.count);
    try std.testing.expectError(error.NotFound, (domain.GetPatch{ .repo = "", .id = issue_hex }).runOpen(&ctx, kind, Local.repo_opts, &repo, resolved));
    const events = try (domain.ListEvents{ .repo = "" }).runOpen(&ctx, kind, Local.repo_opts, &repo, resolved);
    try std.testing.expectEqual(2, events.count);
    try std.testing.expectEqualStrings(discussion_hex, events.events[0].id);
    try std.testing.expectEqualStrings(issue_hex, events.events[1].id);
}

test "domain: lists: every read runs on a local git or xit repo opened once" {
    try expectLocalRunOpen(.git, .sha1);
    try expectLocalRunOpen(.git, .sha256);
    try expectLocalRunOpen(.xit, .sha1);
    try expectLocalRunOpen(.xit, .sha256);
}

test "domain: lists: ListPatches searches with the decoded text as given" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    try server.commitBranch(server.open, "team/next", "next\n");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.bob);
    // "%41" would decode to "A", so a search for the first label must not be decoded again
    const first = try (domain.CreateThread{ .repo = "alice:open", .kind = .patch, .title = "café ouvert", .labels = "50%41off", .target_branch = "master", .source_branch = "team/next" }).run(&ctx);
    const second = try (domain.CreateThread{ .repo = "alice:open", .kind = .patch, .title = "cafe closed", .labels = "50Aoff", .target_branch = "master", .source_branch = "team/next" }).run(&ctx);

    for ([_][]const u8{ "label:50%41off", "café" }) |search| {
        const window = try (domain.ListPatches{ .repo = "alice:open", .search = search }).run(&ctx);
        try std.testing.expectEqual(1, window.count);
        try std.testing.expectEqualStrings(&first.id, window.items[0].id);
    }
    // the named patch must match the search and exist
    try std.testing.expectError(error.NotFound, (domain.ListPatches{ .repo = "alice:open", .search = "café", .from = &second.id }).run(&ctx));
    for ([_][]const u8{ "55555555555555555555555555555555", "not an id", "%" }) |from| {
        try std.testing.expectError(error.NotFound, (domain.ListPatches{ .repo = "alice:open", .from = from }).run(&ctx));
    }
    try std.testing.expectError(error.NotFound, (domain.GetPatch{ .repo = "alice:open", .id = "%" }).run(&ctx));
}

test "domain: lists: a read denies before it opens the repo" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addEvent(server.open, Server.alice_author, issue_id, .{ .issue = .{ .title = "an issue", .description = "", .labels = "" } });
    // every thread tab off, then the repo's storage gone
    try server.setTabs(server.open, null, null, null);
    try std.Io.Dir.cwd().deleteTree(io, try server.repoPath(server.open));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    {
        var ctx = try server.ctx(&arena, server.alice);
        try std.testing.expectError(error.NotFound, (domain.ListIssues{ .repo = "alice:open" }).run(&ctx));
        try std.testing.expectError(error.NotFound, (domain.GetIssue{ .repo = "alice:open", .id = issue_hex }).run(&ctx));
        try std.testing.expectError(error.NotFound, (domain.ListDiscussions{ .repo = "alice:open" }).run(&ctx));
        try std.testing.expectError(error.NotFound, (domain.GetDiscussion{ .repo = "alice:open", .id = discussion_hex }).run(&ctx));
        try std.testing.expectError(error.NotFound, (domain.ListPatches{ .repo = "alice:open" }).run(&ctx));
        try std.testing.expectError(error.NotFound, (domain.GetPatch{ .repo = "alice:open", .id = issue_hex }).run(&ctx));
    }
    // a reader of the public repo has no history to see
    var carol = try server.ctx(&arena, server.carol);
    try std.testing.expectError(error.NotFound, (domain.ListEvents{ .repo = "alice:open" }).run(&carol));
}

test "domain: lists: ListPatches lists no drafts in local mode" {
    var local = try fixture.Local(.xit, .sha1).init();
    defer local.deinit();
    try local.commitBranch("feature", "feature\n");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);
    _ = try (domain.CreateThread{ .repo = "", .kind = .patch, .title = "a feature", .target_branch = "master", .source_branch = "feature" }).run(&ctx);

    // local repos have no drafts: the window is empty, not unavailable
    const window = try (domain.ListPatches{ .repo = "", .view = .drafts }).run(&ctx);
    try std.testing.expectEqual(0, window.count);
    try std.testing.expectEqual(0, window.items.len);
    try std.testing.expectEqual(1, (try (domain.ListPatches{ .repo = "" }).run(&ctx)).count);
}

test "domain: lists: ListPatches refuses a search of the drafts, which it can't filter" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.bob);
    _ = try (domain.CreateThread{ .repo = "alice:open", .kind = .patch, .title = "a draft", .target_branch = "master" }).run(&ctx);

    try std.testing.expectEqual(1, (try (domain.ListPatches{ .repo = "alice:open", .view = .drafts }).run(&ctx)).count);
    try std.testing.expectError(error.InvalidReadArguments, (domain.ListPatches{ .repo = "alice:open", .view = .drafts, .search = "draft" }).run(&ctx));
}
