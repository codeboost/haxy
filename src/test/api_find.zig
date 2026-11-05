const std = @import("std");
const api_repo = @import("../api/repo.zig");
const ui = @import("../ui.zig");

const Files = ui.Repo.Files;

test "the file finder is a route of a repo" {
    try std.testing.expectEqual(.find, api_repo.route("/api/v1/repos/bobby/linux/find").?.resource);
    try std.testing.expectEqual(api_repo.Route{ .target = .local, .resource = .find }, api_repo.route("/api/v1/repo/find").?);
    for ([_][]const u8{ "/api/v1/repos/bobby/linux/find/x", "/api/v1/repo/find/x", "/api/v1/repos/bobby/linux/files/find" }) |path| {
        try std.testing.expectEqual(null, api_repo.route(path));
    }
}

test "only an xit repo's branches can have a file index" {
    try std.testing.expectEqual(null, Files.indexable(.xit, .branch));
    try std.testing.expectEqual(.ref, Files.indexable(.xit, .tag).?);
    // a commit and a patch revision are both read as an object
    try std.testing.expectEqual(.ref, Files.indexable(.xit, .object).?);
    for ([_]ui.RoutablePage.RefOrOid{ .branch, .tag, .object }) |kind| {
        try std.testing.expectEqual(.repository, Files.indexable(.git, kind).?);
    }
}
