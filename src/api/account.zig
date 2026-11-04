//! the account routes of the JSON API (`/api/v1/account…`): registration and
//! the logged-in viewer's own email, password, ssh keys and account deletion.
//! they always act on the session's viewer — no route names another user —
//! and call the operations the TUI and the web forms use (evt.createUser,
//! evt.updateUser, evt.addUserKey, evt.removeUserKey, ui.Delete.perform), so
//! their rules live in one place. a local host has no accounts, so every
//! route answers `unsupported` there. a change naming someone other than the
//! session's viewer in `X-Haxy-Viewer` never gets here: api/session.zig's
//! guardWrite refuses it for every write.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const api = @import("../api.zig");
const api_session = @import("./session.zig");
const evt = @import("../event.zig");
const ui = @import("../ui.zig");
const web = @import("../web.zig");

const UserFailure = ui.Session.FormFeedback.UserFailure;
const KeyFailure = ui.Session.FormFeedback.KeyFailure;

pub const Route = union(enum) {
    // GET the viewer's account; POST registers a new one; DELETE deletes the
    // viewer's account
    account,
    // PUT the viewer's email
    email,
    // PUT the viewer's password
    password,
    // GET the viewer's ssh keys; POST adds one
    keys,
    // DELETE removes the viewer's ssh key with this fingerprint, still
    // percent-encoded
    key: []const u8,
};

const prefix = "/api/v1/account";

/// the account route `path` names, or null when it names none
pub fn route(path: []const u8) ?Route {
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    if (rest.len == 0) return .account;
    if (std.mem.eql(u8, rest, "/email")) return .email;
    if (std.mem.eql(u8, rest, "/password")) return .password;
    if (std.mem.eql(u8, rest, "/keys")) return .keys;
    if (std.mem.startsWith(u8, rest, "/keys/")) {
        const fingerprint = rest["/keys/".len..];
        if (fingerprint.len == 0 or std.mem.indexOfScalar(u8, fingerprint, '/') != null) return null;
        return .{ .key = fingerprint };
    }
    return null;
}

// --- request bodies ---------------------------------------------------------

pub const Registration = struct {
    name: []const u8,
    email: []const u8,
    password: []const u8,
    password_again: []const u8,
};

pub const Deletion = struct {
    // the account's name, typed to confirm
    confirm: []const u8,
    password: []const u8,
};

pub const KeyAddition = struct {
    // one authorized_keys line
    key: []const u8,
};

pub const EmailChange = struct {
    email: []const u8,
};

pub const PasswordChange = struct {
    current_password: []const u8,
    new_password: []const u8,
    new_password_again: []const u8,
};

pub fn Parsed(comptime T: type) type {
    return union(enum) { ok: T, invalid: api.Error };
}

/// reads a request body: a JSON object whose fields are T's, all strings. a
/// missing or null field reads as empty, so the shared rules report it; a
/// form-encoded body is refused, since any page can post one. strings are
/// allocated in `arena`.
pub fn parseBody(comptime T: type, arena: std.mem.Allocator, content_type: ?[]const u8, body: []const u8) !Parsed(T) {
    const malformed: Parsed(T) = .{ .invalid = .{ .code = .validation, .message = "Send the request as a JSON object of strings." } };
    if (!api_session.isJson(content_type orelse return malformed)) return malformed;
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return malformed,
    };
    const object = switch (value) {
        .object => |object| object,
        else => return malformed,
    };
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        @field(result, name) = switch (object.get(name) orelse .null) {
            .string => |string| string,
            .null => "",
            else => return malformed,
        };
    }
    return .{ .ok = result };
}

// --- errors -----------------------------------------------------------------

const check_fields = "Check the highlighted fields.";

fn fieldError(code: api.ErrorCode, comptime field: []const u8, comptime message: []const u8) api.Error {
    return .{ .code = code, .message = check_fields, .field_errors = &.{.{ .field = field, .message = message }} };
}

/// why a registration was refused, beside the field the shared rules
/// (evt.createUser) rejected. a taken name or email is a conflict.
pub fn registrationError(failure: UserFailure) api.Error {
    return switch (failure) {
        .required_name => fieldError(.validation, "name", "Choose a username."),
        .invalid_name => fieldError(.validation, "name", std.fmt.comptimePrint("Use {d} to {d} letters, digits and single hyphens, not starting or ending with a hyphen.", .{ evt.User.name_min_len, evt.User.name_max_len })),
        .name_taken => fieldError(.conflict, "name", "That username is taken."),
        .required_email => fieldError(.validation, "email", "Enter an email address."),
        .email_taken => fieldError(.conflict, "email", "Another account already uses that email address."),
        .required_password => fieldError(.validation, "password", "Choose a password."),
        .password_mismatch => fieldError(.validation, "password_again", "The passwords don't match."),
        // registration checks no existing password
        .wrong_password => unreachable,
    };
}

/// why an email or password change was refused, beside the field the shared
/// rules (evt.updateUser) rejected. a taken email is a conflict.
pub fn settingsError(failure: UserFailure) api.Error {
    return switch (failure) {
        .required_email => fieldError(.validation, "email", "Enter an email address."),
        .email_taken => fieldError(.conflict, "email", "Another account already uses that email address."),
        .wrong_password => fieldError(.validation, "current_password", "Your current password is incorrect."),
        .required_password => fieldError(.validation, "new_password", "Choose a new password."),
        .password_mismatch => fieldError(.validation, "new_password_again", "The new passwords don't match."),
        // the name never changes here
        .required_name, .invalid_name, .name_taken => unreachable,
    };
}

/// a password change must name the current password. evt.updateUser changes
/// the password only when a password field is filled in, so without this an
/// empty form would succeed without changing anything.
pub fn passwordChangeMissing(change: PasswordChange) ?api.Error {
    if (change.current_password.len > 0) return null;
    return fieldError(.validation, "current_password", "Enter your current password.");
}

/// why an ssh key was refused by the shared rules (evt.addUserKey), beside
/// the key field. a key already added is a conflict.
pub fn keyError(failure: KeyFailure) api.Error {
    return switch (failure) {
        .invalid => fieldError(.validation, "key", "Paste one OpenSSH public key line, such as the contents of id_ed25519.pub."),
        .unsupported => fieldError(.validation, "key", "Haxy accepts " ++ comptime listOfTypes() ++ " keys."),
        .already_added => fieldError(.conflict, "key", "You have already added this key."),
        .too_many => fieldError(.validation, "key", std.fmt.comptimePrint("You can have at most {d} SSH keys. Remove one to add another.", .{evt.User.ssh_key_max_count})),
    };
}

/// why ui.Delete.perform refused to delete the viewer's account, beside the
/// field it rejected
pub fn deletionError(arena: std.mem.Allocator, failure: ui.Session.FormFeedback.DeleteFailure, name: []const u8) !api.Error {
    const field: api.FieldError = switch (failure) {
        .wrong_confirm => .{ .field = "confirm", .message = try std.fmt.allocPrint(arena, "Type {s} exactly to confirm.", .{name}) },
        .wrong_password => .{ .field = "password", .message = "Incorrect password." },
    };
    return .{ .code = .validation, .message = check_fields, .field_errors = try arena.dupe(api.FieldError, &.{field}) };
}

// "a, b, c and d"
fn listOfTypes() []const u8 {
    const types = evt.User.supported_key_types;
    var text: []const u8 = types[0];
    for (types[1..], 1..) |name, index| text = text ++ (if (index == types.len - 1) " and " else ", ") ++ name;
    return text;
}

// --- bodies -----------------------------------------------------------------

/// one of the viewer's ssh keys. public keys aren't secret, so the whole
/// line is included.
pub const KeyItem = struct {
    // SHA256, as ssh-keygen -l prints it; identifies the key in its route
    fingerprint: []const u8,
    type: []const u8,
    // null when the key has none
    comment: ?[]const u8,
    // the authorized_keys line
    key: []const u8,

    pub fn of(key: *const ui.UserKeys.SshKey) KeyItem {
        const parts = ui.UserKeys.keyParts(key.line);
        return .{
            .fingerprint = &key.fingerprint,
            .type = parts.type,
            .comment = if (parts.comment.len > 0) parts.comment else null,
            .key = key.line,
        };
    }
};

/// writes the viewer's ssh keys as one page: a user holds at most
/// evt.User.ssh_key_max_count, so the list is never split
pub fn writeKeys(writer: *std.Io.Writer, keys: []const ui.UserKeys.SshKey) std.Io.Writer.Error!void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try json.objectField("items");
    try json.beginArray();
    for (keys) |*key| try json.write(KeyItem.of(key));
    try json.endArray();
    try json.objectField("page");
    try json.write(.{ .has_more = false, .next_cursor = @as(?[]const u8, null), .count = api.Count{ .exact = keys.len } });
    try json.endObject();
}

/// the viewer's own account. only its owner ever sees the email.
pub const Account = struct {
    name: []const u8,
    email: []const u8,
};

// --- the routes -------------------------------------------------------------

/// what a server host provides these routes
pub const Server = struct {
    admin_repo_path: []const u8,
    users_dir: []const u8,
    session_store: web.SessionStore,
};

pub fn handle(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    // null on a local host
    server_maybe: ?Server,
    matched: Route,
) !void {
    const method = request.head.method;
    const allow = switch (matched) {
        .account => "GET, HEAD, POST, DELETE",
        .email, .password => "PUT",
        .keys => "GET, HEAD, POST",
        .key => "DELETE",
    };
    // the body goes unread, so the connection closes
    const server = server_maybe orelse
        return api.respondError(request, allocator, .{ .code = .unsupported, .message = "Local mode has no accounts." }, .{ .keep_alive = false });
    switch (matched) {
        .account => switch (method) {
            .GET, .HEAD => return getAccount(io, request, allocator, server),
            .POST => return register(io, request, allocator, server),
            .DELETE => return deleteAccount(io, request, allocator, server),
            else => {},
        },
        .email => if (method == .PUT) return changeEmail(io, request, allocator, server),
        .password => if (method == .PUT) return changePassword(io, request, allocator, server),
        .keys => switch (method) {
            .GET, .HEAD => return listKeys(io, request, allocator, server),
            .POST => return addKey(io, request, allocator, server),
            else => {},
        },
        .key => |encoded| if (method == .DELETE) return removeKey(io, request, allocator, server, encoded),
    }
    return api.respondError(request, allocator, .{ .code = .unsupported, .message = "This route doesn't support that method." }, .{ .allow = allow, .keep_alive = false });
}

// the logged-in viewer's active account, or null when there is none (no
// session, a revoked one, or a deleted account)
fn viewerAccount(io: std.Io, allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator, server: Server, request: *std.http.Server.Request) !?struct { id: [evt.event_id_size]u8, record: evt.User.Record } {
    const user_id = web.requestUserId(request, server.session_store) orelse return null;
    var admin_repo = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = server.admin_repo_path });
    defer admin_repo.deinit(io, allocator);
    // a fresh server has no moment, and so no users, until its first event
    const moment = evt.currentMoment(evt.admin_repo_opts, &admin_repo) catch |err| switch (err) {
        error.NotFound => return null,
        else => |e| return e,
    };
    const record = (try ui.activeUser(moment, arena, user_id)) orelse return null;
    return .{ .id = user_id, .record = record };
}

fn respondUnauthenticated(request: *std.http.Server.Request, allocator: std.mem.Allocator) !void {
    return api.respondError(request, allocator, .{ .code = .unauthenticated, .message = "Log in to manage your account." }, .{ .keep_alive = false });
}

fn respondAccount(request: *std.http.Server.Request, arena: *std.heap.ArenaAllocator, account: Account, status: std.http.Status) !void {
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try std.json.Stringify.value(account, .{}, &out.writer);
    try api.respondJson(request, out.written(), .{ .status = status });
}

fn getAccount(io: std.Io, request: *std.http.Server.Request, allocator: std.mem.Allocator, server: Server) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const viewer = (try viewerAccount(io, allocator, &arena, server, request)) orelse return respondUnauthenticated(request, allocator);
    try respondAccount(request, &arena, .{ .name = viewer.record.event.name, .email = viewer.record.event.email }, .ok);
}

// reads a JSON request body of T's fields, or answers the refusal and
// returns null. headers are invalid after this.
fn readBody(comptime T: type, request: *std.http.Server.Request, allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator) !?T {
    // copied before the body read, which invalidates the request's headers
    const content_type = if (request.head.content_type) |value| try arena.allocator().dupe(u8, value) else null;
    var buffer: [256]u8 = undefined;
    const reader = try request.readerExpectContinue(&buffer);
    const body = reader.allocRemaining(arena.allocator(), .limited(64 * 1024)) catch |err| switch (err) {
        error.StreamTooLong => {
            try api.respondError(request, allocator, .{ .code = .validation, .message = "The request is too large." }, .{ .keep_alive = false });
            return null;
        },
        else => |e| return e,
    };
    switch (try parseBody(T, arena.allocator(), content_type, body)) {
        .ok => |value| return value,
        .invalid => |err| {
            try api.respondError(request, allocator, err, .{});
            return null;
        },
    }
}

// registers a new account and logs the browser in as it, as the web sign-up
// form does. someone already logged in must log out first, as on the web.
fn register(io: std.Io, request: *std.http.Server.Request, allocator: std.mem.Allocator, server: Server) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    if (try viewerAccount(io, allocator, &arena, server, request) != null)
        return api.respondError(request, allocator, .{ .code = .forbidden, .message = "Log out before creating another account." }, .{ .keep_alive = false });

    const previous_token = if (web.getCookieValue(request, web.cookie_name)) |value| try arena.allocator().dupe(u8, value) else null;
    const fields = (try readBody(Registration, request, allocator, &arena)) orelse return;

    const user_id = blk: {
        var admin_repo = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = server.admin_repo_path });
        defer admin_repo.deinit(io, allocator);
        break :blk evt.createUser(io, allocator, server.users_dir, &admin_repo, fields.name, fields.email, fields.password, fields.password_again) catch |err| {
            const failure = UserFailure.fromError(err) orelse return err;
            return api.respondError(request, allocator, registrationError(failure), .{});
        };
    };
    try api_session.respondLoggedIn(io, request, &arena, server.session_store, previous_token, user_id, fields.name, .created);
}

// changes the viewer's email or password through evt.updateUser, as the
// settings form does, and answers with the account as it now is
fn updateViewer(io: std.Io, request: *std.http.Server.Request, allocator: std.mem.Allocator, server: Server, comptime T: type) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const viewer = (try viewerAccount(io, allocator, &arena, server, request)) orelse return respondUnauthenticated(request, allocator);
    const fields = (try readBody(T, request, allocator, &arena)) orelse return;
    const email: ?[]const u8, const passwords = switch (T) {
        EmailChange => .{ fields.email, PasswordChange{ .current_password = "", .new_password = "", .new_password_again = "" } },
        // the shared update keeps the stored email, read at write time
        PasswordChange => blk: {
            if (passwordChangeMissing(fields)) |err| return api.respondError(request, allocator, err, .{});
            break :blk .{ null, fields };
        },
        else => @compileError("not an account change"),
    };

    var admin_repo = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = server.admin_repo_path });
    defer admin_repo.deinit(io, allocator);
    evt.updateUser(io, allocator, server.users_dir, &admin_repo, &viewer.id, email, passwords.current_password, passwords.new_password, passwords.new_password_again) catch |err| switch (err) {
        // the account was deleted meanwhile
        error.NotFound => return respondUnauthenticated(request, allocator),
        else => {
            const failure = UserFailure.fromError(err) orelse return err;
            return api.respondError(request, allocator, settingsError(failure), .{});
        },
    };
    const updated = (try ui.activeUser(try evt.currentMoment(evt.admin_repo_opts, &admin_repo), &arena, viewer.id)) orelse return respondUnauthenticated(request, allocator);
    try respondAccount(request, &arena, .{ .name = updated.event.name, .email = updated.event.email }, .ok);
}

fn changeEmail(io: std.Io, request: *std.http.Server.Request, allocator: std.mem.Allocator, server: Server) !void {
    return updateViewer(io, request, allocator, server, EmailChange);
}

fn changePassword(io: std.Io, request: *std.http.Server.Request, allocator: std.mem.Allocator, server: Server) !void {
    return updateViewer(io, request, allocator, server, PasswordChange);
}

// the viewer's ssh keys as they are now
fn readKeys(io: std.Io, allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator, server: Server, user_id: [evt.event_id_size]u8) ![]ui.UserKeys.SshKey {
    var admin_repo = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = server.admin_repo_path });
    defer admin_repo.deinit(io, allocator);
    const user = (try ui.activeUser(try evt.currentMoment(evt.admin_repo_opts, &admin_repo), arena, user_id)) orelse return error.NotFound;
    return ui.UserKeys.parseKeys(arena.allocator(), user.event.ssh_keys);
}

fn respondKeys(request: *std.http.Server.Request, arena: *std.heap.ArenaAllocator, keys: []const ui.UserKeys.SshKey) !void {
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try writeKeys(&out.writer, keys);
    try api.respondJson(request, out.written(), .{});
}

fn listKeys(io: std.Io, request: *std.http.Server.Request, allocator: std.mem.Allocator, server: Server) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const viewer = (try viewerAccount(io, allocator, &arena, server, request)) orelse return respondUnauthenticated(request, allocator);
    try respondKeys(request, &arena, try ui.UserKeys.parseKeys(arena.allocator(), viewer.record.event.ssh_keys));
}

// adds a key through evt.addUserKey, as the keys tab does, and answers with
// the key as stored
fn addKey(io: std.Io, request: *std.http.Server.Request, allocator: std.mem.Allocator, server: Server) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const viewer = (try viewerAccount(io, allocator, &arena, server, request)) orelse return respondUnauthenticated(request, allocator);
    const fields = (try readBody(KeyAddition, request, allocator, &arena)) orelse return;
    {
        var admin_repo = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = server.admin_repo_path });
        defer admin_repo.deinit(io, allocator);
        evt.addUserKey(io, allocator, server.users_dir, &admin_repo, &viewer.id, fields.key) catch |err| switch (err) {
            // the account was deleted meanwhile
            error.NotFound => return respondUnauthenticated(request, allocator),
            else => {
                const failure = KeyFailure.fromError(err) orelse return err;
                return api.respondError(request, allocator, keyError(failure), .{});
            },
        };
    }
    // a key that was added has a fingerprint
    const fingerprint = evt.User.fingerprintOfKey(fields.key) orelse unreachable;
    const keys = readKeys(io, allocator, &arena, server, viewer.id) catch |err| switch (err) {
        error.NotFound => return respondUnauthenticated(request, allocator),
        else => |e| return e,
    };
    for (keys) |*key| if (std.mem.eql(u8, &key.fingerprint, &fingerprint)) {
        var out: std.Io.Writer.Allocating = .init(arena.allocator());
        try std.json.Stringify.value(KeyItem.of(key), .{}, &out.writer);
        return api.respondJson(request, out.written(), .{ .status = .created });
    };
    // removed again before it could be read back
    return api.respondError(request, allocator, .{ .code = .conflict, .message = "The key was removed again before it could be shown. Reload your keys." }, .{});
}

// removes a key through evt.removeUserKey, as the keys tab's confirmation
// does, and answers with the keys that remain. a key the viewer doesn't hold
// is not found.
fn removeKey(io: std.Io, request: *std.http.Server.Request, allocator: std.mem.Allocator, server: Server, encoded: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const viewer = (try viewerAccount(io, allocator, &arena, server, request)) orelse return respondUnauthenticated(request, allocator);
    const not_found: api.Error = .{ .code = .not_found, .message = "You have no SSH key with that fingerprint." };
    const decoded = std.Uri.percentDecodeInPlace(try arena.allocator().dupe(u8, encoded));
    if (decoded.len != evt.User.fingerprint_len) return api.respondError(request, allocator, not_found, .{});
    const fingerprint = decoded[0..evt.User.fingerprint_len];

    const held = for (try ui.UserKeys.parseKeys(arena.allocator(), viewer.record.event.ssh_keys)) |key| {
        if (std.mem.eql(u8, &key.fingerprint, fingerprint)) break true;
    } else false;
    if (!held) return api.respondError(request, allocator, not_found, .{});
    {
        var admin_repo = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = server.admin_repo_path });
        defer admin_repo.deinit(io, allocator);
        evt.removeUserKey(io, allocator, server.users_dir, &admin_repo, &viewer.id, fingerprint) catch |err| switch (err) {
            error.NotFound => return respondUnauthenticated(request, allocator),
            else => |e| return e,
        };
    }
    const keys = readKeys(io, allocator, &arena, server, viewer.id) catch |err| switch (err) {
        error.NotFound => return respondUnauthenticated(request, allocator),
        else => |e| return e,
    };
    try respondKeys(request, &arena, keys);
}

// deletes the viewer's account through ui.Delete.perform, with the typed
// name and password checks the delete tab uses, then logs the browser out as
// the web form does. evt.deleteUser removes the account and everything in
// its user dir: every repository and fork it owns.
fn deleteAccount(io: std.Io, request: *std.http.Server.Request, allocator: std.mem.Allocator, server: Server) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const viewer = (try viewerAccount(io, allocator, &arena, server, request)) orelse return respondUnauthenticated(request, allocator);
    // copied before the body read, which invalidates the request's headers
    const session_token = if (web.getCookieValue(request, web.cookie_name)) |value| try arena.allocator().dupe(u8, value) else null;
    const fields = (try readBody(Deletion, request, allocator, &arena)) orelse return;

    const failure = blk: {
        var admin_repo = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = server.admin_repo_path });
        defer admin_repo.deinit(io, allocator);
        break :blk ui.Delete.perform(io, allocator, server.users_dir, &admin_repo, viewer.id, .{ .user = viewer.record.event.name }, fields.confirm, fields.password) catch |err| switch (err) {
            // deleted meanwhile
            error.NotFound => return respondUnauthenticated(request, allocator),
            else => |e| return e,
        };
    };
    if (failure) |value| return api.respondError(request, allocator, try deletionError(arena.allocator(), value, viewer.record.event.name), .{});
    try api_session.respondLoggedOut(io, request, &arena, server.session_store, session_token);
}
