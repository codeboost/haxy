const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const Server = fixture.Server;

const alices: fixture.Id = @splat(0xa1);
const alices_hex = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";

test "domain: GetIssue offers a notified user mute and anyone else subscribe" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    // alice is involved in her own issue
    try server.addIssue(server.open, Server.alice_author, alices);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var alice = try server.ctx(&arena, server.alice);
    try std.testing.expectEqual(.mute, (try (domain.GetIssue{ .repo = "alice:open", .id = alices_hex }).run(&alice)).notify_action);
    var carol = try server.ctx(&arena, server.carol);
    try std.testing.expectEqual(.subscribe, (try (domain.GetIssue{ .repo = "alice:open", .id = alices_hex }).run(&carol)).notify_action);
}

test "domain: GetIssue offers no notify button logged out, to a removed user or in local mode" {
    const server = try Server.init(.sha256);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, alices);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for ([_]?fixture.Id{ server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectEqual(null, (try (domain.GetIssue{ .repo = "alice:open", .id = alices_hex }).run(&ctx)).notify_action);
    }

    inline for ([_]hx.xit.repo.RepoKind{ .git, .xit }) |kind| {
        var local = try fixture.Local(kind, .sha1).init();
        defer local.deinit();
        try local.addEvent(Server.alice_author, alices, .{ .issue = .{ .title = "an issue", .description = "", .labels = "" } });
        var ctx = local.ctx(&arena);
        try std.testing.expectEqual(null, (try (domain.GetIssue{ .repo = "", .id = alices_hex }).run(&ctx)).notify_action);
    }
}

test "domain: ListIssues offers each listed issue's notify button" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, alices);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var carol = try server.ctx(&arena, server.carol);
    try std.testing.expectEqual(.subscribe, (try (domain.ListIssues{ .repo = "alice:open" }).run(&carol)).items[0].notify_action);
    try (domain.Subscribe{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex }).run(&carol);
    try std.testing.expectEqual(.mute, (try (domain.ListIssues{ .repo = "alice:open" }).run(&carol)).items[0].notify_action);
    var nobody = try server.ctx(&arena, null);
    try std.testing.expectEqual(null, (try (domain.ListIssues{ .repo = "alice:open" }).run(&nobody)).items[0].notify_action);
}

test "domain: GetDiscussion offers the discussion's notify button" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    // bob started it, which involves him
    var bob = try server.ctx(&arena, server.bob);
    const created = try (domain.CreateThread{ .repo = "alice:secret", .kind = .discuss, .title = "roadmap" }).run(&bob);

    try std.testing.expectEqual(.mute, (try (domain.GetDiscussion{ .repo = "alice:secret", .id = &created.id }).run(&bob)).notify_action);
    var alice = try server.ctx(&arena, server.alice);
    try std.testing.expectEqual(.subscribe, (try (domain.GetDiscussion{ .repo = "alice:secret", .id = &created.id }).run(&alice)).notify_action);
}

test "domain: GetPatch offers a patch's notify button but none on a draft" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    try server.addEvent(server.open, Server.alice_author, alices, .{ .patch = .{ .title = "a patch", .description = "", .labels = "", .target_branch = "master" } });
    const bobs_draft: fixture.Id = @splat(0xb1);
    try server.addDraft(server.open, server.bob, Server.bob_author, bobs_draft);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var alice = try server.ctx(&arena, server.alice);
    try std.testing.expectEqual(.mute, (try (domain.GetPatch{ .repo = "alice:open", .id = alices_hex }).run(&alice)).notify_action);
    var bob = try server.ctx(&arena, server.bob);
    try std.testing.expectEqual(.subscribe, (try (domain.GetPatch{ .repo = "alice:open", .id = alices_hex }).run(&bob)).notify_action);
    // a draft lives in its fork, where nobody can follow it yet
    try std.testing.expectEqual(null, (try (domain.GetPatch{ .repo = "alice:open", .id = "b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1" }).run(&bob)).notify_action);
}

test "domain: ListPatches offers each listed patch's notify button but none on drafts" {
    const server = try Server.init(.sha256);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    try server.addEvent(server.open, Server.alice_author, alices, .{ .patch = .{ .title = "a patch", .description = "", .labels = "", .target_branch = "master" } });
    try server.addDraft(server.open, server.bob, Server.bob_author, @splat(0xb1));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var alice = try server.ctx(&arena, server.alice);
    try std.testing.expectEqual(.mute, (try (domain.ListPatches{ .repo = "alice:open" }).run(&alice)).items[0].notify_action);
    var bob = try server.ctx(&arena, server.bob);
    try std.testing.expectEqual(.subscribe, (try (domain.ListPatches{ .repo = "alice:open" }).run(&bob)).items[0].notify_action);
    try std.testing.expectEqual(null, (try (domain.ListPatches{ .repo = "alice:open", .view = .drafts }).run(&bob)).items[0].notify_action);
}
