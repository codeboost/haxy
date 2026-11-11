//! repo-level operations.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const evt = @import("../event.zig");
const pch = @import("../patch.zig");
const domain = @import("../domain.zig");

pub const RefreshLocal = struct {
    pub const tool_name = "refresh_local";
    pub const tool_description = "Bring the local repository's issues, patches and discussions up to date with its events branch.";
    pub const tool_schema_notes = .{
        .repo = "\"\" or omitted; local mode has one repository.",
    };

    // "" in local mode, which has one repo
    repo: []const u8 = "",

    // consume the events branch into the event db and refresh the patch
    // branches, as a local page build does before it reads
    pub fn run(self: RefreshLocal, ctx: *domain.Ctx) !void {
        // a server consumes every write in its own transaction
        if (ctx.host != .local) return error.UnavailableHere;
        const resolved = (try domain.resolveRepo(ctx, self.repo)) orelse return error.NotFound;
        try domain.withRepo(ctx, resolved, {}, refresh);
    }
};

fn refresh(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    ctx: *domain.Ctx,
    repo: *rp.Repo(repo_kind, repo_opts),
    _: void,
) !void {
    try evt.consume(.local, .repo, repo_kind, repo_opts, ctx.io, ctx.gpa, repo, evt.events_ref, &.{});
    try pch.refreshBranches(.local, repo_kind, repo_opts, ctx.io, ctx.gpa, repo, null);
}
