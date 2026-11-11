//! json-rpc 2.0 envelopes: reading one request from a line and writing one
//! response line.

const std = @import("std");

// a request id, echoed back exactly
pub const Id = union(enum) {
    integer: i64,
    string: []const u8,

    pub fn jsonStringify(self: Id, jw: anytype) !void {
        switch (self) {
            .integer => |integer| try jw.write(integer),
            .string => |string| try jw.write(string),
        }
    }
};

pub const ErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
};

pub const Request = struct {
    // null for a notification, which gets no response
    id: ?Id,
    method: []const u8,
    params: ?std.json.Value,
};

// a line that isn't a request, with the error it is answered with
pub const Invalid = struct {
    // the id when the line has a readable one
    id: ?Id,
    code: ErrorCode,
    message: []const u8,
};

pub const Parsed = union(enum) {
    request: Request,
    invalid: Invalid,
};

// the request `line` holds, or why it holds none. its strings point into `arena`.
pub fn parse(arena: std.mem.Allocator, line: []const u8) !Parsed {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return .{ .invalid = .{ .id = null, .code = .parse_error, .message = "parse error" } },
    };
    // batches were removed in 2025-06-18, so an array is no request either
    const object = switch (value) {
        .object => |object| object,
        else => return invalidRequest(null),
    };
    // mcp ids are strings or integers, never null
    const id: ?Id = if (object.get("id")) |raw| switch (raw) {
        .integer => |integer| .{ .integer = integer },
        .string => |string| .{ .string = string },
        else => return invalidRequest(null),
    } else null;
    const version = object.get("jsonrpc") orelse return invalidRequest(id);
    if (version != .string or !std.mem.eql(u8, version.string, "2.0")) return invalidRequest(id);
    const method = object.get("method") orelse return invalidRequest(id);
    if (method != .string) return invalidRequest(id);
    // mcp's params are always named, so an object or nothing
    const params = object.get("params");
    if (params != null and params.? != .object) return invalidRequest(id);
    return .{ .request = .{ .id = id, .method = method.string, .params = params } };
}

fn invalidRequest(id: ?Id) Parsed {
    return .{ .invalid = .{ .id = id, .code = .invalid_request, .message = "invalid request" } };
}

// write the response line for a request that succeeded with `result`
pub fn writeResult(out: *std.Io.Writer, id: Id, result: anytype) !void {
    try std.json.Stringify.value(.{ .jsonrpc = "2.0", .id = id, .result = result }, .{}, out);
    try out.writeByte('\n');
}

// write the response line for a request that failed. `id` is null when the
// request's id couldn't be read.
pub fn writeError(out: *std.Io.Writer, id: ?Id, code: ErrorCode, message: []const u8) !void {
    try std.json.Stringify.value(.{
        .jsonrpc = "2.0",
        .id = id,
        .@"error" = .{ .code = @intFromEnum(code), .message = message },
    }, .{}, out);
    try out.writeByte('\n');
}
