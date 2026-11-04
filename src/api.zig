//! shared shapes for the JSON API under /api/. see haxy-hub's
//! docs/api-conventions.md for the contract these helpers implement.

const std = @import("std");
const evt = @import("./event.zig");

/// bumped only for breaking changes; clients refuse versions they don't know
pub const version = 1;

/// stable, machine-readable error codes. clients switch on these, never on
/// the message or the HTTP status.
pub const ErrorCode = enum {
    validation,
    unauthenticated,
    forbidden,
    // also used for resources the viewer may not know exist
    not_found,
    conflict,
    // the method or operation isn't available here, e.g. on a local host
    unsupported,
    internal,

    pub fn status(self: ErrorCode) std.http.Status {
        return switch (self) {
            .validation => .bad_request,
            .unauthenticated => .unauthorized,
            .forbidden => .forbidden,
            .not_found => .not_found,
            .conflict => .conflict,
            .unsupported => .method_not_allowed,
            .internal => .internal_server_error,
        };
    }
};

/// one rejected request field. errors are sent as a JSON object mapping each
/// field's name (as the client sent it) to its message, so a field appears
/// at most once.
pub const FieldError = struct {
    // the request field's name, as the client sent it
    field: []const u8,
    message: []const u8,
};

pub const Error = struct {
    code: ErrorCode,
    // user-facing; never includes paths, tokens or other private detail
    message: []const u8,
    // omitted from the JSON when empty
    field_errors: []const FieldError = &.{},
};

/// writes `{"error":{"code":...,"message":...}}`
pub fn writeError(writer: *std.Io.Writer, err: Error) std.Io.Writer.Error!void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try json.objectField("error");
    try json.beginObject();
    try json.objectField("code");
    try json.write(@tagName(err.code));
    try json.objectField("message");
    try json.write(err.message);
    if (err.field_errors.len > 0) {
        try json.objectField("field_errors");
        try json.beginObject();
        for (err.field_errors) |field_error| {
            try json.objectField(field_error.field);
            try json.write(field_error.message);
        }
        try json.endObject();
    }
    try json.endObject();
    try json.endObject();
}

/// the body of GET /api/v1/status
pub fn writeStatus(writer: *std.Io.Writer, mode: evt.HostKind) std.Io.Writer.Error!void {
    try std.json.Stringify.value(.{ .service = "haxy", .api_version = version, .mode = mode }, .{}, writer);
}

/// how many results a whole listing has, as far as the backend knows
pub const Count = union(enum) {
    exact: u64,
    // the listing stopped counting here; there may be more
    at_least: u64,
    unknown,

    pub fn jsonStringify(self: Count, json: *std.json.Stringify) std.Io.Writer.Error!void {
        try json.beginObject();
        try json.objectField("kind");
        try json.write(@tagName(self));
        switch (self) {
            .exact, .at_least => |value| {
                try json.objectField("value");
                try json.write(value);
            },
            .unknown => {},
        }
        try json.endObject();
    }
};

pub const Page = struct {
    // opaque to clients; null on the last page
    next_cursor: ?[]const u8,
    count: Count,
};

/// writes `{"items":[...],"page":{"has_more":...,"next_cursor":...,"count":...}}`
pub fn writePage(writer: *std.Io.Writer, items: anytype, page: Page) std.Io.Writer.Error!void {
    try std.json.Stringify.value(.{
        .items = items,
        .page = .{
            .has_more = page.next_cursor != null,
            .next_cursor = page.next_cursor,
            .count = page.count,
        },
    }, .{}, writer);
}

pub const RespondOptions = struct {
    // defaults to 200 for bodies and to the code's status for errors
    status: ?std.http.Status = null,
    // the methods a route accepts, sent with a 405
    allow: ?[]const u8 = null,
};

/// sends an already-encoded JSON body with the API's headers. API responses
/// are viewer-specific, so they are never cached.
pub fn respondJson(request: *std.http.Server.Request, body: []const u8, options: RespondOptions) !void {
    var headers: [3]std.http.Header = .{
        .{ .name = "content-type", .value = "application/json; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
        undefined,
    };
    var header_count: usize = 2;
    if (options.allow) |allow| {
        headers[2] = .{ .name = "allow", .value = allow };
        header_count = 3;
    }
    try request.respond(body, .{ .status = options.status orelse .ok, .extra_headers = headers[0..header_count] });
}

/// sends an error envelope, with the code's conventional status unless overridden
pub fn respondError(request: *std.http.Server.Request, allocator: std.mem.Allocator, err: Error, options: RespondOptions) !void {
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    try writeError(&body.writer, err);
    var with_status = options;
    with_status.status = options.status orelse err.code.status();
    try respondJson(request, body.written(), with_status);
}
