const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const Server = fixture.Server;

// the role `user` holds in the repo `identity` names, or null when they can't see it
fn roleOf(server: *Server, arena: *std.heap.ArenaAllocator, user: fixture.Id, identity: []const u8) !?evt.Repo.Role {
    var ctx = try server.ctx(arena, user);
    const resolved = (try domain.resolveRepo(&ctx, identity)) orelse return null;
    return resolved.role;
}

test "domain: Grant makes a user a member" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);

    try std.testing.expectEqual(null, try roleOf(server, &arena, server.carol, "alice:secret"));
    try (domain.Grant{ .repo = "alice:secret", .user = "carol" }).run(&alice);
    try std.testing.expectEqual(.write, try roleOf(server, &arena, server.carol, "alice:secret"));
}

test "domain: Grant refuses a user who doesn't exist" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);

    try std.testing.expectError(error.UnknownUser, (domain.Grant{ .repo = "alice:secret", .user = "nobody" }).run(&alice));
    const failure = domain.classify(error.UnknownUser);
    try std.testing.expectEqual(.invalid_input, failure.kind);
    try std.testing.expect(!failure.changed);
}

test "domain: Grant refuses the creator and an existing member, and upgrades a reader" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);

    try std.testing.expectError(error.AlreadyMember, (domain.Grant{ .repo = "alice:secret", .user = "alice" }).run(&alice));
    try std.testing.expectError(error.AlreadyMember, (domain.Grant{ .repo = "alice:secret", .user = "bob" }).run(&alice));
    try std.testing.expectEqual(.owner, try roleOf(server, &arena, server.alice, "alice:secret"));
    try std.testing.expectEqual(.write, try roleOf(server, &arena, server.bob, "alice:secret"));
    const failure = domain.classify(error.AlreadyMember);
    try std.testing.expectEqual(.conflict, failure.kind);

    // a read grant becomes a member's
    try evt.grantRole(std.testing.io, allocator, server.users_dir, &server.alice, &server.secret.repo_id, &server.carol, .read, Server.alice_author);
    try std.testing.expectEqual(.read, try roleOf(server, &arena, server.carol, "alice:secret"));
    try (domain.Grant{ .repo = "alice:secret", .user = "carol" }).run(&alice);
    try std.testing.expectEqual(.write, try roleOf(server, &arena, server.carol, "alice:secret"));
}

test "domain: Revoke takes a member's role away" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);

    try (domain.Revoke{ .repo = "alice:secret", .user = "bob" }).run(&alice);
    try std.testing.expectEqual(null, try roleOf(server, &arena, server.bob, "alice:secret"));
    // a public repo's former member still reads it
    try (domain.Revoke{ .repo = "alice:open", .user = "bob" }).run(&alice);
    try std.testing.expectEqual(.read, try roleOf(server, &arena, server.bob, "alice:open"));
}

test "domain: Revoke finds no member in a user without a grant or a name nobody has" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);

    for ([_][]const u8{ "carol", "nobody", "alice" }) |name| {
        try std.testing.expectError(error.NotAMember, (domain.Revoke{ .repo = "alice:secret", .user = name }).run(&alice));
    }
    try std.testing.expectEqual(.owner, try roleOf(server, &arena, server.alice, "alice:secret"));
    const failure = domain.classify(error.NotAMember);
    try std.testing.expectEqual(.not_found, failure.kind);
}

test "domain: Promote makes a member an owner and Demote a member again" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);

    try (domain.Promote{ .repo = "alice:secret", .user = "bob" }).run(&alice);
    try std.testing.expectEqual(.owner, try roleOf(server, &arena, server.bob, "alice:secret"));
    try (domain.Demote{ .repo = "alice:secret", .user = "bob" }).run(&alice);
    try std.testing.expectEqual(.write, try roleOf(server, &arena, server.bob, "alice:secret"));
}

test "domain: Promote and Demote act only on a user with a grant" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);

    // carol holds no grant, nobody doesn't exist, and the creator holds none either
    for ([_][]const u8{ "carol", "nobody", "alice" }) |name| {
        try std.testing.expectError(error.NotAMember, (domain.Promote{ .repo = "alice:secret", .user = name }).run(&alice));
        try std.testing.expectError(error.NotAMember, (domain.Demote{ .repo = "alice:secret", .user = name }).run(&alice));
    }
    try std.testing.expectEqual(null, try roleOf(server, &arena, server.carol, "alice:secret"));
    try std.testing.expectEqual(.owner, try roleOf(server, &arena, server.alice, "alice:secret"));
}

// run the member action `Op` names on `user` in `repo`
fn act(comptime Op: type, ctx: *domain.Ctx, repo: []const u8, user: []const u8) !void {
    try (Op{ .repo = repo, .user = user }).run(ctx);
}

test "domain: member actions need the owner role" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);
    var carol = try server.ctx(&arena, server.carol);
    var dave = try server.ctx(&arena, server.dave);
    var nobody = try server.ctx(&arena, null);

    inline for (.{ domain.Grant, domain.Revoke, domain.Promote, domain.Demote }) |Op| {
        try std.testing.expectError(error.Forbidden, act(Op, &bob, "alice:secret", "bob"));
        try std.testing.expectError(error.Forbidden, act(Op, &carol, "alice:open", "bob"));
        try std.testing.expectError(error.NotFound, act(Op, &carol, "alice:secret", "bob"));
        try std.testing.expectError(error.LoginRequired, act(Op, &dave, "alice:secret", "bob"));
        try std.testing.expectError(error.LoginRequired, act(Op, &nobody, "alice:secret", "bob"));
    }
    try std.testing.expectEqual(.write, try roleOf(server, &arena, server.bob, "alice:secret"));
}

test "domain: an owner may give up their own role" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);
    try act(domain.Promote, &alice, "alice:secret", "bob");
    var bob = try server.ctx(&arena, server.bob);

    try act(domain.Demote, &bob, "alice:secret", "bob");
    try std.testing.expectEqual(.write, try roleOf(server, &arena, server.bob, "alice:secret"));
    try act(domain.Promote, &alice, "alice:secret", "bob");
    try act(domain.Revoke, &bob, "alice:secret", "bob");
    try std.testing.expectEqual(null, try roleOf(server, &arena, server.bob, "alice:secret"));
}

test "domain: member actions are server only" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);
    inline for (.{ domain.Grant, domain.Revoke, domain.Promote, domain.Demote }) |Op| {
        try std.testing.expectError(error.UnavailableHere, act(Op, &ctx, "", "bob"));
    }
}

test "domain: members and branches form feedback reads the domain errors" {
    const FormFeedback = hx.ui.Session.FormFeedback;
    try std.testing.expectEqual(.not_found, FormFeedback.MembersFailure.fromError(error.UnknownUser).?);
    try std.testing.expectEqual(.already_added, FormFeedback.MembersFailure.fromError(error.AlreadyMember).?);
    // a stale row is no add failure
    try std.testing.expectEqual(null, FormFeedback.MembersFailure.fromError(error.NotAMember));
    try std.testing.expectEqual(.not_found, FormFeedback.BranchesFailure.fromError(error.UnknownBranch).?);
    try std.testing.expectEqual(.too_long, FormFeedback.BranchesFailure.fromError(error.BranchNameTooLong).?);
    try std.testing.expectEqual(.already_added, FormFeedback.BranchesFailure.fromError(error.BranchProtected).?);
    try std.testing.expectEqual(null, FormFeedback.BranchesFailure.fromError(error.NotFound));
}

test "domain: Grant finds a user registered after the context was built" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);
    var nobody = try server.ctx(&arena, null);
    const erin = (try (domain.RegisterUser{ .name = "erin", .email = "erin@example.test", .password = "password", .password_again = "password" }).run(&nobody)).id;

    try (domain.Grant{ .repo = "alice:secret", .user = "erin" }).run(&alice);
    try std.testing.expectEqual(.write, try roleOf(server, &arena, erin, "alice:secret"));
}

test "domain: Grant names the account that holds the name when it runs" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);
    var carol = try server.ctx(&arena, server.carol);
    try (domain.DeleteUser{ .confirm = "carol", .password = "password" }).run(&carol);

    // the removed account's name names nobody
    try std.testing.expectError(error.UnknownUser, (domain.Grant{ .repo = "alice:secret", .user = "carol" }).run(&alice));
    // and once taken again, the new account
    var nobody = try server.ctx(&arena, null);
    const new_carol = (try (domain.RegisterUser{ .name = "carol", .email = "carol2@example.test", .password = "password", .password_again = "password" }).run(&nobody)).id;
    try (domain.Grant{ .repo = "alice:secret", .user = "carol" }).run(&alice);
    try std.testing.expectEqual(.write, try roleOf(server, &arena, new_carol, "alice:secret"));
}
