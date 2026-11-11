const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const Server = fixture.Server;

const revision: fixture.Id = @splat(0x33);
const revision_hex = "33333333333333333333333333333333";

fn expectServerDiff(comptime hash_kind: hx.xit.hash.HashKind) !void {
    const server = try Server.init(hash_kind);
    defer server.deinit();
    try server.commitReadme(server.open);
    const initial = (try server.readBranch(server.open, "master")).?;
    try server.commitBranch(server.open, "master", "one\n");
    const one = (try server.readBranch(server.open, "master")).?;
    try server.commitBranch(server.open, "master", "two\n");
    const two = (try server.readBranch(server.open, "master")).?;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.carol);

    // against its first parent
    {
        const diff = try (domain.Diff{ .repo = "alice:open", .oid = two }).run(&ctx);
        try std.testing.expectEqual(1, diff.window.hunks.len);
        try std.testing.expectEqualStrings("README", diff.window.hunks[0].path.?);
        // the files end in a newline, so an empty last line follows as context
        try std.testing.expectEqualStrings("1 -one\n1 +two\n2  ", diff.window.hunks[0].text);
        try std.testing.expectEqualStrings("-+ ", diff.window.hunks[0].prefixes);
        try std.testing.expectEqualStrings(one, diff.route.repo.base_oid);
        try std.testing.expect(!diff.window.has_more);
    }
    // against a base of the caller's
    {
        const diff = try (domain.Diff{ .repo = "alice:open", .oid = two, .base = initial }).run(&ctx);
        try std.testing.expectEqualStrings("1 -repo\n1 +two\n2  ", diff.window.hunks[0].text);
    }
    // a root commit adds what it holds
    {
        const diff = try (domain.Diff{ .repo = "alice:open", .oid = initial }).run(&ctx);
        try std.testing.expectEqual(1, diff.window.hunks.len);
        try std.testing.expectEqualStrings("README", diff.window.hunks[0].path.?);
        try std.testing.expectEqual(.added, diff.window.hunks[0].status);
    }
}

test "domain: history: Diff reads what a commit changed" {
    try expectServerDiff(.sha1);
    try expectServerDiff(.sha256);
}

test "domain: history: Diff narrows to a path, decoded" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.open);
    const path = "dir/50% \u{fc}ber.txt";
    try fixture.commitServerFiles(server, server.open, "master", &.{
        .{ .path = path, .contents = "a\n" },
        .{ .path = "other.txt", .contents = "b\n" },
    }, "two files");
    const tip = (try server.readBranch(server.open, "master")).?;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, null);

    const diff = try (domain.Diff{ .repo = "alice:open", .oid = tip, .path = path }).run(&ctx);
    try std.testing.expectEqualStrings(path, diff.path);
    try std.testing.expectEqual(1, diff.window.hunks.len);
    try std.testing.expectEqualStrings(path, diff.window.hunks[0].path.?);
    try std.testing.expectEqual(.added, diff.window.hunks[0].status);
    // a path the commit didn't touch, and the encoded name of one it did
    for ([_][]const u8{ "README", "nope.txt", "dir/50%25%20%C3%BCber.txt" }) |other| {
        try std.testing.expectError(error.NotFound, (domain.Diff{ .repo = "alice:open", .oid = tip, .path = other }).run(&ctx));
    }
}

test "domain: history: Diff pages across a window boundary" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.open);
    var files: [12]fixture.TreeFile = undefined;
    for (&files, 0..) |*file, i| file.* = .{ .path = try std.fmt.allocPrint(server.arena.allocator(), "f{d:0>2}.txt", .{i}), .contents = "x\n" };
    try fixture.commitServerFiles(server, server.open, "master", &files, "twelve files");
    const tip = (try server.readBranch(server.open, "master")).?;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.carol);

    const first = try (domain.Diff{ .repo = "alice:open", .oid = tip }).run(&ctx);
    try std.testing.expectEqual(10, first.window.hunks.len);
    try std.testing.expectEqualStrings("f00.txt", first.window.hunks[0].path.?);
    try std.testing.expectEqualStrings("f09.txt", first.window.hunks[9].path.?);
    try std.testing.expect(first.window.has_more);

    const second = try (domain.Diff{ .repo = "alice:open", .oid = tip, .start = 10 }).run(&ctx);
    try std.testing.expectEqual(10, second.window.start);
    try std.testing.expectEqual(2, second.window.hunks.len);
    try std.testing.expectEqualStrings("f10.txt", second.window.hunks[0].path.?);
    try std.testing.expectEqualStrings("f11.txt", second.window.hunks[1].path.?);
    try std.testing.expect(!second.window.has_more);

    // past the last hunk
    try std.testing.expectError(error.NotFound, (domain.Diff{ .repo = "alice:open", .oid = tip, .start = 12 }).run(&ctx));
}

test "domain: history: Diff reads a patch revision" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.open);
    try server.commitBranch(server.open, "feature", "feature\n");
    try fixture.addServerRevision(server, server.open, Server.alice_author, revision, "feature");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.carol);

    const diff = try (domain.Diff{ .repo = "alice:open", .patchrev = revision_hex }).run(&ctx);
    try std.testing.expectEqual(1, diff.window.hunks.len);
    try std.testing.expectEqualStrings("1 -repo\n1 +feature\n2  ", diff.window.hunks[0].text);
    try std.testing.expectEqualStrings(revision_hex, diff.route.patchrev.id);
}

test "domain: history: Diff finds no commit or revision that doesn't exist" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.open);
    const initial = (try server.readBranch(server.open, "master")).?;
    try server.commitBranch(server.open, "feature", "feature\n");
    try fixture.addServerRevision(server, server.open, Server.alice_author, revision, "feature");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.alice);

    const missing = [_]domain.Diff{
        .{ .repo = "alice:open", .oid = "abc" },
        .{ .repo = "alice:open", .oid = "0123456789012345678901234567890123456789" },
        .{ .repo = "alice:open", .oid = initial, .base = "0123456789012345678901234567890123456789" },
        .{ .repo = "alice:open", .oid = initial, .base = "abc" },
        .{ .repo = "alice:open", .patchrev = "44444444444444444444444444444444" },
        .{ .repo = "alice:open", .patchrev = "xyz" },
    };
    for (missing) |op| try std.testing.expectError(error.NotFound, op.run(&ctx));

    // inputs that can't go together
    var long_path: [1025]u8 = undefined;
    @memset(&long_path, 'a');
    const invalid = [_]domain.Diff{
        // nothing named, or both
        .{ .repo = "alice:open" },
        .{ .repo = "alice:open", .oid = initial, .patchrev = revision_hex },
        // a revision's base is its own
        .{ .repo = "alice:open", .patchrev = revision_hex, .base = initial },
        // longer than a diff's path can be
        .{ .repo = "alice:open", .oid = initial, .path = &long_path },
    };
    for (invalid) |op| try std.testing.expectError(error.InvalidReadArguments, op.run(&ctx));
}

test "domain: history: Diff pages one file's hunks across windows" {
    var local = try fixture.Local(.xit, .sha1).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    // 15 changes 20 lines apart, too far apart to share a hunk
    var before: std.Io.Writer.Allocating = .init(aa);
    var after: std.Io.Writer.Allocating = .init(aa);
    for (0..300) |i| {
        try before.writer.print("line {d}\n", .{i});
        if (i % 20 == 0) try after.writer.print("changed {d}\n", .{i}) else try after.writer.print("line {d}\n", .{i});
    }
    try fixture.commitLocalFiles(.xit, &local, "master", &.{.{ .path = "long.txt", .contents = before.written() }}, "long");
    try fixture.commitLocalFiles(.xit, &local, "master", &.{.{ .path = "long.txt", .contents = after.written() }}, "fifteen changes");
    const tip = try fixture.localBranchOid(.xit, &local, aa, "master");
    var ctx = local.ctx(&arena);

    const first = try (domain.Diff{ .repo = "", .oid = tip }).run(&ctx);
    try std.testing.expectEqual(10, first.window.hunks.len);
    try std.testing.expect(first.window.has_more);
    // the file's first hunk carries its path, the rest of the window continues it
    try std.testing.expectEqualStrings("long.txt", first.window.hunks[0].path.?);
    for (first.window.hunks[1..]) |hunk| try std.testing.expectEqual(null, hunk.path);
    for (first.window.hunks, 0..) |hunk, i| try expectChange(aa, hunk, i * 20);

    const second = try (domain.Diff{ .repo = "", .oid = tip, .start = first.window.start + first.window.hunks.len }).run(&ctx);
    try std.testing.expectEqual(5, second.window.hunks.len);
    try std.testing.expect(!second.window.has_more);
    // a window's first hunk names its file again, though it continues it
    try std.testing.expectEqualStrings("long.txt", second.window.hunks[0].path.?);
    for (second.window.hunks[1..]) |hunk| try std.testing.expectEqual(null, hunk.path);
    for (second.window.hunks, 10..) |hunk, i| try expectChange(aa, hunk, i * 20);
}

// a hunk that turns "line `n`" into "changed `n`"
fn expectChange(aa: std.mem.Allocator, hunk: hx.ui.Repo.Diff.Hunk, n: usize) !void {
    errdefer std.debug.print("hunk for line {d}:\n{s}\n", .{ n, hunk.text });
    try std.testing.expectEqual(.changed, hunk.status);
    try std.testing.expect(std.mem.indexOf(u8, hunk.text, try std.fmt.allocPrint(aa, " -line {d}\n", .{n})) != null);
    try std.testing.expect(std.mem.indexOf(u8, hunk.text, try std.fmt.allocPrint(aa, " +changed {d}\n", .{n})) != null);
}

test "domain: history: Diff names an added or removed file without its lines" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    try fixture.commitLocalFiles(.git, &local, "master", &.{.{ .path = "old.txt", .contents = "old\n" }}, "old");
    try fixture.commitLocalFiles(.git, &local, "master", &.{.{ .path = "new.txt", .contents = "new\n" }}, "new");
    try fixture.removeLocalFiles(.git, &local, &.{"old.txt"}, "no old");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const tip = try fixture.localBranchOid(.git, &local, arena.allocator(), "master");
    var ctx = local.ctx(&arena);
    // the last two commits together, against the one that added old.txt
    const new_commit = (try (domain.GetCommit{ .repo = "", .oid = tip }).run(&ctx)).parent_oid;
    const old_commit = (try (domain.GetCommit{ .repo = "", .oid = new_commit }).run(&ctx)).parent_oid;
    const diff = try (domain.Diff{ .repo = "", .oid = tip, .base = old_commit }).run(&ctx);
    try std.testing.expectEqual(2, diff.window.hunks.len);
    for (diff.window.hunks) |hunk| {
        const path = hunk.path orelse return error.TestExpectedPath;
        if (std.mem.eql(u8, path, "new.txt"))
            try std.testing.expectEqual(.added, hunk.status)
        else if (std.mem.eql(u8, path, "old.txt"))
            try std.testing.expectEqual(.removed, hunk.status)
        else
            return error.TestUnexpectedPath;
    }
    try std.testing.expect(!std.mem.eql(u8, diff.window.hunks[0].path.?, diff.window.hunks[1].path.?));
    // only the path and status: the lines aren't carried
    for (diff.window.hunks) |hunk| {
        try std.testing.expectEqualStrings("", hunk.text);
        try std.testing.expectEqualStrings("", hunk.prefixes);
    }

    // a commit whose object can't be read fails as storage, not as missing
    try fixture.corruptGitObject(&local, tip);
    if ((domain.Diff{ .repo = "", .oid = tip }).run(&ctx)) |_| return error.TestUnexpectedSuccess else |err| {
        try std.testing.expect(err != error.NotFound);
        try std.testing.expectEqual(.internal, domain.classify(err).kind);
    }
}

test "domain: history: Diff finds no repo the viewer can't see" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.secret);
    const initial = (try server.readBranch(server.secret, "master")).?;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for ([_]?fixture.Id{ server.carol, server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.NotFound, (domain.Diff{ .repo = "alice:secret", .oid = initial }).run(&ctx));
    }
    var bob = try server.ctx(&arena, server.bob);
    const diff = try (domain.Diff{ .repo = "alice:secret", .oid = initial }).run(&bob);
    try std.testing.expectEqualStrings("README", diff.window.hunks[0].path.?);
}

fn expectLocalDiff(comptime kind: hx.xit.repo.RepoKind, comptime hash_kind: hx.xit.hash.HashKind) !void {
    var local = try fixture.Local(kind, hash_kind).init();
    defer local.deinit();
    try local.commitBranch("master", "second\n");
    try local.commitBranch("feature", "feature\n");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const tip = try fixture.localBranchOid(kind, &local, arena.allocator(), "master");
    var ctx = local.ctx(&arena);

    const diff = try (domain.Diff{ .repo = "", .oid = tip }).run(&ctx);
    try std.testing.expectEqualStrings("readme.txt", diff.window.hunks[0].path.?);
    try std.testing.expectEqualStrings("1 -hello\n1 +second\n2  ", diff.window.hunks[0].text);

    // a patch's revision, against master
    const created = try (domain.CreateThread{ .repo = "", .kind = .patch, .title = "a feature", .target_branch = "master", .source_branch = "feature" }).run(&ctx);
    const patch = try (domain.GetPatch{ .repo = "", .id = &created.id }).run(&ctx);
    const revised = try (domain.Diff{ .repo = "", .patchrev = &patch.record.event.revision.?.id }).run(&ctx);
    try std.testing.expectEqualStrings("1 -second\n1 +feature\n2  ", revised.window.hunks[0].text);
}

test "domain: history: Diff reads a local git or xit repo" {
    try expectLocalDiff(.git, .sha1);
    try expectLocalDiff(.git, .sha256);
    try expectLocalDiff(.xit, .sha1);
    try expectLocalDiff(.xit, .sha256);
}

test "domain: history: Diff runOpen reads an already open repo" {
    var local = try fixture.Local(.xit, .sha256).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);
    const resolved = (try domain.resolveRepo(&ctx, "")).?;

    var repo = try hx.xit.repo.Repo(.xit, .{ .hash = .sha256 }).open(std.testing.io, allocator, .{ .path = local.path });
    defer repo.deinit(std.testing.io, allocator);
    const diff = try (domain.Diff{ .repo = "", .oid = &local.master_oid }).runOpen(&ctx, .xit, .{ .hash = .sha256 }, &repo, resolved);
    try std.testing.expectEqualStrings("readme.txt", diff.window.hunks[0].path.?);
}
