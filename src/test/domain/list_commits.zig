const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const Server = fixture.Server;

fn expectServerLog(comptime hash_kind: hx.xit.hash.HashKind) !void {
    const server = try Server.init(hash_kind);
    defer server.deinit();
    try server.commitReadme(server.open);
    try server.commitBranch(server.open, "master", "second\n");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = try server.ctx(&arena, server.carol);
    const log = try (domain.ListCommits{ .repo = "alice:open" }).run(&ctx);
    try std.testing.expectEqual(.branch, log.ref_or_oid);
    try std.testing.expectEqualStrings("master", log.ref_or_oid_value);
    try std.testing.expectEqual(2, log.commits.len);
    try std.testing.expectEqualStrings("second", log.commits[0].message);
    try std.testing.expectEqualStrings("initial", log.commits[1].message);
    try std.testing.expectEqual(null, log.next_start);
}

test "domain: history: ListCommits walks the default branch, newest first" {
    try expectServerLog(.sha1);
    try expectServerLog(.sha256);
}

test "domain: history: ListCommits walks a named branch, tag or commit, names decoded" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.open);
    const initial = (try server.readBranch(server.open, "master")).?;
    const branch = "team/50%-\u{fc}ber";
    try server.commitBranch(server.open, branch, "on the branch\n");
    try server.commitBranch(server.open, "master", "on master\n");
    try fixture.addServerRefs(server, server.open, .tag, &.{"v1/50%-\u{fc}"});
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, null);

    {
        const log = try (domain.ListCommits{ .repo = "alice:open", .ref_kind = .branch, .ref = branch }).run(&ctx);
        try std.testing.expectEqual(2, log.commits.len);
        try std.testing.expectEqualStrings("on the branch", log.commits[0].message);
        try std.testing.expectEqualStrings("initial", log.commits[1].message);
    }
    {
        // an annotated tag at master, peeled to its commit
        const log = try (domain.ListCommits{ .repo = "alice:open", .ref_kind = .tag, .ref = "v1/50%-\u{fc}" }).run(&ctx);
        try std.testing.expectEqual(2, log.commits.len);
        try std.testing.expectEqualStrings("on master", log.commits[0].message);
    }
    {
        const log = try (domain.ListCommits{ .repo = "alice:open", .ref_kind = .object, .ref = initial }).run(&ctx);
        try std.testing.expectEqual(1, log.commits.len);
        try std.testing.expectEqualStrings(initial, log.commits[0].oid);
        try std.testing.expectEqualStrings("initial", log.commits[0].message);
    }
}

test "domain: history: ListCommits finds no ref, commit or cursor that doesn't exist" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.open);
    try server.commitBranch(server.open, "team/x", "on the branch\n");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.alice);

    const missing = [_]domain.ListCommits{
        .{ .repo = "alice:open", .ref_kind = .branch, .ref = "nope" },
        // the encoded name of a branch that exists is another name
        .{ .repo = "alice:open", .ref_kind = .branch, .ref = "team%2Fx" },
        .{ .repo = "alice:open", .ref_kind = .tag, .ref = "team/x" },
        .{ .repo = "alice:open", .ref_kind = .object, .ref = "abc" },
        .{ .repo = "alice:open", .ref_kind = .object, .ref = "0123456789012345678901234567890123456789" },
        .{ .repo = "alice:open", .ref_kind = .object, .ref = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz" },
        .{ .repo = "alice:open", .from = "0123456789012345678901234567890123456789" },
        .{ .repo = "alice:open", .from = "abc" },
        .{ .repo = "alice:open", .base = "0123456789012345678901234567890123456789" },
        .{ .repo = "alice:open", .merge = "0123456789012345678901234567890123456789" },
    };
    for (missing) |op| try std.testing.expectError(error.NotFound, op.run(&ctx));
    // a ref with no kind names nothing to look for
    try std.testing.expectError(error.InvalidReadArguments, (domain.ListCommits{ .repo = "alice:open", .ref = "master" }).run(&ctx));
}

test "domain: history: ListCommits pages across a window boundary" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.open);
    var messages: [24][]const u8 = undefined;
    for (&messages, 1..) |*message, i| {
        message.* = try std.fmt.allocPrint(server.arena.allocator(), "c{d}\n", .{i});
        try server.commitBranch(server.open, "master", message.*);
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.carol);

    const first = try (domain.ListCommits{ .repo = "alice:open" }).run(&ctx);
    try std.testing.expectEqual(20, first.commits.len);
    try std.testing.expectEqualStrings("c24", first.commits[0].message);
    try std.testing.expectEqualStrings("c5", first.commits[19].message);
    const next = first.next_start orelse return error.TestExpectedNext;

    const second = try (domain.ListCommits{ .repo = "alice:open", .from = next }).run(&ctx);
    try std.testing.expectEqual(5, second.commits.len);
    try std.testing.expectEqualStrings("c4", second.commits[0].message);
    try std.testing.expectEqualStrings(next, second.commits[0].oid);
    try std.testing.expectEqualStrings("initial", second.commits[4].message);
    try std.testing.expectEqual(null, second.next_start);
}

test "domain: history: ListCommits stops at a base and lists what a merge brought in" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.open);
    const initial = (try server.readBranch(server.open, "master")).?;
    try server.commitBranch(server.open, "master", "one\n");
    // started from "one", so master and it part there
    // in a file of its own, so the merge is clean
    try fixture.commitServerFiles(server, server.open, "feature", &.{.{ .path = "feature.txt", .contents = "feature\n" }}, "feature");
    try server.commitBranch(server.open, "master", "two\n");
    try fixture.mergeServerBranch(server, server.open, "feature");
    const merge = (try server.readBranch(server.open, "master")).?;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.carol);

    {
        const log = try (domain.ListCommits{ .repo = "alice:open", .ref_kind = .branch, .ref = "master", .base = initial }).run(&ctx);
        try std.testing.expectEqual(3, log.commits.len);
        try std.testing.expectEqualStrings(merge, log.commits[0].oid);
        try std.testing.expectEqualStrings("two", log.commits[1].message);
        try std.testing.expectEqualStrings("one", log.commits[2].message);
    }
    {
        const log = try (domain.ListCommits{ .repo = "alice:open", .merge = merge }).run(&ctx);
        try std.testing.expectEqual(1, log.commits.len);
        try std.testing.expectEqualStrings("feature", log.commits[0].message);
    }
    // a commit with one parent merged nothing in
    try std.testing.expectError(error.NotFound, (domain.ListCommits{ .repo = "alice:open", .merge = initial }).run(&ctx));
    // a merge names its own head and base, and isn't indexed for search
    for ([_]domain.ListCommits{
        .{ .repo = "alice:open", .merge = merge, .ref_kind = .branch, .ref = "master" },
        .{ .repo = "alice:open", .merge = merge, .base = initial },
        .{ .repo = "alice:open", .merge = merge, .search = "feature" },
    }) |op| try std.testing.expectError(error.InvalidReadArguments, op.run(&ctx));
}

test "domain: history: ListCommits pages through what a merge brought in" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.open);
    // 25 commits on a branch, in a file of their own so the merge is clean
    var messages: [25][]const u8 = undefined;
    for (&messages, 1..) |*message, i| {
        message.* = try std.fmt.allocPrint(server.arena.allocator(), "f{d}", .{i});
        try fixture.commitServerFiles(server, server.open, "feature", &.{.{ .path = "feature.txt", .contents = message.* }}, message.*);
    }
    try server.commitBranch(server.open, "master", "on master\n");
    try fixture.mergeServerBranch(server, server.open, "feature");
    const merge = (try server.readBranch(server.open, "master")).?;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.carol);

    // newest first, every commit once, window by window with each result's cursor
    var seen: usize = 0;
    var from: []const u8 = "";
    var windows: usize = 0;
    while (true) {
        windows += 1;
        const log = try (domain.ListCommits{ .repo = "alice:open", .merge = merge, .from = from }).run(&ctx);
        for (log.commits) |commit| {
            try std.testing.expectEqualStrings(messages[messages.len - 1 - seen], commit.message);
            seen += 1;
        }
        from = log.next_start orelse break;
    }
    try std.testing.expectEqual(25, seen);
    try std.testing.expectEqual(2, windows);
    // a cursor the merge's log doesn't hold
    try std.testing.expectError(error.NotFound, (domain.ListCommits{ .repo = "alice:open", .merge = merge, .from = "0123456789012345678901234567890123456789" }).run(&ctx));
}

test "domain: history: ListCommits and GetCommit tell a missing commit from a failed read" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    // a tree is no commit
    const tree = try fixture.localCommitTree(.git, &local, arena.allocator(), &local.master_oid);
    try std.testing.expectError(error.NotFound, (domain.GetCommit{ .repo = "", .oid = tree }).run(&ctx));
    try std.testing.expectError(error.NotFound, (domain.ListCommits{ .repo = "", .ref_kind = .object, .ref = tree }).run(&ctx));
    try std.testing.expectError(error.NotFound, (domain.ListCommits{ .repo = "", .from = tree }).run(&ctx));
    // an unknown oid
    try std.testing.expectError(error.NotFound, (domain.GetCommit{ .repo = "", .oid = "0123456789012345678901234567890123456789" }).run(&ctx));

    // a commit whose object can't be read fails as storage, not as missing
    // or as an empty log
    try fixture.corruptGitObject(&local, &local.master_oid);
    try expectFailedRead((domain.GetCommit{ .repo = "", .oid = &local.master_oid }).run(&ctx));
    try expectFailedRead((domain.ListCommits{ .repo = "" }).run(&ctx));
    try expectFailedRead((domain.ListCommits{ .repo = "", .ref_kind = .branch, .ref = "master" }).run(&ctx));
    try expectFailedRead((domain.ListCommits{ .repo = "", .ref_kind = .object, .ref = &local.master_oid }).run(&ctx));
}

// a read that failed, and not because what it names is missing
fn expectFailedRead(result: anytype) !void {
    if (result) |_| return error.TestUnexpectedSuccess else |err| {
        errdefer std.debug.print("failed with {s}\n", .{@errorName(err)});
        try std.testing.expect(err != error.NotFound);
        try std.testing.expectEqual(.internal, domain.classify(err).kind);
    }
}

test "domain: history: ListCommits searches an indexed branch, the text decoded" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.open);
    try server.commitBranch(server.open, "master", "Apple\n");
    const apple = (try server.readBranch(server.open, "master")).?;
    try server.commitBranch(server.open, "master", "41pple\n");
    try server.commitBranch(server.open, "master", "\u{fc}ber\n");
    try fixture.indexServerCommits(server, server.open);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.carol);

    {
        // a literal %, which a url would decode to "Apple"
        const log = try (domain.ListCommits{ .repo = "alice:open", .ref_kind = .branch, .ref = "master", .search = "%41pple" }).run(&ctx);
        try std.testing.expectEqual(1, log.commits.len);
        try std.testing.expectEqualStrings("41pple", log.commits[0].message);
        try std.testing.expectEqualStrings("%41pple", log.search.?);
        // a cursor at a commit the search doesn't find
        try std.testing.expectError(error.NotFound, (domain.ListCommits{ .repo = "alice:open", .ref_kind = .branch, .ref = "master", .search = "%41pple", .from = apple }).run(&ctx));
    }
    {
        const log = try (domain.ListCommits{ .repo = "alice:open", .ref_kind = .branch, .ref = "master", .search = "\u{fc}ber" }).run(&ctx);
        try std.testing.expectEqual(1, log.commits.len);
        try std.testing.expectEqualStrings("\u{fc}ber", log.commits[0].message);
    }
}

test "domain: history: ListCommits finds no repo the viewer can't see" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.secret);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for ([_]?fixture.Id{ server.carol, server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.NotFound, (domain.ListCommits{ .repo = "alice:secret" }).run(&ctx));
    }
    var bob = try server.ctx(&arena, server.bob);
    const log = try (domain.ListCommits{ .repo = "alice:secret" }).run(&bob);
    try std.testing.expectEqualStrings("initial", log.commits[0].message);
    for ([_][]const u8{ "alice:missing", "alice", "" }) |identity| {
        try std.testing.expectError(error.NotFound, (domain.ListCommits{ .repo = identity }).run(&bob));
    }
}

fn expectLocalLog(comptime kind: hx.xit.repo.RepoKind, comptime hash_kind: hx.xit.hash.HashKind) !void {
    var local = try fixture.Local(kind, hash_kind).init();
    defer local.deinit();
    try local.commitBranch("master", "second\n");
    try local.commitBranch("team/x", "on the branch\n");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    const log = try (domain.ListCommits{ .repo = "" }).run(&ctx);
    try std.testing.expectEqual(2, log.commits.len);
    try std.testing.expectEqualStrings("second", log.commits[0].message);
    try std.testing.expectEqualStrings("first", log.commits[1].message);
    try std.testing.expectEqualStrings(&local.master_oid, log.commits[1].oid);
    const branch = try (domain.ListCommits{ .repo = "", .ref_kind = .branch, .ref = "team/x" }).run(&ctx);
    try std.testing.expectEqualStrings("on the branch", branch.commits[0].message);
    // local mode names its one repo with ""
    try std.testing.expectError(error.NotFound, (domain.ListCommits{ .repo = "alice:open" }).run(&ctx));
}

test "domain: history: ListCommits reads a local git or xit repo" {
    try expectLocalLog(.git, .sha1);
    try expectLocalLog(.git, .sha256);
    try expectLocalLog(.xit, .sha1);
    try expectLocalLog(.xit, .sha256);
}

test "domain: history: ListCommits runOpen reads an already open repo" {
    var local = try fixture.Local(.xit, .sha1).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);
    const resolved = (try domain.resolveRepo(&ctx, "")).?;

    var repo = try hx.xit.repo.Repo(.xit, .{}).open(std.testing.io, allocator, .{ .path = local.path });
    defer repo.deinit(std.testing.io, allocator);
    const log = try (domain.ListCommits{ .repo = "" }).runOpen(&ctx, .xit, .{}, &repo, resolved);
    try std.testing.expectEqualStrings("first", log.commits[0].message);
}
