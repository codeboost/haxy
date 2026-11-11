const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const Server = fixture.Server;

test "domain: files: GetRepo reads a repo's header and settings as a reader sees them" {
    const server = try Server.init(.sha256);
    defer server.deinit();
    try evt.updateRepo(std.testing.io, allocator, server.users_dir, &server.alice, Server.alice_author, "open", "open", "a 100% café", .public, .write, .read, null);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = try server.ctx(&arena, server.carol);
    const repo = try (domain.GetRepo{ .repo = "alice:open" }).run(&ctx);
    try std.testing.expectEqualStrings("open", repo.name);
    try std.testing.expectEqualStrings("alice", repo.owner_name);
    try std.testing.expectEqualStrings("a 100% café", repo.description);
    try std.testing.expectEqual(.public, repo.access);
    try std.testing.expectEqual(.write, repo.discuss_role.?);
    try std.testing.expectEqual(.read, repo.issue_role.?);
    try std.testing.expectEqual(null, repo.patch_role);
    try std.testing.expectEqualStrings("master", repo.default_branch.?);
    try std.testing.expectEqual(.sha256, repo.hash_kind);
    try std.testing.expectEqual(.read, repo.role.?);
}

test "domain: files: GetRepo gives each viewer their role, and logged out none" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for ([_]?fixture.Id{ server.alice, server.bob, server.carol, null }, [_]?evt.Repo.Role{ .owner, .write, .read, null }) |user, role| {
        var ctx = try server.ctx(&arena, user);
        const repo = try (domain.GetRepo{ .repo = "alice:open" }).run(&ctx);
        try std.testing.expectEqual(role, repo.role);
        try std.testing.expectEqual(.sha1, repo.hash_kind);
        // a repo with no commit yet still names the branch HEAD will be
        try std.testing.expectEqualStrings("master", repo.default_branch.?);
    }
    // a private repo shows its access to a member
    var ctx = try server.ctx(&arena, server.bob);
    const repo = try (domain.GetRepo{ .repo = "alice:secret" }).run(&ctx);
    try std.testing.expectEqualStrings("secret", repo.name);
    try std.testing.expectEqual(.private, repo.access);
    try std.testing.expectEqual(.write, repo.role.?);
}

test "domain: files: GetRepo finds no repo the viewer can't see" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for ([_]?fixture.Id{ server.carol, server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.NotFound, (domain.GetRepo{ .repo = "alice:secret" }).run(&ctx));
    }
    var ctx = try server.ctx(&arena, server.alice);
    for ([_][]const u8{ "alice:missing", "alice", "", "bob:open" }) |identity| {
        try std.testing.expectError(error.NotFound, (domain.GetRepo{ .repo = identity }).run(&ctx));
    }
}

fn expectLocalRepo(comptime kind: hx.xit.repo.RepoKind, comptime hash_kind: hx.xit.hash.HashKind) !void {
    var local = try fixture.Local(kind, hash_kind).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = local.ctx(&arena);
    const repo = try (domain.GetRepo{ .repo = "" }).run(&ctx);
    try std.testing.expectEqualStrings(std.Io.Dir.path.basename(local.path), repo.name);
    try std.testing.expectEqualStrings("", repo.owner_name);
    try std.testing.expectEqualStrings("master", repo.default_branch.?);
    try std.testing.expectEqual(hash_kind, repo.hash_kind);
    // local mode owns its repo and shows every tab
    try std.testing.expectEqual(.owner, repo.role.?);
    try std.testing.expectEqual(.read, repo.issue_role.?);
    try std.testing.expectError(error.NotFound, (domain.GetRepo{ .repo = "alice:open" }).run(&ctx));
}

test "domain: files: GetRepo reads a local git or xit repo" {
    try expectLocalRepo(.git, .sha1);
    try expectLocalRepo(.git, .sha256);
    try expectLocalRepo(.xit, .sha1);
    try expectLocalRepo(.xit, .sha256);
}

test "domain: files: GetRepo reports a head it can't read rather than no default branch" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    try fixture.corruptGitHead(&local);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    if ((domain.GetRepo{ .repo = "" }).run(&ctx)) |_| return error.TestExpectedError else |err| {
        try std.testing.expectEqual(.internal, domain.classify(err).kind);
    }
}
