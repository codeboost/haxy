//! read operations on a repo's files and refs, bridged over the files and refs
//! tab loaders, so they return the loaders' own data types.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const evt = @import("../event.zig");
const domain = @import("../domain.zig");
const ui = @import("../ui.zig");
const accounts = @import("accounts.zig");

const Files = ui.Repo.Files;
const Refs = ui.Repo.Refs;

pub const GetRepo = struct {
    pub const tool_name = "get_repo";
    pub const tool_description = "Read what any reader may see of a repository: its name, owner, description, access, tab roles, default branch, hash kind and the acting user's role.";
    pub const tool_schema_notes = .{
        .repo = domain.repo_note,
    };

    // "owner:name"; "" in local mode
    repo: []const u8,

    pub const Result = struct {
        name: []const u8,
        // "" in local mode, which has no accounts
        owner_name: []const u8,
        description: []const u8,
        access: evt.Repo.Access,
        // a tab's role is null when the tab is off
        discuss_role: ?evt.Repo.Role,
        issue_role: ?evt.Repo.Role,
        patch_role: ?evt.Repo.Role,
        // the branch HEAD names, null when HEAD is detached
        default_branch: ?[]const u8,
        hash_kind: hash.HashKind,
        // the acting user's role, null when logged out. local mode owns its repo.
        role: ?evt.Repo.Role,
    };

    pub fn run(self: GetRepo, ctx: *domain.Ctx) !Result {
        return try runResolved(GetRepo, self, ctx);
    }

    pub fn runOpen(
        self: GetRepo,
        ctx: *domain.Ctx,
        comptime repo_kind: rp.RepoKind,
        comptime repo_opts: rp.RepoOpts(repo_kind),
        repo: *rp.Repo(repo_kind, repo_opts),
        resolved: domain.Resolved,
    ) !Result {
        _ = self;
        const event = resolved.record.event;
        const owner_name = switch (ctx.host) {
            .local => "",
            .server => owner: {
                const owner_id = try evt.parseEventId(&event.user_id);
                const owner = (try evt.User.readById(evt.AdminDB, evt.admin_repo_opts.hash, ctx.moment orelse unreachable, ctx.arena, &owner_id)) orelse return error.NotFound;
                break :owner owner.event.name;
            },
        };
        // the settings page shows a head it can't read as no branch; a read
        // reports it
        var head_buffer: [xit.ref.MAX_REF_CONTENT_SIZE]u8 = undefined;
        const default_branch: ?[]const u8 = switch (try repo.head(ctx.io, &head_buffer)) {
            .ref => |ref| try ctx.arena.allocator().dupe(u8, ref.name),
            .oid => null,
        };
        return .{
            .name = event.name,
            .owner_name = owner_name,
            .description = event.description,
            .access = event.read_access,
            .discuss_role = event.discuss_role,
            .issue_role = event.issue_role,
            .patch_role = event.patch_role,
            .default_branch = default_branch,
            .hash_kind = repo_opts.hash,
            .role = if (viewer(ctx, resolved)) |v| v.role else null,
        };
    }
};

pub const ListFiles = struct {
    pub const tool_name = "list_files";
    pub const tool_description = "List one directory of a repository at a branch, tag or commit, directories first. The listing stops at 1000 entries (`capped` says it did), and each file entry carries the first window of its content, up to about 2 MB for the whole listing (`loaded` says which do).";
    pub const tool_schema_notes = .{
        .repo = domain.repo_note,
        .ref_kind = "What `ref` names: branch, tag or object (a commit's full hex oid); omitted lists the default branch. Given with `ref`, and not with `patchrev`.",
        .ref = "The branch or tag name or the commit oid; given with ref_kind, and omitted with it.",
        .path = "The directory, relative to the repository's root; \"\" or omitted is the root.",
        .patchrev = "A patch revision's hex event id, to list its files instead of a ref's; not with ref_kind or ref.",
        .fork_id = fork_id_note,
    };

    // "owner:name"; "" in local mode. with `fork_id`, the fork's "forker:name"
    repo: []const u8,
    // null is the default branch, with `ref` ""
    ref_kind: ?ui.RoutablePage.RefOrOid = null,
    // decoded
    ref: []const u8 = "",
    // decoded; "" is the root
    path: []const u8 = "",
    // a patch revision's hex event id, which replaces the ref
    patchrev: []const u8 = "",
    // a fork's hex id, to list the fork's files instead of the repo's
    fork_id: []const u8 = "",

    pub const Result = Files;

    pub fn run(self: ListFiles, ctx: *domain.Ctx) !Result {
        if (self.fork_id.len != 0) return try accounts.runFork(ListFiles, self, ctx);
        return try runResolved(ListFiles, self, ctx);
    }

    // the files of the open fork `fork` resolves to, as the fork page lists
    // them: at its patch branch or a commit
    pub fn runOpenFork(
        self: ListFiles,
        ctx: *domain.Ctx,
        comptime repo_opts: rp.RepoOpts(.xit),
        repo: *rp.Repo(.xit, repo_opts),
        fork: domain.ResolvedFork,
        tip: domain.ForkTip(repo_opts.hash),
    ) !Result {
        _ = tip;
        try checkForkRef(self.ref_kind, self.patchrev);
        return try self.list(ctx, .xit, repo_opts, repo, try accounts.forkHandle(ctx, fork, self.repo));
    }

    pub fn runOpen(
        self: ListFiles,
        ctx: *domain.Ctx,
        comptime repo_kind: rp.RepoKind,
        comptime repo_opts: rp.RepoOpts(repo_kind),
        repo: *rp.Repo(repo_kind, repo_opts),
        resolved: domain.Resolved,
    ) !Result {
        // the open repo is no fork's
        if (self.fork_id.len != 0) return error.NotFound;
        return try self.list(ctx, repo_kind, repo_opts, repo, try repoHandle(ctx, resolved, self.repo));
    }

    fn list(
        self: ListFiles,
        ctx: *domain.Ctx,
        comptime repo_kind: rp.RepoKind,
        comptime repo_opts: rp.RepoOpts(repo_kind),
        repo: *rp.Repo(repo_kind, repo_opts),
        handle: ui.RepoHandle,
    ) !Result {
        const files = try loadFiles(ctx, repo_kind, repo_opts, repo, handle, self.ref_kind, self.ref, self.patchrev, self.path, 0, "");
        // a path that names a file is the page's parent listing with it selected
        if (files.selected_file != null) return error.NotADirectory;
        return files;
    }
};

pub const ReadFile = struct {
    pub const tool_name = "read_file";
    pub const tool_description = "Read a window of up to 5000 lines of one file at a branch, tag or commit. `window_start` is the 0-based index of the window's first line; while `has_more` is true, the next window is read with `line` = window_start + lines.len + 1. A file that ends in a newline ends with an empty string in its last window. A binary file (invalid UTF-8, or too large) comes back with is_binary true and no lines.";
    pub const tool_schema_notes = .{
        .repo = domain.repo_note,
        .ref_kind = "What `ref` names: branch, tag or object (a commit's full hex oid); omitted reads the default branch. Given with `ref`, and not with `patchrev`.",
        .ref = "The branch or tag name or the commit oid; given with ref_kind, and omitted with it.",
        .path = "The file's path, relative to the repository's root.",
        .line = "The 1-based number of the window's first line; 0 or omitted is 1. The next window's is window_start + lines.len + 1.",
        .find = "A file name prefix to search the branch for, whose results `path` must be among; only a server branch has the index. Not with `patchrev`.",
        .patchrev = "A patch revision's hex event id, to read its file instead of a ref's; not with ref_kind, ref or find.",
        .fork_id = fork_id_note,
    };

    // "owner:name"; "" in local mode
    repo: []const u8,
    // null is the default branch, with `ref` ""
    ref_kind: ?ui.RoutablePage.RefOrOid = null,
    // decoded
    ref: []const u8 = "",
    // decoded
    path: []const u8,
    // 1-based; 0 is the first line
    line: usize = 0,
    // decoded
    find: []const u8 = "",
    // a patch revision's hex event id, which replaces the ref
    patchrev: []const u8 = "",
    // a fork's hex id, to read the fork's file instead of the repo's
    fork_id: []const u8 = "",

    pub const Result = Files.Entry;

    pub fn run(self: ReadFile, ctx: *domain.Ctx) !Result {
        if (self.fork_id.len != 0) return try accounts.runFork(ReadFile, self, ctx);
        return try runResolved(ReadFile, self, ctx);
    }

    // a file of the open fork `fork` resolves to, as the fork page shows it
    pub fn runOpenFork(
        self: ReadFile,
        ctx: *domain.Ctx,
        comptime repo_opts: rp.RepoOpts(.xit),
        repo: *rp.Repo(.xit, repo_opts),
        fork: domain.ResolvedFork,
        tip: domain.ForkTip(repo_opts.hash),
    ) !Result {
        _ = tip;
        try checkForkRef(self.ref_kind, self.patchrev);
        return try self.read(ctx, .xit, repo_opts, repo, try accounts.forkHandle(ctx, fork, self.repo));
    }

    pub fn runOpen(
        self: ReadFile,
        ctx: *domain.Ctx,
        comptime repo_kind: rp.RepoKind,
        comptime repo_opts: rp.RepoOpts(repo_kind),
        repo: *rp.Repo(repo_kind, repo_opts),
        resolved: domain.Resolved,
    ) !Result {
        // the open repo is no fork's
        if (self.fork_id.len != 0) return error.NotFound;
        return try self.read(ctx, repo_kind, repo_opts, repo, try repoHandle(ctx, resolved, self.repo));
    }

    fn read(
        self: ReadFile,
        ctx: *domain.Ctx,
        comptime repo_kind: rp.RepoKind,
        comptime repo_opts: rp.RepoOpts(repo_kind),
        repo: *rp.Repo(repo_kind, repo_opts),
        handle: ui.RepoHandle,
    ) !Result {
        // the root is a directory
        if (self.path.len == 0) return error.NotAFile;
        const files = try loadFiles(ctx, repo_kind, repo_opts, repo, handle, self.ref_kind, self.ref, self.patchrev, self.path, self.line, self.find);
        // a find lists its results by full path, a directory listing by name
        const name = if (self.find.len != 0) self.path else files.selected_file orelse return error.NotAFile;
        for (files.entries) |entry| {
            if (!entry.is_dir and std.mem.eql(u8, entry.name, name)) return entry;
        }
        return error.NotFound;
    }
};

pub const ListRefs = struct {
    pub const tool_name = "list_refs";
    pub const tool_description = "List a repository's branches or tags in name order, a window at a time; `next` names the next window's first ref and `prev` the previous window's (\"\" is the first).";
    pub const tool_schema_notes = .{
        .repo = domain.repo_note,
        .kind = "Which refs: branch or tag; omitted lists branches.",
        .search = "A prefix the names must start with.",
        .from = "The name of the first ref of the window to list; \"\" or omitted lists the first window.",
    };

    // "owner:name"; "" in local mode
    repo: []const u8,
    kind: ui.RoutablePage.RefKind = .branch,
    // decoded; a name prefix
    search: []const u8 = "",
    // decoded; the window's first name, "" for the first window
    from: []const u8 = "",

    pub const Result = Refs.Column;

    pub fn run(self: ListRefs, ctx: *domain.Ctx) !Result {
        return try runResolved(ListRefs, self, ctx);
    }

    pub fn runOpen(
        self: ListRefs,
        ctx: *domain.Ctx,
        comptime repo_kind: rp.RepoKind,
        comptime repo_opts: rp.RepoOpts(repo_kind),
        repo: *rp.Repo(repo_kind, repo_opts),
        resolved: domain.Resolved,
    ) !Result {
        const refs = try Refs.load(.propagate, repo_kind, repo_opts, ctx.arena, repo, ctx.io, ctx.gpa, self.repo, self.kind, self.from, self.search);
        _ = resolved;
        const column = switch (self.kind) {
            .branch => refs.branches,
            .tag => refs.tags,
        };
        // the loader seeks to the first name at or after `from`, so one that
        // names no ref leaves the window somewhere else
        if (self.from.len != 0 and (column.names.len == 0 or !std.mem.eql(u8, column.names[0], self.from))) return error.NotFound;
        return column;
    }
};

// the files tab's data for a ref or a patch revision, read the way the page
// reads it except that what the tree names but can't be read is an error, not
// an empty file or listing. a ref, path or revision that doesn't exist is
// NotFound; inputs that can't go together are InvalidReadArguments.
fn loadFiles(
    ctx: *domain.Ctx,
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    repo: *rp.Repo(repo_kind, repo_opts),
    handle: ui.RepoHandle,
    ref_kind: ?ui.RoutablePage.RefOrOid,
    ref: []const u8,
    patchrev: []const u8,
    path: []const u8,
    line: usize,
    find: []const u8,
) !Files {
    if (patchrev.len != 0) {
        // a revision replaces the ref and has no file index
        if (ref_kind != null or ref.len != 0 or find.len != 0) return error.InvalidReadArguments;
        return try Files.loadPatchRev(.propagate, repo_kind, repo_opts, ctx.arena, repo, ctx.io, ctx.gpa, handle, patchrev, path, line);
    }
    // a ref and its kind come together
    if ((ref_kind == null) != (ref.len == 0)) return error.InvalidReadArguments;
    const value = if (ref_kind) |kind| switch (kind) {
        .branch, .tag => ref,
        .object => oid: {
            // the loader only checks an oid's length and lists nothing for one
            // that names no tree, so it is looked up here
            if (!try hasTree(repo_kind, repo_opts, repo, ctx.io, ctx.gpa, ref)) return error.NotFound;
            break :oid ref;
        },
    } else "";
    const files = try Files.loadWith(.propagate, repo_kind, repo_opts, ctx.arena, repo, ctx.io, ctx.gpa, handle, ref_kind, value, path, line, find);
    // with no commit on the default branch the loader lists nothing at any path
    if (files.no_commits and path.len != 0) return error.NotFound;
    return files;
}

// the handle a page of the resolved repo is built with, as `Repo.init` builds it
fn repoHandle(ctx: *domain.Ctx, resolved: domain.Resolved, identity: []const u8) !ui.RepoHandle {
    return .{
        .location = .{ .repo = identity },
        .viewer = viewer(ctx, resolved),
        .read_access = resolved.record.event.read_access,
    };
}

pub const fork_id_note = "A fork's hex id, to read the fork instead of a repository; `repo` is then the fork as \"forker:name\", the name it was made under. A fork is read at its patch branch or a commit (ref_kind object), and has no patch revisions to name: with fork_id, ref_kind branch or tag and patchrev are invalid. Server only.";

// what a fork-addressed read may name: the fork page routes its patch branch
// or a commit, and no patch revision
fn checkForkRef(ref_kind: ?ui.RoutablePage.RefOrOid, patchrev: []const u8) !void {
    if (patchrev.len != 0) return error.InvalidReadArguments;
    if (ref_kind) |kind| if (kind != .object) return error.InvalidReadArguments;
}

// whether `oid` is a full hex oid naming a commit, tag or tree of the repo
fn hasTree(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    gpa: std.mem.Allocator,
    oid: []const u8,
) !bool {
    const hex_len = comptime hash.hexLen(repo_opts.hash);
    if (oid.len != hex_len) return false;
    for (oid) |c| if (!std.ascii.isHex(c)) return false;
    var moment = try repo.core.latestMoment();
    const state = rp.Repo(repo_kind, repo_opts).State(.read_only){ .core = &repo.core, .extra = .{ .moment = &moment } };
    var object = xit.object.Object(repo_kind, repo_opts).init(state, io, gpa, oid[0..hex_len]) catch |err| switch (err) {
        error.ObjectNotFound => return false,
        else => |e| return e,
    };
    defer object.deinit();
    return object.content != .blob;
}

// who the files tab is read for, as `Repo.init` builds its handle: null when
// logged out. local mode owns everything.
fn viewer(ctx: *domain.Ctx, resolved: domain.Resolved) ?ui.Viewer {
    return switch (ctx.host) {
        .local => .{ .role = .owner, .email = "" },
        .server => .{ .role = resolved.role, .email = (ctx.user orelse return null).event.email },
    };
}

// run = resolve, open, runOpen
fn runResolved(comptime Op: type, op: Op, ctx: *domain.Ctx) !Op.Result {
    const resolved = (try domain.resolveRepo(ctx, op.repo)) orelse return error.NotFound;
    return try domain.withRepo(ctx, resolved, Opened(Op){ .op = op, .resolved = resolved }, Opened(Op).body);
}

fn Opened(comptime Op: type) type {
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
