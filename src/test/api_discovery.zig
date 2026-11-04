const std = @import("std");
const query = @import("../api/query.zig");
const api_md = @import("../api/markdown.zig");
const md = @import("../markdown.zig");

const limits: query.Page.Limits = .{ .default = 20, .max = 100 };

fn parsePage(arena: std.mem.Allocator, text: []const u8) !query.Page {
    return switch (try query.Page.parse(arena, text, limits)) {
        .ok => |page| page,
        .invalid => error.Invalid,
    };
}

fn rejectedField(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    return switch (try query.Page.parse(arena, text, limits)) {
        .ok => error.Accepted,
        .invalid => |err| blk: {
            try std.testing.expectEqual(.validation, err.code);
            try std.testing.expectEqual(1, err.field_errors.len);
            break :blk err.field_errors[0].field;
        },
    };
}

test "a page starts at the first result with the route's default size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(query.Page{ .start = 0, .limit = 20 }, try parsePage(arena.allocator(), ""));
    try std.testing.expectEqual(query.Page{ .start = 0, .limit = 20 }, try parsePage(arena.allocator(), "search=al"));
}

test "a cursor handed out for a page resumes there, and page_size is capped at the route's maximum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const cursor = (try query.Page.nextCursor(aa, 40)).?;
    const resumed = try parsePage(aa, try std.fmt.allocPrint(aa, "cursor={s}&page_size=5", .{cursor}));
    try std.testing.expectEqual(query.Page{ .start = 40, .limit = 5 }, resumed);
    try std.testing.expectEqual(@as(usize, 100), (try parsePage(aa, "page_size=1000")).limit);
    try std.testing.expectEqual(null, try query.Page.nextCursor(aa, null));
}

test "unusable paging parameters are rejected by name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    for ([_][2][]const u8{
        .{ "page_size=0", "page_size" },
        .{ "page_size=-1", "page_size" },
        .{ "page_size=ten", "page_size" },
        .{ "page_size=", "page_size" },
        .{ "cursor=abc", "cursor" },
        .{ "cursor=", "cursor" },
        .{ "cursor=99999999999999999999999", "cursor" },
        .{ "cursor=%zz", "cursor" },
    }) |case| try std.testing.expectEqualStrings(case[1], try rejectedField(aa, case[0]));
}

test "query parameters decode form encoding and take the first occurrence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    try std.testing.expectEqualStrings("a b/c", (try query.param(aa, "x=1&search=a+b%2Fc&search=other", "search")).?);
    try std.testing.expectEqualStrings("", (try query.param(aa, "search", "search")).?);
    try std.testing.expectEqual(null, try query.param(aa, "searched=1", "search"));
    try std.testing.expectError(error.InvalidPercentEncoding, query.param(aa, "search=%4", "search"));
}

test "markdown blocks serialize with a kind on every variant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try md.parseText(arena.allocator(), "## Hi\n\nsee [docs](https://example.test) and `x`\n\n- [x] done\n\n---");
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(api_md.Blocks{ .blocks = doc.blocks }, .{}, &out.writer);
    try std.testing.expectEqualStrings(
        \\[{"kind":"heading","level":2,"center":false,"inlines":[{"text":"Hi","bold":false,"italic":false,"strike":false,"code":false,"link":null}]},
    ++
        \\{"kind":"paragraph","center":false,"pre":false,"inlines":[{"text":"see ","bold":false,"italic":false,"strike":false,"code":false,"link":null},{"text":"docs","bold":false,"italic":false,"strike":false,"code":false,"link":"https://example.test"},{"text":" and ","bold":false,"italic":false,"strike":false,"code":false,"link":null},{"text":"x","bold":false,"italic":false,"strike":false,"code":true,"link":null}]},
    ++
        \\{"kind":"list","ordered":false,"start":0,"items":[{"task":true,"blocks":[{"kind":"paragraph","center":false,"pre":false,"inlines":[{"text":"done","bold":false,"italic":false,"strike":false,"code":false,"link":null}]}]}]},
    ++
        \\{"kind":"rule"}]
    , out.written());
}
