const std = @import("std");
const hx = @import("../../lib.zig");
const ui = hx.ui;
const evt = hx.event;
const xit = hx.xit;
const fixture = @import("fixture.zig");

const io = std.testing.io;
const allocator = std.testing.allocator;
const Server = fixture.Server;

test "domain: a terminal thread form keeps its text when the tab is turned off under it" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var session = ui.Session{
        .arena = &arena,
        .page_arena = &arena,
        .io = io,
        .is_terminal = true,
        .admin_repo = &server.admin,
        .users_dir = server.users_dir,
        .data = .{ .host_kind = .server, .user_id = &server.carol },
    };
    session.data.current_page = ui.RoutablePage.repoIssuesRoute("alice:open", .open, "") orelse return error.BadRoute;
    var data = try ui.Repo.Issues.emptyResult(arena.allocator(), "alice:open", "", "", "", 0, "", .open);
    data.viewer = .{ .role = .read, .email = Server.carol_author.email };
    data.repo_source = .{ .path = try server.repoPath(server.open), .repo_kind = .xit };
    var root = ui.Widget{ .repo_issues = try ui.Repo.Issues.View.init(allocator, &data, &session) };
    defer root.deinit(allocator);
    const focus = root.getFocus();
    const constraint = xit.xitui.layout.Constraint{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 100, .height = 40 },
    };
    try root.build(allocator, constraint, focus);

    // to the new tab, then type a title
    for ([_]xit.xitui.input.Key{ .arrow_right, .arrow_right, .arrow_right, .arrow_right, .arrow_down }) |key| {
        try ui.inputKey(allocator, &root, key, &session);
        try root.build(allocator, constraint, focus);
    }
    const title = session.text_inputs.get(focus.grandchild_id orelse return error.NoFocus) orelse return error.MissingInput;
    try std.testing.expectEqualStrings("title", title.options.name);
    try ui.inputKey(allocator, &root, .{ .codepoint = 'x' }, &session);
    try root.build(allocator, constraint, focus);
    // past labels and description to the submit button
    for (0..3) |_| {
        try ui.inputKey(allocator, &root, .tab, &session);
        try root.build(allocator, constraint, focus);
    }

    // the owner turns the issue tab off after the page was built
    try evt.updateRepo(io, allocator, server.users_dir, &server.alice, Server.alice_author, "open", "open", "", .public, .read, null, null);
    try ui.inputKey(allocator, &root, .enter, &session);

    const value = try title.text(allocator);
    defer allocator.free(value);
    try std.testing.expectEqualStrings("x", value);
}
