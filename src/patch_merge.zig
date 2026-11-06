//! merging a patch, as the TUI, Haxy's web forms and the JSON API all do it:
//! with the method chosen (its source commits or its squashed commit) and
//! what the merging client was shown (the patch's revision and the target
//! branch's tip), which the merge checks again inside its own write, so a
//! patch or a target that moved since is refused rather than merged unseen.
//! every refusal is reported as one; none is ever answered as a merge.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const evt = @import("event.zig");
const pch = @import("patch.zig");
const ui = @import("ui.zig");

/// who may merge: the repository's writers (and its owner), in a patches
/// tab they may write to
pub const min_role: evt.Repo.Role = .write;

pub const Method = evt.Patch.MergeRevision;

/// what the merging client was shown, as hex ids
pub const Reviewed = struct {
    revision: []const u8,
    target_commit: []const u8,
};

/// why a merge didn't happen
pub const Refusal = enum {
    // the patch proposes another revision, or changed while merging
    stale_revision,
    // the target branch moved, or is gone
    target_moved,
    // the chosen method conflicts with the target
    conflict,
    // haxy hasn't checked the merge against the target's tip
    unchecked,
    // closed, or merged already
    not_open,
    // nothing pushed yet
    not_pushed,
    // a fork-backed patch whose fork is gone
    fork_gone,
    // concurrent edits to its fields await resolution
    conflicted,
    // no such patch
    not_found,
};

/// merges patch `id` of the server repository at `source`, or says why not
pub fn merge(
    server: evt.Host.Server,
    io: std.Io,
    allocator: std.mem.Allocator,
    source: ui.RepoSource,
    author: evt.CommitAuthor,
    id: *const [evt.event_id_size]u8,
    method: Method,
    reviewed: Reviewed,
) !?Refusal {
    // haxy checks mergeability only in its own repositories
    if (source.repo_kind != .xit) return .unchecked;
    var target_repo = try rp.AnyRepo(.xit, .{}).open(io, allocator, source.localInitOpts());
    defer target_repo.deinit(io, allocator);
    const input: pch.MergeInput = .{
        .id = std.fmt.bytesToHex(id.*, .lower),
        .revision = method,
        .author = author,
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        .reviewed = .{ .revision = reviewed.revision, .target_oid = reviewed.target_commit },
    };
    const merged = switch (target_repo) {
        inline else => |*repo| pch.mergeAndRemoveFork(repo.self_repo_opts, io, allocator, server, repo, input),
    };
    merged catch |err| return refusalOf(err) orelse err;
    return null;
}

/// the refusal a merge's error stands for, or null for a failure
pub fn refusalOf(err: anyerror) ?Refusal {
    return switch (err) {
        error.StaleRevision, error.PatchOutOfDate => .stale_revision,
        error.TargetMoved, error.InvalidTargetBranch => .target_moved,
        error.MergeConflict => .conflict,
        error.MergeCheckUnavailable => .unchecked,
        error.PatchClosed, error.PatchAlreadyMerged => .not_open,
        error.PatchNotPushed => .not_pushed,
        error.PatchDataUnavailable => .fork_gone,
        error.PatchConflicted => .conflicted,
        error.InvalidPatch => .not_found,
        else => null,
    };
}

/// a refusal, as the TUI and Haxy's merge page say it
pub fn refusalText(refusal: Refusal) []const u8 {
    return switch (refusal) {
        .stale_revision => "not merged: the patch changed since this page loaded. review it again",
        .target_moved => "not merged: the target branch moved since this page loaded. review the patch again",
        .conflict => "not merged: this conflicts with the target branch",
        .unchecked => "not merged: haxy hasn't checked this against the target branch's tip yet. try again shortly",
        .not_open => "not merged: the patch is no longer open",
        .not_pushed => "not merged: nothing has been pushed to this patch",
        .fork_gone => "not merged: the patch's fork is gone",
        .conflicted => "not merged: concurrent edits to this patch need resolving first",
        .not_found => "not merged: the patch is gone",
    };
}
