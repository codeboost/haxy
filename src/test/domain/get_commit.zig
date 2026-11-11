const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const Server = fixture.Server;

// a message longer than the log's preview of it
fn longMessage(aa: std.mem.Allocator) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(aa);
    for (1..61) |i| try out.writer.print("line {d}\n", .{i});
    return out.written();
}

fn expectServerCommit(comptime hash_kind: hx.xit.hash.HashKind) !void {
    const server = try Server.init(hash_kind);
    defer server.deinit();
    try server.commitReadme(server.open);
    const initial = (try server.readBranch(server.open, "master")).?;
    try server.commitBranch(server.open, "master", try longMessage(server.arena.allocator()));
    const tip = (try server.readBranch(server.open, "master")).?;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.carol);

    const commit = try (domain.GetCommit{ .repo = "alice:open", .oid = tip }).run(&ctx);
    try std.testing.expectEqualStrings(tip, commit.oid);
    try std.testing.expectEqualStrings(initial, commit.parent_oid);
    try std.testing.expect(!commit.message_truncated);
    try std.testing.expect(std.mem.startsWith(u8, commit.message, "line 1\nline 2\n"));
    try std.testing.expect(std.mem.endsWith(u8, commit.message, "line 59\nline 60"));
    // the log shows a preview of the same message
    const log = try (domain.ListCommits{ .repo = "alice:open" }).run(&ctx);
    try std.testing.expect(log.commits[0].message_truncated);

    const root = try (domain.GetCommit{ .repo = "alice:open", .oid = initial }).run(&ctx);
    try std.testing.expectEqualStrings("initial", root.message);
    for (root.parent_oid) |c| try std.testing.expectEqual('0', c);
}

test "domain: history: GetCommit reads one commit with its whole message" {
    try expectServerCommit(.sha1);
    try expectServerCommit(.sha256);
}

test "domain: history: GetCommit finds no commit that doesn't exist" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.open);
    const initial = (try server.readBranch(server.open, "master")).?;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.alice);

    const upper = try std.ascii.allocUpperString(arena.allocator(), initial);
    for ([_][]const u8{ "", "abc", "master", "0123456789012345678901234567890123456789", "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz", upper, initial[0..39] }) |oid| {
        try std.testing.expectError(error.NotFound, (domain.GetCommit{ .repo = "alice:open", .oid = oid }).run(&ctx));
    }
}

test "domain: history: GetCommit finds no repo the viewer can't see" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.secret);
    const initial = (try server.readBranch(server.secret, "master")).?;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for ([_]?fixture.Id{ server.carol, server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.NotFound, (domain.GetCommit{ .repo = "alice:secret", .oid = initial }).run(&ctx));
    }
    var bob = try server.ctx(&arena, server.bob);
    const commit = try (domain.GetCommit{ .repo = "alice:secret", .oid = initial }).run(&bob);
    try std.testing.expectEqualStrings("initial", commit.message);
}

fn expectLocalCommit(comptime kind: hx.xit.repo.RepoKind, comptime hash_kind: hx.xit.hash.HashKind) !void {
    var local = try fixture.Local(kind, hash_kind).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    const commit = try (domain.GetCommit{ .repo = "", .oid = &local.master_oid }).run(&ctx);
    try std.testing.expectEqualStrings("first", commit.message);
    try std.testing.expectEqualStrings(&local.master_oid, commit.oid);
}

test "domain: history: GetCommit reads a local git or xit repo" {
    try expectLocalCommit(.git, .sha1);
    try expectLocalCommit(.git, .sha256);
    try expectLocalCommit(.xit, .sha1);
    try expectLocalCommit(.xit, .sha256);
}

test "domain: history: GetCommit runOpen reads an already open repo" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);
    const resolved = (try domain.resolveRepo(&ctx, "")).?;

    var repo = try hx.xit.repo.Repo(.git, .{}).open(std.testing.io, allocator, .{ .path = local.path });
    defer repo.deinit(std.testing.io, allocator);
    const commit = try (domain.GetCommit{ .repo = "", .oid = &local.master_oid }).runOpen(&ctx, .git, .{}, &repo, resolved);
    try std.testing.expectEqualStrings("first", commit.message);
}
