const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const Server = fixture.Server;

test "domain: DeleteUser deletes the acting user once their name and password are given" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);
    const repo_path = try server.repoPath(server.open);

    try (domain.DeleteUser{ .confirm = "alice", .password = "password" }).run(&alice);
    try std.testing.expectEqual(null, try server.account(server.alice));
    try std.testing.expect(!try server.logsIn("alice", "password"));
    // a context built for the deleted account has no user
    const after = try server.ctx(&arena, server.alice);
    try std.testing.expectEqual(null, after.user_id);
    // their repos went with them
    var bob = try server.ctx(&arena, server.bob);
    try std.testing.expectEqual(null, try domain.resolveRepo(&bob, "alice:open"));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, repo_path, .{}));
    // nobody else went
    try std.testing.expect(try server.account(server.bob) != null);
}

test "domain: DeleteUser checks the typed name before the password and deletes nothing on either" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);

    try std.testing.expectError(error.WrongConfirm, (domain.DeleteUser{ .confirm = "alcie", .password = "wrong" }).run(&alice));
    // another user's name confirms nothing
    try std.testing.expectError(error.WrongConfirm, (domain.DeleteUser{ .confirm = "bob", .password = "password" }).run(&alice));
    try std.testing.expectError(error.WrongPassword, (domain.DeleteUser{ .confirm = "alice", .password = "wrong" }).run(&alice));
    try std.testing.expectError(error.WrongPassword, (domain.DeleteUser{ .confirm = "alice", .password = "" }).run(&alice));
    try std.testing.expect(try server.account(server.alice) != null);
    try std.testing.expect(try domain.resolveRepo(&alice, "alice:open") != null);
}

test "domain: DeleteUser needs a login and a server" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for ([_]?fixture.Id{ server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.LoginRequired, (domain.DeleteUser{ .confirm = "dave", .password = "password" }).run(&ctx));
        try std.testing.expectError(error.LoginRequired, domain.DeleteUser.deleteAsOperator(&ctx));
    }

    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var ctx = local.ctx(&arena);
    try std.testing.expectError(error.UnavailableHere, (domain.DeleteUser{ .confirm = "", .password = "" }).run(&ctx));
    try std.testing.expectError(error.UnavailableHere, domain.DeleteUser.deleteAsOperator(&ctx));
}

test "domain: DeleteUser's operator entry deletes without a confirmation or password" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);

    try domain.DeleteUser.deleteAsOperator(&bob);
    try std.testing.expectEqual(null, try server.account(server.bob));
    try std.testing.expect(try server.account(server.alice) != null);
    // alice's repos keep going without their member
    var alice = try server.ctx(&arena, server.alice);
    try std.testing.expect(try domain.resolveRepo(&alice, "alice:open") != null);
}
