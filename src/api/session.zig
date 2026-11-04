//! the session API (`/api/v1/session`) and the same-origin + CSRF check every
//! state-changing API request passes. see haxy-hub's docs/api-conventions.md
//! (Security notes) for the strategy and its rationale.
//!
//! sessions are the web UI's own: the HttpOnly `haxy_session` cookie backed by
//! web.SessionStore, minted only after evt.User.verifyCredentials, the check
//! the TUI and the login form share.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const api = @import("../api.zig");
const evt = @import("../event.zig");
const ui = @import("../ui.zig");
const web = @import("../web.zig");

pub const path = "/api/v1/session";

/// the request header a write carries its CSRF token in. a custom header
/// can't be sent cross-origin without a CORS preflight, which haxy never
/// approves.
pub const csrf_header = "x-haxy-csrf";

/// the HttpOnly cookie holding the random nonce a browser's CSRF token is
/// bound to. it is rotated on login and logout.
pub const csrf_cookie = "haxy_csrf";
// strict, so no cross-site request carries it; the same lifetime as the
// session cookie so a remembered session keeps a working token.
const csrf_cookie_fmt = csrf_cookie ++ "={s}; Path=/; HttpOnly; SameSite=Strict; Max-Age=34560000";
const session_cookie_clear = web.cookie_name ++ "=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0";

const nonce_size = 16;
pub const nonce_hex_len = nonce_size * 2;
pub const token_hex_len = std.crypto.auth.hmac.sha2.HmacSha256.mac_length * 2;

// --- CSRF -------------------------------------------------------------------

/// the CSRF token for a browser's nonce: a MAC keyed by the nonce, so it is
/// unforgeable without the HttpOnly cookie, never reveals it, and needs no
/// server-side state (it survives restarts with the cookie).
pub fn csrfToken(nonce: []const u8) [token_hex_len]u8 {
    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&mac, "haxy-csrf-v1", nonce);
    return std.fmt.bytesToHex(mac, .lower);
}

pub const WriteInput = struct {
    // the Origin header, when the client sent one (browsers always do on
    // non-GET requests)
    origin: ?[]const u8,
    // the Host header, which the Vite proxy preserves
    host: ?[]const u8,
    // the x-haxy-csrf header
    token: ?[]const u8,
    // the haxy_csrf cookie
    nonce: ?[]const u8,
};

pub const WriteCheck = enum { allowed, foreign_origin, missing_token, bad_token };

/// whether a state-changing request may proceed: an Origin, when present, must
/// be this host's own, and the token must be the one bound to the request's
/// nonce cookie.
pub fn checkWrite(input: WriteInput) WriteCheck {
    if (input.origin) |origin| if (!sameOrigin(origin, input.host)) return .foreign_origin;
    const token = input.token orelse return .missing_token;
    if (token.len == 0) return .missing_token;
    const nonce = input.nonce orelse return .bad_token;
    if (!isNonce(nonce) or token.len != token_hex_len) return .bad_token;
    const expected = csrfToken(nonce);
    return if (std.crypto.timing_safe.eql([token_hex_len]u8, expected, token[0..token_hex_len].*)) .allowed else .bad_token;
}

// whether `origin` (scheme://host[:port]) names the server `host` (the Host
// header) addresses. a default port matches its absence for its own scheme.
fn sameOrigin(origin: []const u8, host_maybe: ?[]const u8) bool {
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
    if (authority.len == 0 or std.mem.indexOfAny(u8, authority, "/?#@") != null) return false;
    return std.ascii.eqlIgnoreCase(withoutPort(authority, default_port), withoutPort(host, default_port));
}

fn withoutPort(authority: []const u8, default_port: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, authority, default_port)) authority[0 .. authority.len - default_port.len] else authority;
}

fn isNonce(value: []const u8) bool {
    if (value.len != nonce_hex_len) return false;
    for (value) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

fn newNonce(io: std.Io) [nonce_hex_len]u8 {
    var bytes: [nonce_size]u8 = undefined;
    io.random(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

/// the shared middleware: every /api/ request other than GET and HEAD must
/// pass checkWrite before it is routed, so later write routes are covered
/// without opting in. returns false once the refusal has been sent.
pub fn guardWrite(request: *std.http.Server.Request, allocator: std.mem.Allocator) !bool {
    const method = request.head.method;
    if (method == .GET or method == .HEAD) return true;
    const check = checkWrite(.{
        .origin = findHeader(request, "origin"),
        .host = findHeader(request, "host"),
        .token = findHeader(request, csrf_header),
        .nonce = web.getCookieValue(request, csrf_cookie),
    });
    const message = switch (check) {
        .allowed => return true,
        .foreign_origin => "Haxy only accepts changes sent from its own site.",
        .missing_token, .bad_token => "This request has no valid CSRF token. Reload the page and try again.",
    };
    // the body goes unread, so the connection closes
    try api.respondError(request, allocator, .{ .code = .csrf, .message = message }, .{ .keep_alive = false });
    return false;
}

fn findHeader(request: *std.http.Server.Request, name: []const u8) ?[]const u8 {
    var iter = request.iterateHeaders();
    while (iter.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

// --- body shapes ------------------------------------------------------------

pub const Viewer = struct {
    name: []const u8,
};

/// the body of every /api/v1/session response
pub const Body = struct {
    // null when nobody is logged in, and always in local mode
    viewer: ?Viewer,
    // send back in the x-haxy-csrf header on writes
    csrf_token: []const u8,
};

pub fn writeBody(writer: *std.Io.Writer, body: Body) std.Io.Writer.Error!void {
    try std.json.Stringify.value(body, .{}, writer);
}

pub const Credentials = struct {
    username: []const u8,
    password: []const u8,
};

pub const LoginRequest = union(enum) {
    credentials: Credentials,
    invalid: api.Error,
};

/// reads a login request: a JSON object with string `username` and
/// `password`. a form-encoded body is refused, since any page can post one.
/// strings are allocated in `arena`.
pub fn parseLogin(arena: std.mem.Allocator, content_type: ?[]const u8, body: []const u8) !LoginRequest {
    const malformed: LoginRequest = .{ .invalid = .{ .code = .validation, .message = "Send the username and password as a JSON object." } };
    if (!isJson(content_type orelse return malformed)) return malformed;
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return malformed,
    };
    const object = switch (value) {
        .object => |object| object,
        else => return malformed,
    };
    const username = stringField(object, "username") catch return malformed;
    const password = stringField(object, "password") catch return malformed;

    var field_errors: std.ArrayList(api.FieldError) = .empty;
    if (std.mem.trim(u8, username, " \t\r\n").len == 0) try field_errors.append(arena, .{ .field = "username", .message = "Enter your username." });
    if (password.len == 0) try field_errors.append(arena, .{ .field = "password", .message = "Enter your password." });
    if (field_errors.items.len > 0) return .{ .invalid = .{
        .code = .validation,
        .message = "Enter your username and password.",
        .field_errors = field_errors.items,
    } };
    return .{ .credentials = .{ .username = username, .password = password } };
}

// a missing field reads as empty; any other type is malformed
fn stringField(object: std.json.ObjectMap, name: []const u8) error{WrongType}![]const u8 {
    return switch (object.get(name) orelse return "") {
        .string => |string| string,
        .null => "",
        else => error.WrongType,
    };
}

/// whether a Content-Type names JSON, ignoring parameters such as charset
pub fn isJson(content_type: []const u8) bool {
    const media_type = std.mem.trim(u8, content_type[0 .. std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len], " \t");
    return std.ascii.eqlIgnoreCase(media_type, "application/json");
}

// --- the route --------------------------------------------------------------

/// `/api/v1/session`: GET/HEAD read the viewer and this browser's CSRF token;
/// on a server, POST logs in and DELETE logs out. local mode has no accounts.
pub fn handle(io: std.Io, request: *std.http.Server.Request, allocator: std.mem.Allocator, host: web.Host) !void {
    const method = request.head.method;
    const allow = switch (host) {
        .server => "GET, HEAD, POST, DELETE",
        .local => "GET, HEAD",
    };
    switch (method) {
        .GET, .HEAD => return respondCurrent(io, request, allocator, host),
        .POST, .DELETE => switch (host) {
            .server => |server| return if (method == .POST)
                login(io, request, allocator, server.admin_repo_path, server.session_store)
            else
                logout(io, request, allocator, server.session_store),
            .local => return api.respondError(request, allocator, .{ .code = .unsupported, .message = "Local mode has no accounts to log in to." }, .{ .allow = allow, .keep_alive = false }),
        },
        else => return api.respondError(request, allocator, .{ .code = .unsupported, .message = "This route doesn't support that method." }, .{ .allow = allow, .keep_alive = false }),
    }
}

fn respondCurrent(io: std.Io, request: *std.http.Server.Request, allocator: std.mem.Allocator, host: web.Host) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // a browser keeps its nonce until login or logout rotates it
    const existing = web.getCookieValue(request, csrf_cookie);
    var fresh: [nonce_hex_len]u8 = undefined;
    const nonce: []const u8 = if (existing != null and isNonce(existing.?)) existing.? else blk: {
        fresh = newNonce(io);
        break :blk &fresh;
    };
    const set_nonce = nonce.ptr == &fresh;

    const viewer: ?Viewer = switch (host) {
        .local => null,
        .server => |server| blk: {
            // the auto-login the `try` demo leaves is for the web UI; the API
            // never claims it
            const user_id = web.requestUserId(request, server.session_store) orelse break :blk null;
            const user = (try readActiveUser(io, allocator, &arena, server.admin_repo_path, user_id)) orelse break :blk null;
            break :blk .{ .name = user.event.name };
        },
    };

    const token = csrfToken(nonce);
    var cookie_buf: [128]u8 = undefined;
    const cookie = if (set_nonce) try std.fmt.bufPrint(&cookie_buf, csrf_cookie_fmt, .{nonce}) else null;
    try respondSession(request, &arena, .{ .viewer = viewer, .csrf_token = &token }, &.{cookie}, .ok);
}

fn login(io: std.Io, request: *std.http.Server.Request, allocator: std.mem.Allocator, admin_repo_path: []const u8, session_store: web.SessionStore) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // copied before the body read, which invalidates the request's headers
    const content_type = if (request.head.content_type) |value| try arena.allocator().dupe(u8, value) else null;
    const previous_token = if (web.getCookieValue(request, web.cookie_name)) |value| try arena.allocator().dupe(u8, value) else null;

    var buffer: [256]u8 = undefined;
    const reader = try request.readerExpectContinue(&buffer);
    const body = reader.allocRemaining(arena.allocator(), .limited(64 * 1024)) catch |err| switch (err) {
        error.StreamTooLong => return api.respondError(request, allocator, .{ .code = .validation, .message = "The login request is too large." }, .{ .keep_alive = false }),
        else => |e| return e,
    };

    const credentials = switch (try parseLogin(arena.allocator(), content_type, body)) {
        .credentials => |value| value,
        .invalid => |err| return api.respondError(request, allocator, err, .{}),
    };

    const User = struct { id: [evt.event_id_size]u8, name: []const u8 };
    const user: User = (blk: {
        var admin_repo = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = admin_repo_path });
        defer admin_repo.deinit(io, allocator);
        // a fresh server has no moment, and so no users, until its first event
        const moment = evt.currentMoment(evt.admin_repo_opts, &admin_repo) catch |err| switch (err) {
            error.NotFound => break :blk null,
            else => |e| return e,
        };
        break :blk switch (try evt.User.verifyCredentials(evt.AdminDB, evt.admin_repo_opts.hash, moment, &arena, credentials.username, credentials.password)) {
            // a deleted account can't log in
            .success => |id| if (try ui.activeUser(moment, &arena, id)) |record| User{ .id = id, .name = record.event.name } else null,
            .unknown_user, .wrong_password => null,
        };
    }) orelse return api.respondError(request, allocator, .{ .code = .unauthenticated, .message = "Incorrect username or password." }, .{});

    try respondLoggedIn(io, request, &arena, session_store, previous_token, user.id, user.name, .ok);
}

/// answers a request that logged `user_id` in (a login, or a registration):
/// replaces the browser's previous session, if any, with a new one, and
/// rotates the CSRF nonce. `previous_token` must be copied before the body
/// read, which invalidates the request's headers.
pub fn respondLoggedIn(
    io: std.Io,
    request: *std.http.Server.Request,
    arena: *std.heap.ArenaAllocator,
    session_store: web.SessionStore,
    previous_token: ?[]const u8,
    user_id: [evt.event_id_size]u8,
    name: []const u8,
    status: std.http.Status,
) !void {
    // a login replaces any session this browser already had
    if (previous_token) |token| session_store.remove(token);
    const session_token = try session_store.create(&user_id);
    const nonce = newNonce(io);
    const token = csrfToken(&nonce);
    var session_cookie_buf: [256]u8 = undefined;
    const session_cookie = try std.fmt.bufPrint(&session_cookie_buf, web.session_cookie_fmt, .{session_token});
    var nonce_cookie_buf: [128]u8 = undefined;
    const nonce_cookie = try std.fmt.bufPrint(&nonce_cookie_buf, csrf_cookie_fmt, .{nonce});
    try respondSession(request, arena, .{ .viewer = .{ .name = name }, .csrf_token = &token }, &.{ session_cookie, nonce_cookie }, status);
}

fn logout(io: std.Io, request: *std.http.Server.Request, allocator: std.mem.Allocator, session_store: web.SessionStore) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try respondLoggedOut(io, request, &arena, session_store, web.getCookieValue(request, web.cookie_name));
}

/// answers a request that ended the browser's session (a logout, or deleting
/// the account): revokes `session_token`'s session server-side, so the cookie
/// is dead for anyone holding a copy, clears the cookie and rotates the CSRF
/// nonce.
pub fn respondLoggedOut(
    io: std.Io,
    request: *std.http.Server.Request,
    arena: *std.heap.ArenaAllocator,
    session_store: web.SessionStore,
    session_token: ?[]const u8,
) !void {
    if (session_token) |value| session_store.remove(value);
    const nonce = newNonce(io);
    const token = csrfToken(&nonce);
    var nonce_cookie_buf: [128]u8 = undefined;
    const nonce_cookie = try std.fmt.bufPrint(&nonce_cookie_buf, csrf_cookie_fmt, .{nonce});
    try respondSession(request, arena, .{ .viewer = null, .csrf_token = &token }, &.{ session_cookie_clear, nonce_cookie }, .ok);
}

fn readActiveUser(io: std.Io, allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator, admin_repo_path: []const u8, user_id: [evt.event_id_size]u8) !?evt.User.Record {
    var admin_repo = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = admin_repo_path });
    defer admin_repo.deinit(io, allocator);
    const moment = evt.currentMoment(evt.admin_repo_opts, &admin_repo) catch |err| switch (err) {
        error.NotFound => return null,
        else => |e| return e,
    };
    return try ui.activeUser(moment, arena, user_id);
}

fn respondSession(request: *std.http.Server.Request, arena: *std.heap.ArenaAllocator, body: Body, cookies: []const ?[]const u8, status: std.http.Status) !void {
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try writeBody(&out.writer, body);
    try api.respondJson(request, out.written(), .{ .set_cookies = cookies, .status = status });
}
