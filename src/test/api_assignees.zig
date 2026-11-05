const std = @import("std");
const api_assignees = @import("../api/assignees.zig");

test "assignee routes name an issue's assignees, or one assignment of it, on a server or the local repo" {
    const all = api_assignees.route("/api/v1/repos/bobby/linux/issues/0123456789abcdef0123456789abcdef/assignees").?;
    try std.testing.expectEqualStrings("bobby", all.issue.target.server.owner);
    try std.testing.expectEqualStrings("linux", all.issue.target.server.name);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", all.issue.resource.thread);
    try std.testing.expectEqual(null, all.assignment);

    const one = api_assignees.route("/api/v1/repo/issues/abc/assignees/fedcba9876543210fedcba9876543210").?;
    try std.testing.expectEqual(.local, std.meta.activeTag(one.issue.target));
    try std.testing.expectEqualStrings("abc", one.issue.resource.thread);
    try std.testing.expectEqualStrings("fedcba9876543210fedcba9876543210", one.assignment.?);

    for ([_][]const u8{
        "/api/v1/repos/bobby/linux/issues/abc",
        "/api/v1/repos/bobby/linux/issues/assignees",
        "/api/v1/repos/bobby/linux/issues/labels/assignees",
        "/api/v1/repos/bobby/linux/issues/abc/assignees/",
        "/api/v1/repos/bobby/linux/issues/abc/assignees/x/y",
        "/api/v1/repos/bobby/linux/issues/abc/status/assignees",
        "/api/v1/repos/bobby/linux/issues/abc/assigneesx",
        "/api/v1/repo/issues//assignees",
        "/api/v1/repo/discussions/abc/assignees",
    }) |path| {
        try std.testing.expectEqual(null, api_assignees.route(path));
    }
}
