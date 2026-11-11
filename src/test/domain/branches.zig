const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const Server = fixture.Server;

// the protected branches of the repo `identity` names, as its creator sees it
fn protectedBranches(server: *Server, arena: *std.heap.ArenaAllocator, identity: []const u8) ![]const []const u8 {
    var ctx = try server.ctx(arena, server.alice);
    const resolved = (try domain.resolveRepo(&ctx, identity)) orelse return error.TestExpectedRepo;
    return try resolved.record.event.protectedBranchNames(arena.allocator());
}

test "domain: ProtectBranch protects existing branches in order" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.open);
    try server.commitBranch(server.open, "feature/one", "one\n");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);

    try (domain.ProtectBranch{ .repo = "alice:open", .branch = "master" }).run(&alice);
    try (domain.ProtectBranch{ .repo = "alice:open", .branch = "feature/one" }).run(&alice);
    const both = try protectedBranches(server, &arena, "alice:open");
    try std.testing.expectEqual(2, both.len);
    try std.testing.expectEqualStrings("master", both[0]);
    try std.testing.expectEqualStrings("feature/one", both[1]);
}

test "domain: ProtectBranch refuses a branch the repo doesn't have" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.open);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);

    for ([_][]const u8{ "missing", "", "bad..name" }) |branch| {
        try std.testing.expectError(error.UnknownBranch, (domain.ProtectBranch{ .repo = "alice:open", .branch = branch }).run(&alice));
    }
    try std.testing.expectEqual(0, (try protectedBranches(server, &arena, "alice:open")).len);
    try std.testing.expectEqual(.invalid_input, domain.classify(error.UnknownBranch).kind);
}

// 129 times "%", each url-encoded as "%25", then `tail` times "b": a ref name
// is at most 255 bytes, so its encoding reaches a route's 512 bytes only
// through bytes that encode to three
fn percents(arena: *std.heap.ArenaAllocator, tail: usize) ![]const u8 {
    var name: std.ArrayList(u8) = .empty;
    try name.appendNTimes(arena.allocator(), '%', 129);
    try name.appendNTimes(arena.allocator(), 'b', tail);
    return name.items;
}

test "domain: ProtectBranch and SetDefaultBranch take a name whose url encoding fits a route" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.open);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const long_bytes: [171]u8 = @splat('b');
    const long: []const u8 = &long_bytes;
    // 129 * 3 + 125 = 512 encoded bytes
    const fits = try percents(&arena, 125);
    const names = [_][]const u8{ long, fits, "100%", "café", "feature/one" };
    for (names) |name| try server.commitBranch(server.open, name, "branch\n");
    var alice = try server.ctx(&arena, server.alice);

    for (names) |name| try (domain.ProtectBranch{ .repo = "alice:open", .branch = name }).run(&alice);
    const protected = try protectedBranches(server, &arena, "alice:open");
    try std.testing.expectEqual(names.len, protected.len);
    for (names, protected) |name, held| try std.testing.expectEqualStrings(name, held);
    for (names) |name| {
        try (domain.SetDefaultBranch{ .repo = "alice:open", .branch = name }).run(&alice);
        try std.testing.expectEqualStrings(name, (try server.defaultBranch(server.open)).?);
    }
}

test "domain: ProtectBranch and SetDefaultBranch refuse a name whose url encoding outgrows a route" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.open);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    // 129 * 3 + 126 = 513 encoded bytes, in a 255 byte name
    const too_long = try percents(&arena, 126);
    try server.commitBranch(server.open, too_long, "branch\n");
    var alice = try server.ctx(&arena, server.alice);

    try std.testing.expectError(error.BranchNameTooLong, (domain.ProtectBranch{ .repo = "alice:open", .branch = too_long }).run(&alice));
    try std.testing.expectEqual(0, (try protectedBranches(server, &arena, "alice:open")).len);
    try std.testing.expectError(error.BranchNameTooLong, (domain.SetDefaultBranch{ .repo = "alice:open", .branch = too_long }).run(&alice));
    try std.testing.expectEqualStrings("master", (try server.defaultBranch(server.open)).?);
    try std.testing.expectEqual(.invalid_input, domain.classify(error.BranchNameTooLong).kind);
}

test "domain: ProtectBranch refuses a protected branch" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.open);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);

    try (domain.ProtectBranch{ .repo = "alice:open", .branch = "master" }).run(&alice);
    try std.testing.expectError(error.BranchProtected, (domain.ProtectBranch{ .repo = "alice:open", .branch = "master" }).run(&alice));
    try std.testing.expectEqual(1, (try protectedBranches(server, &arena, "alice:open")).len);
}

test "domain: UnprotectBranch takes a branch out, and a branch that isn't in is no failure" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.open);
    try server.commitBranch(server.open, "feature/one", "one\n");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);
    try (domain.ProtectBranch{ .repo = "alice:open", .branch = "master" }).run(&alice);
    try (domain.ProtectBranch{ .repo = "alice:open", .branch = "feature/one" }).run(&alice);

    try (domain.UnprotectBranch{ .repo = "alice:open", .branch = "master" }).run(&alice);
    const left = try protectedBranches(server, &arena, "alice:open");
    try std.testing.expectEqual(1, left.len);
    try std.testing.expectEqualStrings("feature/one", left[0]);
    // a name that isn't protected, or doesn't exist at all, changes nothing
    try (domain.UnprotectBranch{ .repo = "alice:open", .branch = "master" }).run(&alice);
    try (domain.UnprotectBranch{ .repo = "alice:open", .branch = "missing" }).run(&alice);
    try std.testing.expectEqual(1, (try protectedBranches(server, &arena, "alice:open")).len);
}

test "domain: SetDefaultBranch points HEAD at an existing branch" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.open);
    try server.commitBranch(server.open, "feature/one", "one\n");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);
    try std.testing.expectEqualStrings("master", (try server.defaultBranch(server.open)).?);

    try (domain.SetDefaultBranch{ .repo = "alice:open", .branch = "feature/one" }).run(&alice);
    try std.testing.expectEqualStrings("feature/one", (try server.defaultBranch(server.open)).?);
    // it writes no event, so nothing is protected
    try std.testing.expectEqual(0, (try protectedBranches(server, &arena, "alice:open")).len);
}

test "domain: SetDefaultBranch refuses a branch the repo doesn't have" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.open);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);

    try std.testing.expectError(error.UnknownBranch, (domain.SetDefaultBranch{ .repo = "alice:open", .branch = "missing" }).run(&alice));
    try std.testing.expectEqualStrings("master", (try server.defaultBranch(server.open)).?);
}

test "domain: ProtectBranch refuses a branch past the protected branch limit" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.open);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (0..evt.Repo.protected_branch_max_count) |i| {
        const name = try arena.allocator().print("b{d}", .{i});
        try evt.protectBranch(std.testing.io, allocator, server.users_dir, &server.alice, &server.open.repo_id, name, true, Server.alice_author);
    }
    var alice = try server.ctx(&arena, server.alice);

    try std.testing.expectError(error.TooManyProtectedBranches, (domain.ProtectBranch{ .repo = "alice:open", .branch = "master" }).run(&alice));
    try std.testing.expectEqual(evt.Repo.protected_branch_max_count, (try protectedBranches(server, &arena, "alice:open")).len);
}

// run the branch action `Op` names on `branch` in `repo`
fn act(comptime Op: type, ctx: *domain.Ctx, repo: []const u8, branch: []const u8) !void {
    try (Op{ .repo = repo, .branch = branch }).run(ctx);
}

test "domain: branch actions need the owner role" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.open);
    try server.commitReadme(server.secret);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);
    var carol = try server.ctx(&arena, server.carol);
    var dave = try server.ctx(&arena, server.dave);
    var nobody = try server.ctx(&arena, null);

    inline for (.{ domain.ProtectBranch, domain.UnprotectBranch, domain.SetDefaultBranch }) |Op| {
        try std.testing.expectError(error.Forbidden, act(Op, &bob, "alice:secret", "master"));
        try std.testing.expectError(error.Forbidden, act(Op, &carol, "alice:open", "master"));
        try std.testing.expectError(error.NotFound, act(Op, &carol, "alice:secret", "master"));
        try std.testing.expectError(error.LoginRequired, act(Op, &dave, "alice:secret", "master"));
        try std.testing.expectError(error.LoginRequired, act(Op, &nobody, "alice:secret", "master"));
    }
    try std.testing.expectEqual(0, (try protectedBranches(server, &arena, "alice:secret")).len);

    // a granted owner may
    try evt.grantRole(std.testing.io, allocator, server.users_dir, &server.alice, &server.secret.repo_id, &server.bob, .owner, Server.alice_author);
    try act(domain.ProtectBranch, &bob, "alice:secret", "master");
    try std.testing.expectEqual(1, (try protectedBranches(server, &arena, "alice:secret")).len);
}

test "domain: branch actions are server only" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);
    inline for (.{ domain.ProtectBranch, domain.UnprotectBranch, domain.SetDefaultBranch }) |Op| {
        try std.testing.expectError(error.UnavailableHere, act(Op, &ctx, "", "master"));
    }
}
