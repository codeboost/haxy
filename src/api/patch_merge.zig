//! `POST …/patches/{id}/merge`: merging a patch, with its source commits or
//! its squashed commit, through the merge the TUI and Haxy's merge form use
//! (`patch_merge.merge`). the client sends what it reviewed (the patch's
//! revision and the target branch's tip), which the merge checks again
//! inside its own write; the answer is the merged patch, or why it wasn't
//! merged. a server merges; local mode merges with git.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const api = @import("../api.zig");
const api_account = @import("./account.zig");
const api_patches = @import("./patches.zig");
const api_repo = @import("./repo.zig");
const api_thread = @import("./thread.zig");
const evt = @import("../event.zig");
const patch_merge = @import("../patch_merge.zig");
const ui = @import("../ui.zig");

const Patches = ui.Repo.Patches;
const Availability = api_thread.Availability;

pub const Route = struct { target: api_repo.Route.Target, id: []const u8 };

/// the merge route `path` names, or null when it names none
pub fn route(path: []const u8) ?Route {
    const merge_suffix = "/merge";
    if (!std.mem.endsWith(u8, path, merge_suffix)) return null;
    const matched = api_thread.route(path[0 .. path.len - merge_suffix.len], "patches") orelse return null;
    return switch (matched.resource) {
        .thread => |id| .{ .target = matched.target, .id = id },
        else => null,
    };
}

/// the body of a merge: how to merge, and what the client reviewed
pub const MergeRequest = struct {
    method: []const u8,
    // the patch revision's id, as the patch's `revision.id` gave it
    revision: []const u8,
    // the target branch's tip, as the patch's `target.commit` gave it
    target_commit: []const u8,
};

const unauthenticated: api.Error = .{ .code = .unauthenticated, .message = "Log in to merge patches." };
const forbidden: api.Error = .{ .code = .forbidden, .message = "Only the repository's writers can merge its patches." };
const unauthenticated_reason: Availability = .{ .unavailable = .{ .code = .unauthenticated, .message = unauthenticated.message } };
const forbidden_reason: Availability = .{ .unavailable = .{ .code = .forbidden, .message = forbidden.message } };

/// whether the viewer may merge the patch: haxy offers it (`Patches.mergeBlock`,
/// the TUI's merge button), and the viewer writes to the repository
pub fn availability(entry: *const Patches.Entry, host_kind: evt.HostKind, viewer: api_thread.ViewerRights) Availability {
    if (Patches.mergeBlock(entry.*, host_kind)) |block| {
        const reason = api_patches.mergeUnavailable(block);
        return .{ .unavailable = .{ .code = reason.code, .message = reason.message } };
    }
    if (!viewer.signed_in) return unauthenticated_reason;
    const tab = viewer.tab orelse return forbidden_reason;
    return if (tab.role.atLeast(patch_merge.min_role)) .available else forbidden_reason;
}

pub fn handle(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    host: api_repo.Host,
    viewer: ?[evt.event_id_size]u8,
    matched: Route,
) !void {
    if (request.head.method != .POST) return api_thread.unsupported(request, allocator, "POST");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    // the body is read before anything answers, so no answer leaves it unread
    const body = (try api_account.readBody(MergeRequest, request, allocator, &arena)) orelse return;

    var admin_repo_maybe: ?rp.Repo(.xit, evt.admin_repo_opts) = null;
    defer if (admin_repo_maybe) |*admin_repo| admin_repo.deinit(io, allocator);
    var opened = (try api_thread.openRepo(io, request, allocator, &arena, host, viewer, matched.target, &admin_repo_maybe)) orelse return;
    if (!ui.Repo.hasSection(.patches, opened.resolved.repo.event, opened.handle, opened.session.data.host_kind, opened.source.repo_kind))
        return api.respondError(request, allocator, api_patches.patches_off, .{});
    const id = evt.parseEventId(std.Uri.percentDecodeInPlace(try arena.allocator().dupe(u8, matched.id))) catch
        return api.respondError(request, allocator, api_patches.no_such_patch, .{});
    if (try api_patches.readDetail(&arena, io, &opened, &id) == null) return api.respondError(request, allocator, api_patches.no_such_patch, .{});

    const failure = try mergeFailure(io, allocator, &arena, host, viewer, &opened, &id, body);
    if (failure) |err| return api.respondError(request, allocator, err, .{});
    return api_patches.respondDetail(request, allocator, &arena, io, &opened, &id, .ok);
}

// merges the patch as the viewer, or says why it wasn't merged
fn mergeFailure(
    io: std.Io,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    host: api_repo.Host,
    viewer: ?[evt.event_id_size]u8,
    opened: *api_thread.Opened,
    id: *const [evt.event_id_size]u8,
    body: MergeRequest,
) !?api.Error {
    const server = switch (host) {
        .local => return blockedError(.local),
        .server => |server| server,
    };
    const author = switch (try authorize(io, arena, server, viewer, opened)) {
        .author => |author| author,
        .refused => |err| return err,
    };
    const method = std.meta.stringToEnum(patch_merge.Method, body.method) orelse return invalidField("method", "Merge with \"source\" or \"squash\".");
    if (!isHex(body.revision, evt.event_id_size * 2)) return invalidField("revision", "Send the id of the patch revision you reviewed.");
    if (!isHex(body.target_commit, sha1_hex_len) and !isHex(body.target_commit, sha256_hex_len)) return invalidField("target_commit", "Send the target branch's commit you reviewed against.");
    const refusal = try patch_merge.merge(
        .{ .users_dir = server.users_dir, .admin_repo_path = server.admin_repo_path },
        io,
        allocator,
        opened.source,
        author,
        id,
        method,
        .{ .revision = body.revision, .target_commit = body.target_commit },
    );
    return if (refusal) |value| refusalError(value) else null;
}

// the merging viewer's identity: a writer of the repository, in a patches
// tab they may write to, decided afresh as the TUI and the merge form do
fn authorize(
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    server: @FieldType(api_repo.Host, "server"),
    viewer: ?[evt.event_id_size]u8,
    opened: *api_thread.Opened,
) !union(enum) { author: evt.CommitAuthor, refused: api.Error } {
    const user_id = viewer orelse return .{ .refused = unauthenticated };
    const moment = opened.session.haxy_moment orelse return .{ .refused = unauthenticated };
    return switch (try ui.authorizeUser(io, moment, arena, server.users_dir, user_id, opened.resolved.identity, patch_merge.min_role, .patch)) {
        .actor => |actor| .{ .author = actor.author },
        .login_required => .{ .refused = unauthenticated },
        .repo_not_found => .{ .refused = api_repo.not_found_repo },
        .forbidden => .{ .refused = forbidden },
    };
}

const sha1_hex_len = 40;
const sha256_hex_len = 64;

fn isHex(text: []const u8, len: usize) bool {
    if (text.len != len) return false;
    for (text) |char| if (!std.ascii.isDigit(char) and !(char >= 'a' and char <= 'f')) return false;
    return true;
}

fn invalidField(comptime field: []const u8, comptime message: []const u8) api.Error {
    return .{ .code = .validation, .message = "Check the request's fields.", .field_errors = &.{.{ .field = field, .message = message }} };
}

fn conflictOn(comptime field: []const u8, comptime message: []const u8, comptime detail: []const u8) api.Error {
    return .{ .code = .conflict, .message = message, .field_errors = &.{.{ .field = field, .message = detail }} };
}

const not_merged = "The patch wasn't merged.";
const review_again = " Load it again and review it before merging.";

/// a refusal to merge, as the API answers it: what moved since the client's
/// review (its `revision` or `target_commit`), how the method fares against
/// the target (`method`), or why haxy no longer offers merging it, as the
/// patch's `mergeability` would now say
pub fn refusalError(refusal: patch_merge.Refusal) api.Error {
    return switch (refusal) {
        .stale_revision => conflictOn("revision", not_merged, "This patch proposes another revision now, or changed while it was being merged." ++ review_again),
        .target_moved => conflictOn("target_commit", not_merged, "The target branch moved since you loaded this patch." ++ review_again),
        .conflict => conflictOn("method", not_merged, "Merging this way conflicts with the target branch."),
        .unchecked => conflictOn("method", not_merged, "Haxy hasn't checked this merge against the target branch's tip yet. Load the patch again shortly."),
        .not_open => blockedError(.not_open),
        .not_pushed => blockedError(.no_revision),
        .fork_gone => blockedError(.no_source),
        .conflicted => blockedError(.conflicted),
        .not_found => api_patches.no_such_patch,
    };
}

fn blockedError(block: Patches.MergeBlock) api.Error {
    const reason = api_patches.mergeUnavailable(block);
    return .{ .code = switch (reason.code) {
        .conflict => .conflict,
        .unauthenticated => .unauthenticated,
        .forbidden => .forbidden,
        .unsupported, .disabled => .unsupported,
    }, .message = reason.message };
}
