const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const author: evt.CommitAuthor = .{ .name = "ada", .email = "ada@example.test" };
const issue: fixture.Id = @splat(0x11);
const issue_hex = "11111111111111111111111111111111";

fn expectRefreshSeesFetched(comptime hash_kind: hx.xit.hash.HashKind) !void {
    var local = try fixture.Local(.git, hash_kind).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    try local.commitUnconsumed(author, issue, .{ .issue = .{ .title = "fetched", .description = "", .labels = "" } });
    // reads don't consume the events branch
    try std.testing.expectEqual(0, (try (domain.ListIssues{ .repo = "" }).run(&ctx)).count);

    try (domain.RefreshLocal{}).run(&ctx);
    const window = try (domain.ListIssues{ .repo = "" }).run(&ctx);
    try std.testing.expectEqual(1, window.count);
    try std.testing.expectEqualStrings(issue_hex, window.items[0].id);
}

test "domain: RefreshLocal brings a local git repo's issues up to its events branch" {
    try expectRefreshSeesFetched(.sha1);
    try expectRefreshSeesFetched(.sha256);
}

test "domain: RefreshLocal runs on a local xit repo, which consumes as it commits" {
    var local = try fixture.Local(.xit, .sha1).init();
    defer local.deinit();
    try local.addEvent(author, issue, .{ .issue = .{ .title = "written", .description = "", .labels = "" } });
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    try (domain.RefreshLocal{}).run(&ctx);
    try std.testing.expectEqual(1, (try (domain.ListIssues{ .repo = "" }).run(&ctx)).count);
}

test "domain: RefreshLocal is unavailable on a server, whose writes consume as they commit" {
    const server = try fixture.Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for ([_]?fixture.Id{ server.alice, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.UnavailableHere, (domain.RefreshLocal{ .repo = "alice:open" }).run(&ctx));
        try std.testing.expectError(error.UnavailableHere, (domain.RefreshLocal{}).run(&ctx));
    }
}
