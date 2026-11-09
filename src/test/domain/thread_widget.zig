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

const alices: fixture.Id = @splat(0xa1);
const alices_hex = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";

test "domain: a terminal edit form saves through EditThread and keeps a blank title's fields" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, alices);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var session = ui.Session{
        .arena = &arena,
        .page_arena = &arena,
        .io = io,
        .is_terminal = true,
        .admin_repo = &server.admin,
        .users_dir = server.users_dir,
        .data = .{ .host_kind = .server, .user_id = &server.bob },
    };
    const route = ui.RoutablePage.repoThreadEditRoute(.issue, "alice:open", alices_hex) orelse return error.BadRoute;
    session.data.current_page = route;
    var data = blk: {
        var any_repo = try xit.repo.AnyRepo(.xit, .{}).open(io, allocator, .{ .path = try server.repoPath(server.open) });
        defer any_repo.deinit(io, allocator);
        break :blk switch (any_repo) {
            inline else => |*repo| try ui.Repo.Issues.init(.xit, repo.self_repo_opts, &arena, repo, io, session.haxy_moment, "alice:open", "", alices_hex, "", 0, "", .edit, .{ .role = .write, .email = Server.bob_author.email }),
        };
    };
    data.repo_source = .{ .path = try server.repoPath(server.open), .repo_kind = .xit };
    var root = ui.Widget{ .repo_issues = try ui.Repo.Issues.View.init(allocator, &data, &session) };
    defer root.deinit(allocator);
    const focus = root.getFocus();
    const constraint = xit.xitui.layout.Constraint{
        .min_size = .{ .width = null, .height = null },
        .max_size = .{ .width = 100, .height = 40 },
    };
    try root.build(allocator, constraint, focus);

    // down into the title, which the form fills with the issue's, and blank it
    try ui.inputKey(allocator, &root, .arrow_down, &session);
    try root.build(allocator, constraint, focus);
    const title = session.text_inputs.get(focus.grandchild_id orelse return error.NoFocus) orelse return error.MissingInput;
    try std.testing.expectEqualStrings("title", title.options.name);
    title.clear(allocator);
    // a label, then past the description to the submit button
    try ui.inputKey(allocator, &root, .tab, &session);
    try ui.inputKey(allocator, &root, .{ .codepoint = 'z' }, &session);
    try root.build(allocator, constraint, focus);
    for (0..2) |_| {
        try ui.inputKey(allocator, &root, .tab, &session);
        try root.build(allocator, constraint, focus);
    }
    try ui.inputKey(allocator, &root, .enter, &session);

    // a blank title stays on the form with what was typed
    try std.testing.expectEqual(null, session.next_page);
    const feedback = session.formFeedback(.issue) orelse return error.TestExpectedFeedback;
    try std.testing.expectEqual(.required_title, feedback.failure);
    const fields = feedback.fields orelse return error.TestExpectedFields;
    try std.testing.expectEqualStrings("", fields.title);
    try std.testing.expectEqualStrings("z", fields.labels);

    // a title saves the edit and goes back to the issue in its list
    try title.setContent(allocator, "renamed");
    try ui.inputKey(allocator, &root, .enter, &session);
    const next = session.next_page orelse return error.TestExpectedNavigation;
    try std.testing.expect(next.eql(ui.RoutablePage.repoIssuesRoute("alice:open", .open, alices_hex) orelse return error.BadRoute));
    var ctx = try server.ctx(&arena, server.bob);
    const entry = try (hx.domain.GetIssue{ .repo = "alice:open", .id = alices_hex }).run(&ctx);
    try std.testing.expectEqualStrings("renamed", entry.record.event.title);
    try std.testing.expectEqualStrings("z", entry.record.event.labels);
}
