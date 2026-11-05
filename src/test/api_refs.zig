const std = @import("std");
const api_refs = @import("../api/refs.zig");
const api_repo = @import("../api/repo.zig");
const query_params = @import("../api/query.zig");

test "a ref selection names a branch, tag, commit or patch revision by its kind" {
    try std.testing.expectEqualDeep(api_refs.Selection{ .branch = "feature/a b" }, api_refs.Selection.parse("branch:feature/a b").?);
    try std.testing.expectEqualDeep(api_refs.Selection{ .tag = "v1.0" }, api_refs.Selection.parse("tag:v1.0").?);
    try std.testing.expectEqualDeep(api_refs.Selection{ .commit = "0123abcd" }, api_refs.Selection.parse("commit:0123abcd").?);
    try std.testing.expectEqualDeep(api_refs.Selection{ .revision = "ff00" }, api_refs.Selection.parse("revision:ff00").?);
    // only the first colon separates the kind
    try std.testing.expectEqualDeep(api_refs.Selection{ .branch = "a:b" }, api_refs.Selection.parse("branch:a:b").?);

    for ([_][]const u8{ "", "branch", "branch:", "main", ":main", "object:0123", "patchrev:ff00", "Branch:main" }) |text| {
        try std.testing.expectEqual(null, api_refs.Selection.parse(text));
    }
}

test "a ref's id is its kind and its name percent-encoded byte for byte, like a path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // ref names are bytes too: this one isn't utf-8 and holds url syntax
    const raw = "feature/caf\xe9 x+%2F&#?";
    const id = try (api_refs.Selection{ .branch = raw }).id(aa);
    try std.testing.expectEqualStrings("branch:feature/caf%E9%20x%2B%252F%26%23%3F", id);
    // sent back as the `ref` parameter, it names the same bytes
    const query = try std.fmt.allocPrint(aa, "path=docs&ref={s}", .{id});
    const parsed = api_refs.Selection.parse((try query_params.param(aa, query, "ref")).?).?;
    try std.testing.expectEqualStrings(raw, parsed.branch);

    try std.testing.expectEqualStrings("tag:v1.0", try (api_refs.Selection{ .tag = "v1.0" }).id(aa));
    try std.testing.expectEqualStrings("commit:0123abcd", try (api_refs.Selection{ .commit = "0123abcd" }).id(aa));
    try std.testing.expectEqualStrings("revision:ff00", try (api_refs.Selection{ .revision = "ff00" }).id(aa));
}

test "the branch and tag lists are routes of a repo" {
    try std.testing.expectEqual(.branches, api_repo.route("/api/v1/repos/bobby/linux/branches").?.resource);
    try std.testing.expectEqual(.tags, api_repo.route("/api/v1/repos/bobby/linux/tags").?.resource);
    try std.testing.expectEqual(api_repo.Route{ .target = .local, .resource = .branches }, api_repo.route("/api/v1/repo/branches").?);
    try std.testing.expectEqual(api_repo.Route{ .target = .local, .resource = .tags }, api_repo.route("/api/v1/repo/tags").?);
    for ([_][]const u8{ "/api/v1/repos/bobby/linux/refs", "/api/v1/repos/bobby/linux/overview", "/api/v1/repos/bobby/linux/tags/x", "/api/v1/repo/overview" }) |path| {
        try std.testing.expectEqual(null, api_repo.route(path));
    }
}
