const std = @import("std");
const api = @import("../api.zig");

fn expectJson(expected: []const u8, comptime write: anytype, args: anytype) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try @call(.auto, write, .{&out.writer} ++ args);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "error envelope carries a stable code and a user-facing message" {
    try expectJson(
        \\{"error":{"code":"not_found","message":"No API route matches \"/api/v1/nope\"."}}
    , api.writeError, .{api.Error{ .code = .not_found, .message = "No API route matches \"/api/v1/nope\"." }});
}

test "validation errors list each field beside its own message, in order" {
    try expectJson(
        \\{"error":{"code":"validation","message":"Check the highlighted fields.","field_errors":[{"field":"name","message":"Name is required."},{"field":"email","message":"Email is invalid."}]}}
    , api.writeError, .{api.Error{
        .code = .validation,
        .message = "Check the highlighted fields.",
        .field_errors = &.{
            .{ .field = "name", .message = "Name is required." },
            .{ .field = "email", .message = "Email is invalid." },
        },
    }});
}

test "each error code has a conventional HTTP status" {
    const expected = [_]struct { api.ErrorCode, std.http.Status }{
        .{ .validation, .bad_request },
        .{ .unauthenticated, .unauthorized },
        .{ .forbidden, .forbidden },
        .{ .not_found, .not_found },
        .{ .conflict, .conflict },
        .{ .unsupported, .method_not_allowed },
        .{ .internal, .internal_server_error },
    };
    for (expected) |pair| try std.testing.expectEqual(pair[1], pair[0].status());
}

test "status names the service, API version and host mode" {
    try expectJson(
        \\{"service":"haxy","api_version":1,"mode":"server"}
    , api.writeStatus, .{.server});
    try expectJson(
        \\{"service":"haxy","api_version":1,"mode":"local"}
    , api.writeStatus, .{.local});
}

test "a page with more results carries an opaque cursor and a lower-bound count" {
    try expectJson(
        \\{"items":["a","b"],"page":{"has_more":true,"next_cursor":"b3BhcXVl","count":{"kind":"at_least","value":100}}}
    , api.writePage, .{ [_][]const u8{ "a", "b" }, api.Page{ .next_cursor = "b3BhcXVl", .count = .{ .at_least = 100 } } });
}

test "the last page has no cursor and may report an exact or unknown count" {
    try expectJson(
        \\{"items":[],"page":{"has_more":false,"next_cursor":null,"count":{"kind":"exact","value":0}}}
    , api.writePage, .{ [_]u32{}, api.Page{ .next_cursor = null, .count = .{ .exact = 0 } } });
    try expectJson(
        \\{"items":[{"id":"7"}],"page":{"has_more":false,"next_cursor":null,"count":{"kind":"unknown"}}}
    , api.writePage, .{ [_]struct { id: []const u8 }{.{ .id = "7" }}, api.Page{ .next_cursor = null, .count = .unknown } });
}
