//! the arranged data the page snapshots are taken of: one world per host kind,
//! made through the web forms with harness clients where a form exists and
//! through the event module or xit otherwise. everything gets a stable human
//! name: each step runs under a label, and the events it writes are named
//! after it in the id table (`<issue:leaky-roof>`, `<comment:leaky-roof.c03>`,
//! `<patchrev:p-open>`), commits by the label they are made under
//! (`<commit:feature-2>`). the clock and the ids come from `snapshot.Det`, so
//! two builds of a world are the same byte for byte.

const std = @import("std");
const xit = @import("xit");
const evt = @import("../../event.zig");
const h = @import("harness.zig");
const snap = @import("snapshot.zig");

const rp = xit.repo;
const gpa = std.testing.allocator;
const tio = std.testing.io;

// each step moves the frozen clock on by this much
const step_seconds = 60;

pub const File = struct { path: []const u8, bytes: []const u8 };

// the step labels, the event-id table and the urls made along the way
pub const Book = struct {
    arena: std.heap.ArenaAllocator,
    names: snap.Names,
    io: std.Io,
    steps: u64 = 0,
    label: []const u8 = "",
    // event commits already looked at, by repo path and oid
    seen: std.StringHashMapUnmanaged(void) = .empty,
    // urls a step led to, by label
    urls: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn init() Book {
        snap.Det.reset();
        return .{ .arena = std.heap.ArenaAllocator.init(gpa), .names = snap.Names.init(), .io = snap.Det.io() };
    }

    pub fn deinit(self: *Book) void {
        self.seen.deinit(gpa);
        self.urls.deinit(gpa);
        self.names.deinit();
        self.arena.deinit();
    }

    pub fn aa(self: *Book) std.mem.Allocator {
        return self.arena.allocator();
    }

    // start the step `label`: the clock moves on and ids come from its own seed
    pub fn step(self: *Book, label: []const u8) void {
        self.steps += 1;
        snap.Det.setClock(snap.Det.base_seconds + @as(i64, @intCast(self.steps)) * step_seconds);
        snap.Det.reseed(self.steps);
        self.label = label;
    }

    pub fn print(self: *Book, comptime fmt: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(self.aa(), fmt, args);
    }

    pub fn remember(self: *Book, label: []const u8, url_: []const u8) !void {
        try self.urls.put(gpa, try self.aa().dupe(u8, label), try self.aa().dupe(u8, url_));
    }

    pub fn url(self: *const Book, label: []const u8) []const u8 {
        return self.urls.get(label) orelse std.debug.panic("no url was remembered as {s}", .{label});
    }

    // the hex an event or commit was named with
    pub fn real(self: *const Book, kind: []const u8, label: []const u8) []const u8 {
        var buffer: [256]u8 = undefined;
        const name = std.fmt.bufPrint(&buffer, "<{s}:{s}>", .{ kind, label }) catch unreachable;
        for (self.names.hex.items) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.real;
        for (self.names.hex.items) |entry| if (std.mem.indexOf(u8, entry.name, label) != null) std.debug.print("  there is {s}\n", .{entry.name});
        std.debug.panic("nothing is named {s}", .{name});
    }

    // name the events of `repo`'s events branch not seen before after the
    // current step's label, oldest first
    pub fn sweepRepo(self: *Book, path: []const u8, repo: anytype) !void {
        const head = (try repo.readRef(self.io, evt.events_ref)) orelse return;
        const tip_key = try self.print("{s}#{s}", .{ path, &head });
        if (self.seen.contains(tip_key)) return;
        var iter = try repo.log(self.io, gpa, .{ .start_oids = &.{head} });
        defer iter.deinit();
        var found: std.ArrayList(struct { id: []const u8, kind: []const u8, data: ?std.json.Value, oid: []const u8 }) = .empty;
        defer found.deinit(gpa);
        while (try iter.next(gpa)) |object| {
            defer object.deinit();
            const key = try self.print("{s}#{s}", .{ path, &object.oid });
            if (self.seen.contains(key)) continue;
            try self.seen.put(gpa, key, {});
            const Message = struct { id: []const u8, kind: []const u8, data: ?std.json.Value = null };
            const parsed = std.json.parseFromSliceLeaky(Message, self.aa(), object.content.commit.metadata.message, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch continue;
            try found.append(gpa, .{ .id = parsed.id, .kind = parsed.kind, .data = parsed.data, .oid = try self.aa().dupe(u8, &object.oid) });
        }
        var i = found.items.len;
        while (i > 0) {
            i -= 1;
            const event = found.items[i];
            // an event's own commit, which a patch revision's pages show
            if (!self.names.has(event.oid)) _ = try self.names.addHexFresh(event.oid, "event-commit", self.label);
            if (event.data) |data| try self.nameOids(data);
            if (self.names.has(event.id)) continue;
            _ = try self.names.addIdHexFresh(event.id, event.kind, self.label);
        }
    }

    // the commits an event names in its `*_oid` fields (a patch revision's
    // squash commit, a merge's base) that no step named, after the label
    fn nameOids(self: *Book, data: std.json.Value) !void {
        switch (data) {
            .object => |object| {
                var it = object.iterator();
                while (it.next()) |entry| {
                    const value = entry.value_ptr.*;
                    if (std.mem.endsWith(u8, entry.key_ptr.*, "_oid") and value == .string and value.string.len != 0) {
                        const oid = value.string;
                        const zero = for (oid) |c| (if (c != '0') break false) else true;
                        if (!zero and !self.names.has(oid)) _ = try self.names.addHexFresh(oid, "commit", try self.print("{s}.{s}", .{ self.label, entry.key_ptr.* }));
                    } else try self.nameOids(value);
                }
            },
            .array => |array| for (array.items) |item| try self.nameOids(item),
            else => {},
        }
    }
};

// open the repo at `path` (git or xit, either hash) and run `f(book, repo, ctx)`
fn withAnyRepo(book: *Book, comptime kind: rp.RepoKind, path: []const u8, ctx: anytype, comptime f: anytype) !void {
    var any = try rp.AnyRepo(kind, .{}).open(book.io, gpa, .{ .path = path });
    defer any.deinit(book.io, gpa);
    switch (any) {
        inline else => |*repo| try f(book, repo, ctx),
    }
}

fn sweepOne(book: *Book, repo: anytype, path: []const u8) !void {
    try book.sweepRepo(path, repo);
}

// ---- content: files, commits, branches and tags through xit

// write `files` into the work dir, add and commit them as `author`; the
// commit is named `<commit:label>`
pub fn commitFiles(book: *Book, repo: anytype, files: []const File, message: []const u8, author: []const u8, label: []const u8) ![]const u8 {
    book.step(label);
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(gpa);
    for (files) |file| {
        if (std.Io.Dir.path.dirname(file.path)) |dir| try repo.core.work_dir.createDirPath(book.io, dir);
        const handle = try repo.core.work_dir.createFile(book.io, file.path, .{ .truncate = true });
        defer handle.close(book.io);
        try handle.writeStreamingAll(book.io, file.bytes);
        try paths.append(gpa, file.path);
    }
    try repo.add(book.io, gpa, paths.items);
    const oid = try repo.commit(book.io, gpa, .{ .message = message, .author = author });
    _ = try book.names.addHex(&oid, "commit", label);
    return book.aa().dupe(u8, &oid);
}

pub fn switchTo(book: *Book, repo: anytype, branch: []const u8) !void {
    var result = try repo.switchDir(book.io, gpa, .{ .target = .{ .ref = .{ .kind = .head, .name = branch } } });
    result.deinit();
}

// a branch at the checked-out commit
pub fn addBranch(book: *Book, repo: anytype, name: []const u8) !void {
    try repo.addBranch(book.io, .{ .name = name });
}

pub fn tip(book: *Book, repo: anytype, branch: []const u8) ![]const u8 {
    const oid = (try repo.readRef(book.io, .{ .kind = .head, .name = branch })) orelse return error.TestNoSuchBranch;
    return book.aa().dupe(u8, &oid);
}

// a merge commit of `other` into the checked-out branch keeping its tree
pub fn mergeCommit(book: *Book, repo: anytype, branch: []const u8, other: []const u8, author: []const u8, label: []const u8) ![]const u8 {
    book.step(label);
    const ours = (try repo.readRef(book.io, .{ .kind = .head, .name = branch })) orelse return error.TestNoSuchBranch;
    const theirs = (try repo.readRef(book.io, .{ .kind = .head, .name = other })) orelse return error.TestNoSuchBranch;
    const oid = try repo.commitAtRef(book.io, gpa, .{
        .message = try book.print("merge {s} into {s}", .{ other, branch }),
        .author = author,
        .parent_oids = &.{ ours, theirs },
    }, null, .{ .kind = .head, .name = branch });
    _ = try book.names.addHex(&oid, "commit", label);
    return book.aa().dupe(u8, &oid);
}

pub fn addTag(book: *Book, repo: anytype, name: []const u8, message: ?[]const u8) !void {
    book.step(name);
    _ = try repo.addTag(book.io, gpa, .{ .name = name, .message = message, .tagger = "alice <alice@example.test>" });
}

// the lines of a file long enough that the files tab windows it
pub fn longText(book: *Book, count: usize) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(book.aa());
    for (1..count + 1) |i| try out.writer.print("line {d}\n", .{i});
    return out.written();
}

pub const readme_md =
    \\# open
    \\
    \\a repo for **snapshots**, with a [link](https://example.test) and a list:
    \\
    \\- one
    \\- two
    \\
    \\```zig
    \\const x = 1;
    \\```
    \\
;

pub const binary_bytes = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x01\x02\x03";

// ---- the server world

pub const Server = struct {
    book: Book,
    server: *h.Server,
    anon: h.Client,
    alice: h.Client,
    bob: h.Client,
    carol: h.Client,
    erin: h.Client,
    frank: h.Client,
    full: bool,

    pub const erin_author: evt.CommitAuthor = .{ .name = "erin", .email = "erin@example.test" };
    pub const frank_author: evt.CommitAuthor = .{ .name = "frank", .email = "frank@example.test" };

    pub fn deinit(self: *Server) void {
        self.anon.deinit();
        self.alice.deinit();
        self.bob.deinit();
        self.carol.deinit();
        self.erin.deinit();
        self.frank.deinit();
        self.server.deinit();
        self.book.deinit();
        gpa.destroy(self);
    }

    // the server's repo `name` of `owner_id`, opened for `f(book, repo, ctx)`
    // with a work dir, which a bare server repo lacks
    fn withServerRepo(self: *Server, path: []const u8, ctx: anytype, comptime f: anytype) !void {
        const Wrap = struct {
            fn run(book: *Book, repo: anytype, inner: anytype) !void {
                try repo.addConfig(book.io, gpa, .{ .name = "core.bare", .value = "false" });
                defer repo.addConfig(book.io, gpa, .{ .name = "core.bare", .value = "true" }) catch {};
                try f(book, repo, inner);
            }
        };
        try withAnyRepo(&self.book, .xit, path, ctx, Wrap.run);
    }

    pub fn repoPath(self: *Server, location: evt.RepoLocation) ![]const u8 {
        return evt.repoPath(self.book.aa(), self.server.users_dir, &location.owner_id, &location.repo_id);
    }

    // name every event written since the last sweep after the current label
    pub fn sweep(self: *Server) !void {
        const book = &self.book;
        try withAnyRepo(book, .xit, self.server.admin_repo_path, self.server.admin_repo_path, sweepOne);
        var users = try std.Io.Dir.openDirAbsolute(tio, self.server.users_dir, .{ .iterate = true });
        defer users.close(tio);
        for (try sortedEntries(book.aa(), users)) |user| {
            const user_path = try std.Io.Dir.path.join(book.aa(), &.{ self.server.users_dir, user });
            const user_repo = try std.Io.Dir.path.join(book.aa(), &.{ user_path, "user" });
            // a fork shares its draft patch's id, which is better named as the patch
            for ([_][]const u8{ "repos", "forks" }) |sub| {
                const sub_path = try std.Io.Dir.path.join(book.aa(), &.{ user_path, sub });
                var dir = std.Io.Dir.openDirAbsolute(tio, sub_path, .{ .iterate = true }) catch continue;
                defer dir.close(tio);
                for (try sortedEntries(book.aa(), dir)) |entry| {
                    const repo_path = try std.Io.Dir.path.join(book.aa(), &.{ sub_path, entry });
                    try withAnyRepo(book, .xit, repo_path, repo_path, sweepOne);
                }
            }
            if (exists(user_repo)) try withAnyRepo(book, .xit, user_repo, user_repo, sweepOne);
        }
    }

    // a form post that must redirect; names what it wrote after `label` and
    // remembers where it led under `label`
    pub fn post(self: *Server, c: *h.Client, label: []const u8, path: []const u8, fields: []const h.Field) ![]const u8 {
        self.book.step(label);
        const r = try c.post(path, fields);
        defer r.deinit();
        if (r.status != .see_other) {
            r.describe();
            std.debug.print("step {s}: POST {s} did not redirect\n", .{ label, path });
            return error.TestStepFailed;
        }
        const location = r.header("location") orelse return error.TestExpectedLocation;
        try self.book.remember(label, location);
        try self.sweep();
        return self.book.url(label);
    }

    // a thread made through its new form; its page is remembered as `label`
    pub fn thread(self: *Server, c: *h.Client, label: []const u8, repo: []const u8, kind: []const u8, title: []const u8, labels: []const u8, description: []const u8) ![]const u8 {
        return self.post(c, label, try self.book.print("/{s}/{s}/new", .{ repo, kind }), &.{ .{ "title", title }, .{ "labels", labels }, .{ "description", description } });
    }

    pub fn comment(self: *Server, c: *h.Client, label: []const u8, thread_url: []const u8, parent: ?[]const u8, body: []const u8) ![]const u8 {
        const path = if (parent) |parent_label|
            try self.book.print("{s}/comment:{s}/new", .{ thread_url, self.book.real("comment", parent_label) })
        else
            try self.book.print("{s}/new", .{thread_url});
        return self.post(c, label, path, &.{.{ "body", body }});
    }

    pub fn attach(self: *Server, c: *h.Client, label: []const u8, thread_url: []const u8, name: []const u8, bytes: []const u8) !void {
        self.book.step(label);
        const r = try c.send(.{ .method = "POST", .path = try self.book.print("{s}/attach", .{thread_url}), .body = bytes, .headers = &.{
            .{ .name = "x-attachment-name", .value = name },
            .{ .name = "content-type", .value = "application/octet-stream" },
        } });
        defer r.deinit();
        if (r.status != .no_content) {
            r.describe();
            return error.TestStepFailed;
        }
        try self.sweep();
    }

    fn settings(self: *Server, repo: []const u8, name: []const u8, access: []const u8, discuss: []const u8, issue: []const u8, patch: []const u8) !void {
        _ = try self.post(&self.alice, try self.book.print("settings {s}", .{repo}), try self.book.print("/{s}/repo/settings", .{repo}), &.{
            .{ "name", name },            .{ "description", try self.book.print("the {s} repo", .{name}) }, .{ "access", access },
            .{ "discuss_role", discuss }, .{ "issue_role", issue },                                         .{ "patch_role", patch },
        });
    }

    fn createRepo(self: *Server, owner: *const h.Id, author: evt.CommitAuthor, name: []const u8, access: evt.Repo.Access, comptime hash_kind: xit.hash.HashKind) !evt.RepoLocation {
        self.book.step(try self.book.print("{s}:{s}", .{ author.name, name }));
        const location = try evt.createRepo(self.book.io, gpa, self.server.users_dir, owner, author, name, "", access, hash_kind, null);
        try self.sweep();
        return location;
    }

    fn login(self: *Server, name: []const u8) !h.Client {
        self.book.step(try self.book.print("login {s}", .{name}));
        return self.server.clientAs(name);
    }

    pub const Mode = enum {
        // the big sha1 world
        full,
        // the sha256 world: a little of everything
        small,
        // names and texts that need encoding, and long comment threads
        edges,
    };

    pub fn build(comptime hash_kind: xit.hash.HashKind, full: bool) !*Server {
        return buildMode(hash_kind, if (full) .full else .small);
    }

    pub fn buildMode(comptime hash_kind: xit.hash.HashKind, mode: Mode) !*Server {
        const full = mode == .full;
        const self = try gpa.create(Server);
        errdefer gpa.destroy(self);
        self.book = Book.init();
        errdefer self.book.deinit();
        self.full = full;
        const book = &self.book;
        book.step("cast");
        self.server = try h.Server.initWith(hash_kind, .{ .io = book.io });
        errdefer self.server.deinit();
        const server = self.server;
        _ = try book.names.addId(&server.alice, "user", "alice");
        _ = try book.names.addId(&server.bob, "user", "bob");
        _ = try book.names.addId(&server.carol, "user", "carol");
        _ = try book.names.addId(&server.dave, "user", "dave");
        _ = try book.names.addId(&server.open.repo_id, "repo", "alice:open");
        _ = try book.names.addId(&server.secret.repo_id, "repo", "alice:secret");
        try self.sweep();

        book.step("erin");
        const erin = try server.createUser(erin_author);
        _ = try book.names.addId(&erin, "user", "erin");
        book.step("frank");
        const frank = try server.createUser(frank_author);
        _ = try book.names.addId(&frank, "user", "frank");
        try self.sweep();

        self.anon = server.client();
        errdefer self.anon.deinit();
        self.alice = try self.login("alice");
        errdefer self.alice.deinit();
        self.bob = try self.login("bob");
        errdefer self.bob.deinit();
        self.carol = try self.login("carol");
        errdefer self.carol.deinit();
        self.erin = try self.login("erin");
        errdefer self.erin.deinit();
        self.frank = try self.login("frank");
        errdefer self.frank.deinit();

        // tabs: everything open to anybody in open
        try self.settings("alice:open", "open", "public", "anybody", "anybody", "anybody");
        // erin may only read open; frank is made a second owner through the form
        book.step("grant erin");
        try evt.grantRole(book.io, gpa, server.users_dir, &server.alice, &server.open.repo_id, &erin, .read, h.Server.alice_author);
        try self.sweep();
        _ = try self.post(&self.alice, "grant frank", "/alice:open/repo/members/grant", &.{.{ "name", "frank" }});
        _ = try self.post(&self.alice, "promote frank", "/alice:open/repo/members/user:frank/promote", &.{});

        if (mode == .edges) {
            try self.arrangeEdges();
            book.names.seal();
            return self;
        }
        try self.arrangeOpenContent();
        if (full) {
            try self.arrangeIssues();
            try self.arrangeDiscussions();
            try self.arrangePatches();
            try self.arrangeTools();
            try self.arrangeForkTargets();
            try self.arrangeCrowd();
            try self.arrangeAccount();
        } else {
            try self.arrangeSmall();
        }
        book.names.seal();
        return self;
    }

    // ---- the edges world: every name and text below holds a literal `%41`
    // beside an `A`, a `+`, a space, a multi-byte character or a `/`, so a
    // search or cursor decoded twice, or never, finds something else

    pub const odd_tokens = [_][]const u8{ "tok%41", "tokA", "tok+plus", "tok plus", "tokétoile", "tok/slash" };
    pub const odd_labels = [_][]const u8{ "lab%41", "labA", "lab+plus", "lab", "labé", "lab/slash" };
    pub const odd_labels_names = [_][]const u8{ "pct", "a", "plus", "space", "uni", "slash" };

    fn arrangeEdges(self: *Server) !void {
        const book = &self.book;
        const path = try self.repoPath(self.server.open);
        try self.withServerRepo(path, self, struct {
            fn run(b: *Book, repo: anytype, _: *Server) !void {
                const alice = "alice <alice@example.test>";
                _ = try commitFiles(b, repo, &.{
                    .{ .path = "README.md", .bytes = "# edges\n" },
                    .{ .path = "tok%41.txt", .bytes = "a literal percent forty-one\n" },
                    .{ .path = "tokA.txt", .bytes = "an A\n" },
                    .{ .path = "tok+plus.txt", .bytes = "a plus\n" },
                    .{ .path = "tok plus.txt", .bytes = "a space\n" },
                    .{ .path = "tokétoile.txt", .bytes = "an e acute\n" },
                    .{ .path = "dir%41/inner.txt", .bytes = "inside dir%41\n" },
                    .{ .path = "dir A/inner.txt", .bytes = "inside dir A\n" },
                    .{ .path = "dir+é/inner.txt", .bytes = "inside dir+é\n" },
                }, "edges import", alice, "edges-initial");
                for (odd_tokens, odd_labels_names) |token, name| {
                    _ = try commitFiles(b, repo, &.{.{ .path = "log.txt", .bytes = try b.print("{s}\n", .{token}) }}, try b.print("{s} commit", .{token}), alice, try b.print("commit-{s}", .{name}));
                }
                // branches named oddly, each a commit of its own past master,
                // and more refs than one window holds
                for ([_][]const u8{ "tok%41", "tokA", "tok+plus", "tokétoile", "tok/slash" }) |name| {
                    try addBranch(b, repo, name);
                    try switchTo(b, repo, name);
                    _ = try commitFiles(b, repo, &.{.{ .path = "branch.txt", .bytes = try b.print("on {s}\n", .{name}) }}, try b.print("work on {s}", .{name}), "bob <bob@example.test>", try b.print("branch {s}", .{name}));
                    try switchTo(b, repo, "master");
                }
                for (1..51) |i| try addBranch(b, repo, try b.print("b/{d:0>2}", .{i}));
                for ([_][]const u8{ "v%41", "vA", "v+1", "vé" }) |name| try addTag(b, repo, name, try b.print("tag {s}", .{name}));
            }
        }.run);

        // a thread of each kind per odd text, labelled oddly too
        for (odd_tokens, odd_labels, odd_labels_names) |token, label, name| {
            _ = try self.thread(&self.alice, try book.print("i-{s}", .{name}), "alice:open", "issues", try book.print("{s} issue", .{token}), label, try book.print("about {s}", .{token}));
            _ = try self.thread(&self.bob, try book.print("d-{s}", .{name}), "alice:open", "discussions", try book.print("{s} talk", .{token}), label, "");
        }
        _ = try self.post(&self.alice, "assign bob i-pct", try book.print("{s}/assign", .{book.url("i-pct")}), &.{.{ "assignee", "bob@example.test" }});
        _ = try self.post(&self.alice, "assign carol i-uni", try book.print("{s}/assign", .{book.url("i-uni")}), &.{.{ "assignee", "carol@example.test" }});
        const new = "/alice:open/patches/new";
        for ([_][3][]const u8{
            .{ "p-pct", "tok%41", "lab%41" },
            .{ "p-a", "tokA", "labA" },
            .{ "p-plus", "tok+plus", "lab+plus" },
            .{ "p-uni", "tokétoile", "labé" },
        }) |patch| {
            _ = try self.post(&self.bob, patch[0], new, &.{ .{ "title", try book.print("{s} patch", .{patch[1]}) }, .{ "labels", patch[2] }, .{ "description", "" }, .{ "target_branch", "master" }, .{ "source_branch", patch[1] } });
        }
        // a merge through the form builds the find and commit search indexes,
        // which only a push or a merge refreshes
        _ = try self.post(&self.alice, "merge p-a", try book.print("{s}/merge", .{book.url("p-a")}), &.{});
        try self.nameTip(self.server.open, "master", "merge p-a");
        _ = try self.post(&self.bob, "bob-draft", new, &.{ .{ "title", "tok+plus draft" }, .{ "labels", "lab+plus" }, .{ "description", "" }, .{ "target_branch", "master" } });

        // a long thread of each kind: twelve comments, some of them replies
        const long_issue = try self.thread(&self.alice, "i-long", "alice:open", "issues", "the long issue", "long", "");
        const long_talk = try self.thread(&self.bob, "d-long", "alice:open", "discussions", "the long talk", "long", "");
        const long_patch = try self.post(&self.bob, "p-long", new, &.{ .{ "title", "the long patch" }, .{ "labels", "long" }, .{ "description", "" }, .{ "target_branch", "master" }, .{ "source_branch", "tok/slash" } });
        for ([_]struct { []const u8, []const u8 }{ .{ "i-long", long_issue }, .{ "d-long", long_talk }, .{ "p-long", long_patch } }) |thread_| {
            for (1..13) |i| {
                const label = try book.print("{s}.c{d:0>2}", .{ thread_[0], i });
                // every third comment answers the one before it
                const parent = if (i % 3 == 0) try book.print("{s}.c{d:0>2}", .{ thread_[0], i - 1 }) else null;
                const author = if (i % 2 == 0) &self.alice else &self.bob;
                _ = try self.comment(author, label, thread_[1], parent, try book.print("comment {d} on {s}", .{ i, thread_[0] }));
            }
        }
    }

    // ---- open's files, history and refs

    fn arrangeOpenContent(self: *Server) !void {
        const path = try self.repoPath(self.server.open);
        try self.withServerRepo(path, self, struct {
            fn run(book: *Book, repo: anytype, world: *Server) !void {
                const alice = "alice <alice@example.test>";
                const bob = "bob <bob@example.test>";
                _ = try commitFiles(book, repo, &.{
                    .{ .path = "README.md", .bytes = readme_md },
                    .{ .path = "notes.txt", .bytes = "notes\n" },
                    .{ .path = "logo.png", .bytes = binary_bytes },
                    .{ .path = "src/main.zig", .bytes = "pub fn main() void {}\n" },
                    .{ .path = "src/lib/util.zig", .bytes = "pub const answer = 42;\n" },
                    .{ .path = "docs/guide.md", .bytes = "# guide\n\nread me first\n" },
                    .{ .path = "docs/long.txt", .bytes = if (world.full) try longText(book, 5100) else "short\n" },
                }, "initial import", alice, "initial");
                // a history longer than one commits window
                var notes: std.Io.Writer.Allocating = .init(book.aa());
                try notes.writer.writeAll("notes\n");
                const changes: usize = if (world.full) 22 else 3;
                for (1..changes + 1) |i| {
                    try notes.writer.print("change {d}\n", .{i});
                    _ = try commitFiles(book, repo, &.{.{ .path = "notes.txt", .bytes = try book.aa().dupe(u8, notes.written()) }}, try book.print("change {d}\n\nthe {d}th change to the notes", .{ i, i }), if (i % 2 == 0) bob else alice, try book.print("change-{d:0>2}", .{i}));
                }
                if (world.full) {
                    // a commit touching many places of the long file, so its diff has several windows
                    var long: std.Io.Writer.Allocating = .init(book.aa());
                    for (1..5101) |i| if (i % 200 == 0) try long.writer.print("LINE {d}\n", .{i}) else try long.writer.print("line {d}\n", .{i});
                    _ = try commitFiles(book, repo, &.{.{ .path = "docs/long.txt", .bytes = long.written() }}, "shout every 200th line", alice, "shout");
                }

                // branches: a feature two commits ahead, and names that need encoding
                try addBranch(book, repo, "feature");
                try switchTo(book, repo, "feature");
                _ = try commitFiles(book, repo, &.{.{ .path = "src/main.zig", .bytes = "pub fn main() void {\n    feature();\n}\n" }}, "feature one", bob, "feature-1");
                _ = try commitFiles(book, repo, &.{.{ .path = "feature.txt", .bytes = "a feature\n" }}, "feature two", bob, "feature-2");
                try switchTo(book, repo, "master");
                for ([_][]const u8{ "team/next", "100%done", "café" }) |name| try addBranch(book, repo, name);
                // a merge commit on master
                try addBranch(book, repo, "side");
                try switchTo(book, repo, "side");
                _ = try commitFiles(book, repo, &.{.{ .path = "side.txt", .bytes = "side work\n" }}, "side work", alice, "side-1");
                try switchTo(book, repo, "master");
                _ = try mergeCommit(book, repo, "master", "side", alice, "merge-side");
                try addTag(book, repo, "v0.1", null);
                try addTag(book, repo, "v1.0", "the first release");
                if (!world.full) return;

                // branches for the patches
                for ([_]struct { name: []const u8, file: []const u8, commits: usize }{
                    .{ .name = "fix/close", .file = "close.txt", .commits = 1 },
                    .{ .name = "fix/merge", .file = "merge.txt", .commits = 1 },
                    .{ .name = "fix/squash", .file = "squash.txt", .commits = 2 },
                    .{ .name = "fix/stale", .file = "stale.txt", .commits = 1 },
                }) |fix| {
                    try addBranch(book, repo, fix.name);
                    try switchTo(book, repo, fix.name);
                    for (1..fix.commits + 1) |i| {
                        _ = try commitFiles(book, repo, &.{.{ .path = fix.file, .bytes = try book.print("{s} {d}\n", .{ fix.name, i }) }}, try book.print("{s} {d}", .{ fix.name, i }), bob, try book.print("{s}-{d}", .{ fix.name, i }));
                    }
                    try switchTo(book, repo, "master");
                }
                // more branches than one refs window holds
                for (1..51) |i| try addBranch(book, repo, try book.print("b/{d:0>2}", .{i}));
            }
        }.run);
    }

    // ---- issues: more than a window, labels, both statuses, an assignee,
    // an attachment, a removed one, and one long thread

    fn arrangeIssues(self: *Server) !void {
        const book = &self.book;
        const roof = try self.thread(&self.alice, "leaky-roof", "alice:open", "issues", "the roof leaks", "bug roof", "water comes in **when it rains**\n\nsee the photo");
        try self.attach(&self.alice, "roof-photo", roof, "photo.png", binary_bytes);
        _ = try self.post(&self.alice, "assign bob", try book.print("{s}/assign", .{roof}), &.{.{ "assignee", "bob@example.test" }});
        _ = try self.comment(&self.bob, "leaky-roof.c01", roof, null, "i see it too");
        _ = try self.comment(&self.frank, "leaky-roof.c02", roof, null, "a bucket helps");
        _ = try self.comment(&self.alice, "leaky-roof.c03", roof, "leaky-roof.c01", "where exactly?");
        _ = try self.comment(&self.bob, "leaky-roof.c04", roof, "leaky-roof.c03", "over the kitchen");
        // alice reads what she has so far
        book.step("alice reads leaky-roof");
        {
            const r = try self.alice.getJson(roof);
            defer r.deinit();
            try r.expectStatus(.ok);
        }
        _ = try self.comment(&self.carol, "leaky-roof.c05", roof, null, "i can fix roofs");
        _ = try self.comment(&self.bob, "leaky-roof.c06", roof, null, "it got worse");
        _ = try self.comment(&self.erin, "leaky-roof.c07", roof, null, "erin was here");
        _ = try self.comment(&self.frank, "leaky-roof.c08", roof, "leaky-roof.c06", "ordering tiles");
        _ = try self.comment(&self.bob, "leaky-roof.c09", roof, null, "tiles came");
        _ = try self.comment(&self.alice, "leaky-roof.c10", roof, null, "thanks all");
        _ = try self.comment(&self.bob, "leaky-roof.c11", roof, null, "one more thing");
        _ = try self.comment(&self.bob, "leaky-roof.c12", roof, null, "the last comment");
        // an edited comment and a removed one
        const c02 = book.real("comment", "leaky-roof.c02");
        _ = try self.post(&self.frank, "edit leaky-roof.c02", try book.print("{s}/comment:{s}/edit", .{ roof, c02 }), &.{.{ "body", "a bucket helps (edited)" }});
        const c05 = book.real("comment", "leaky-roof.c05");
        _ = try self.post(&self.carol, "remove leaky-roof.c05", try book.print("{s}/comment:{s}/remove", .{ roof, c05 }), &.{});
        _ = try self.comment(&self.bob, "leaky-roof.c13", roof, null, "after the removal");
        _ = try self.attach(&self.bob, "roof-notes", roof, "notes.txt", "measurements\n");

        // closed issues and a removed one
        const door = try self.thread(&self.bob, "flaky-door", "alice:open", "issues", "the door sticks", "bug", "");
        _ = try self.post(&self.bob, "close flaky-door", try book.print("{s}/close", .{door}), &.{});
        const window = try self.thread(&self.frank, "stuck-window", "alice:open", "issues", "the window is stuck", "ui", "it will not open");
        _ = try self.post(&self.alice, "close stuck-window", try book.print("{s}/close", .{window}), &.{});
        const old = try self.thread(&self.alice, "old-news", "alice:open", "issues", "old news", "docs", "never mind");
        _ = try self.post(&self.alice, "remove old-news", try book.print("{s}/remove", .{old}), &.{});
        const edited = try self.thread(&self.bob, "renamed", "alice:open", "issues", "a first title", "docs", "first words");
        _ = try self.post(&self.bob, "edit renamed", try book.print("{s}/edit", .{edited}), &.{ .{ "title", "a better title" }, .{ "labels", "docs ui" }, .{ "description", "better words" } });

        // more open issues than one window shows
        for (1..22) |i| {
            const author = switch (i % 3) {
                0 => &self.alice,
                1 => &self.bob,
                else => &self.carol,
            };
            _ = try self.thread(author, try book.print("issue-{d:0>2}", .{i}), "alice:open", "issues", try book.print("filler issue {d}", .{i}), if (i % 2 == 0) "ui" else "docs", "");
        }
        // the private repo has one too
        _ = try self.thread(&self.bob, "secret-plan", "alice:secret", "issues", "the secret plan", "", "shh");
    }

    fn arrangeDiscussions(self: *Server) !void {
        const book = &self.book;
        const roadmap = try self.thread(&self.alice, "roadmap", "alice:open", "discussions", "the roadmap", "plans", "what comes next");
        _ = try self.comment(&self.bob, "roadmap.c01", roadmap, null, "more tests");
        _ = try self.comment(&self.carol, "roadmap.c02", roadmap, "roadmap.c01", "and docs");
        _ = try self.comment(&self.alice, "roadmap.c03", roadmap, null, "agreed");
        const gone = try self.thread(&self.bob, "gone-talk", "alice:open", "discussions", "a talk to remove", "", "");
        _ = try self.post(&self.bob, "remove gone-talk", try book.print("{s}/remove", .{gone}), &.{});
        for (1..21) |i| {
            _ = try self.thread(if (i % 2 == 0) &self.bob else &self.frank, try book.print("talk-{d:0>2}", .{i}), "alice:open", "discussions", try book.print("filler talk {d}", .{i}), if (i % 2 == 0) "plans" else "chat", "");
        }
    }

    // ---- patches: from branches in every state, drafts, a published fork

    fn arrangePatches(self: *Server) !void {
        const book = &self.book;
        const new = "/alice:open/patches/new";
        const stale = try self.post(&self.bob, "p-stale", new, &.{ .{ "title", "a stale fix" }, .{ "labels", "bug" }, .{ "description", "made before master moved" }, .{ "target_branch", "master" }, .{ "source_branch", "fix/stale" } });
        _ = stale;
        const open = try self.post(&self.bob, "p-open", new, &.{ .{ "title", "the feature" }, .{ "labels", "feature" }, .{ "description", "two commits of **feature**" }, .{ "target_branch", "master" }, .{ "source_branch", "feature" } });
        _ = try self.comment(&self.alice, "p-open.c01", open, null, "looks good");
        _ = try self.comment(&self.bob, "p-open.c02", open, "p-open.c01", "thanks");
        const closed = try self.post(&self.bob, "p-closed", new, &.{ .{ "title", "a fix to close" }, .{ "labels", "bug" }, .{ "description", "" }, .{ "target_branch", "master" }, .{ "source_branch", "fix/close" } });
        _ = try self.post(&self.alice, "close p-closed", try book.print("{s}/close", .{closed}), &.{});
        const merged = try self.post(&self.bob, "p-merged", new, &.{ .{ "title", "a fix to merge" }, .{ "labels", "bug" }, .{ "description", "" }, .{ "target_branch", "master" }, .{ "source_branch", "fix/merge" } });
        _ = try self.post(&self.alice, "merge p-merged", try book.print("{s}/merge", .{merged}), &.{});
        try self.nameTip(self.server.open, "master", "merge p-merged");
        const squashed = try self.post(&self.bob, "p-squashed", new, &.{ .{ "title", "a fix to squash" }, .{ "labels", "" }, .{ "description", "" }, .{ "target_branch", "master" }, .{ "source_branch", "fix/squash" } });
        _ = try self.post(&self.frank, "squash p-squashed", try book.print("{s}/squash", .{squashed}), &.{});
        try self.nameTip(self.server.open, "master", "squash p-squashed");
        // drafts: alice's, bob's, and bob's that he publishes after committing to its fork
        _ = try self.post(&self.alice, "alice-draft", new, &.{ .{ "title", "alice's draft" }, .{ "labels", "" }, .{ "description", "not yet" }, .{ "target_branch", "master" } });
        _ = try self.post(&self.bob, "bob-draft", new, &.{ .{ "title", "bob's draft" }, .{ "labels", "" }, .{ "description", "" }, .{ "target_branch", "master" } });
        const forked = try self.post(&self.bob, "bob-fork", new, &.{ .{ "title", "a fix from a fork" }, .{ "labels", "fork" }, .{ "description", "made in bob's fork" }, .{ "target_branch", "master" } });
        try self.commitToFork(self.server.bob, book.real("patch", "bob-fork"), "fork.txt", "from the fork\n", "bob-fork-1");
        _ = try self.post(&self.bob, "publish bob-fork", try book.print("{s}/publish", .{forked}), &.{});
    }

    // name the commit a form left at the tip of `branch`
    fn nameTip(self: *Server, location: evt.RepoLocation, branch: []const u8, label: []const u8) !void {
        const Ctx = struct { branch: []const u8, label: []const u8 };
        try withAnyRepo(&self.book, .xit, try self.repoPath(location), Ctx{ .branch = branch, .label = label }, struct {
            fn run(book: *Book, repo: anytype, ctx: Ctx) !void {
                // a fast-forward leaves a commit that has its name already
                const oid = try tip(book, repo, ctx.branch);
                if (!book.names.has(oid)) _ = try book.names.addHex(oid, "commit", ctx.label);
            }
        }.run);
    }

    fn commitToFork(self: *Server, forker: h.Id, patch_id: []const u8, file: []const u8, bytes: []const u8, label: []const u8) !void {
        const path = try std.Io.Dir.path.join(self.book.aa(), &.{ self.server.users_dir, &std.fmt.bytesToHex(forker, .lower), "forks", patch_id });
        const Ctx = struct { file: []const u8, bytes: []const u8, label: []const u8 };
        try self.withServerRepo(path, Ctx{ .file = file, .bytes = bytes, .label = label }, struct {
            fn run(book: *Book, repo: anytype, ctx: Ctx) !void {
                try switchTo(book, repo, "patch");
                _ = try commitFiles(book, repo, &.{.{ .path = ctx.file, .bytes = ctx.bytes }}, ctx.label, "bob <bob@example.test>", ctx.label);
            }
        }.run);
    }

    // ---- tools: a members-only tab, a tab turned off, a protected branch
    // and a default branch other than master, and history undone

    fn arrangeTools(self: *Server) !void {
        const tools = try self.createRepo(&self.server.alice, h.Server.alice_author, "tools", .public, .sha1);
        try self.settings("alice:tools", "tools", "public", "anybody", "members", "nobody");
        _ = try self.post(&self.alice, "grant bob tools", "/alice:tools/repo/members/grant", &.{.{ "name", "bob" }});
        const path = try self.repoPath(tools);
        try self.withServerRepo(path, self, struct {
            fn run(b: *Book, repo: anytype, _: *Server) !void {
                _ = try commitFiles(b, repo, &.{.{ .path = "tool.txt", .bytes = "a tool\n" }}, "a tool", "alice <alice@example.test>", "tools-1");
                try addBranch(b, repo, "develop");
                try addBranch(b, repo, "release");
                try switchTo(b, repo, "develop");
                _ = try commitFiles(b, repo, &.{.{ .path = "tool.txt", .bytes = "a better tool\n" }}, "develop the tool", "alice <alice@example.test>", "tools-develop-1");
                try switchTo(b, repo, "master");
            }
        }.run);
        _ = try self.post(&self.alice, "default develop", "/alice:tools/repo/branches/default", &.{.{ "name", "develop" }});
        _ = try self.post(&self.alice, "protect release", "/alice:tools/repo/branches/protect", &.{.{ "name", "release" }});
        _ = try self.thread(&self.bob, "tool-bug", "alice:tools", "issues", "the tool breaks", "bug", "");
        // undo what an issue form wrote; the undo page lists it as undone
        const before = blk: {
            const r = try self.alice.getJson("/alice:tools/undo");
            defer r.deinit();
            try r.expectStatus(.ok);
            break :blk (r.jsonAt("page.repo.undo.count") orelse return error.TestExpectedJson).integer;
        };
        _ = try self.thread(&self.alice, "undone-issue", "alice:tools", "issues", "an issue to undo", "", "");
        _ = try self.post(&self.alice, "undo undone-issue", try self.book.print("/alice:tools/undo/{d}/undo", .{before}), &.{});
    }

    // ---- forks whose target was renamed or deleted

    fn arrangeForkTargets(self: *Server) !void {
        for ([_][]const u8{ "moving", "doomed" }) |name| {
            const location = try self.createRepo(&self.server.alice, h.Server.alice_author, name, .public, .sha1);
            try self.settings(try self.book.print("alice:{s}", .{name}), name, "public", "anybody", "anybody", "anybody");
            const path = try self.repoPath(location);
            try self.withServerRepo(path, name, struct {
                fn run(b: *Book, repo: anytype, repo_name: []const u8) !void {
                    _ = try commitFiles(b, repo, &.{.{ .path = "base.txt", .bytes = "base\n" }}, "base", "alice <alice@example.test>", try b.print("{s}-1", .{repo_name}));
                }
            }.run);
            _ = try self.post(&self.bob, try self.book.print("{s}-draft", .{name}), try self.book.print("/alice:{s}/patches/new", .{name}), &.{ .{ "title", try self.book.print("a draft on {s}", .{name}) }, .{ "labels", "" }, .{ "description", "" }, .{ "target_branch", "master" } });
        }
        try self.settings("alice:moving", "moved", "public", "anybody", "anybody", "anybody");
        _ = try self.post(&self.alice, "delete doomed", "/alice:doomed/repo/delete/delete", &.{ .{ "confirm", "alice:doomed" }, .{ "password", h.password } });
    }

    // ---- enough users and repos for their lists to window

    fn arrangeCrowd(self: *Server) !void {
        const book = &self.book;
        for (1..17) |i| {
            const name = try book.print("user{d:0>2}", .{i});
            book.step(name);
            const id = try self.server.createUser(.{ .name = name, .email = try book.print("{s}@example.test", .{name}) });
            _ = try book.names.addId(&id, "user", name);
        }
        for (1..20) |i| {
            const name = try book.print("repo{d:0>2}", .{i});
            _ = try self.createRepo(&self.server.alice, h.Server.alice_author, name, if (i % 4 == 0) .private else .public, .sha1);
        }
        try self.sweep();
    }

    // ---- alice's account: a key, notifications read and unread

    fn arrangeAccount(self: *Server) !void {
        _ = try self.post(&self.alice, "alice key", "/home/user/keys/addkey", &.{.{ "key", alice_key }});
    }

    // ---- the smaller sha256 world: one of each thread kind and a patch

    fn arrangeSmall(self: *Server) !void {
        const book = &self.book;
        const roof = try self.thread(&self.alice, "leaky-roof", "alice:open", "issues", "the roof leaks", "bug", "it drips");
        _ = try self.comment(&self.bob, "leaky-roof.c01", roof, null, "i see it too");
        _ = try self.comment(&self.alice, "leaky-roof.c02", roof, "leaky-roof.c01", "where?");
        // a second issue, so a window holds more than one item and its order shows
        _ = try self.thread(&self.bob, "flaky-door", "alice:open", "issues", "the door sticks", "", "");
        try self.attach(&self.alice, "roof-photo", roof, "photo.png", binary_bytes);
        const roadmap = try self.thread(&self.alice, "roadmap", "alice:open", "discussions", "the roadmap", "plans", "");
        _ = try self.comment(&self.bob, "roadmap.c01", roadmap, null, "more tests");
        const patch = try self.post(&self.bob, "p-open", "/alice:open/patches/new", &.{ .{ "title", "the feature" }, .{ "labels", "" }, .{ "description", "" }, .{ "target_branch", "master" }, .{ "source_branch", "feature" } });
        _ = try self.comment(&self.alice, "p-open.c01", patch, null, "looks good");
        _ = try self.post(&self.alice, "alice-draft", "/alice:open/patches/new", &.{ .{ "title", "alice's draft" }, .{ "labels", "" }, .{ "description", "" }, .{ "target_branch", "master" } });
        _ = book;
    }
};

pub const alice_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINAoMC501vhkyMjEvSuehVQput+n8qmUt1TiVgb/43F0 alice@laptop";
// its fingerprint, url-encoded as the keys tab links it
pub const alice_fingerprint = "SHA256%3A8wligOakas02tWoqup%2B5u9f%2ByfYeK5dIgSHRhyrb9mw";

fn exists(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(tio, path, .{}) catch return false;
    return true;
}

// a dir's entry names, sorted so a sweep names things in the same order every run
fn sortedEntries(aa: std.mem.Allocator, dir: std.Io.Dir) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(tio)) |entry| try names.append(aa, try aa.dupe(u8, entry.name));
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return names.items;
}

// ---- the local worlds

pub fn Local(comptime kind: rp.RepoKind) type {
    return struct {
        book: Book,
        here_repo: h.Local(kind),
        there_repo: h.Local(kind),
        here: h.Client,
        there: h.Client,

        const Self = @This();
        const repo_opts = h.Local(kind).repo_opts;

        pub fn deinit(self: *Self) void {
            self.here.deinit();
            self.there.deinit();
            self.here_repo.deinit();
            self.there_repo.deinit();
            self.book.deinit();
            gpa.destroy(self);
        }

        fn sweep(self: *Self) !void {
            for ([_][]const u8{ self.here_repo.path, self.there_repo.path }) |path| {
                var repo = try rp.Repo(kind, repo_opts).open(self.book.io, gpa, .{ .path = path });
                defer repo.deinit(self.book.io, gpa);
                try self.book.sweepRepo(path, &repo);
            }
        }

        pub fn post(self: *Self, c: *h.Client, label: []const u8, path: []const u8, fields: []const h.Field) ![]const u8 {
            self.book.step(label);
            const r = try c.post(path, fields);
            defer r.deinit();
            if (r.status != .see_other) {
                r.describe();
                std.debug.print("step {s}: POST {s} did not redirect\n", .{ label, path });
                return error.TestStepFailed;
            }
            const location = r.header("location") orelse return error.TestExpectedLocation;
            try self.book.remember(label, location);
            try self.sweep();
            return self.book.url(label);
        }

        fn sync(self: *Self, label: []const u8) !void {
            _ = try self.post(&self.here, label, "/sync", &.{});
        }

        // a get that brings a local repo's pages up to its events branch
        fn refresh(self: *Self, c: *h.Client, label: []const u8, path: []const u8) !void {
            self.book.step(label);
            const r = try c.getJson(path);
            defer r.deinit();
            try r.expectStatus(.ok);
            try self.sweep();
        }

        fn edit(self: *Self, c: *h.Client, label: []const u8, thread: []const u8, title: []const u8, labels: []const u8, description: []const u8, target: ?[]const u8) !void {
            var form: std.ArrayList(h.Field) = .empty;
            defer form.deinit(gpa);
            try form.appendSlice(gpa, &.{ .{ "title", title }, .{ "labels", labels }, .{ "description", description } });
            if (target) |value| try form.append(gpa, .{ "target_branch", value });
            _ = try self.post(c, label, try self.book.print("{s}/edit", .{thread}), form.items);
        }

        pub fn build() !*Self {
            return buildMode(false);
        }

        // `edges`: more conflicted issues than the conflicts window holds
        pub fn buildMode(edges: bool) !*Self {
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            self.book = Book.init();
            errdefer self.book.deinit();
            const book = &self.book;
            book.step("there");
            self.there_repo = try h.Local(kind).initWith(.{ .io = book.io, .child = "snapshot-repo" });
            errdefer self.there_repo.deinit();
            book.step("here");
            self.here_repo = try h.Local(kind).initWith(.{ .io = book.io, .child = "snapshot-repo" });
            errdefer self.here_repo.deinit();
            {
                var there = try rp.Repo(kind, repo_opts).open(book.io, gpa, .{ .path = self.there_repo.path });
                defer there.deinit(book.io, gpa);
                _ = try book.names.addHex(try tip(book, &there, "master"), "commit", "there-first");
                var repo = try rp.Repo(kind, repo_opts).open(book.io, gpa, .{ .path = self.here_repo.path });
                defer repo.deinit(book.io, gpa);
                _ = try book.names.addHex(try tip(book, &repo, "master"), "commit", "here-first");
                try repo.addRemote(book.io, gpa, .{ .name = "origin", .value = self.there_repo.path });
                try arrangeContent(book, &repo);
            }
            self.here = self.here_repo.client();
            self.there = self.there_repo.client();

            // one of each thread kind, with comments
            const roof = try self.post(&self.here, "leaky-roof", "/issues/new", &.{ .{ "title", "the roof leaks" }, .{ "labels", "bug" }, .{ "description", "it drips" } });
            _ = try self.post(&self.here, "leaky-roof.c01", try book.print("{s}/new", .{roof}), &.{.{ "body", "a bucket helps" }});
            _ = try self.post(&self.here, "leaky-roof.c02", try book.print("{s}/comment:{s}/new", .{ roof, book.real("comment", "leaky-roof.c01") }), &.{.{ "body", "where?" }});
            const door = try self.post(&self.here, "flaky-door", "/issues/new", &.{ .{ "title", "the door sticks" }, .{ "labels", "" }, .{ "description", "" } });
            _ = try self.post(&self.here, "close flaky-door", try book.print("{s}/close", .{door}), &.{});
            const talk = try self.post(&self.here, "roadmap", "/discussions/new", &.{ .{ "title", "the roadmap" }, .{ "labels", "plans" }, .{ "description", "" } });
            _ = try self.post(&self.here, "roadmap.c01", try book.print("{s}/new", .{talk}), &.{.{ "body", "more tests" }});
            const patch = try self.post(&self.here, "p-open", "/patches/new", &.{ .{ "title", "the feature" }, .{ "labels", "" }, .{ "description", "a feature" }, .{ "target_branch", "master" }, .{ "source_branch", "feature" } });
            _ = try self.post(&self.here, "p-open.c01", try book.print("{s}/new", .{patch}), &.{.{ "body", "looks good" }});

            // a real conflict on an issue and on a patch: both sides edit
            // after a sync, then sync again
            const issue = try self.post(&self.here, "conflicted", "/issues/new", &.{ .{ "title", "base" }, .{ "labels", "a" }, .{ "description", "one\ntwo\nthree\n" } });
            const conflicted_patch = try self.post(&self.here, "p-conflicted", "/patches/new", &.{ .{ "title", "base" }, .{ "labels", "a" }, .{ "description", "one\ntwo\nthree\n" }, .{ "target_branch", "master" }, .{ "source_branch", "other" } });
            try self.sync("sync 1");
            try self.refresh(&self.there, "there catches up", "/issues");
            try self.edit(&self.here, "edit conflicted here", issue, "ours", "a ours", "one\nOURS\nthree\n", null);
            try self.edit(&self.there, "edit conflicted there", issue, "theirs", "a theirs", "one\nTHEIRS\nthree\n", null);
            try self.edit(&self.here, "edit p-conflicted here", conflicted_patch, "ours", "a ours", "one\nOURS\nthree\n", "master");
            try self.edit(&self.there, "edit p-conflicted there", conflicted_patch, "theirs", "a theirs", "one\nTHEIRS\nthree\n", "master");
            try self.sync("sync 2");
            if (edges) try self.arrangeConflicts();
            book.names.seal();
            return self;
        }

        // 22 issues edited apart on both sides, so the conflicts window
        // pages and the oldest conflict lies beyond its first window
        pub const conflict_count = 22;

        fn arrangeConflicts(self: *Self) !void {
            const book = &self.book;
            var urls: [conflict_count][]const u8 = undefined;
            for (&urls, 1..) |*url_, i| {
                url_.* = try self.post(&self.here, try book.print("conflict-{d:0>2}", .{i}), "/issues/new", &.{ .{ "title", try book.print("conflict {d}", .{i}) }, .{ "labels", "c" }, .{ "description", "one\ntwo\n" } });
            }
            try self.sync("sync 3");
            try self.refresh(&self.there, "there catches up again", "/issues");
            for (urls, 1..) |url_, i| {
                try self.edit(&self.here, try book.print("edit conflict-{d:0>2} here", .{i}), url_, try book.print("ours {d}", .{i}), "c ours", "one\nOURS\n", null);
                try self.edit(&self.there, try book.print("edit conflict-{d:0>2} there", .{i}), url_, try book.print("theirs {d}", .{i}), "c theirs", "one\nTHEIRS\n", null);
            }
            try self.sync("sync 4");
        }

        fn arrangeContent(book: *Book, repo: anytype) !void {
            const author = "tester <tester@example.test>";
            _ = try commitFiles(book, repo, &.{
                .{ .path = "README.md", .bytes = readme_md },
                .{ .path = "logo.png", .bytes = binary_bytes },
                .{ .path = "src/main.zig", .bytes = "pub fn main() void {}\n" },
            }, "add files", author, "files");
            _ = try commitFiles(book, repo, &.{.{ .path = "readme.txt", .bytes = "hello\nagain\n" }}, "say it again", author, "again");
            for ([_][]const u8{ "feature", "other" }) |name| {
                try addBranch(book, repo, name);
                try switchTo(book, repo, name);
                _ = try commitFiles(book, repo, &.{.{ .path = try book.print("{s}.txt", .{name}), .bytes = try book.print("{s}\n", .{name}) }}, try book.print("{s} work", .{name}), author, try book.print("{s}-1", .{name}));
                try switchTo(book, repo, "master");
            }
            try addBranch(book, repo, "team/next");
            try addTag(book, repo, "v1.0", "the first release");
        }
    };
}
