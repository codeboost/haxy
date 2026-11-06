const std = @import("std");
const api_drafts = @import("../api/patch_drafts.zig");
const evt = @import("../event.zig");
const ui = @import("../ui.zig");

const id = "0123456789abcdef0123456789abcdef";

fn data(ssh: ?[]const u8) ui.Session.Data {
    return .{ .host_kind = .server, .git_http_url = "http://haxy.test", .git_ssh_url = ssh, .git_ssh_prefix = if (ssh != null) "GIT_SSH_COMMAND='ssh -p 2222' " else "" };
}

test "a fork's push, clone and merge commands name its ssh url and carry the host's ssh prefix, as the TUI shows them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const url = "ssh://haxy.test:2222/alice:linux+" ++ id;
    const prefix = "GIT_SSH_COMMAND='ssh -p 2222' ";

    const commands = try ui.widget.forkCommands(aa, data("ssh://haxy.test:2222"), "alice:linux", id, .{});
    try std.testing.expectEqual(3, commands.len);
    try std.testing.expectEqual(.push, commands[0].action);
    try std.testing.expectEqualStrings(url, commands[0].url);
    try std.testing.expectEqualStrings("git push " ++ url ++ " HEAD:patch", commands[0].text);
    try std.testing.expectEqualStrings(prefix ++ "git push " ++ url ++ " HEAD:patch", commands[0].command);
    try std.testing.expectEqual(.clone, commands[1].action);
    try std.testing.expectEqualStrings(prefix ++ "git clone " ++ url, commands[1].command);
    try std.testing.expectEqual(.merge, commands[2].action);
    try std.testing.expectEqualStrings(prefix ++ "git fetch '" ++ url ++ "' refs/heads/patch && git merge FETCH_HEAD", commands[2].command);

    // a fork whose target is gone can't be pushed to, only fetched
    const orphaned = try ui.widget.forkCommands(aa, data("ssh://haxy.test:2222"), "alice:linux", id, .{ .target_deleted = true });
    try std.testing.expectEqual(2, orphaned.len);
    try std.testing.expectEqual(.clone, orphaned[0].action);
    try std.testing.expectEqual(.merge, orphaned[1].action);

    // forks are reached over ssh only
    try std.testing.expectEqual(0, (try ui.widget.forkCommands(aa, data(null), "alice:linux", id, .{})).len);
}

test "draft routes name the viewer's drafts, one draft, or its publication, under a repo's patches" {
    const list = api_drafts.route("/api/v1/repos/bobby/linux/patches/drafts").?;
    try std.testing.expectEqualStrings("bobby", list.target.server.owner);
    try std.testing.expectEqualStrings("linux", list.target.server.name);
    try std.testing.expectEqual(.list, std.meta.activeTag(list.resource));
    try std.testing.expectEqualStrings(id, api_drafts.route("/api/v1/repos/bobby/linux/patches/drafts/" ++ id).?.resource.draft);
    try std.testing.expectEqualStrings(id, api_drafts.route("/api/v1/repos/bobby/linux/patches/drafts/" ++ id ++ "/publish").?.resource.publish);
    // a local host answers its own paths, with unsupported
    try std.testing.expectEqual(.local, std.meta.activeTag(api_drafts.route("/api/v1/repo/patches/drafts").?.target));

    for ([_][]const u8{
        "/api/v1/repos/bobby/linux/patches",
        "/api/v1/repos/bobby/linux/patches/" ++ id,
        "/api/v1/repos/bobby/linux/patches/draftsx",
        "/api/v1/repos/bobby/linux/patches/drafts/",
        "/api/v1/repos/bobby/linux/patches/drafts//publish",
        "/api/v1/repos/bobby/linux/patches/drafts/" ++ id ++ "/edit",
        "/api/v1/repos/bobby/linux/patches/drafts/" ++ id ++ "/publish/x",
        "/api/v1/repos/bobby/patches/drafts",
        "/api/v1/repos//linux/patches/drafts",
    }) |path| {
        try std.testing.expectEqual(null, api_drafts.route(path));
    }
}
