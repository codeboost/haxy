const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const Server = fixture.Server;

test "domain: GetDiscussion reads a discussion the viewer may see" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);
    const created = try (domain.CreateThread{ .repo = "alice:secret", .kind = .discuss, .title = "roadmap", .labels = "plan", .body = "what next" }).run(&bob);

    const entry = try (domain.GetDiscussion{ .repo = "alice:secret", .id = &created.id }).run(&bob);
    try std.testing.expectEqualStrings(&created.id, entry.id);
    try std.testing.expectEqualStrings("roadmap", entry.record.event.title);
    try std.testing.expectEqualStrings("plan", entry.record.event.labels);
    try std.testing.expectEqualStrings("what next", entry.record.event.description);

    try std.testing.expectError(error.NotFound, (domain.GetDiscussion{ .repo = "alice:secret", .id = "22222222222222222222222222222222" }).run(&bob));
    var carol = try server.ctx(&arena, server.carol);
    try std.testing.expectError(error.NotFound, (domain.GetDiscussion{ .repo = "alice:secret", .id = &created.id }).run(&carol));
}
