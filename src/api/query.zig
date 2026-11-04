//! reading an API request's query string: single parameters, and the
//! `cursor` + `page_size` pair every paginated route accepts.

const std = @import("std");
const api = @import("../api.zig");

/// the decoded value of the first `key` parameter in `query` (still encoded,
/// without the "?"), or null when absent. `+` decodes as a space.
pub fn param(arena: std.mem.Allocator, query: []const u8, key: []const u8) error{ OutOfMemory, InvalidPercentEncoding }!?[]const u8 {
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        if (!std.mem.eql(u8, pair[0..eq], key)) continue;
        const encoded = if (eq < pair.len) pair[eq + 1 ..] else "";
        const out = try arena.alloc(u8, encoded.len);
        var len: usize = 0;
        var i: usize = 0;
        while (i < encoded.len) : (i += 1) {
            out[len] = switch (encoded[i]) {
                '+' => ' ',
                '%' => blk: {
                    if (i + 2 >= encoded.len) return error.InvalidPercentEncoding;
                    const hi = std.fmt.charToDigit(encoded[i + 1], 16) catch return error.InvalidPercentEncoding;
                    const lo = std.fmt.charToDigit(encoded[i + 2], 16) catch return error.InvalidPercentEncoding;
                    i += 2;
                    break :blk hi * 16 + lo;
                },
                else => |c| c,
            };
            len += 1;
        }
        return out[0..len];
    }
    return null;
}

/// a paginated route's position and size, as the client asked for them
pub const Page = struct {
    // how many results precede this page. the cursor clients see is this
    // offset as text, which they must treat as opaque.
    start: usize,
    limit: usize,

    pub const Limits = struct {
        default: usize,
        max: usize,
    };

    /// reads `cursor` and `page_size`. a `page_size` above the route's
    /// maximum is lowered to it.
    pub fn parse(arena: std.mem.Allocator, query: []const u8, limits: Limits) !union(enum) { ok: Page, invalid: api.Error } {
        var page: Page = .{ .start = 0, .limit = limits.default };
        const cursor = param(arena, query, "cursor") catch |err| switch (err) {
            error.InvalidPercentEncoding => return .{ .invalid = invalid("cursor", "This cursor isn't one Haxy gave out; start from the first page.") },
            else => |e| return e,
        };
        if (cursor) |text| {
            page.start = parseCount(text) orelse
                return .{ .invalid = invalid("cursor", "This cursor isn't one Haxy gave out; start from the first page.") };
        }
        page.limit = switch (try size(arena, query, limits)) {
            .ok => |limit| limit,
            .invalid => |err| return .{ .invalid = err },
        };
        return .{ .ok = page };
    }

    /// reads `page_size` alone, for a route whose cursor isn't an offset
    pub fn size(arena: std.mem.Allocator, query: []const u8, limits: Limits) !union(enum) { ok: usize, invalid: api.Error } {
        const text = param(arena, query, "page_size") catch |err| switch (err) {
            error.InvalidPercentEncoding => return .{ .invalid = invalid("page_size", "The page size must be a positive whole number.") },
            else => |e| return e,
        } orelse return .{ .ok = limits.default };
        const value = parseCount(text) orelse 0;
        if (value == 0) return .{ .invalid = invalid("page_size", "The page size must be a positive whole number.") };
        return .{ .ok = @min(value, limits.max) };
    }

    /// the cursor for the page starting at `next_start`, or null without one
    pub fn nextCursor(arena: std.mem.Allocator, next_start: ?usize) !?[]const u8 {
        const start = next_start orelse return null;
        return try std.fmt.allocPrint(arena, "{d}", .{start});
    }
};

// bounded so a forged cursor can't overflow position arithmetic
const max_count = std.math.maxInt(u32);

fn parseCount(text: []const u8) ?usize {
    if (text.len == 0) return null;
    for (text) |c| if (!std.ascii.isDigit(c)) return null;
    const value = std.fmt.parseInt(usize, text, 10) catch return null;
    return if (value <= max_count) value else null;
}

fn invalid(comptime field: []const u8, comptime message: []const u8) api.Error {
    return .{
        .code = .validation,
        .message = "Check the paging parameters.",
        .field_errors = &.{.{ .field = field, .message = message }},
    };
}
