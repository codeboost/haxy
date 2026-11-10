const std = @import("std");
const hx = @import("../../lib.zig");
const ui = hx.ui;
const domain = hx.domain;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const Server = fixture.Server;

const alices: fixture.Id = @splat(0xa1);
const alices_hex = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";

test "domain: a page view sets notify buttons and marks the viewed thread's notification read" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    // alice is involved in her issue, so bob's comment notifies her
    try server.addIssue(server.open, Server.alice_author, alices);
    try server.addComment(server.open, Server.bob_author, @splat(0xb1), alices, "hi");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // the listing alone marks nothing read
    {
        var session = try server.session(&arena, &server.alice);
        const route = ui.RoutablePage.repoIssuesRoute("alice:open", .open, "") orelse return error.BadRoute;
        session.data.current_page = route;
        const page = try ui.Repo.init(&arena, &session, route);
        try std.testing.expectEqual(.mute, page.issues.open.items[0].notify_action);
        try std.testing.expectEqual(1, session.data.unread_notifs);
        try std.testing.expect(page.user_notifications.rows[0].unread);
    }
    // viewing the issue shows bob's comment, so it marks it read
    {
        var session = try server.session(&arena, &server.alice);
        const route = ui.RoutablePage.repoIssuesRoute("alice:open", .open, alices_hex) orelse return error.BadRoute;
        session.data.current_page = route;
        const page = try ui.Repo.init(&arena, &session, route);
        try std.testing.expectEqual(0, session.data.unread_notifs);
        try std.testing.expect(!page.user_notifications.rows[0].unread);
    }
    var alice = try server.ctx(&arena, server.alice);
    try std.testing.expectEqual(0, (try (domain.ListNotifications{}).run(&alice)).unread_count);

    // a stranger is offered subscribe
    {
        var session = try server.session(&arena, &server.carol);
        const route = ui.RoutablePage.repoIssuesRoute("alice:open", .open, alices_hex) orelse return error.BadRoute;
        session.data.current_page = route;
        const page = try ui.Repo.init(&arena, &session, route);
        try std.testing.expectEqual(.subscribe, page.issues.open.items[0].notify_action);
    }
}
