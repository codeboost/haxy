//! the assignee routes of the JSON API: assigning someone to an issue, and
//! unassigning them. both write through `thread_write.assign`/`unassign`, the
//! operations the TUI's thread tabs and Haxy's HTML forms use, so who may
//! assign, how an assignee is looked up (an email, or an account's name on a
//! server) and when an assignment is refused are the TUI's.
//!
//! - `POST …/issues/{id}/assignees` with `{assignee}`: the issue as its own
//!   route reads it, with the assignee added
//! - `DELETE …/issues/{id}/assignees/{assignment}`: the issue, without them
//!
//! `{assignment}` is an assignee's `id` in the issue's answer.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const api = @import("../api.zig");
const api_account = @import("./account.zig");
const api_issues = @import("./issues.zig");
const api_repo = @import("./repo.zig");
const api_thread = @import("./thread.zig");
const evt = @import("../event.zig");
const thread_write = @import("../thread_write.zig");
const ui = @import("../ui.zig");

pub const Route = struct {
    // the issue's own route
    issue: api_thread.Route,
    // one assignment's hex id, still encoded; null for the issue's assignees
    assignment: ?[]const u8,
};

const segment = "/assignees";

/// the assignee route `path` names: `<issue>/assignees` or
/// `<issue>/assignees/<assignment>`, where `<issue>` is an issue's own route
pub fn route(path: []const u8) ?Route {
    const issue_path: []const u8, const assignment: ?[]const u8 = blk: {
        if (std.mem.endsWith(u8, path, segment)) break :blk .{ path[0 .. path.len - segment.len], null };
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
        const head = path[0..slash];
        const tail = path[slash + 1 ..];
        if (tail.len == 0 or !std.mem.endsWith(u8, head, segment)) return null;
        break :blk .{ head[0 .. head.len - segment.len], tail };
    };
    const issue = api_issues.route(issue_path) orelse return null;
    if (issue.resource != .thread) return null;
    return .{ .issue = issue, .assignment = assignment };
}

/// `POST …/assignees`: an account name, or an email
pub const AssignRequest = struct {
    assignee: []const u8,
};

const not_assigned: api.Error = .{ .code = .not_found, .message = "This person isn't assigned to this issue." };
const check_field = "Check the highlighted fields.";

pub fn handle(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    host: api_repo.Host,
    // the logged-in viewer, or null when anonymous (always in local mode)
    viewer: ?[evt.event_id_size]u8,
    matched: Route,
) !void {
    const method = request.head.method;
    if (matched.assignment == null and method != .POST) return unsupported(request, allocator, "POST");
    if (matched.assignment != null and method != .DELETE) return unsupported(request, allocator, "DELETE");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // the body is read before anything answers, so no answer leaves it unread
    const body: ?AssignRequest = if (matched.assignment == null)
        (try api_account.readBody(AssignRequest, request, allocator, &arena)) orelse return
    else
        null;

    var admin_repo_maybe: ?rp.Repo(.xit, evt.admin_repo_opts) = null;
    defer if (admin_repo_maybe) |*admin_repo| admin_repo.deinit(io, allocator);
    var opened = (try api_thread.openRepo(io, request, allocator, &arena, host, viewer, matched.issue.target, &admin_repo_maybe)) orelse return;
    if (!ui.Repo.hasSection(.issues, opened.resolved.repo.event, opened.handle, opened.session.data.host_kind, opened.source.repo_kind))
        return api.respondError(request, allocator, api_issues.issues_off, .{});

    const encoded_id = matched.issue.resource.thread;
    const thread_id = evt.parseEventId(std.Uri.percentDecodeInPlace(try aa.dupe(u8, encoded_id))) catch
        return api.respondError(request, allocator, api_issues.no_such_issue, .{});
    if (try api_issues.readDetail(&arena, io, &opened, &thread_id) == null)
        return api.respondError(request, allocator, api_issues.no_such_issue, .{});

    const actor = switch (try api_issues.authorize(io, allocator, &arena, host, viewer, &opened)) {
        .actor => |actor| actor,
        .refused => |err| return api.respondError(request, allocator, err, .{}),
    };
    const event_host: evt.Host = switch (host) {
        .local => .local,
        .server => |server| .{ .server = .{ .users_dir = server.users_dir, .admin_repo_path = server.admin_repo_path } },
    };

    const failure: ?api.Error = if (body) |fields| blk: {
        // local mode has no accounts, so names an assignee by email alone
        const admin_moment = if (host == .local) null else opened.session.haxy_moment;
        const assigned = thread_write.assign(event_host, io, allocator, opened.source, actor, admin_moment, .issue, &thread_id, fields.assignee) catch |err| break :blk try writeError(err);
        break :blk switch (assigned) {
            .assigned => null,
            .refused => |refusal| refusedError(refusal, host == .local, std.mem.trim(u8, fields.assignee, " \t\r\n").len == 0),
        };
    } else blk: {
        const assignment = parseId(std.Uri.percentDecodeInPlace(try aa.dupe(u8, matched.assignment.?))) orelse break :blk not_assigned;
        thread_write.unassign(event_host, io, allocator, opened.source, actor, .issue, &thread_id, &assignment) catch |err| break :blk try writeError(err);
        break :blk null;
    };
    if (failure) |err| return api.respondError(request, allocator, err, .{});
    return api_issues.respondDetail(request, allocator, &arena, io, &opened, &thread_id, .ok);
}

fn writeError(err: anyerror) !api.Error {
    return switch (err) {
        error.Forbidden => api_issues.change_forbidden,
        error.NotFound => api_issues.no_such_issue,
        error.NotAssigned => not_assigned,
        else => return err,
    };
}

// the shared rules' refusal of an assignee, beside the field
fn refusedError(refusal: ui.Session.FormFeedback.AssignmentFailure, local: bool, blank: bool) api.Error {
    const enter: api.Error = .{ .code = .validation, .message = check_field, .field_errors = &.{.{ .field = "assignee", .message = "Enter an account name or an email address." }} };
    const enter_email: api.Error = .{ .code = .validation, .message = check_field, .field_errors = &.{.{ .field = "assignee", .message = "Enter an email address. Local mode has no accounts to name." }} };
    if (blank) return if (local) enter_email else enter;
    return switch (refusal) {
        .not_found => .{ .code = .validation, .message = check_field, .field_errors = &.{.{ .field = "assignee", .message = "No account has this name. Assign by email to name someone without an account." }} },
        .not_an_email => if (local) enter_email else .{ .code = .validation, .message = check_field, .field_errors = &.{.{ .field = "assignee", .message = "This isn't an email address Haxy can assign." }} },
        .already_assigned => .{ .code = .conflict, .message = check_field, .field_errors = &.{.{ .field = "assignee", .message = "This person is already assigned." }} },
    };
}

// an assignment's id: 32 lowercase hex digits, or null
fn parseId(text: []const u8) ?[evt.event_id_size]u8 {
    return (api_thread.parseNewId(text) orelse return null) orelse null;
}

fn unsupported(request: *std.http.Server.Request, allocator: std.mem.Allocator, comptime allow: []const u8) !void {
    // a write's body goes unread, so the connection closes
    return api.respondError(request, allocator, .{ .code = .unsupported, .message = "This route only supports " ++ allow ++ "." }, .{ .allow = allow, .keep_alive = false });
}
