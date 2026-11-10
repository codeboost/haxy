const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const Server = fixture.Server;

test "domain: Undo restores a repo to before a transaction" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const first = try server.historyCount(server.open);
    try server.setUndoValue(server.open, "first");
    try server.setUndoValue(server.open, "second");
    var alice = try server.ctx(&arena, server.alice);

    try (domain.Undo{ .repo = "alice:open", .index = first + 1 }).run(&alice);
    try std.testing.expectEqualStrings("first", (try server.undoValue(server.open)).?);
}

test "domain: Undo finds no transaction outside the history" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try server.setUndoValue(server.open, "first");
    const count = try server.historyCount(server.open);
    var alice = try server.ctx(&arena, server.alice);

    // the first transaction made the repo, and nothing comes after the last
    try std.testing.expectError(error.InvalidHistoryIndex, (domain.Undo{ .repo = "alice:open", .index = 0 }).run(&alice));
    try std.testing.expectError(error.InvalidHistoryIndex, (domain.Undo{ .repo = "alice:open", .index = count }).run(&alice));
    try std.testing.expectEqualStrings("first", (try server.undoValue(server.open)).?);
    for ([_]anyerror{ error.InvalidHistoryIndex, error.TransactionNotFound }) |err| {
        const failure = domain.classify(err);
        try std.testing.expectEqual(.not_found, failure.kind);
        try std.testing.expect(!failure.changed);
    }
}

test "domain: Undo doesn't reach below a copy's own history" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.open);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);
    _ = try (domain.CreateRepo{ .name = "copied", .copy = "alice:open" }).run(&alice);
    const copied = try server.locate(server.alice, "copied");
    const floor = (try server.undoFloor(copied)) orelse return error.TestExpectedFloor;
    const count = try server.historyCount(copied);

    // the floor and what lies under it belong to the repo it copied
    try std.testing.expectError(error.InvalidHistoryIndex, (domain.Undo{ .repo = "alice:copied", .index = floor }).run(&alice));
    try std.testing.expectEqual(count, try server.historyCount(copied));
    // above it, the copy's own history undoes
    try server.setUndoValue(copied, "own");
    try (domain.Undo{ .repo = "alice:copied", .index = count }).run(&alice);
    try std.testing.expectEqual(null, try server.undoValue(copied));
}

test "domain: Undo needs the owner role" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const index = try server.historyCount(server.secret);
    try server.setUndoValue(server.secret, "kept");
    try server.setUndoValue(server.open, "kept");

    var bob = try server.ctx(&arena, server.bob);
    try std.testing.expectError(error.Forbidden, (domain.Undo{ .repo = "alice:secret", .index = index }).run(&bob));
    var carol = try server.ctx(&arena, server.carol);
    try std.testing.expectError(error.Forbidden, (domain.Undo{ .repo = "alice:open", .index = index }).run(&carol));
    try std.testing.expectError(error.NotFound, (domain.Undo{ .repo = "alice:secret", .index = index }).run(&carol));
    for ([_]?fixture.Id{ server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.LoginRequired, (domain.Undo{ .repo = "alice:secret", .index = index }).run(&ctx));
    }
    try std.testing.expectEqualStrings("kept", (try server.undoValue(server.secret)).?);
    try std.testing.expectEqualStrings("kept", (try server.undoValue(server.open)).?);
}

test "domain: Undo is server only, where repos are xit" {
    inline for (.{ hx.xit.repo.RepoKind.git, .xit }) |kind| {
        var local = try fixture.Local(kind, .sha1).init();
        defer local.deinit();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var ctx = local.ctx(&arena);
        try std.testing.expectError(error.UnavailableHere, (domain.Undo{ .repo = "", .index = 1 }).run(&ctx));
    }
}
