const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const Server = fixture.Server;

test "domain: files: ListRefs lists a repo's branches or tags in name order" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.open);
    try fixture.addServerRefs(server, server.open, .branch, &.{ "zeta", "alpha" });
    try fixture.addServerRefs(server, server.open, .tag, &.{"v1"});
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = try server.ctx(&arena, server.carol);
    {
        const branches = try (domain.ListRefs{ .repo = "alice:open" }).run(&ctx);
        try std.testing.expectEqual(3, branches.names.len);
        try std.testing.expectEqualStrings("alpha", branches.names[0]);
        try std.testing.expectEqualStrings("master", branches.names[1]);
        try std.testing.expectEqualStrings("zeta", branches.names[2]);
        try std.testing.expectEqual(null, branches.prev);
        try std.testing.expectEqual(null, branches.next);
    }
    {
        const tags = try (domain.ListRefs{ .repo = "alice:open", .kind = .tag }).run(&ctx);
        try std.testing.expectEqual(1, tags.names.len);
        try std.testing.expectEqualStrings("v1", tags.names[0]);
    }
}

test "domain: files: ListRefs searches and windows from decoded names" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.open);
    // "%41" would decode to "A", so neither may be decoded again
    try fixture.addServerRefs(server, server.open, .branch, &.{ "team/50%41-é", "team/50A-é" });
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.carol);

    {
        const branches = try (domain.ListRefs{ .repo = "alice:open", .search = "team/50%41" }).run(&ctx);
        try std.testing.expectEqual(1, branches.names.len);
        try std.testing.expectEqualStrings("team/50%41-é", branches.names[0]);
    }
    {
        const branches = try (domain.ListRefs{ .repo = "alice:open", .from = "team/50%41-é" }).run(&ctx);
        try std.testing.expectEqual(2, branches.names.len);
        try std.testing.expectEqualStrings("team/50%41-é", branches.names[0]);
        try std.testing.expectEqualStrings("team/50A-é", branches.names[1]);
        try std.testing.expectEqualStrings("", branches.prev.?);
    }
}

test "domain: files: ListRefs pages across a window boundary" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.open);
    // b00 to b54, beside master: 56 branches, past one window of 50
    var names: [55][]const u8 = undefined;
    var buffers: [55][3]u8 = undefined;
    for (&names, &buffers, 0..) |*name, *buffer, i| name.* = try std.fmt.bufPrint(buffer, "b{d:0>2}", .{i});
    try fixture.addServerRefs(server, server.open, .branch, &names);
    try fixture.addServerRefs(server, server.open, .tag, &.{ "v1", "v2", "v3" });
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.carol);

    const first = try (domain.ListRefs{ .repo = "alice:open" }).run(&ctx);
    try std.testing.expectEqual(50, first.names.len);
    try std.testing.expectEqualStrings("b00", first.names[0]);
    try std.testing.expectEqualStrings("b49", first.names[49]);
    try std.testing.expectEqualStrings("b50", first.next.?);
    try std.testing.expectEqual(null, first.prev);

    const second = try (domain.ListRefs{ .repo = "alice:open", .from = "b50" }).run(&ctx);
    try std.testing.expectEqual(6, second.names.len);
    try std.testing.expectEqualStrings("b50", second.names[0]);
    try std.testing.expectEqualStrings("b54", second.names[4]);
    try std.testing.expectEqualStrings("master", second.names[5]);
    try std.testing.expectEqual(null, second.next);
    try std.testing.expectEqualStrings("", second.prev.?);

    const tags = try (domain.ListRefs{ .repo = "alice:open", .kind = .tag, .from = "v2" }).run(&ctx);
    try std.testing.expectEqual(2, tags.names.len);
    try std.testing.expectEqualStrings("v2", tags.names[0]);

    // a `from` that names no ref, or a ref of the other kind
    for ([_]domain.ListRefs{
        .{ .repo = "alice:open", .from = "b50x" },
        .{ .repo = "alice:open", .from = "zzz" },
        .{ .repo = "alice:open", .from = "v1" },
        .{ .repo = "alice:open", .kind = .tag, .from = "master" },
        .{ .repo = "alice:open", .search = "b5", .from = "b00" },
    }) |op| {
        try std.testing.expectError(error.NotFound, op.run(&ctx));
    }
}

test "domain: files: ListRefs finds no repo the viewer can't see, and lets anyone read a public one" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.open);
    try server.commitReadme(server.secret);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for ([_]?fixture.Id{ server.carol, server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.NotFound, (domain.ListRefs{ .repo = "alice:secret" }).run(&ctx));
    }
    var ctx = try server.ctx(&arena, null);
    const branches = try (domain.ListRefs{ .repo = "alice:open" }).run(&ctx);
    try std.testing.expectEqual(1, branches.names.len);
    try std.testing.expectEqualStrings("master", branches.names[0]);
}

fn expectLocalRefs(comptime kind: hx.xit.repo.RepoKind, comptime hash_kind: hx.xit.hash.HashKind) !void {
    var local = try fixture.Local(kind, hash_kind).init();
    defer local.deinit();
    try fixture.addLocalRefs(kind, &local, .branch, &.{"team/50%41-é"});
    try fixture.addLocalRefs(kind, &local, .tag, &.{"v1"});
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    const branches = try (domain.ListRefs{ .repo = "" }).run(&ctx);
    try std.testing.expectEqual(2, branches.names.len);
    try std.testing.expectEqualStrings("master", branches.names[0]);
    try std.testing.expectEqualStrings("team/50%41-é", branches.names[1]);
    const tags = try (domain.ListRefs{ .repo = "", .kind = .tag }).run(&ctx);
    try std.testing.expectEqual(1, tags.names.len);
    try std.testing.expectEqualStrings("v1", tags.names[0]);
    try std.testing.expectError(error.NotFound, (domain.ListRefs{ .repo = "alice:open" }).run(&ctx));
}

test "domain: files: ListRefs lists a local git or xit repo's refs" {
    try expectLocalRefs(.git, .sha1);
    try expectLocalRefs(.git, .sha256);
    try expectLocalRefs(.xit, .sha1);
    try expectLocalRefs(.xit, .sha256);
}

test "domain: files: ListRefs reports a listing that fails" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    try fixture.removeGitRefs(&local);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    // the page shows the columns empty; a read fails internally
    for ([_]hx.ui.RoutablePage.RefKind{ .branch, .tag }) |kind| {
        if ((domain.ListRefs{ .repo = "", .kind = kind }).run(&ctx)) |_| return error.TestExpectedError else |err| {
            try std.testing.expectEqual(.internal, domain.classify(err).kind);
        }
    }
}
