//! a patch's draft: a patch started with a new fork of its target repo
//! (src/fork.zig), which stays its author's alone until they publish it.
//! the TUI's patches tab, Haxy's HTML forms and the JSON API all go through
//! these, so the rules live in one place:
//!
//! - who may start a draft, or change or publish one, is the author's right
//!   to write in the target's patches tab (`ui.authorizeUser`), which callers
//!   check when the write runs;
//! - a draft is its author's: for anyone else, and for a draft of another
//!   repo, there is none (error.NotFound);
//! - a draft's target must be an existing branch of its target repo;
//! - publishing is Haxy's own `pch.publish`.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const rf = xit.ref;
const evt = @import("./event.zig");
const fork = @import("./fork.zig");
const pch = @import("./patch.zig");
const thread_write = @import("./thread_write.zig");
const ui = @import("./ui.zig");

const Patches = ui.Repo.Patches;

/// the repo a draft proposes changes to
pub const Target = struct {
    source: ui.RepoSource,
    repo_id: [evt.event_id_size]u8,
};

/// starts a draft under `id` with a new fork of `target`, made under the
/// repo's `repo_name`, written by `actor`. the caller has checked the fields
/// (`thread_write.checkFields`) and the actor's right to write patches.
/// error.InvalidTargetBranch when the target names no branch; error.IdTaken
/// when the actor's forks or the target's events already have the id, so a
/// retry can't start a second draft.
pub fn start(
    users_dir: []const u8,
    io: std.Io,
    allocator: std.mem.Allocator,
    target: Target,
    repo_name: []const u8,
    actor: ui.Actor,
    id: *const [evt.event_id_size]u8,
    fields: thread_write.Fields,
) !void {
    const user_id = actor.user_id orelse return error.NotFound;
    const repo_user_id = actor.repo_user_id orelse return error.NotFound;
    if (!try branchExists(io, allocator, target.source, fields.target_branch)) return error.InvalidTargetBranch;
    if (try thread_write.idUsedIn(io, allocator, target.source, id)) return error.IdTaken;
    const fork_path = try fork.create(.{}, io, allocator, users_dir, .{
        .id = std.fmt.bytesToHex(id.*, .lower),
        .user_id = user_id,
        .repo_id = target.repo_id,
        .repo_user_id = repo_user_id,
        .repo_name = repo_name,
        .title = fields.title,
        .description = fields.description,
        .labels = fields.labels,
        .target_branch = fields.target_branch,
        .author = actor.author,
        .timestamp = now(io),
    });
    allocator.free(fork_path);
}

/// replaces the fields and target of `actor`'s draft `id` of `target`, as of
/// `revision` (its `evt.Patch.contentRevision`; null overwrites, as the TUI
/// and HTML forms do): error.Stale when it changed since. a new target drops
/// the revision pushed so far, as Haxy always has.
pub fn edit(
    users_dir: []const u8,
    io: std.Io,
    allocator: std.mem.Allocator,
    admin_repo: *rp.Repo(.xit, evt.admin_repo_opts),
    target: Target,
    actor: ui.Actor,
    id: *const [evt.event_id_size]u8,
    fields: thread_write.Fields,
    revision: ?evt.Patch.ContentRevision,
) !void {
    const user_id = actor.user_id orelse return error.NotFound;
    try ownDraft(io, allocator, users_dir, &user_id, &target.repo_id, id);
    if (!try branchExists(io, allocator, target.source, fields.target_branch)) return error.InvalidTargetBranch;
    const edited = try pch.editDraft(.{}, io, allocator, users_dir, admin_repo, .{
        .id = std.fmt.bytesToHex(id.*, .lower),
        .user_id = user_id,
        .repo_id = target.repo_id,
        .title = fields.title,
        .labels = fields.labels,
        .description = fields.description,
        .target_branch = fields.target_branch,
        .author = actor.author,
        .timestamp = now(io),
        .revision = revision,
    });
    if (!edited) return error.NotFound;
}

/// removes `actor`'s draft `id` of the repo `repo_id` names, its fork with it
pub fn remove(
    users_dir: []const u8,
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_id: *const [evt.event_id_size]u8,
    actor: ui.Actor,
    id: *const [evt.event_id_size]u8,
) !void {
    const user_id = actor.user_id orelse return error.NotFound;
    try ownDraft(io, allocator, users_dir, &user_id, repo_id, id);
    try fork.remove(io, allocator, users_dir, &user_id, &std.fmt.bytesToHex(id.*, .lower), actor.author);
}

/// publishes `actor`'s draft `id` as a patch of `target` under the same id,
/// with what was pushed to its fork. publishing a draft that already was
/// changes nothing, so a retry is safe. error.NotFound when the actor has no
/// such draft; error.PatchIdTaken when the target already has another
/// patch under its id; error.PatchNotPushed when its fork lacks the revision
/// it names.
pub fn publish(
    server: evt.Host.Server,
    io: std.Io,
    allocator: std.mem.Allocator,
    admin_repo: *rp.Repo(.xit, evt.admin_repo_opts),
    target: Target,
    actor: ui.Actor,
    id: *const [evt.event_id_size]u8,
) !void {
    const user_id = actor.user_id orelse return error.NotFound;
    var target_repo = try rp.AnyRepo(.xit, .{}).open(io, allocator, target.source.localInitOpts());
    defer target_repo.deinit(io, allocator);
    const published = switch (target_repo) {
        inline else => |*repo| pch.publish(repo.self_repo_opts, io, allocator, server, admin_repo, repo, .{
            .id = std.fmt.bytesToHex(id.*, .lower),
            .user_id = user_id,
            .repo_id = target.repo_id,
            .author = actor.author,
            .timestamp = now(io),
        }),
    };
    published catch |err| return switch (err) {
        error.InvalidPatchDraft => error.NotFound,
        error.InvalidPatch => error.PatchIdTaken,
        else => err,
    };
}

/// `user_id`'s draft `id` of the repo `repo_id` names, as the patches tab
/// lists it (`Patches.loadDraftEntry`), or null when they have none
pub fn read(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    admin_moment: evt.AdminDB.HashMap(.read_only),
    users_dir: []const u8,
    user: Owner,
    repo_id: *const [evt.event_id_size]u8,
    target_repo: *rp.Repo(repo_kind, repo_opts),
    id: *const [evt.event_id_size]u8,
) !?Patches.PatchWithId {
    const record = (try draftRecord(io, arena.child_allocator, arena, users_dir, &user.id, repo_id, id)) orelse return null;
    const path = try fork.forkPath(arena.allocator(), users_dir, &user.id, id);
    // a fork shares its target's hash kind
    var fork_repo = rp.Repo(.xit, .{ .hash = repo_opts.hash }).open(io, arena.child_allocator, .{ .path = path, .require_repo_root = true }) catch return null;
    defer fork_repo.deinit(io, arena.child_allocator);
    const fork_identity = try arena.allocator().print("{s}:{s}", .{ user.name, record.event.repo_name });
    return try Patches.loadDraftEntry(repo_kind, repo_opts, arena, io, admin_moment, &fork_repo, target_repo, id.*, fork_identity);
}

/// whether `user_id` started the draft `id` of the repo `repo_id` names
/// with a fork they still have, published since or not
pub fn ownsFork(
    io: std.Io,
    allocator: std.mem.Allocator,
    users_dir: []const u8,
    user_id: *const [evt.event_id_size]u8,
    repo_id: *const [evt.event_id_size]u8,
    id: *const [evt.event_id_size]u8,
) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const record = (try evt.readForkById(io, allocator, &arena, users_dir, user_id, id)) orelse return false;
    return !record.removed and std.mem.eql(u8, &record.event.repo_id, &std.fmt.bytesToHex(repo_id.*, .lower));
}

/// who a draft is read for: its author, by id and name
pub const Owner = struct {
    id: [evt.event_id_size]u8,
    name: []const u8,
};

/// whether `user_id` has the live draft `id` of the repo `repo_id` names
pub fn isDraft(
    io: std.Io,
    allocator: std.mem.Allocator,
    users_dir: []const u8,
    user_id: *const [evt.event_id_size]u8,
    repo_id: *const [evt.event_id_size]u8,
    id: *const [evt.event_id_size]u8,
) !bool {
    ownDraft(io, allocator, users_dir, user_id, repo_id, id) catch |err| return if (err == error.NotFound) false else err;
    return true;
}

// fails with error.NotFound unless `user_id` has the draft `id` of the repo `repo_id` names
fn ownDraft(
    io: std.Io,
    allocator: std.mem.Allocator,
    users_dir: []const u8,
    user_id: *const [evt.event_id_size]u8,
    repo_id: *const [evt.event_id_size]u8,
    id: *const [evt.event_id_size]u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = (try draftRecord(io, allocator, &arena, users_dir, user_id, repo_id, id)) orelse return error.NotFound;
}

// the fork record of `user_id`'s live draft `id` of the repo `repo_id` names, or null
fn draftRecord(
    io: std.Io,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    users_dir: []const u8,
    user_id: *const [evt.event_id_size]u8,
    repo_id: *const [evt.event_id_size]u8,
    id: *const [evt.event_id_size]u8,
) !?evt.Fork.Record {
    const record = (try evt.readForkById(io, allocator, arena, users_dir, user_id, id)) orelse return null;
    if (record.removed or record.event.stage != .draft) return null;
    if (!std.mem.eql(u8, &record.event.repo_id, &std.fmt.bytesToHex(repo_id.*, .lower))) return null;
    return record;
}

fn branchExists(io: std.Io, allocator: std.mem.Allocator, source: ui.RepoSource, branch: []const u8) !bool {
    return evt.Patch.branchValid(branch) and try source.hasBranch(io, allocator, branch);
}

fn now(io: std.Io) u64 {
    return @intCast(std.Io.Timestamp.now(io, .real).toSeconds());
}
