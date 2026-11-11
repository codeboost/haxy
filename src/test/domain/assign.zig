const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const Server = fixture.Server;

const alices: fixture.Id = @splat(0xa1);
const alices_hex = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
const carols: fixture.Id = @splat(0xc1);
const carols_hex = "c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1";

// the emails assigned to an issue, in the order the thread shows them
fn assignees(ctx: *domain.Ctx, repo: []const u8, id: []const u8) ![]const hx.ui.Assignee {
    return (try (domain.GetIssue{ .repo = repo, .id = id }).run(ctx)).assignees;
}

test "domain: Assign assigns an email to an issue" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, alices);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);

    try (domain.Assign{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex, .assignee = "someone@example.test" }).run(&bob);
    const assigned = try assignees(&bob, "alice:open", alices_hex);
    try std.testing.expectEqual(1, assigned.len);
    try std.testing.expectEqualStrings("someone@example.test", assigned[0].email);
}

test "domain: Assign on a server looks a user up by name" {
    const server = try Server.init(.sha256);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, alices);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);

    try (domain.Assign{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex, .assignee = " carol " }).run(&bob);
    const assigned = try assignees(&bob, "alice:open", alices_hex);
    try std.testing.expectEqual(1, assigned.len);
    try std.testing.expectEqualStrings("carol@example.test", assigned[0].email);
    try std.testing.expectEqualStrings("carol", assigned[0].name.?);

    // nobody has the name, and a removed user has none any more
    for ([_][]const u8{ "nobody", "dave" }) |name| {
        try std.testing.expectError(error.UnknownAssignee, (domain.Assign{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex, .assignee = name }).run(&bob));
    }
    try std.testing.expectEqual(1, (try assignees(&bob, "alice:open", alices_hex)).len);
}

test "domain: Assign refuses an email already assigned and one that isn't an email" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, alices);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);

    try (domain.Assign{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex, .assignee = "carol" }).run(&bob);
    // by email or by name, carol holds the one assignment she can
    for ([_][]const u8{ "carol@example.test", "carol" }) |assignee| {
        try std.testing.expectError(error.AlreadyAssigned, (domain.Assign{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex, .assignee = assignee }).run(&bob));
    }
    try std.testing.expectError(error.NotAnEmail, (domain.Assign{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex, .assignee = "carol @example.test" }).run(&bob));
    try std.testing.expectEqual(1, (try assignees(&bob, "alice:open", alices_hex)).len);
}

test "domain: Assign lets a writer assign on any thread and a reader only on their own" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, alices);
    try server.addIssue(server.open, Server.carol_author, carols);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var carol = try server.ctx(&arena, server.carol);

    try std.testing.expectError(error.Forbidden, (domain.Assign{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex, .assignee = "carol" }).run(&carol));
    try std.testing.expectEqual(0, (try assignees(&carol, "alice:open", alices_hex)).len);
    try (domain.Assign{ .repo = "alice:open", .kind = .issue, .thread_id = carols_hex, .assignee = "bob" }).run(&carol);
    try std.testing.expectEqualStrings("bob@example.test", (try assignees(&carol, "alice:open", carols_hex))[0].email);
}

test "domain: Assign needs a login, the tab's role, a repo the user can see and a known thread" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.carol_author, carols);
    try server.addIssue(server.secret, Server.alice_author, alices);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for ([_]?fixture.Id{ server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.LoginRequired, (domain.Assign{ .repo = "alice:open", .kind = .issue, .thread_id = carols_hex, .assignee = "bob" }).run(&ctx));
    }
    var carol = try server.ctx(&arena, server.carol);
    try std.testing.expectError(error.NotFound, (domain.Assign{ .repo = "alice:secret", .kind = .issue, .thread_id = alices_hex, .assignee = "bob" }).run(&carol));

    var bob = try server.ctx(&arena, server.bob);
    const cases = [_]struct { domain.ThreadKind, []const u8 }{
        .{ .issue, "22222222222222222222222222222222" },
        .{ .issue, "not an id" },
        .{ .discuss, carols_hex },
    };
    for (cases) |case| {
        try std.testing.expectError(error.NotFound, (domain.Assign{ .repo = "alice:open", .kind = case[0], .thread_id = case[1], .assignee = "bob" }).run(&bob));
    }

    // only writers may write to the public repo's issues, even their own
    try server.setTabs(server.open, .read, .write, null);
    try std.testing.expectError(error.Forbidden, (domain.Assign{ .repo = "alice:open", .kind = .issue, .thread_id = carols_hex, .assignee = "bob" }).run(&carol));
}

fn expectLocalAssign(comptime kind: hx.xit.repo.RepoKind, comptime hash_kind: hx.xit.hash.HashKind) !void {
    var local = try fixture.Local(kind, hash_kind).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    try local.addEvent(Server.alice_author, alices, .{ .issue = .{ .title = "fetched", .description = "", .labels = "" } });
    // local mode has no users, so a bare name is no email
    try std.testing.expectError(error.NotAnEmail, (domain.Assign{ .repo = "", .kind = .issue, .thread_id = alices_hex, .assignee = "carol" }).run(&ctx));
    try (domain.Assign{ .repo = "", .kind = .issue, .thread_id = alices_hex, .assignee = "carol@example.test" }).run(&ctx);
    const assigned = try assignees(&ctx, "", alices_hex);
    try std.testing.expectEqual(1, assigned.len);
    try std.testing.expectEqualStrings("carol@example.test", assigned[0].email);
    try std.testing.expectEqual(null, assigned[0].name);
}

test "domain: Assign assigns an email in a local git or xit repo" {
    try expectLocalAssign(.git, .sha1);
    try expectLocalAssign(.git, .sha256);
    try expectLocalAssign(.xit, .sha1);
    try expectLocalAssign(.xit, .sha256);
}

test "domain: Unassign removes an assigned email" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, alices);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);
    try (domain.Assign{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex, .assignee = "carol" }).run(&bob);
    try (domain.Assign{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex, .assignee = "someone@example.test" }).run(&bob);

    try (domain.Unassign{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex, .email = "carol@example.test" }).run(&bob);
    const assigned = try assignees(&bob, "alice:open", alices_hex);
    try std.testing.expectEqual(1, assigned.len);
    try std.testing.expectEqualStrings("someone@example.test", assigned[0].email);
    // the assignment is gone, so it can't go twice
    try std.testing.expectError(error.NotFound, (domain.Unassign{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex, .email = "carol@example.test" }).run(&bob));
}

test "domain: Unassign lets a writer unassign on any thread and a reader only on their own" {
    const server = try Server.init(.sha256);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, alices);
    try server.addIssue(server.open, Server.carol_author, carols);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);
    for ([_][]const u8{ alices_hex, carols_hex }) |id| {
        try (domain.Assign{ .repo = "alice:open", .kind = .issue, .thread_id = id, .assignee = "carol" }).run(&bob);
    }
    var carol = try server.ctx(&arena, server.carol);

    // even her own assignment on a thread she didn't write
    try std.testing.expectError(error.Forbidden, (domain.Unassign{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex, .email = "carol@example.test" }).run(&carol));
    try std.testing.expectEqual(1, (try assignees(&carol, "alice:open", alices_hex)).len);
    try (domain.Unassign{ .repo = "alice:open", .kind = .issue, .thread_id = carols_hex, .email = "carol@example.test" }).run(&carol);
    try std.testing.expectEqual(0, (try assignees(&carol, "alice:open", carols_hex)).len);
}

test "domain: Unassign needs a login, the tab's role, a repo the user can see and a known thread" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    const other: fixture.Id = @splat(0x22);
    const other_hex = "22222222222222222222222222222222";
    try server.addIssue(server.open, Server.carol_author, carols);
    try server.addIssue(server.open, Server.alice_author, other);
    try server.addIssue(server.secret, Server.alice_author, alices);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);
    try (domain.Assign{ .repo = "alice:open", .kind = .issue, .thread_id = carols_hex, .assignee = "bob" }).run(&bob);
    try (domain.Assign{ .repo = "alice:secret", .kind = .issue, .thread_id = alices_hex, .assignee = "bob" }).run(&bob);

    for ([_]?fixture.Id{ server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.LoginRequired, (domain.Unassign{ .repo = "alice:open", .kind = .issue, .thread_id = carols_hex, .email = "bob@example.test" }).run(&ctx));
    }
    var carol = try server.ctx(&arena, server.carol);
    try std.testing.expectError(error.NotFound, (domain.Unassign{ .repo = "alice:secret", .kind = .issue, .thread_id = alices_hex, .email = "bob@example.test" }).run(&carol));

    // the assignment is on another thread, the thread is of another kind or no thread at all
    const cases = [_]struct { domain.ThreadKind, []const u8 }{
        .{ .issue, other_hex },
        .{ .issue, "not an id" },
        .{ .discuss, carols_hex },
    };
    for (cases) |case| {
        try std.testing.expectError(error.NotFound, (domain.Unassign{ .repo = "alice:open", .kind = case[0], .thread_id = case[1], .email = "bob@example.test" }).run(&bob));
    }
    try std.testing.expectEqual(1, (try assignees(&bob, "alice:open", carols_hex)).len);

    // only writers may write to the public repo's issues, even their own
    try server.setTabs(server.open, .read, .write, null);
    try std.testing.expectError(error.Forbidden, (domain.Unassign{ .repo = "alice:open", .kind = .issue, .thread_id = carols_hex, .email = "bob@example.test" }).run(&carol));
}

fn expectLocalUnassign(comptime kind: hx.xit.repo.RepoKind, comptime hash_kind: hx.xit.hash.HashKind) !void {
    var local = try fixture.Local(kind, hash_kind).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    try local.addEvent(Server.alice_author, alices, .{ .issue = .{ .title = "fetched", .description = "", .labels = "" } });
    try (domain.Assign{ .repo = "", .kind = .issue, .thread_id = alices_hex, .assignee = "carol@example.test" }).run(&ctx);
    try (domain.Unassign{ .repo = "", .kind = .issue, .thread_id = alices_hex, .email = "carol@example.test" }).run(&ctx);
    try std.testing.expectEqual(0, (try assignees(&ctx, "", alices_hex)).len);
}

test "domain: Unassign removes an email in a local git or xit repo" {
    try expectLocalUnassign(.git, .sha1);
    try expectLocalUnassign(.xit, .sha256);
}
