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
    // a write failed the same-origin or CSRF token check. distinct from
    // forbidden so clients can refresh their token rather than report a
    // permission problem.
    csrf,
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
            .forbidden, .csrf => .forbidden,
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
    // false closes the connection, e.g. when the request body goes unread
    keep_alive: bool = true,
    // set-cookie values; null entries are skipped
    set_cookies: []const ?[]const u8 = &.{},
};

/// sends an already-encoded JSON body with the API's headers. API responses
/// are viewer-specific, so they are never cached.
pub fn respondJson(request: *std.http.Server.Request, body: []const u8, options: RespondOptions) !void {
    const max_cookies = 4;
    std.debug.assert(options.set_cookies.len <= max_cookies);
    var headers: [3 + max_cookies]std.http.Header = undefined;
    headers[0] = .{ .name = "content-type", .value = "application/json; charset=utf-8" };
    headers[1] = .{ .name = "cache-control", .value = "no-store" };
    var header_count: usize = 2;
    if (options.allow) |allow| {
        headers[header_count] = .{ .name = "allow", .value = allow };
        header_count += 1;
    }
    for (options.set_cookies) |cookie_maybe| if (cookie_maybe) |cookie| {
        headers[header_count] = .{ .name = "set-cookie", .value = cookie };
        header_count += 1;
    };
    // a client still waiting for "100 Continue" hasn't sent the body this
    // response leaves unread. keeping the connection would make std try to
    // discard that body, soliciting it with a still-buffered 100 Continue
    // and waiting forever, so close instead.
    const keep_alive = options.keep_alive and request.head.expect == null;
    try request.respond(body, .{ .status = options.status orelse .ok, .keep_alive = keep_alive, .extra_headers = headers[0..header_count] });
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

/// an instant as the API writes it: RFC 3339 in UTC with whole seconds and a
/// `Z` suffix, e.g. "2026-11-04T14:03:00Z". haxy stores unix seconds.
pub const Instant = struct {
    seconds: u64,

    pub const max_len = "YYYY-MM-DDTHH:MM:SSZ".len;
    // 9999-12-31T23:59:59Z: a commit can claim any time, and RFC 3339 years
    // have four digits
    const latest = 253402300799;

    /// `seconds` formatted into `buffer`, past the year 9999 as its last second
    pub fn format(buffer: *[max_len]u8, seconds: u64) []const u8 {
        const epoch: std.time.epoch.EpochSeconds = .{ .secs = @min(seconds, latest) };
        const year_day = epoch.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day = epoch.getDaySeconds();
        return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day.getHoursIntoDay(),
            day.getMinutesIntoHour(),
            day.getSecondsIntoMinute(),
        }) catch unreachable;
    }

    pub fn jsonStringify(self: Instant, json: *std.json.Stringify) std.Io.Writer.Error!void {
        var buffer: [max_len]u8 = undefined;
        try json.write(format(&buffer, self.seconds));
    }
};
