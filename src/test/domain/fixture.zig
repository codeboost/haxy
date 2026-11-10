//! temp server data and temp local repos for the domain tests. every fixture
//! lives in a tmp dir it removes on deinit.

const std = @import("std");
const hx = @import("../../lib.zig");
const evt = hx.event;
const domain = hx.domain;
const xit = hx.xit;
const rp = xit.repo;
const hash = xit.hash;
const copy = @import("../../copy.zig");

const io = std.testing.io;
const allocator = std.testing.allocator;

pub const Id = [evt.event_id_size]u8;

const tester: evt.CommitAuthor = .{ .name = "tester", .email = "tester@example.test" };

// a server data dir holding:
// - alice, who created the public repo `alice:open` and the private repo
//   `alice:secret`, with their default tabs (the patch tab is off)
// - bob, granted write on both repos
// - carol, a stranger to both
// - dave, granted write on both repos and then removed
pub const Server = struct {
    temp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    admin: rp.Repo(.xit, evt.admin_repo_opts),
    users_dir: []const u8,
    alice: Id,
    bob: Id,
    carol: Id,
    dave: Id,
    open: evt.RepoLocation,
    secret: evt.RepoLocation,

    pub const alice_author: evt.CommitAuthor = .{ .name = "alice", .email = "alice@example.test" };
    pub const bob_author: evt.CommitAuthor = .{ .name = "bob", .email = "bob@example.test" };
    pub const carol_author: evt.CommitAuthor = .{ .name = "carol", .email = "carol@example.test" };
    pub const dave_author: evt.CommitAuthor = .{ .name = "dave", .email = "dave@example.test" };

    // heap allocated so the admin repo a Ctx points at stays put
    pub fn init(comptime hash_kind: hash.HashKind) !*Server {
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);
        self.temp = std.testing.tmpDir(.{});
        errdefer self.temp.cleanup();
        self.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.arena.deinit();
        const aa = self.arena.allocator();
        const base = try self.temp.dir.realPathFileAlloc(io, ".", aa);
        self.users_dir = try std.Io.Dir.path.join(aa, &.{ base, "users" });
        self.admin = try evt.initAdminRepo(io, allocator, try std.Io.Dir.path.join(aa, &.{ base, "admin" }));
        errdefer self.admin.deinit(io, allocator);

        self.alice = try createUser(self, alice_author);
        self.bob = try createUser(self, bob_author);
        self.carol = try createUser(self, carol_author);
        self.dave = try createUser(self, dave_author);

        self.open = try evt.createRepo(io, allocator, self.users_dir, &self.alice, alice_author, "open", "", .public, hash_kind, null);
        self.secret = try evt.createRepo(io, allocator, self.users_dir, &self.alice, alice_author, "secret", "", .private, hash_kind, null);
        for ([_]evt.RepoLocation{ self.open, self.secret }) |location| {
            for ([_]*const Id{ &self.bob, &self.dave }) |user| {
                try evt.grantRole(io, allocator, self.users_dir, &self.alice, &location.repo_id, user, .write, alice_author);
            }
        }
        try evt.deleteUser(io, allocator, self.users_dir, &self.admin, &self.dave, dave_author);
        return self;
    }

    fn createUser(self: *Server, author: evt.CommitAuthor) !Id {
        return try evt.createUser(io, allocator, self.users_dir, &self.admin, author.name, author.email, "password", "password");
    }

    pub fn deinit(self: *Server) void {
        self.admin.deinit(io, allocator);
        self.arena.deinit();
        self.temp.cleanup();
        allocator.destroy(self);
    }

    // a context acting as `user`, or logged out when null. results land in `arena`.
    pub fn ctx(self: *Server, arena: *std.heap.ArenaAllocator, user: ?Id) !domain.Ctx {
        return try domain.Ctx.initServer(io, allocator, arena, &self.admin, self.users_dir, user, 0);
    }

    // the account `user` names as it stands now, or null once it is removed
    pub fn account(self: *Server, user: Id) !?evt.User.Record {
        const moment = try evt.currentMoment(evt.admin_repo_opts, &self.admin);
        return try domain.activeUser(moment, &self.arena, user);
    }

    // the id of the account named `name`, or null when there is none
    pub fn accountId(self: *Server, name: []const u8) !?Id {
        const moment = try evt.currentMoment(evt.admin_repo_opts, &self.admin);
        return try evt.User.readIdByName(evt.AdminDB, evt.admin_repo_opts.hash, moment, name);
    }

    // whether `name` and `password` log in, as the login form checks them
    pub fn logsIn(self: *Server, name: []const u8, password: []const u8) !bool {
        const moment = try evt.currentMoment(evt.admin_repo_opts, &self.admin);
        return switch (try evt.User.verifyCredentials(evt.AdminDB, evt.admin_repo_opts.hash, moment, &self.arena, name, password)) {
            .success => true,
            else => false,
        };
    }

    // alice's issue `issue` on the open repo with bob's comment `comment` on
    // it, which notifies her
    pub fn notifyAlice(self: *Server, issue: Id, comment: Id) !void {
        try self.addIssue(self.open, alice_author, issue);
        try self.addComment(self.open, bob_author, comment, issue, "hi");
    }

    // a server page session acting as `user`
    pub fn session(self: *Server, arena: *std.heap.ArenaAllocator, user: *const Id) !hx.ui.Session {
        var result = try hx.ui.Session.init(arena, &self.admin, .{ .user_id = user });
        result.io = io;
        result.users_dir = self.users_dir;
        return result;
    }

    // the on-disk path of a repo in the fixture
    pub fn repoPath(self: *Server, location: evt.RepoLocation) ![]const u8 {
        return try std.Io.Dir.path.join(self.arena.allocator(), &.{ self.users_dir, &std.fmt.bytesToHex(location.owner_id, .lower), "repos", &std.fmt.bytesToHex(location.repo_id, .lower) });
    }

    // set the roles of a repo's discussion, issue and patch tabs; null turns a tab off
    pub fn setTabs(self: *Server, location: evt.RepoLocation, discuss: ?evt.Repo.Role, issue: ?evt.Repo.Role, patch: ?evt.Repo.Role) !void {
        const name, const access: evt.Repo.Access = if (std.mem.eql(u8, &location.repo_id, &self.open.repo_id)) .{ "open", .public } else .{ "secret", .private };
        try evt.updateRepo(io, allocator, self.users_dir, &self.alice, alice_author, name, name, "", access, discuss, issue, patch);
    }

    // commit a readme to a repo's master branch, which patches may target
    pub fn commitReadme(self: *Server, location: evt.RepoLocation) !void {
        var any_repo = try rp.AnyRepo(.xit, .{}).open(io, allocator, .{ .path = try self.repoPath(location) });
        defer any_repo.deinit(io, allocator);
        switch (any_repo) {
            inline else => |*repo| {
                // server repos are bare, so give this one a worktree for the commit
                try repo.addConfig(io, allocator, .{ .name = "core.bare", .value = "false" });
                defer repo.addConfig(io, allocator, .{ .name = "core.bare", .value = "true" }) catch {};
                {
                    const file = try repo.core.work_dir.createFile(io, "README", .{});
                    defer file.close(io);
                    try file.writeStreamingAll(io, "repo\n");
                }
                try repo.add(io, allocator, &.{"README"});
                _ = try repo.commit(io, allocator, .{ .message = "initial", .author = "alice <alice@example.test>" });
            },
        }
    }

    // the oid `branch` of a repo points at, or null when it doesn't exist
    pub fn readBranch(self: *Server, location: evt.RepoLocation, branch: []const u8) !?[]const u8 {
        var any_repo = try rp.AnyRepo(.xit, .{}).open(io, allocator, .{ .path = try self.repoPath(location) });
        defer any_repo.deinit(io, allocator);
        return switch (any_repo) {
            inline else => |*repo| if (try repo.readRef(io, .{ .kind = .head, .name = branch })) |oid| try self.arena.allocator().dupe(u8, &oid) else null,
        };
    }

    // the branch a repo's HEAD names, its default, or null when HEAD is detached
    pub fn defaultBranch(self: *Server, location: evt.RepoLocation) !?[]const u8 {
        var any_repo = try rp.AnyRepo(.xit, .{}).open(io, allocator, .{ .path = try self.repoPath(location) });
        defer any_repo.deinit(io, allocator);
        var buffer: [xit.ref.MAX_REF_CONTENT_SIZE]u8 = undefined;
        return switch (any_repo) {
            inline else => |*repo| switch (try repo.head(io, &buffer)) {
                .ref => |ref| try self.arena.allocator().dupe(u8, ref.name),
                .oid => null,
            },
        };
    }

    // set a repo's `undo.value` config, one transaction in its history
    pub fn setUndoValue(self: *Server, location: evt.RepoLocation, value: []const u8) !void {
        var any_repo = try rp.AnyRepo(.xit, .{}).open(io, allocator, .{ .path = try self.repoPath(location) });
        defer any_repo.deinit(io, allocator);
        switch (any_repo) {
            inline else => |*repo| try repo.addConfig(io, allocator, .{ .name = "undo.value", .value = value }),
        }
    }

    // a repo's `undo.value` config, or null when it has none
    pub fn undoValue(self: *Server, location: evt.RepoLocation) !?[]const u8 {
        var any_repo = try rp.AnyRepo(.xit, .{}).open(io, allocator, .{ .path = try self.repoPath(location) });
        defer any_repo.deinit(io, allocator);
        switch (any_repo) {
            inline else => |*repo| {
                var config = try repo.listConfig(io, allocator);
                defer config.deinit();
                const section = config.local_sections.get("undo") orelse return null;
                const value = section.get("value") orelse return null;
                return try self.arena.allocator().dupe(u8, value);
            },
        }
    }

    // how many transactions a repo's history holds; the next one gets this index
    pub fn historyCount(self: *Server, location: evt.RepoLocation) !u64 {
        var any_repo = try rp.AnyRepo(.xit, .{}).open(io, allocator, .{ .path = try self.repoPath(location) });
        defer any_repo.deinit(io, allocator);
        switch (any_repo) {
            inline else => |*repo| {
                const DB = @TypeOf(repo.*).DB;
                const history = try DB.ArrayList(.read_only).init(repo.core.db.rootCursor().readOnly());
                return try history.count();
            },
        }
    }

    // the lowest transaction undo may reach in a copied repo, or null for one that isn't a copy
    pub fn undoFloor(self: *Server, location: evt.RepoLocation) !?u64 {
        var any_repo = try rp.AnyRepo(.xit, .{}).open(io, allocator, .{ .path = try self.repoPath(location) });
        defer any_repo.deinit(io, allocator);
        return switch (any_repo) {
            inline else => |*repo| try copy.undoFloor(repo.self_repo_opts, &repo.core),
        };
    }

    // the location of `owner`'s repo `name`
    pub fn locate(self: *Server, owner: Id, name: []const u8) !evt.RepoLocation {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var user_repo = (try evt.openUserRepo(io, allocator, self.users_dir, &owner)) orelse return error.TestExpectedUserRepo;
        defer user_repo.deinit(io, allocator);
        const moment = (try evt.userMoment(&user_repo)) orelse return error.TestExpectedRepo;
        const found = (try evt.Repo.readByName(evt.UserDB, evt.user_repo_opts.hash, moment, &arena, name)) orelse return error.TestExpectedRepo;
        return .{ .owner_id = owner, .repo_id = found.event_id };
    }

    // commit `contents` as the README of `branch` in a repo, starting the
    // branch from master when it doesn't exist yet, so a patch has a source
    pub fn commitBranch(self: *Server, location: evt.RepoLocation, branch: []const u8, contents: []const u8) !void {
        var any_repo = try rp.AnyRepo(.xit, .{}).open(io, allocator, .{ .path = try self.repoPath(location) });
        defer any_repo.deinit(io, allocator);
        switch (any_repo) {
            inline else => |*repo| {
                // server repos are bare, so give this one a worktree for the commit
                try repo.addConfig(io, allocator, .{ .name = "core.bare", .value = "false" });
                defer repo.addConfig(io, allocator, .{ .name = "core.bare", .value = "true" }) catch {};
                try commitOnBranch(repo, branch, "README", contents);
            },
        }
    }

    // a fork-backed draft patch `user` starts on a repo, targeting master
    pub fn addDraft(self: *Server, location: evt.RepoLocation, user: Id, author: evt.CommitAuthor, id: Id) !void {
        const path = try hx.fork.create(.{}, io, allocator, self.users_dir, .{
            .id = std.fmt.bytesToHex(id, .lower),
            .user_id = user,
            .repo_id = location.repo_id,
            .repo_user_id = location.owner_id,
            .repo_name = if (std.mem.eql(u8, &location.repo_id, &self.open.repo_id)) "open" else "secret",
            .title = "a draft",
            .description = "",
            .labels = "",
            .target_branch = "master",
            .author = author,
            .timestamp = 1,
        });
        allocator.free(path);
    }

    // record `branch`'s tip as the newest revision of the draft `id` that
    // `user` started, as a push to its fork does. the fork copied the repo, so
    // it holds the branch when the branch predates the draft.
    pub fn pushDraft(self: *Server, user: Id, author: evt.CommitAuthor, id: Id, branch: []const u8) !void {
        const path = try hx.fork.forkPath(self.arena.allocator(), self.users_dir, &user, &id);
        var any_repo = try rp.AnyRepo(.xit, .{}).open(io, allocator, .{ .path = path, .require_repo_root = true });
        defer any_repo.deinit(io, allocator);
        switch (any_repo) {
            inline else => |*repo| {
                const opts = repo.self_repo_opts;
                const base_oid = (try repo.readRef(io, .{ .kind = .head, .name = "master" })) orelse return error.TestExpectedBranch;
                const source_oid = (try repo.readRef(io, .{ .kind = .head, .name = branch })) orelse return error.TestExpectedBranch;
                const base_tree = try commitTree(opts, repo, &base_oid);
                const head_tree = try commitTree(opts, repo, &source_oid);
                const host: evt.Host = .{ .server = .{ .users_dir = self.users_dir, .admin_repo_path = self.admin.core.work_path } };
                const revision_id: Id = @splat(0xee);
                try evt.consume(host, .fork, .xit, opts, io, allocator, repo, evt.events_ref, &.{.{
                    .id = std.fmt.bytesToHex(revision_id, .lower),
                    .author = author,
                    .tree_entries = &.{ .{ .tree = .{ .name = "base", .oid = &base_tree } }, .{ .tree = .{ .name = "head", .oid = &head_tree } } },
                    .event = .{ .patchrev = .{ .base_oid = &base_oid, .source_oid = &source_oid, .message = branch } },
                }});
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const moment = try evt.currentMoment(opts, repo);
                const revision = (try evt.PatchRev.readById(evt.EventDB(opts.hash), opts.hash, moment, &arena, &revision_id)) orelse return error.TestExpectedRevision;
                var patch = ((try evt.Patch.readById(evt.EventDB(opts.hash), opts.hash, moment, &arena, &id)) orelse return error.TestExpectedPatch).event;
                patch.revision = evt.Patch.Revision.fromRecord(revision_id, revision);
                try evt.consume(host, .fork, .xit, opts, io, allocator, repo, evt.events_ref, &.{.{ .id = std.fmt.bytesToHex(id, .lower), .author = author, .event = .{ .patch = patch } }});
            },
        }
    }

    // whether `user` is notified of the thread `thread` in a repo, read
    // through the notify module from its owner's user repo
    pub fn isNotified(self: *Server, location: evt.RepoLocation, thread: Id, user: Id) !bool {
        var owner_repo = (try evt.openUserRepo(io, allocator, self.users_dir, &location.owner_id)) orelse return error.TestExpectedUserRepo;
        defer owner_repo.deinit(io, allocator);
        const moment = try owner_repo.core.latestMoment();
        return try hx.notify.isNotified(moment, &hx.notify.idOf(&location.repo_id, &thread), &user);
    }

    // the bytes of the attachment `id` names in a repo, read from its blob
    // through the repo, as a download does
    pub fn readAttachment(self: *Server, location: evt.RepoLocation, id: []const u8) ![]const u8 {
        var any_repo = try rp.AnyRepo(.xit, .{}).open(io, allocator, .{ .path = try self.repoPath(location) });
        defer any_repo.deinit(io, allocator);
        switch (any_repo) {
            inline else => |*repo| {
                const opts = repo.self_repo_opts;
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const id_bytes = try evt.parseEventId(id);
                const record = (try evt.Attachment.readById(evt.EventDB(opts.hash), opts.hash, try evt.currentMoment(opts, repo), &arena, &id_bytes)) orelse return error.TestExpectedAttachment;
                var moment = try repo.core.latestMoment();
                const state = rp.Repo(.xit, opts).State(.read_only){ .core = &repo.core, .extra = .{ .moment = &moment } };
                var reader = try xit.object.ObjectReader(.xit, opts).init(state, io, allocator, record.blob_oid[0..comptime hash.hexLen(opts.hash)]);
                defer reader.deinit();
                return try reader.interface.allocRemaining(self.arena.allocator(), .unlimited);
            },
        }
    }

    // add an issue authored by `author` to a repo, returning its id
    pub fn addIssue(self: *Server, location: evt.RepoLocation, author: evt.CommitAuthor, id: Id) !void {
        try self.addEvent(location, author, id, .{ .issue = .{ .title = "an issue", .description = "", .labels = "" } });
    }

    // add a comment authored by `author` to the thread `thread`, under the id `id`
    pub fn addComment(self: *Server, location: evt.RepoLocation, author: evt.CommitAuthor, id: Id, thread: Id, body: []const u8) !void {
        const thread_hex = std.fmt.bytesToHex(thread, .lower);
        try self.addEvent(location, author, id, .{ .comment = .{ .thread_id = thread_hex, .parent_id = thread_hex, .body = body } });
    }

    // attach a small file authored by `author` to the thread `thread`, returning its hex id
    pub fn addAttachment(self: *Server, location: evt.RepoLocation, author: evt.CommitAuthor, kind: evt.EventKind, thread: Id) ![evt.event_id_size * 2]u8 {
        const path = try self.repoPath(location);
        var any_repo = try rp.AnyRepo(.xit, .{}).open(io, allocator, .{ .path = path });
        defer any_repo.deinit(io, allocator);
        const contents = "hello\n";
        var reader = std.Io.Reader.fixed(contents);
        return switch (any_repo) {
            inline else => |*repo| try evt.Attachment.create(
                .{ .server = .{ .users_dir = self.users_dir, .admin_repo_path = self.admin.core.work_path } },
                .xit,
                repo.self_repo_opts,
                io,
                allocator,
                repo,
                kind,
                &std.fmt.bytesToHex(thread, .lower),
                .{ .name = "notes.txt", .size = contents.len, .reader = &reader },
                author,
            ),
        };
    }

    // add an event authored by `author` to a repo under the id `id`
    pub fn addEvent(self: *Server, location: evt.RepoLocation, author: evt.CommitAuthor, id: Id, event: evt.Event) !void {
        const path = try self.repoPath(location);
        var any_repo = try rp.AnyRepo(.xit, .{}).open(io, allocator, .{ .path = path });
        defer any_repo.deinit(io, allocator);
        switch (any_repo) {
            inline else => |*repo| try evt.consume(
                .{ .server = .{ .users_dir = self.users_dir, .admin_repo_path = self.admin.core.work_path } },
                .repo,
                .xit,
                repo.self_repo_opts,
                io,
                allocator,
                repo,
                evt.events_ref,
                &.{.{ .id = std.fmt.bytesToHex(id, .lower), .author = author, .event = event }},
            ),
        }
    }
};

// the tree of the commit `oid` names
fn commitTree(comptime opts: anytype, repo: anytype, oid: anytype) !@TypeOf(oid.*) {
    var moment = try repo.core.latestMoment();
    const state = rp.Repo(.xit, opts).State(.read_only){ .core = &repo.core, .extra = .{ .moment = &moment } };
    var object = try xit.object.Object(.xit, opts).initCommit(state, io, allocator, oid);
    defer object.deinit();
    return object.content.commit.tree;
}

// commit `contents` as `file` on `branch` of a repo with a worktree on
// master, starting the branch from master when it doesn't exist yet, and leave
// master checked out
fn commitOnBranch(repo: anytype, branch: []const u8, file_name: []const u8, contents: []const u8) !void {
    const on_master = std.mem.eql(u8, branch, "master");
    if (!on_master) {
        if (try repo.readRef(io, .{ .kind = .head, .name = branch }) == null) try repo.addBranch(io, .{ .name = branch });
        var selected = try repo.switchDir(io, allocator, .{ .target = .{ .ref = .{ .kind = .head, .name = branch } } });
        selected.deinit();
    }
    {
        const file = try repo.core.work_dir.createFile(io, file_name, .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, contents);
    }
    try repo.add(io, allocator, &.{file_name});
    _ = try repo.commit(io, allocator, .{ .message = contents, .author = "tester <tester@example.test>" });
    if (!on_master) {
        var restored = try repo.switchDir(io, allocator, .{ .target = .{ .ref = .{ .kind = .head, .name = "master" } } });
        restored.deinit();
    }
}

// server data as `haxy serve` first makes it, with no accounts yet
pub const FreshServer = struct {
    temp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    admin: rp.Repo(.xit, evt.admin_repo_opts),
    users_dir: []const u8,

    // heap allocated so the admin repo a Ctx points at stays put
    pub fn init() !*FreshServer {
        const self = try allocator.create(FreshServer);
        errdefer allocator.destroy(self);
        self.temp = std.testing.tmpDir(.{});
        errdefer self.temp.cleanup();
        self.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.arena.deinit();
        const aa = self.arena.allocator();
        const base = try self.temp.dir.realPathFileAlloc(io, ".", aa);
        self.users_dir = try std.Io.Dir.path.join(aa, &.{ base, "users" });
        self.admin = try evt.initAdminRepo(io, allocator, try std.Io.Dir.path.join(aa, &.{ base, "admin" }));
        return self;
    }

    pub fn deinit(self: *FreshServer) void {
        self.admin.deinit(io, allocator);
        self.arena.deinit();
        self.temp.cleanup();
        allocator.destroy(self);
    }

    // a context acting as `user`, or logged out when null. results land in `arena`.
    pub fn ctx(self: *FreshServer, arena: *std.heap.ArenaAllocator, user: ?Id) !domain.Ctx {
        return try domain.Ctx.initServer(io, allocator, arena, &self.admin, self.users_dir, user, 0);
    }
};

// a temp local repo of `kind` and `hash_kind` with one commit on master, the
// way `haxy` with no arguments sees a repo
pub fn Local(comptime kind: rp.RepoKind, comptime hash_kind: hash.HashKind) type {
    return struct {
        temp: std.testing.TmpDir,
        path: [:0]const u8,
        // the oid master points at
        master_oid: [hash.hexLen(hash_kind)]u8,

        const Self = @This();
        pub const repo_opts: rp.RepoOpts(kind) = .{ .hash = hash_kind };

        pub fn init() !Self {
            var temp = std.testing.tmpDir(.{});
            errdefer temp.cleanup();
            const path = try temp.dir.realPathFileAlloc(io, ".", allocator);
            errdefer allocator.free(path);
            var repo = try rp.Repo(kind, repo_opts).init(io, allocator, .{ .path = path });
            defer repo.deinit(io, allocator);
            {
                const file = try repo.core.work_dir.createFile(io, "readme.txt", .{});
                defer file.close(io);
                try file.writeStreamingAll(io, "hello\n");
            }
            try repo.add(io, allocator, &.{"readme.txt"});
            const oid = try repo.commit(io, allocator, .{ .message = "first", .author = "tester <tester@example.test>" });
            return .{ .temp = temp, .path = path, .master_oid = oid };
        }

        pub fn deinit(self: *Self) void {
            allocator.free(self.path);
            self.temp.cleanup();
        }

        pub fn source(self: *const Self) hx.ui.RepoSource {
            return .{ .path = self.path, .repo_kind = kind };
        }

        // set the repo's user.name and user.email
        pub fn setAuthor(self: *const Self, author: evt.CommitAuthor) !void {
            var repo = try rp.Repo(kind, repo_opts).open(io, allocator, .{ .path = self.path });
            defer repo.deinit(io, allocator);
            try repo.addConfig(io, allocator, .{ .name = "user.name", .value = author.name });
            try repo.addConfig(io, allocator, .{ .name = "user.email", .value = author.email });
        }

        // add a remote `name` fetching from `url`, which may be another
        // local repo's path
        pub fn addRemote(self: *const Self, name: []const u8, url: []const u8) !void {
            var repo = try rp.Repo(kind, repo_opts).open(io, allocator, .{ .path = self.path });
            defer repo.deinit(io, allocator);
            try repo.addRemote(io, allocator, .{ .name = name, .value = url });
        }

        // set a config entry of the repo
        pub fn setConfig(self: *const Self, name: []const u8, value: []const u8) !void {
            var repo = try rp.Repo(kind, repo_opts).open(io, allocator, .{ .path = self.path });
            defer repo.deinit(io, allocator);
            try repo.addConfig(io, allocator, .{ .name = name, .value = value });
        }

        // commit `contents` as the readme of `branch`, starting it from master
        // when it doesn't exist yet
        pub fn commitBranch(self: *const Self, branch: []const u8, contents: []const u8) !void {
            var repo = try rp.Repo(kind, repo_opts).open(io, allocator, .{ .path = self.path });
            defer repo.deinit(io, allocator);
            try commitOnBranch(&repo, branch, "readme.txt", contents);
        }

        // start `branch` with a commit of its own that shares no history with master
        pub fn commitOrphan(self: *const Self, branch: []const u8) !void {
            var repo = try rp.Repo(kind, repo_opts).open(io, allocator, .{ .path = self.path });
            defer repo.deinit(io, allocator);
            _ = try repo.commitAtRef(io, allocator, .{ .message = "orphan", .author = "tester <tester@example.test>", .parent_oids = &.{} }, null, .{ .kind = .head, .name = branch });
        }

        // add an event to the events branch and consume it, as a write does
        pub fn addEvent(self: *const Self, author: evt.CommitAuthor, id: Id, event: evt.Event) !void {
            var repo = try rp.Repo(kind, repo_opts).open(io, allocator, .{ .path = self.path });
            defer repo.deinit(io, allocator);
            try evt.consume(.local, .repo, kind, repo_opts, io, allocator, &repo, evt.events_ref, &.{.{ .id = std.fmt.bytesToHex(id, .lower), .author = author, .event = event }});
        }

        // an issue whose labels a merge of two event histories set apart, so
        // its labels conflict: ours on the events branch, theirs merged in
        pub fn conflictIssueLabels(self: *const Self, id: Id, ours: []const u8, theirs: []const u8) !void {
            if (kind != .xit) @compileError("the merge runs on a xit worktree");
            // the merge commit is authored from the config
            try self.setAuthor(tester);
            try self.addEvent(tester, id, .{ .issue = .{ .title = "an issue", .description = "", .labels = "" } });
            var repo = try rp.Repo(kind, repo_opts).open(io, allocator, .{ .path = self.path });
            defer repo.deinit(io, allocator);
            const base = (try repo.readRef(io, evt.events_ref)) orelse return error.TestExpectedEvents;
            const other: xit.ref.Ref = .{ .kind = .head, .name = "haxy/other" };
            for ([_]xit.ref.Ref{ evt.events_ref, other }, [_][]const u8{ ours, theirs }) |ref, labels| {
                const event = evt.EventWithId{ .id = std.fmt.bytesToHex(id, .lower), .author = tester, .event = .{ .issue = .{ .title = "an issue", .description = "", .labels = labels } } };
                var json: std.Io.Writer.Allocating = .init(allocator);
                defer json.deinit();
                try std.json.Stringify.value(event, .{}, &json.writer);
                _ = try repo.commitAtRef(io, allocator, .{ .parent_oids = &.{base}, .message = json.written(), .author = "tester <tester@example.test>" }, null, ref);
            }
            {
                var on_events = try repo.switchDir(io, allocator, .{ .target = .{ .ref = evt.events_ref } });
                on_events.deinit();
                var merge = try repo.merge(io, allocator, .{ .kind = .full, .action = .{ .new = .{ .source = &.{.{ .ref = other }} } } }, null);
                defer merge.deinit();
                if (merge.result != .success) return error.TestExpectedMerge;
                var on_master = try repo.switchDir(io, allocator, .{ .target = .{ .ref = .{ .kind = .head, .name = "master" } } });
                on_master.deinit();
            }
            try evt.consume(.local, .repo, kind, repo_opts, io, allocator, &repo, evt.events_ref, &.{});
        }

        // commit an event to a git repo's events branch without consuming it
        // into the event db next to the repo, as a fetch or a push from
        // elsewhere leaves it
        pub fn commitUnconsumed(self: *const Self, author: evt.CommitAuthor, id: Id, event: evt.Event) !void {
            if (kind != .git) @compileError("a xit repo consumes in the commit's transaction");
            var repo = try rp.Repo(kind, repo_opts).open(io, allocator, .{ .path = self.path });
            defer repo.deinit(io, allocator);
            try evt.commitEvents(kind, repo_opts, .{ .core = &repo.core, .extra = .{} }, io, allocator, evt.events_ref, &.{.{ .id = std.fmt.bytesToHex(id, .lower), .author = author, .event = event }}, null);
        }

        pub fn ctx(self: *const Self, arena: *std.heap.ArenaAllocator) domain.Ctx {
            return domain.Ctx.initLocal(io, allocator, arena, self.source(), 0);
        }
    };
}
