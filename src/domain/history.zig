//! history reads: a ref's log, one commit and what a commit or patch revision
//! changed, bridged over the commits and diff loaders the pages use, so they
//! return the loaders' own data types.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const evt = @import("../event.zig");
const domain = @import("../domain.zig");
const ui = @import("../ui.zig");
const accounts = @import("accounts.zig");
const fork_id_note = @import("files.zig").fork_id_note;

const Commits = ui.Repo.Commits;
const RefOrOid = ui.RoutablePage.RefOrOid;
const RoutablePage = ui.RoutablePage;

pub const ListCommits = struct {
    pub const tool_name = "list_commits";
    pub const tool_description = "List a repository's commits from a branch, tag or commit back along first parents, newest first, a window at a time; the result's next_start is the from of the next window.";
    pub const tool_schema_notes = .{
        .repo = domain.repo_note,
        .ref_kind = "What ref names: branch, tag or object (a commit oid); omitted lists the default branch.",
        .ref = "The branch or tag name, or the commit's hex oid; needs ref_kind, else the arguments are invalid.",
        .base = "A commit's hex oid where the walk stops, leaving it out; it isn't checked to be an ancestor, so a base the walk never meets lists to the root. Omitted lists to the root.",
        .merge = "A merge commit's hex oid: lists the commits it brought in, from its second parent back to the parents' common ancestor. Goes with from only; with ref_kind, ref, base or search the arguments are invalid.",
        .search = "Words to find in the commit messages of an indexed branch or tag (server repos).",
        .from = "The oid of the first commit of the window to list, a previous result's next_start; \"\" or omitted lists the first window. In a plain log the cursor may be any commit and the walk goes on from it; it isn't checked to be on the named branch. In a search it must be one of the results.",
        .fork_id = fork_id_note ++ " A fork's log names a commit by object or none (its patch branch) and stops at its newest revision's base, leaving the base out; a commit before the base walks on to the root. With a branch or tag, base, merge or search the arguments are invalid.",
    };

    // "owner:name"; "" in local mode
    repo: []const u8,
    // null lists the default branch
    ref_kind: ?RefOrOid = null,
    // decoded branch or tag name, or a commit oid
    ref: []const u8 = "",
    // the commit the walk stops at, without it
    base: []const u8 = "",
    // a merge commit whose brought-in commits are listed, set alone
    merge: []const u8 = "",
    // decoded; the ui search syntax
    search: []const u8 = "",
    // the oid of the window's first commit; "" for the first window
    from: []const u8 = "",
    // a fork's hex id, to list the fork's log instead of the repo's
    fork_id: []const u8 = "",

    pub const Result = Commits;

    pub fn run(self: ListCommits, ctx: *domain.Ctx) !Commits {
        if (self.fork_id.len != 0) return try accounts.runFork(ListCommits, self, ctx);
        return try runResolved(ListCommits, self, ctx);
    }

    // the open fork's log, as the fork page shows it: from its patch branch
    // or a commit back to its newest revision's base
    pub fn runOpenFork(
        self: ListCommits,
        ctx: *domain.Ctx,
        comptime repo_opts: rp.RepoOpts(.xit),
        repo: *rp.Repo(.xit, repo_opts),
        fork: domain.ResolvedFork,
        tip: domain.ForkTip(repo_opts.hash),
    ) !Commits {
        // the fork's base is its own, and its log isn't indexed for search
        if (self.base.len != 0 or self.merge.len != 0 or self.search.len != 0) return error.InvalidReadArguments;
        if (self.ref_kind) |kind| {
            // the fork page routes no branch or tag
            if (kind != .object) return error.InvalidReadArguments;
            _ = try readCommit(.xit, repo_opts, ctx, repo, self.ref);
        } else if (self.ref.len != 0) return error.InvalidReadArguments;
        if (self.from.len != 0) _ = try readCommit(.xit, repo_opts, ctx, repo, self.from);
        return try forkLog(repo_opts, ctx, repo, fork, self.repo, tip, self.ref_kind, self.ref, false, self.from);
    }

    pub fn runOpen(
        self: ListCommits,
        ctx: *domain.Ctx,
        comptime repo_kind: rp.RepoKind,
        comptime repo_opts: rp.RepoOpts(repo_kind),
        repo: *rp.Repo(repo_kind, repo_opts),
        resolved: domain.Resolved,
    ) !Commits {
        // the open repo is no fork's
        if (self.fork_id.len != 0) return error.NotFound;
        // a name without its kind can't be looked up
        if (self.ref_kind == null and self.ref.len != 0) return error.InvalidReadArguments;
        const ref_kind: ?RefOrOid, const value: []const u8, const base: []const u8 = if (self.merge.len != 0) merged: {
            // a merge names its own head and base, and its log isn't indexed;
            // a cursor goes on through it
            if (self.ref_kind != null or self.base.len != 0 or self.search.len != 0) return error.InvalidReadArguments;
            const merged = try Commits.resolveMerge(repo_kind, repo_opts, ctx.arena, repo, ctx.io, ctx.gpa, self.merge);
            break :merged .{ .object, merged.oid, merged.base_oid };
        } else .{ self.ref_kind, self.ref, self.base };
        // the page shows an empty log for an oid that names no commit
        if (ref_kind == .object) _ = try readCommit(repo_kind, repo_opts, ctx, repo, value);
        if (base.len != 0) _ = try readCommit(repo_kind, repo_opts, ctx, repo, base);
        if (self.from.len != 0) _ = try readCommit(repo_kind, repo_opts, ctx, repo, self.from);

        const log = try Commits.loadStrict(repo_kind, repo_opts, ctx.arena, repo, ctx.io, ctx.gpa, ctx.moment, try handleOf(ctx, resolved, self.repo), ref_kind, value, false, base, self.search, self.from);
        // a cursor the walk or the search doesn't reach starts no window of it
        if (self.from.len != 0 and (log.commits.len == 0 or !std.mem.eql(u8, log.commits[0].oid, self.from))) return error.NotFound;
        return log;
    }
};

pub const GetCommit = struct {
    pub const tool_name = "get_commit";
    pub const tool_description = "Read one commit of a repository: its whole message, author, committer, time, first parent and, in xit repos, its change stats.";
    pub const tool_schema_notes = .{
        .repo = domain.repo_note,
        .oid = "The commit's hex oid.",
        .fork_id = fork_id_note ++ " The fork's log stops at its newest revision's base, so that commit itself isn't found; a commit before it is.",
    };

    // "owner:name"; "" in local mode. with `fork_id`, the fork's "forker:name"
    repo: []const u8,
    // the commit's hex oid
    oid: []const u8,
    // a fork's hex id, to read the commit from the fork
    fork_id: []const u8 = "",

    pub const Result = Commits.Commit;

    pub fn run(self: GetCommit, ctx: *domain.Ctx) !Commits.Commit {
        if (self.fork_id.len != 0) return try accounts.runFork(GetCommit, self, ctx);
        return try runResolved(GetCommit, self, ctx);
    }

    // a commit of the open fork, as the fork's commit page reads it
    pub fn runOpenFork(
        self: GetCommit,
        ctx: *domain.Ctx,
        comptime repo_opts: rp.RepoOpts(.xit),
        repo: *rp.Repo(.xit, repo_opts),
        fork: domain.ResolvedFork,
        tip: domain.ForkTip(repo_opts.hash),
    ) !Commits.Commit {
        _ = try readCommit(.xit, repo_opts, ctx, repo, self.oid);
        const log = try forkLog(repo_opts, ctx, repo, fork, self.repo, tip, .object, self.oid, true, "");
        // the walk stops at the base itself, so it reads nothing for the base;
        // an ancestor of the base starts a walk that never meets it
        if (log.commits.len == 0) return error.NotFound;
        return log.commits[0];
    }

    // the log rooted at the commit with its whole message, as the commit's
    // own page reads it
    pub fn runOpen(
        self: GetCommit,
        ctx: *domain.Ctx,
        comptime repo_kind: rp.RepoKind,
        comptime repo_opts: rp.RepoOpts(repo_kind),
        repo: *rp.Repo(repo_kind, repo_opts),
        resolved: domain.Resolved,
    ) !Commits.Commit {
        // the open repo is no fork's
        if (self.fork_id.len != 0) return error.NotFound;
        _ = try readCommit(repo_kind, repo_opts, ctx, repo, self.oid);
        const log = try Commits.loadStrict(repo_kind, repo_opts, ctx.arena, repo, ctx.io, ctx.gpa, ctx.moment, try handleOf(ctx, resolved, self.repo), .object, self.oid, true, "", "", "");
        if (log.commits.len == 0) return error.NotFound;
        return log.commits[0];
    }
};

pub const Diff = struct {
    pub const tool_name = "get_diff";
    pub const tool_description = "Read what a commit changed against its first parent (or a given base), or what a patch revision changes, as a window of up to 10 hunks in file order. Each hunk's text is its lines, numbered, each with its +, - or space prefix (prefixes holds one per line). A file's first hunk in a window carries its path; a hunk with a null path continues the file of the hunk before it. An added, removed or binary file is one entry with its path and status and no lines. While has_more is set, the next window starts at start plus the number of hunks returned; truncated means the rest was too large to diff.";
    pub const tool_schema_notes = .{
        .repo = domain.repo_note,
        .oid = "The commit's hex oid; set exactly one of oid and patchrev, else the arguments are invalid.",
        .base = "The hex oid of the commit to compare the commit with, all zeros for none; omitted is its first parent. Not with patchrev, whose base is its own.",
        .patchrev = "A patch revision's hex event id, whose diff against its base is read; set exactly one of oid and patchrev.",
        .start = "The index of the first hunk of the window, a previous window's start plus its number of hunks; 0 or omitted reads the first window.",
        .path = "A changed file's path, to read only its hunks; omitted reads every file. At most 1024 bytes.",
        .fork_id = fork_id_note ++ " Without oid, a fork's diff is its whole patch's, against its newest revision's base, and takes no base. A fork has no patchrev.",
    };

    // "owner:name"; "" in local mode
    repo: []const u8,
    // the commit's hex oid; set this or `patchrev`
    oid: []const u8 = "",
    // what the commit is compared with; "" is its first parent
    base: []const u8 = "",
    // a patch revision's hex event id
    patchrev: []const u8 = "",
    // the index of the window's first hunk
    start: usize = 0,
    // decoded; one changed file's path, "" for every file
    path: []const u8 = "",
    // a fork's hex id, to read the fork's diff instead of the repo's
    fork_id: []const u8 = "",

    pub const Result = ui.Repo.Diff;

    pub fn run(self: Diff, ctx: *domain.Ctx) !ui.Repo.Diff {
        if (self.fork_id.len != 0) return try accounts.runFork(Diff, self, ctx);
        return try runResolved(Diff, self, ctx);
    }

    // the open fork's diff, as the fork page shows it: a commit's, or with
    // no oid the whole patch's against its newest revision's base
    pub fn runOpenFork(
        self: Diff,
        ctx: *domain.Ctx,
        comptime repo_opts: rp.RepoOpts(.xit),
        repo: *rp.Repo(.xit, repo_opts),
        fork: domain.ResolvedFork,
        tip: domain.ForkTip(repo_opts.hash),
    ) !ui.Repo.Diff {
        // a fork has no revisions of its own to name
        if (self.patchrev.len != 0) return error.InvalidReadArguments;
        // the whole patch's base is the fork's own
        if (self.oid.len == 0 and self.base.len != 0) return error.InvalidReadArguments;
        const base = if (self.oid.len == 0) "" else try compareBase(.xit, repo_opts, ctx, repo, self.oid, self.base);
        const diff = try ui.Fork.loadDiff(repo_opts, ctx.arena, repo, ctx.io, ctx.gpa, self.repo, &std.fmt.bytesToHex(fork.id, .lower), tip, self.oid, base, self.start, self.path);
        if (diff.window.hunks.len == 0 and !diff.window.truncated and (self.start != 0 or self.path.len != 0)) return error.NotFound;
        return diff;
    }

    pub fn runOpen(
        self: Diff,
        ctx: *domain.Ctx,
        comptime repo_kind: rp.RepoKind,
        comptime repo_opts: rp.RepoOpts(repo_kind),
        repo: *rp.Repo(repo_kind, repo_opts),
        resolved: domain.Resolved,
    ) !ui.Repo.Diff {
        _ = resolved;
        // the open repo is no fork's
        if (self.fork_id.len != 0) return error.NotFound;
        // exactly one of the two names what is read
        if ((self.oid.len == 0) == (self.patchrev.len == 0)) return error.InvalidReadArguments;
        // a revision's base is its own
        if (self.patchrev.len != 0 and self.base.len != 0) return error.InvalidReadArguments;
        // a value longer than a route holds is no input a page could send
        var route: RoutablePage.RepoDiffRoute = .{
            .name = RoutablePage.Array(RoutablePage.repo_identity_max_len).from(self.repo) orelse return error.InvalidReadArguments,
            .start = self.start,
            .path = RoutablePage.Array(RoutablePage.repo_route_max_len).from(self.path) orelse return error.InvalidReadArguments,
        };
        if (self.patchrev.len != 0) {
            // a malformed id names no revision
            route.patchrev_id = RoutablePage.Array(evt.event_id_size * 2).from(self.patchrev) orelse return error.NotFound;
        } else {
            const base = try compareBase(repo_kind, repo_opts, ctx, repo, self.oid, self.base);
            route.ref_or_oid = .object;
            // both are checked commit oids, which fit
            route.value = RoutablePage.Array(RoutablePage.ref_route_max_len).from(self.oid) orelse unreachable;
            route.base_oid = RoutablePage.Array(RoutablePage.ref_route_max_len).from(base) orelse unreachable;
        }
        const diff = try ui.Repo.Diff.init(repo_kind, repo_opts, ctx.arena, repo, ctx.io, ctx.gpa, route);
        // a window past the end, or a path the diff doesn't touch, is nothing
        // the diff has, unless the diff was too large to reach it
        if (diff.window.hunks.len == 0 and !diff.window.truncated and (self.start != 0 or self.path.len != 0)) return error.NotFound;
        return diff;
    }
};

// what the commit `oid` names is compared with: `base` ("" is its first
// parent, all zeros is nothing) once both are commits, else NotFound
fn compareBase(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    ctx: *domain.Ctx,
    repo: *rp.Repo(repo_kind, repo_opts),
    oid: []const u8,
    base: []const u8,
) ![]const u8 {
    const parent = try readCommit(repo_kind, repo_opts, ctx, repo, oid);
    const zeros: [xit.hash.hexLen(repo_opts.hash)]u8 = @splat('0');
    if (base.len == 0)
        // a root commit is compared with nothing
        return try ctx.arena.allocator().dupe(u8, &(parent orelse zeros));
    if (std.mem.eql(u8, base, &zeros)) return base;
    _ = try readCommit(repo_kind, repo_opts, ctx, repo, base);
    return base;
}

// the first parent of the commit `oid` names, null for a root commit. an oid
// naming no object, or one that isn't a commit, is NotFound; a commit that
// can't be read is the failure it is.
fn readCommit(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    ctx: *domain.Ctx,
    repo: *rp.Repo(repo_kind, repo_opts),
    oid: []const u8,
) !?[xit.hash.hexLen(repo_opts.hash)]u8 {
    const hex_len = comptime xit.hash.hexLen(repo_opts.hash);
    evt.PatchRev.validateOid(repo_opts.hash, oid) catch return error.NotFound;
    var moment = try repo.core.latestMoment();
    const state = rp.Repo(repo_kind, repo_opts).State(.read_only){ .core = &repo.core, .extra = .{ .moment = &moment } };
    var commit = xit.object.Object(repo_kind, repo_opts).initCommit(state, ctx.io, ctx.gpa, oid[0..hex_len]) catch |err|
        return if (Commits.isMissingCommit(err)) error.NotFound else err;
    defer commit.deinit();
    return if (commit.content.commit.metadata.firstParent()) |parent| parent.* else null;
}

// the open fork's log as `ui.Fork.loadCommits` reads it for the page, walked
// strictly: a commit that can't be read fails instead of showing as empty
fn forkLog(
    comptime repo_opts: rp.RepoOpts(.xit),
    ctx: *domain.Ctx,
    repo: *rp.Repo(.xit, repo_opts),
    fork: domain.ResolvedFork,
    identity: []const u8,
    tip: domain.ForkTip(repo_opts.hash),
    ref_kind: ?RefOrOid,
    oid: []const u8,
    message: bool,
    from: []const u8,
) !Commits {
    var log = try Commits.loadStrict(.xit, repo_opts, ctx.arena, repo, ctx.io, ctx.gpa, ctx.moment, try accounts.forkHandle(ctx, fork, identity), ref_kind, oid, message, &tip.base, "", from);
    log.commit_count = tip.commit_count;
    // a cursor the walk doesn't start at starts no window of it
    if (from.len != 0 and (log.commits.len == 0 or !std.mem.eql(u8, log.commits[0].oid, from))) return error.NotFound;
    return log;
}

// run = resolve, open, runOpen
fn runResolved(comptime Op: type, op: Op, ctx: *domain.Ctx) !Op.Result {
    const resolved = (try domain.resolveRepo(ctx, op.repo)) orelse return error.NotFound;
    return try domain.withRepo(ctx, resolved, OpenArgs(Op){ .op = op, .resolved = resolved }, OpenArgs(Op).body);
}

// what `withRepo` hands its body, which calls the operation's runOpen.
// runOpen is generic, so the operation declares its result as `Result`.
fn OpenArgs(comptime Op: type) type {
    return struct {
        op: Op,
        resolved: domain.Resolved,

        fn body(
            comptime repo_kind: rp.RepoKind,
            comptime repo_opts: rp.RepoOpts(repo_kind),
            ctx: *domain.Ctx,
            repo: *rp.Repo(repo_kind, repo_opts),
            args: @This(),
        ) !Op.Result {
            return try args.op.runOpen(ctx, repo_kind, repo_opts, repo, args.resolved);
        }
    };
}

// the handle a page of the resolved repo is built with: where its links are
// rooted and who views it, as `Repo.init` builds it
fn handleOf(ctx: *domain.Ctx, resolved: domain.Resolved, identity: []const u8) !ui.RepoHandle {
    return .{
        .location = .{ .repo = try ctx.arena.allocator().dupe(u8, identity) },
        .viewer = switch (ctx.host) {
            .local => .{ .role = .owner, .email = "" },
            .server => if (ctx.user) |user| .{ .role = resolved.role, .email = user.event.email } else null,
        },
        .read_access = resolved.record.event.read_access,
    };
}
