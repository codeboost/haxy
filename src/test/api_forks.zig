const std = @import("std");
const api_discovery = @import("../api/discovery.zig");
const api_forks = @import("../api/forks.zig");

const id = "0123456789abcdef0123456789abcdef";
const base = "/api/v1/forks/bobby/parser/" ++ id;

test "fork routes name a fork by its forker, the repo it was made from and its id, then its views" {
    const fork = api_forks.route(base).?;
    try std.testing.expectEqualStrings("bobby", fork.forker);
    try std.testing.expectEqualStrings("parser", fork.name);
    try std.testing.expectEqualStrings(id, fork.id);
    try std.testing.expectEqual(.fork, fork.resource);

    try std.testing.expectEqual(.files, api_forks.route(base ++ "/files").?.resource);
    try std.testing.expectEqual(.branches, api_forks.route(base ++ "/branches").?.resource);
    try std.testing.expectEqual(.tags, api_forks.route(base ++ "/tags").?.resource);
    try std.testing.expectEqual(.find, api_forks.route(base ++ "/find").?.resource);
    try std.testing.expectEqual(.diff, api_forks.route(base ++ "/diff").?.resource);
    try std.testing.expectEqual(.list, api_forks.route(base ++ "/commits").?.resource.commits);
    try std.testing.expectEqualStrings("abc", api_forks.route(base ++ "/commits/abc").?.resource.commits.commit);
    try std.testing.expectEqualStrings("abc", api_forks.route(base ++ "/commits/abc/diff").?.resource.commits.diff);

    for ([_][]const u8{
        "/api/v1/forks/bobby/parser",
        "/api/v1/forks/bobby//" ++ id,
        base ++ "/",
        base ++ "/issues",
        base ++ "/files/more",
        base ++ "/commits/",
        base ++ "/commits/abc/stats",
    }) |path| try std.testing.expectEqual(null, api_forks.route(path));
}

test "a user's forks hang off the user, beside their repos" {
    try std.testing.expectEqualStrings("bobby", api_discovery.route("/api/v1/users/bobby/forks").?.user_forks);
    try std.testing.expectEqualStrings("bobby", api_discovery.route("/api/v1/users/bobby/repos").?.user_repos);
    try std.testing.expectEqual(null, api_discovery.route("/api/v1/users/bobby/stars"));
}
