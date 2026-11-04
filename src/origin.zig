//! the same-origin rule every state-changing browser request passes: when a
//! request carries an `Origin` header, it must name the request's own `Host`.
//! the JSON API (api/session.zig's guardWrite) adds a CSRF token on top; the
//! server-rendered HTML forms rely on this check alone. see haxy-hub's
//! docs/api-conventions.md (Security notes) for the rationale.

const std = @import("std");

/// whether `origin` (an `Origin` header: scheme://host[:port]) names the
/// server that `host` (the request's `Host` header) addresses. a default port
/// matches its absence for its own scheme; hosts compare case-insensitively.
/// the opaque origin "null", a missing Host and anything malformed never match.
pub fn sameOrigin(origin: []const u8, host_maybe: ?[]const u8) bool {
    const host = host_maybe orelse return false;
    const separator = std.mem.indexOf(u8, origin, "://") orelse return false;
    const scheme = origin[0..separator];
    const default_port = if (std.ascii.eqlIgnoreCase(scheme, "http"))
        ":80"
    else if (std.ascii.eqlIgnoreCase(scheme, "https"))
        ":443"
    else
        return false;
    const authority = origin[separator + 3 ..];
    // an origin always names a host, even when the Host header doesn't
    if (authority.len == 0 or authority[0] == ':' or std.mem.indexOfAny(u8, authority, "/?#@") != null) return false;
    return std.ascii.eqlIgnoreCase(withoutPort(authority, default_port), withoutPort(host, default_port));
}

fn withoutPort(authority: []const u8, default_port: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, authority, default_port)) authority[0 .. authority.len - default_port.len] else authority;
}

pub const FormWrite = struct {
    method: std.http.Method,
    // the Origin header, when the client sent one
    origin: ?[]const u8,
    // the Host header
    host: ?[]const u8,
};

/// whether a request to one of the HTML (non-API) routes may reach its
/// handler: reads always may, and so may a write without an Origin (a
/// non-browser client); a browser write must come from this host.
pub fn formWriteAllowed(input: FormWrite) bool {
    if (input.method == .GET or input.method == .HEAD) return true;
    const origin = input.origin orelse return true;
    return sameOrigin(origin, input.host);
}

/// the page a refused form write gets. it is static, so nothing from the
/// request is echoed back.
pub const refused_page =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head><meta charset="utf-8"><title>HAXY: change refused</title></head>
    \\<body>
    \\<h1>Change refused</h1>
    \\<p>Haxy only accepts changes sent from its own site. Nothing was changed.</p>
    \\<p>If you were using Haxy, go back to <a href="/">the home page</a>, reload it and try again.</p>
    \\</body>
    \\</html>
    \\
;

/// the choke point for Haxy's HTML (non-API) routes: a state-changing
/// request that names a foreign origin is refused before any form handler
/// runs, so new form routes are covered without opting in. git's smart HTTP
/// is dispatched before this, and the API has its own guard. returns false
/// once the refusal has been sent.
pub fn guardForm(request: *std.http.Server.Request) !bool {
    if (formWriteAllowed(.{
        .method = request.head.method,
        .origin = findHeader(request, "origin"),
        .host = findHeader(request, "host"),
    })) return true;
    // the body goes unread, so the connection closes
    try request.respond(refused_page, .{
        .status = .forbidden,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
    });
    return false;
}

fn findHeader(request: *std.http.Server.Request, name: []const u8) ?[]const u8 {
    var iter = request.iterateHeaders();
    while (iter.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}
