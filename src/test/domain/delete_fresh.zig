//! the deletes check the account as it is when they run, not as the context
//! saw it when it was built: a web handler builds it before reading the body.

const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const Server = fixture.Server;

// change alice's password to "rotated" through a context of its own
fn rotateAlice(server: *Server, arena: *std.heap.ArenaAllocator) !void {
    var other = try server.ctx(arena, server.alice);
    try (domain.UpdateUserSettings{ .email = "alice@example.test", .current_password = "password", .new_password = "rotated", .new_password_again = "rotated" }).run(&other);
}

test "domain: DeleteRepo checks the password the account has when it runs" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);
    try rotateAlice(server, &arena);

    try std.testing.expectError(error.WrongPassword, (domain.DeleteRepo{ .repo = "alice:open", .confirm = "alice:open", .password = "password" }).run(&alice));
    try std.testing.expect(try domain.resolveRepo(&alice, "alice:open") != null);
    try (domain.DeleteRepo{ .repo = "alice:open", .confirm = "alice:open", .password = "rotated" }).run(&alice);
    try std.testing.expectEqual(null, try domain.resolveRepo(&alice, "alice:open"));
}

test "domain: DeleteUser checks the password the account has when it runs" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);
    try rotateAlice(server, &arena);

    try std.testing.expectError(error.WrongPassword, (domain.DeleteUser{ .confirm = "alice", .password = "password" }).run(&alice));
    try std.testing.expect(try server.account(server.alice) != null);
    try (domain.DeleteUser{ .confirm = "alice", .password = "rotated" }).run(&alice);
    try std.testing.expectEqual(null, try server.account(server.alice));
}

const alices_draft: fixture.Id = @splat(0xa7);
const alices_draft_hex = "a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7";

test "domain: DeleteFork checks the password the account has when it runs" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    try server.addDraft(server.open, server.alice, Server.alice_author, alices_draft);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);
    try rotateAlice(server, &arena);

    try std.testing.expectError(error.WrongPassword, (domain.DeleteFork{ .identity = "alice:open", .fork_id = alices_draft_hex, .confirm = "alice:open", .password = "password" }).run(&alice));
    try std.testing.expectEqual(1, (try (domain.ListPatches{ .repo = "alice:open", .view = .drafts }).run(&alice)).count);
    try (domain.DeleteFork{ .identity = "alice:open", .fork_id = alices_draft_hex, .confirm = "alice:open", .password = "rotated" }).run(&alice);
    try std.testing.expectEqual(0, (try (domain.ListPatches{ .repo = "alice:open", .view = .drafts }).run(&alice)).count);
}

test "domain: the deletes log out an account removed after the context was built" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    try server.addDraft(server.open, server.bob, Server.bob_author, alices_draft);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);
    _ = try (domain.CreateRepo{ .name = "mine" }).run(&bob);
    var removed = try server.ctx(&arena, server.bob);
    try (domain.DeleteUser{ .confirm = "bob", .password = "password" }).run(&removed);

    try std.testing.expectError(error.LoginRequired, (domain.DeleteRepo{ .repo = "bob:mine", .confirm = "bob:mine", .password = "password" }).run(&bob));
    try std.testing.expectError(error.LoginRequired, (domain.DeleteFork{ .identity = "bob:open", .fork_id = alices_draft_hex, .confirm = "bob:open", .password = "password" }).run(&bob));
    try std.testing.expectError(error.LoginRequired, (domain.DeleteUser{ .confirm = "bob", .password = "password" }).run(&bob));
}

test "domain: a repo deletion whose directory stays is classified as changed" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);
    const io = std.testing.io;
    // a repos dir that can't lose an entry keeps the repo's directory
    const repos_dir = std.Io.Dir.path.dirname(try server.repoPath(server.open)).?;
    try std.Io.Dir.cwd().setFilePermissions(io, repos_dir, .fromMode(0o555), .{});
    defer std.Io.Dir.cwd().setFilePermissions(io, repos_dir, .fromMode(0o755), .{}) catch {};
    const result = blk: {
        const log_level = std.testing.log_level;
        std.testing.log_level = .err;
        defer std.testing.log_level = log_level;
        break :blk (domain.DeleteRepo{ .repo = "alice:open", .confirm = "alice:open", .password = "password" }).run(&alice);
    };
    try std.testing.expectError(error.RepoRemovedDirKept, result);
    const failure = domain.classify(error.RepoRemovedDirKept);
    try std.testing.expectEqual(.internal, failure.kind);
    try std.testing.expect(failure.changed);
    // the record is gone, so the repo is
    try std.testing.expectEqual(null, try domain.resolveRepo(&alice, "alice:open"));
}

test "domain: an account deletion whose directory stays is classified as changed" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var carol = try server.ctx(&arena, server.carol);
    const io = std.testing.io;
    // a users dir that can't lose an entry keeps the account's directory
    try std.Io.Dir.cwd().setFilePermissions(io, server.users_dir, .fromMode(0o555), .{});
    defer std.Io.Dir.cwd().setFilePermissions(io, server.users_dir, .fromMode(0o755), .{}) catch {};
    const result = blk: {
        const log_level = std.testing.log_level;
        std.testing.log_level = .err;
        defer std.testing.log_level = log_level;
        break :blk (domain.DeleteUser{ .confirm = "carol", .password = "password" }).run(&carol);
    };
    try std.testing.expectError(error.UserRemovedDirKept, result);
    const failure = domain.classify(error.UserRemovedDirKept);
    try std.testing.expectEqual(.internal, failure.kind);
    try std.testing.expect(failure.changed);
    // the account is gone
    try std.testing.expectEqual(null, try server.account(server.carol));
}
