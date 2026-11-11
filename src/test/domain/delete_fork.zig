const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const Server = fixture.Server;

const bobs: fixture.Id = @splat(0xb1);
const bobs_hex = "b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1";

test "domain: DeleteFork deletes the forker's fork once its name and their password are given" {
    const server = try Server.init(.sha256);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    try server.addDraft(server.open, server.bob, Server.bob_author, bobs);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);

    try std.testing.expectError(error.WrongConfirm, (domain.DeleteFork{ .identity = "bob:open", .fork_id = bobs_hex, .confirm = "bob:opne", .password = "password" }).run(&bob));
    try std.testing.expectError(error.WrongPassword, (domain.DeleteFork{ .identity = "bob:open", .fork_id = bobs_hex, .confirm = "bob:open", .password = "wrong" }).run(&bob));
    try std.testing.expectEqual(1, (try (domain.ListPatches{ .repo = "alice:open", .view = .drafts }).run(&bob)).count);

    try (domain.DeleteFork{ .identity = "bob:open", .fork_id = bobs_hex, .confirm = "bob:open", .password = "password" }).run(&bob);
    try std.testing.expectEqual(0, (try (domain.ListPatches{ .repo = "alice:open", .view = .drafts }).run(&bob)).count);
    const fork_path = try hx.fork.forkPath(arena.allocator(), server.users_dir, &server.bob, &bobs);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, fork_path, .{}));
    // a deleted fork is gone
    try std.testing.expectError(error.NotFound, (domain.DeleteFork{ .identity = "bob:open", .fork_id = bobs_hex, .confirm = "bob:open", .password = "password" }).run(&bob));
}

test "domain: DeleteFork needs a login, the forker and a fork of theirs" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    try server.addDraft(server.open, server.bob, Server.bob_author, bobs);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for ([_]?fixture.Id{ server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.LoginRequired, (domain.DeleteFork{ .identity = "bob:open", .fork_id = bobs_hex, .confirm = "bob:open", .password = "password" }).run(&ctx));
    }
    // only the forker deletes a fork, whatever they type
    var carol = try server.ctx(&arena, server.carol);
    try std.testing.expectError(error.Forbidden, (domain.DeleteFork{ .identity = "bob:open", .fork_id = bobs_hex, .confirm = "bob:open", .password = "password" }).run(&carol));
    // carol has no fork of that id
    try std.testing.expectError(error.NotFound, (domain.DeleteFork{ .identity = "carol:open", .fork_id = bobs_hex, .confirm = "carol:open", .password = "password" }).run(&carol));
    var bob = try server.ctx(&arena, server.bob);
    for ([_][]const u8{ "22222222222222222222222222222222", "not an id" }) |id| {
        try std.testing.expectError(error.NotFound, (domain.DeleteFork{ .identity = "bob:open", .fork_id = id, .confirm = "bob:open", .password = "password" }).run(&bob));
    }
    try std.testing.expectEqual(1, (try (domain.ListPatches{ .repo = "alice:open", .view = .drafts }).run(&bob)).count);
}

test "domain: DeleteFork is server only" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);
    try std.testing.expectError(error.UnavailableHere, (domain.DeleteFork{ .identity = "x:open", .fork_id = bobs_hex, .confirm = "x:open", .password = "" }).run(&ctx));
}

test "domain: DeleteFork finds nothing when the id names a fork of another repo" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.setTabs(server.secret, .read, .read, .read);
    try server.commitReadme(server.open);
    try server.addDraft(server.open, server.bob, Server.bob_author, bobs);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);

    // the confirmation names bob's fork of secret, but the id is his fork of open
    try std.testing.expectError(error.NotFound, (domain.DeleteFork{ .identity = "bob:secret", .fork_id = bobs_hex, .confirm = "bob:secret", .password = "password" }).run(&bob));
    try std.testing.expectEqual(1, (try (domain.ListPatches{ .repo = "alice:open", .view = .drafts }).run(&bob)).count);
}

test "domain: a fork removal whose directory stays is classified as changed" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    try server.addDraft(server.open, server.bob, Server.bob_author, bobs);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);

    // a forks dir that can't lose an entry keeps the fork's directory
    const io = std.testing.io;
    const forks_dir = std.Io.Dir.path.dirname(try hx.fork.forkPath(arena.allocator(), server.users_dir, &server.bob, &bobs)).?;
    try std.Io.Dir.cwd().setFilePermissions(io, forks_dir, .fromMode(0o555), .{});
    defer std.Io.Dir.cwd().setFilePermissions(io, forks_dir, .fromMode(0o755), .{}) catch {};
    const result = blk: {
        // the expected failure logs a warning
        const log_level = std.testing.log_level;
        std.testing.log_level = .err;
        defer std.testing.log_level = log_level;
        break :blk (domain.DeleteFork{ .identity = "bob:open", .fork_id = bobs_hex, .confirm = "bob:open", .password = "password" }).run(&bob);
    };
    try std.testing.expectError(error.ForkRemovedDirKept, result);
    const failure = domain.classify(error.ForkRemovedDirKept);
    try std.testing.expectEqual(.internal, failure.kind);
    try std.testing.expect(failure.changed);
    // the fork's record is gone, so the draft is too
    try std.testing.expectEqual(0, (try (domain.ListPatches{ .repo = "alice:open", .view = .drafts }).run(&bob)).count);
}

test "domain: DeleteFork deletes a published patch's fork and leaves the patch" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    try server.addDraft(server.open, server.bob, Server.bob_author, bobs);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);
    try (domain.PublishPatch{ .repo = "alice:open", .patch_id = bobs_hex }).run(&bob);

    try (domain.DeleteFork{ .identity = "bob:open", .fork_id = bobs_hex, .confirm = "bob:open", .password = "password" }).run(&bob);
    const fork_path = try hx.fork.forkPath(arena.allocator(), server.users_dir, &server.bob, &bobs);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, fork_path, .{}));
    const entry = try (domain.GetPatch{ .repo = "alice:open", .id = bobs_hex }).run(&bob);
    try std.testing.expectEqualStrings("a draft", entry.record.event.title);
    try std.testing.expect(!entry.fork_exists);
}
