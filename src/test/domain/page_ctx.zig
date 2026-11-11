const std = @import("std");
const hx = @import("../../lib.zig");
const ui = hx.ui;
const evt = hx.event;
const fixture = @import("fixture.zig");

const io = std.testing.io;
const allocator = std.testing.allocator;
const Server = fixture.Server;

fn filesRoute(identity: []const u8) !ui.RoutablePage {
    return ui.RoutablePage.repoFilesRoute(identity, null, "", "", 0) orelse error.BadRoute;
}

test "domain: page context: a session held stale builds its page at its own moment" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // bob's issue on the private repo, where alice's comment notifies him
    try server.addIssue(server.secret, Server.bob_author, @splat(0xb2));
    try server.addComment(server.secret, Server.alice_author, @splat(0xa2), @splat(0xb2), "hi");

    // bob, a member of the private repo, is removed after his session was
    // built. his account is tombstoned and his dir kept, as a delete that
    // failed to remove the dir leaves it, so his inbox is still there.
    var session = try server.session(&arena, &server.bob);
    try evt.remove(.{ .server = .{ .users_dir = server.users_dir } }, .admin, .xit, evt.admin_repo_opts, io, allocator, &server.admin, &server.bob, .user, Server.bob_author);

    // the session still holds the moment it checked bob at, so the page is
    // built as bob, as the session says it is
    const route = try filesRoute("alice:secret");
    session.data.current_page = route;
    const page = try ui.Repo.init(&arena, &session, route);
    try std.testing.expectEqualStrings(Server.bob_author.email, (page.handle.viewer orelse return error.NoViewer).email);
    try std.testing.expectEqual(.write, page.handle.viewer.?.role);
    try std.testing.expect(session.data.user_id != null);
    try std.testing.expectEqualStrings("bob", session.data.user_name.?);
    // and its header lists bob's inbox as of that moment
    try std.testing.expectEqual(1, page.user_notifications.rows.len);
    try std.testing.expect(page.user_notifications.rows[0].unread);
    try std.testing.expectEqualStrings("alice:secret", page.user_notifications.rows[0].identity);
    try std.testing.expectEqual(1, session.data.unread_notifs);

    // once the session reloads its moment it logs bob out, and the page agrees
    try session.reloadMoment(allocator, &server.admin);
    try std.testing.expectEqual(null, session.data.user_id);
    try std.testing.expectError(error.NotFound, ui.Repo.init(&arena, &session, route));
    const open = try filesRoute("alice:open");
    session.data.current_page = open;
    const open_page = try ui.Repo.init(&arena, &session, open);
    try std.testing.expectEqual(null, open_page.handle.viewer);
    try std.testing.expectEqual(0, open_page.user_notifications.rows.len);
}

test "domain: page context: a session naming an account its moment holds removed is logged out" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // a caller that set the id without checking it: dave was removed before
    // this session's moment
    var session = try server.session(&arena, &server.carol);
    session.data.user_id = &server.dave;
    session.data.user_name = "dave";
    const route = try filesRoute("alice:open");
    session.data.current_page = route;
    const page = try ui.Repo.init(&arena, &session, route);
    // dave was a member, but the page is built logged out, and so is the session
    try std.testing.expectEqual(null, page.handle.viewer);
    try std.testing.expectEqual(null, session.data.user_id);
    try std.testing.expectEqual(null, session.data.user_name);
    try std.testing.expectError(error.NotFound, ui.Repo.init(&arena, &session, try filesRoute("alice:secret")));
}
