const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const Server = fixture.Server;

test "domain: files: ListFiles lists the default branch's root, directories first" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try fixture.commitServerFiles(server, server.open, "master", &.{
        .{ .path = "b.txt", .contents = "bee\n" },
        .{ .path = "a.txt", .contents = "ay\n" },
        .{ .path = "src/main.zig", .contents = "main\n" },
    }, "first");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = try server.ctx(&arena, server.carol);
    const files = try (domain.ListFiles{ .repo = "alice:open" }).run(&ctx);
    try std.testing.expectEqual(.branch, files.ref_or_oid);
    try std.testing.expectEqualStrings("master", files.ref_or_oid_value);
    try std.testing.expectEqualStrings("", files.dir);
    try std.testing.expectEqual(3, files.entries.len);
    try std.testing.expectEqualStrings("src", files.entries[0].name);
    try std.testing.expect(files.entries[0].is_dir);
    try std.testing.expectEqualStrings("a.txt", files.entries[1].name);
    try std.testing.expect(!files.entries[1].is_dir);
    try std.testing.expectEqualStrings("ay", files.entries[1].lines[0]);
    try std.testing.expectEqualStrings("b.txt", files.entries[2].name);
}

// a branch, a directory and a file whose names hold a literal `%`, a
// multi-byte character and a `/`, beside ones a second decoding would name
const odd_branch = "team/50%41-é";
const odd_dir = "50%41 café/sub";

fn commitOddFiles(server: *Server) !void {
    try fixture.commitServerFiles(server, server.open, "master", &.{
        .{ .path = "README", .contents = "master\n" },
        .{ .path = odd_dir ++ "/odd.txt", .contents = "odd\n" },
        .{ .path = "50A café/sub/plain.txt", .contents = "plain\n" },
    }, "first");
    try fixture.commitServerFiles(server, server.open, odd_branch, &.{.{ .path = "on-odd.txt", .contents = "odd branch\n" }}, "odd");
    try fixture.commitServerFiles(server, server.open, "team/50A-é", &.{.{ .path = "on-plain.txt", .contents = "plain branch\n" }}, "plain");
}

test "domain: files: ListFiles takes decoded branches and paths" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try commitOddFiles(server);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.carol);

    {
        const files = try (domain.ListFiles{ .repo = "alice:open", .path = odd_dir }).run(&ctx);
        try std.testing.expectEqualStrings(odd_dir, files.dir);
        try std.testing.expectEqual(1, files.entries.len);
        try std.testing.expectEqualStrings("odd.txt", files.entries[0].name);
    }
    {
        const files = try (domain.ListFiles{ .repo = "alice:open", .ref_kind = .branch, .ref = odd_branch }).run(&ctx);
        // the loader keeps the ref url-encoded, as the page's links want it
        try std.testing.expectEqualStrings("team%2F50%2541-%C3%A9", files.ref_or_oid_value);
        var names: [4][]const u8 = undefined;
        for (files.entries, 0..) |entry, i| names[i] = entry.name;
        try std.testing.expectEqual(4, files.entries.len);
        try std.testing.expectEqualStrings("50%41 café", names[0]);
        try std.testing.expectEqualStrings("50A café", names[1]);
        try std.testing.expectEqualStrings("README", names[2]);
        try std.testing.expectEqualStrings("on-odd.txt", names[3]);
    }
}

test "domain: files: ListFiles lists a tag or a commit" {
    const server = try Server.init(.sha256);
    defer server.deinit();
    try fixture.commitServerFiles(server, server.open, "master", &.{.{ .path = "old.txt", .contents = "old\n" }}, "first");
    const old_oid = (try server.readBranch(server.open, "master")).?;
    try fixture.addServerRefs(server, server.open, .tag, &.{"v1"});
    try fixture.commitServerFiles(server, server.open, "master", &.{.{ .path = "new.txt", .contents = "new\n" }}, "second");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.carol);

    for ([_]domain.ListFiles{
        .{ .repo = "alice:open", .ref_kind = .tag, .ref = "v1" },
        .{ .repo = "alice:open", .ref_kind = .object, .ref = old_oid },
    }) |op| {
        const files = try op.run(&ctx);
        try std.testing.expectEqual(1, files.entries.len);
        try std.testing.expectEqualStrings("old.txt", files.entries[0].name);
    }
    const files = try (domain.ListFiles{ .repo = "alice:open" }).run(&ctx);
    try std.testing.expectEqual(2, files.entries.len);
}

test "domain: files: ListFiles finds no missing ref, commit or path" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try commitOddFiles(server);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.carol);

    for ([_]domain.ListFiles{
        .{ .repo = "alice:open", .ref_kind = .branch, .ref = "missing" },
        // the encoded form names no branch
        .{ .repo = "alice:open", .ref_kind = .branch, .ref = "team%2F50%2541-%C3%A9" },
        .{ .repo = "alice:open", .ref_kind = .tag, .ref = "master" },
        // well formed, but no object
        .{ .repo = "alice:open", .ref_kind = .object, .ref = "1111111111111111111111111111111111111111" },
        .{ .repo = "alice:open", .ref_kind = .object, .ref = "not an oid" },
        .{ .repo = "alice:open", .ref_kind = .object, .ref = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz" },
        .{ .repo = "alice:open", .path = "missing" },
        .{ .repo = "alice:open", .path = "50A café/missing" },
        .{ .repo = "alice:open", .ref_kind = .branch, .ref = "master", .path = "on-odd.txt" },
    }) |op| {
        try std.testing.expectError(error.NotFound, op.run(&ctx));
    }
    // a path that names a file is no directory
    try std.testing.expectError(error.NotADirectory, (domain.ListFiles{ .repo = "alice:open", .path = "README" }).run(&ctx));
    // a ref with no kind, or a kind with no ref, is incomplete
    for ([_]domain.ListFiles{
        .{ .repo = "alice:open", .ref = "master" },
        .{ .repo = "alice:open", .ref_kind = .branch, .ref = "" },
        .{ .repo = "alice:open", .ref_kind = .object },
    }) |op| {
        try std.testing.expectError(error.InvalidReadArguments, op.run(&ctx));
    }
}

test "domain: files: ListFiles shows an empty repo's default branch, and no path in it" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.carol);

    const files = try (domain.ListFiles{ .repo = "alice:open" }).run(&ctx);
    try std.testing.expect(files.no_commits);
    try std.testing.expectEqual(0, files.entries.len);
    try std.testing.expectError(error.NotFound, (domain.ListFiles{ .repo = "alice:open", .path = "src" }).run(&ctx));
}

test "domain: files: ListFiles lists a patch revision's files" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try commitOddFiles(server);
    const revision: fixture.Id = @splat(0x77);
    try fixture.addServerRevision(server, server.open, Server.alice_author, revision, odd_branch);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.carol);

    const files = try (domain.ListFiles{ .repo = "alice:open", .patchrev = "77777777777777777777777777777777" }).run(&ctx);
    try std.testing.expectEqualStrings("77777777777777777777777777777777", files.patchrev_id.?);
    try std.testing.expectEqual(4, files.entries.len);
    try std.testing.expectEqualStrings("on-odd.txt", files.entries[3].name);
    for ([_]domain.ListFiles{
        .{ .repo = "alice:open", .patchrev = "88888888888888888888888888888888" },
        .{ .repo = "alice:open", .patchrev = "not an id" },
        .{ .repo = "alice:open", .patchrev = "77777777777777777777777777777777", .path = "missing" },
    }) |op| {
        try std.testing.expectError(error.NotFound, op.run(&ctx));
    }
    // a revision replaces the ref, so it can't come with one
    for ([_]domain.ListFiles{
        .{ .repo = "alice:open", .patchrev = "77777777777777777777777777777777", .ref_kind = .branch, .ref = "master" },
        .{ .repo = "alice:open", .patchrev = "77777777777777777777777777777777", .ref = "master" },
    }) |op| {
        try std.testing.expectError(error.InvalidReadArguments, op.run(&ctx));
    }
}

test "domain: files: ListFiles finds no repo the viewer can't see, and lets anyone read a public one" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.open);
    try server.commitReadme(server.secret);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for ([_]?fixture.Id{ server.carol, server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.NotFound, (domain.ListFiles{ .repo = "alice:secret" }).run(&ctx));
    }
    var ctx = try server.ctx(&arena, null);
    const files = try (domain.ListFiles{ .repo = "alice:open" }).run(&ctx);
    try std.testing.expectEqual(1, files.entries.len);
    try std.testing.expectEqualStrings("README", files.entries[0].name);
    // logged out views the page as nobody
    try std.testing.expectEqual(null, files.handle.viewer);
}

fn expectLocalFiles(comptime kind: hx.xit.repo.RepoKind, comptime hash_kind: hx.xit.hash.HashKind) !void {
    var local = try fixture.Local(kind, hash_kind).init();
    defer local.deinit();
    try fixture.commitLocalFiles(kind, &local, odd_branch, &.{.{ .path = odd_dir ++ "/odd.txt", .contents = "odd\n" }}, "odd");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    {
        const files = try (domain.ListFiles{ .repo = "" }).run(&ctx);
        try std.testing.expectEqual(1, files.entries.len);
        try std.testing.expectEqualStrings("readme.txt", files.entries[0].name);
    }
    {
        const files = try (domain.ListFiles{ .repo = "", .ref_kind = .branch, .ref = odd_branch, .path = odd_dir }).run(&ctx);
        try std.testing.expectEqual(1, files.entries.len);
        try std.testing.expectEqualStrings("odd.txt", files.entries[0].name);
    }
    {
        const files = try (domain.ListFiles{ .repo = "", .ref_kind = .object, .ref = &local.master_oid }).run(&ctx);
        try std.testing.expectEqual(1, files.entries.len);
    }
    const missing_oid: [hx.xit.hash.hexLen(hash_kind)]u8 = @splat('1');
    try std.testing.expectError(error.NotFound, (domain.ListFiles{ .repo = "", .ref_kind = .object, .ref = &missing_oid }).run(&ctx));
    try std.testing.expectError(error.NotFound, (domain.ListFiles{ .repo = "alice:open" }).run(&ctx));
}

test "domain: files: ListFiles lists a local git or xit repo" {
    try expectLocalFiles(.git, .sha1);
    try expectLocalFiles(.git, .sha256);
    try expectLocalFiles(.xit, .sha1);
    try expectLocalFiles(.xit, .sha256);
}
