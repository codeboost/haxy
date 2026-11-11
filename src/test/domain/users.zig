const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const Server = fixture.Server;

test "domain: RegisterUser creates an account that logs in" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, null);

    const created = try (domain.RegisterUser{ .name = "erin", .email = "erin@example.test", .password = "secret", .password_again = "secret" }).run(&ctx);
    try std.testing.expectEqualSlices(u8, &created.id, &((try server.accountId("erin")) orelse return error.TestExpectedUser));
    const account = (try server.account(created.id)) orelse return error.TestExpectedUser;
    try std.testing.expectEqualStrings("erin@example.test", account.event.email);
    try std.testing.expect(try server.logsIn("erin", "secret"));
}

test "domain: RegisterUser is server only" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);
    try std.testing.expectError(error.UnavailableHere, (domain.RegisterUser{ .name = "erin", .email = "erin@example.test", .password = "secret", .password_again = "secret" }).run(&ctx));
}

test "domain: RegisterUser refuses a caller who is logged in" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);

    try std.testing.expectError(error.Forbidden, (domain.RegisterUser{ .name = "erin", .email = "erin@example.test", .password = "secret", .password_again = "secret" }).run(&bob));
    try std.testing.expectEqual(null, try server.accountId("erin"));
}

test "domain: RegisterUser lets a removed account's context register" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var dave = try server.ctx(&arena, server.dave);

    _ = try (domain.RegisterUser{ .name = "erin", .email = "erin@example.test", .password = "secret", .password_again = "secret" }).run(&dave);
    try std.testing.expect(try server.logsIn("erin", "secret"));
}

test "domain: RegisterUser rejects bad names, emails and passwords and creates nothing" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, null);

    const Case = struct { err: anyerror, name: []const u8, email: []const u8 = "erin@example.test", password: []const u8 = "secret", password_again: []const u8 = "secret" };
    for ([_]Case{
        .{ .err = error.NameEmpty, .name = "" },
        .{ .err = error.NameTooShort, .name = "er" },
        .{ .err = error.NameTooLong, .name = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" },
        .{ .err = error.InvalidName, .name = "erin!" },
        .{ .err = error.InvalidName, .name = "user" },
        .{ .err = error.NameTaken, .name = "bob" },
        .{ .err = error.EmailEmpty, .name = "erin", .email = "" },
        .{ .err = error.EmailTaken, .name = "erin", .email = "bob@example.test" },
        .{ .err = error.PasswordEmpty, .name = "erin", .password = "", .password_again = "" },
        .{ .err = error.PasswordMismatch, .name = "erin", .password_again = "secrte" },
    }) |case| {
        try std.testing.expectError(case.err, (domain.RegisterUser{ .name = case.name, .email = case.email, .password = case.password, .password_again = case.password_again }).run(&ctx));
    }
    try std.testing.expectEqual(null, try server.accountId("erin"));
}

test "domain: RegisterUser registers the first account of a fresh server" {
    const server = try fixture.FreshServer.init();
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, null);

    const created = try (domain.RegisterUser{ .name = "erin", .email = "erin@example.test", .password = "secret", .password_again = "secret" }).run(&ctx);
    const erin = try server.ctx(&arena, created.id);
    try std.testing.expectEqualStrings("erin", (erin.user orelse return error.TestExpectedUser).event.name);
}

test "domain: UpdateUserSettings changes the acting user's email and password" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);

    // the password stays when its fields are empty
    try (domain.UpdateUserSettings{ .email = "alice@new.test" }).run(&alice);
    try std.testing.expectEqualStrings("alice@new.test", ((try server.account(server.alice)) orelse return error.TestExpectedUser).event.email);
    try std.testing.expect(try server.logsIn("alice", "password"));

    try (domain.UpdateUserSettings{ .email = "alice@new.test", .current_password = "password", .new_password = "changed", .new_password_again = "changed" }).run(&alice);
    try std.testing.expect(try server.logsIn("alice", "changed"));
    try std.testing.expect(!try server.logsIn("alice", "password"));
    // nobody else changed
    try std.testing.expectEqualStrings("bob@example.test", ((try server.account(server.bob)) orelse return error.TestExpectedUser).event.email);
    try std.testing.expect(try server.logsIn("bob", "password"));
}

test "domain: UpdateUserSettings needs a login and a server" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for ([_]?fixture.Id{ server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.LoginRequired, (domain.UpdateUserSettings{ .email = "x@example.test" }).run(&ctx));
    }

    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var ctx = local.ctx(&arena);
    try std.testing.expectError(error.UnavailableHere, (domain.UpdateUserSettings{ .email = "x@example.test" }).run(&ctx));
}

test "domain: UpdateUserSettings rejects bad emails and passwords and changes nothing" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);

    const Case = struct { err: anyerror, email: []const u8 = "alice@new.test", current: []const u8 = "password", new: []const u8 = "changed", again: []const u8 = "changed" };
    for ([_]Case{
        .{ .err = error.EmailEmpty, .email = "" },
        .{ .err = error.EmailTaken, .email = "bob@example.test" },
        .{ .err = error.WrongPassword, .current = "wrong" },
        // a new password needs the current one
        .{ .err = error.WrongPassword, .current = "" },
        .{ .err = error.PasswordEmpty, .new = "", .again = "" },
        .{ .err = error.PasswordMismatch, .again = "chagned" },
    }) |case| {
        try std.testing.expectError(case.err, (domain.UpdateUserSettings{ .email = case.email, .current_password = case.current, .new_password = case.new, .new_password_again = case.again }).run(&alice));
    }
    try std.testing.expectEqualStrings("alice@example.test", ((try server.account(server.alice)) orelse return error.TestExpectedUser).event.email);
    try std.testing.expect(try server.logsIn("alice", "password"));
}
