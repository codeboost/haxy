const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const evt = @import("event.zig");
const progress = @import("progress.zig");

const UserDB = evt.UserDB;
const hash_kind = evt.user_repo_opts.hash;

// the user repo keys, outside the haxy moment
const notif_map_key = "haxy/notif-id->notif";
const recent_notif_id_set_key = "haxy/recent-notif-id-set";
const unread_notif_id_set_key = "haxy/unread-notif-id-set";

// the most notifs a user keeps
pub const max_notifs = 1000;

// the most users a thread's capped tiers hold
pub const max_commented = 250;
pub const max_subscribed = 100;

// the owner's user repo key mapping each thread's notif id to the user ids in
// `mode`'s tier, and the most that tier holds. a mute has no tier.
fn tierOf(comptime mode: evt.Notify.Mode) ?struct { map_key: []const u8, cap: ?u64 } {
    const map_key = "haxy/notif-id->" ++ @tagName(mode) ++ "-id-set";
    return switch (mode) {
        .involved => .{ .map_key = map_key, .cap = null },
        .commented => .{ .map_key = map_key, .cap = max_commented },
        .subscribed => .{ .map_key = map_key, .cap = max_subscribed },
        .muted => null,
    };
}

// one thread's item in a user's inbox. the names and title are as of its last bump.
pub const Notif = struct {
    // the repo holding the thread
    repo_id: [evt.event_id_size]u8,
    owner_name: []const u8,
    repo_name: []const u8,
    thread_id: [evt.event_id_size]u8,
    thread_kind: evt.EventKind,
    title: []const u8,
    // the comment or assignment that last bumped it
    last_child_id: [evt.event_id_size]u8,
    // when it was last bumped, which also orders the sets
    time: u64 = 0,
};

// a notif as the inbox lists it
pub const Item = struct {
    notif: Notif,
    unread: bool,
};

// the id of the one notif a user can hold on a thread
pub fn idOf(repo_id: *const [evt.event_id_size]u8, thread_id: *const [evt.event_id_size]u8) [evt.event_id_size]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(repo_id);
    hasher.update(thread_id);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest[0..evt.event_id_size].*;
}

// run `ctx` in a transaction on the user's repo
fn transact(io: std.Io, allocator: std.mem.Allocator, users_dir: []const u8, user_id: *const [evt.event_id_size]u8, ctx: anytype) !void {
    var user_repo = (try evt.openUserRepo(io, allocator, users_dir, user_id)) orelse return error.NotFound;
    defer user_repo.deinit(io, allocator);

    try user_repo.core.db_file.lock(io, .exclusive);
    defer user_repo.core.db_file.unlock(io);

    const history = try UserDB.ArrayList(.read_write).init(user_repo.core.db.rootCursor());
    history.appendContext(.{ .slot = try history.getSlot(-1) }, ctx) catch |err| switch (err) {
        error.CancelTransaction => {},
        else => |e| return e,
    };
}

// a stored notif's time, or null when the user has none for the id
fn readTime(arena: *std.heap.ArenaAllocator, records: UserDB.HashMap(.read_only), id: *const [evt.event_id_size]u8) !?u64 {
    const record_cursor = try records.getCursor(hash.hashInt(hash_kind, id)) orelse return null;
    return (try evt.read(struct { time: u64 }, UserDB, hash_kind, arena, try UserDB.HashMap(.read_only).init(record_cursor))).time;
}

// drop a notif from the map and both sets
fn removeNotif(moment: UserDB.HashMap(.read_write), records: UserDB.HashMap(.read_write), id: *const [evt.event_id_size]u8, time: u64) !void {
    const order_key = evt.orderKeyDesc(time, id);
    _ = try records.remove(hash.hashInt(hash_kind, id));
    _ = try (try UserDB.SortedSet(.read_write).init(try moment.putCursor(hash.hashInt(hash_kind, recent_notif_id_set_key)))).remove(&order_key);
    _ = try (try UserDB.SortedSet(.read_write).init(try moment.putCursor(hash.hashInt(hash_kind, unread_notif_id_set_key)))).remove(&order_key);
}

// upsert one user's batch as unread and newest, pruning past the cap
pub fn deliver(io: std.Io, allocator: std.mem.Allocator, users_dir: []const u8, user_id: *const [evt.event_id_size]u8, notifs: []const Notif) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const Ctx = struct {
        arena: *std.heap.ArenaAllocator,
        notifs: []const Notif,
        time: u64,

        pub fn run(ctx: @This(), cursor: *UserDB.Cursor(.read_write)) !void {
            const moment = try UserDB.HashMap(.read_write).init(cursor.*);
            const records = try UserDB.HashMap(.read_write).init(try moment.putCursor(hash.hashInt(hash_kind, notif_map_key)));
            const recent = try UserDB.SortedSet(.read_write).init(try moment.putCursor(hash.hashInt(hash_kind, recent_notif_id_set_key)));
            const unread = try UserDB.SortedSet(.read_write).init(try moment.putCursor(hash.hashInt(hash_kind, unread_notif_id_set_key)));

            for (ctx.notifs) |notif| {
                const id = idOf(&notif.repo_id, &notif.thread_id);
                if (try readTime(ctx.arena, records.readOnly(), &id)) |old_time| {
                    const old_key = evt.orderKeyDesc(old_time, &id);
                    _ = try recent.remove(&old_key);
                    _ = try unread.remove(&old_key);
                }
                var stored = notif;
                stored.time = ctx.time;
                try evt.upsert(Notif, UserDB, hash_kind, try UserDB.HashMap(.read_write).init(try records.putCursor(hash.hashInt(hash_kind, &id))), stored);
                const order_key = evt.orderKeyDesc(ctx.time, &id);
                try recent.put(&order_key);
                try unread.put(&order_key);
            }

            // the oldest go past the cap
            var count = try recent.count();
            while (count > max_notifs) : (count -= 1) {
                const oldest = (try recent.getIndexKeyValuePair(@intCast(count - 1))) orelse unreachable;
                var order_key: [@sizeOf(u64) + evt.event_id_size]u8 = undefined;
                _ = try oldest.key_cursor.readBytes(&order_key);
                const id = order_key[@sizeOf(u64)..].*;
                const time = std.math.maxInt(u64) - std.mem.readInt(u64, order_key[0..@sizeOf(u64)], .big);
                try removeNotif(moment, records, &id, time);
            }
        }
    };

    try transact(io, allocator, users_dir, user_id, Ctx{
        .arena = &arena,
        .notifs = notifs,
        .time = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
    });
}

// mark a notif read, unless it was bumped past `last_child_id` since the user saw it
pub fn markRead(
    io: std.Io,
    allocator: std.mem.Allocator,
    users_dir: []const u8,
    user_id: *const [evt.event_id_size]u8,
    notif_id: *const [evt.event_id_size]u8,
    last_child_id: *const [evt.event_id_size]u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const Ctx = struct {
        arena: *std.heap.ArenaAllocator,
        notif_id: *const [evt.event_id_size]u8,
        last_child_id: *const [evt.event_id_size]u8,

        pub fn run(ctx: @This(), cursor: *UserDB.Cursor(.read_write)) !void {
            const moment = try UserDB.HashMap(.read_write).init(cursor.*);
            const records_cursor = try moment.readOnly().getCursor(hash.hashInt(hash_kind, notif_map_key)) orelse return error.CancelTransaction;
            const record_cursor = try (try UserDB.HashMap(.read_only).init(records_cursor)).getCursor(hash.hashInt(hash_kind, ctx.notif_id)) orelse return error.CancelTransaction;
            const notif = try evt.read(Notif, UserDB, hash_kind, ctx.arena, try UserDB.HashMap(.read_only).init(record_cursor));
            if (!std.mem.eql(u8, &notif.last_child_id, ctx.last_child_id)) return error.CancelTransaction;

            const unread = try UserDB.SortedSet(.read_write).init(try moment.putCursor(hash.hashInt(hash_kind, unread_notif_id_set_key)));
            if (!try unread.remove(&evt.orderKeyDesc(notif.time, ctx.notif_id))) return error.CancelTransaction;
        }
    };

    try transact(io, allocator, users_dir, user_id, Ctx{ .arena = &arena, .notif_id = notif_id, .last_child_id = last_child_id });
}

// remove a notif. the thread's next bump recreates it.
pub fn dismiss(io: std.Io, allocator: std.mem.Allocator, users_dir: []const u8, user_id: *const [evt.event_id_size]u8, notif_id: *const [evt.event_id_size]u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const Ctx = struct {
        arena: *std.heap.ArenaAllocator,
        notif_id: *const [evt.event_id_size]u8,

        pub fn run(ctx: @This(), cursor: *UserDB.Cursor(.read_write)) !void {
            const moment = try UserDB.HashMap(.read_write).init(cursor.*);
            const records = try UserDB.HashMap(.read_write).init(try moment.putCursor(hash.hashInt(hash_kind, notif_map_key)));
            const time = (try readTime(ctx.arena, records.readOnly(), ctx.notif_id)) orelse return error.CancelTransaction;
            try removeNotif(moment, records, ctx.notif_id, time);
        }
    };

    try transact(io, allocator, users_dir, user_id, Ctx{ .arena = &arena, .notif_id = notif_id });
}

// up to `count` notifs from `start`, newest first. `moment` is the user repo's latest.
pub fn readRecent(moment: UserDB.HashMap(.read_only), arena: *std.heap.ArenaAllocator, start: u64, count: usize) ![]const Item {
    var items: std.ArrayList(Item) = .empty;
    const recent_cursor = try moment.getCursor(hash.hashInt(hash_kind, recent_notif_id_set_key)) orelse return items.items;
    const recent = try UserDB.SortedSet(.read_only).init(recent_cursor);

    var iter = try recent.iteratorFromIndex(start);
    while (items.items.len < count) {
        const kv_cursor = (try iter.next()) orelse break;
        const id = try evt.readOrderKeyId(UserDB, kv_cursor);
        try items.append(arena.allocator(), (try readItem(moment, arena, &id)) orelse return error.NotFound);
    }
    return items.items;
}

// the notif `id` names with its read state, or null when the user has none. `moment` is the user repo's latest.
pub fn readItem(moment: UserDB.HashMap(.read_only), arena: *std.heap.ArenaAllocator, id: *const [evt.event_id_size]u8) !?Item {
    const records_cursor = try moment.getCursor(hash.hashInt(hash_kind, notif_map_key)) orelse return null;
    const record_cursor = try (try UserDB.HashMap(.read_only).init(records_cursor)).getCursor(hash.hashInt(hash_kind, id)) orelse return null;
    const notif = try evt.read(Notif, UserDB, hash_kind, arena, try UserDB.HashMap(.read_only).init(record_cursor));
    const unread_cursor = try moment.getCursor(hash.hashInt(hash_kind, unread_notif_id_set_key)) orelse return .{ .notif = notif, .unread = false };
    const unread = try (try UserDB.SortedSet(.read_only).init(unread_cursor)).contains(&evt.orderKeyDesc(notif.time, id));
    return .{ .notif = notif, .unread = unread };
}

// a user repo's latest moment, or null before its first transaction
pub fn latestMoment(user_repo: *rp.Repo(.xit, evt.user_repo_opts)) !?UserDB.HashMap(.read_only) {
    return user_repo.core.latestMoment() catch |err| switch (err) {
        error.DatabaseIsEmpty => null,
        else => |e| e,
    };
}

// how many notifs are unread. `moment` is the user repo's latest.
pub fn unreadCount(moment: UserDB.HashMap(.read_only)) !u64 {
    const unread_cursor = try moment.getCursor(hash.hashInt(hash_kind, unread_notif_id_set_key)) orelse return 0;
    return try (try UserDB.SortedSet(.read_only).init(unread_cursor)).count();
}

//
// what a user may see of their inbox
//

/// whether someone holding `role` in `repo` (null for none) may read its
/// threads of `kind`: the repo is theirs to read and the kind's tab is on.
/// delivery and every inbox reader decide by this one rule.
pub fn mayRead(repo: evt.Repo, role: ?evt.Repo.Role, kind: evt.EventKind) bool {
    return role != null and repo.threadRole(kind) != null;
}

/// where a notif's thread lives now, as a reader who may still read it finds it
pub const Place = struct {
    owner_name: []const u8,
    // the repo's name now, which a rename since the notif's last bump changed
    repo_name: []const u8,
};

/// decides which of a user's notifs they may still read, remembering each
/// repo's answer. a notif names its repo's owner as of its last bump; the
/// repo is then read again by its id, so a repo that took its name since is
/// never mistaken for it.
pub const Readable = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    users_dir: []const u8,
    admin_moment: evt.AdminDB.HashMap(.read_only),
    viewer_id: [evt.event_id_size]u8,
    // each repo as the viewer reads it now, or null when it's gone or hidden from them
    repos: std.AutoHashMapUnmanaged([evt.event_id_size]u8, ?Found) = .empty,

    const Found = struct { owner_id: [evt.event_id_size]u8, repo: evt.Repo.RepoWithRole };

    /// where the notif's thread is, or null when the viewer may no longer read
    /// its repo's threads of its kind. whether the thread itself is still there
    /// is `dropRemoved`'s to say.
    pub fn placeOf(self: *Readable, notif: Notif) !?Place {
        const found = (try self.repoOf(notif)) orelse return null;
        if (!mayRead(found.repo.repo.event, found.repo.role, notif.thread_kind)) return null;
        return .{ .owner_name = notif.owner_name, .repo_name = found.repo.repo.event.name };
    }

    fn repoOf(self: *Readable, notif: Notif) !?Found {
        if (self.repos.get(notif.repo_id)) |found| return found;
        const found: ?Found = blk: {
            const owner_id = (try evt.User.readIdByName(evt.AdminDB, evt.admin_repo_opts.hash, self.admin_moment, notif.owner_name)) orelse break :blk null;
            const repo = (try evt.readRepoById(self.io, self.allocator, self.arena, self.users_dir, &owner_id, &notif.repo_id, self.viewer_id)) orelse break :blk null;
            break :blk .{ .owner_id = owner_id, .repo = repo };
        };
        try self.repos.put(self.arena.allocator(), notif.repo_id, found);
        return found;
    }

    /// clears the place of every entry of `repo_id`'s repo whose thread is
    /// removed (or not there at all), opening the repo once
    fn dropRemoved(self: *Readable, entries: []Entry, repo_id: *const [evt.event_id_size]u8) !void {
        const found = (self.repos.get(repo_id.*) orelse return) orelse return;
        const path = try evt.repoPath(self.arena.allocator(), self.users_dir, &found.owner_id, repo_id);
        // only this directory's own repo: never one an ancestor directory holds
        var any_repo = rp.AnyRepo(.xit, .{}).open(self.io, self.allocator, .{ .path = path, .require_repo_root = true }) catch |err| switch (err) {
            // deleted since its record was read, partly (its database gone,
            // `RepoNotFound`) or wholly (its directory gone, `FileNotFound`):
            // unreadable, as a repo that is gone
            error.FileNotFound, error.RepoNotFound => {
                for (entries) |*entry| {
                    if (std.mem.eql(u8, &entry.item.notif.repo_id, repo_id)) entry.place = null;
                }
                return;
            },
            else => |e| return e,
        };
        defer any_repo.deinit(self.io, self.allocator);
        switch (any_repo) {
            inline else => |*repo| {
                const repo_opts = repo.self_repo_opts;
                // a repo without events yet holds no threads
                const moment = evt.currentMoment(repo_opts, repo) catch |err| switch (err) {
                    error.NotFound => null,
                    else => |e| return e,
                };
                for (entries) |*entry| {
                    if (entry.place == null or !std.mem.eql(u8, &entry.item.notif.repo_id, repo_id)) continue;
                    const live = if (moment) |value| try threadLive(repo_opts.hash, self.arena, value, entry.item.notif.thread_kind, &entry.item.notif.thread_id) else false;
                    if (!live) entry.place = null;
                }
            },
        }
    }
};

// a notif as `readWindow` walks it: where its thread is, or null when the viewer may not read it
const Entry = struct { item: Item, place: ?Place, order_key: OrderKey };

/// whether `id` names a thread of `kind` that isn't removed, in a repo's events `moment`
pub fn threadLive(comptime repo_hash: hash.HashKind, arena: *std.heap.ArenaAllocator, moment: evt.EventDB(repo_hash).HashMap(.read_only), kind: evt.EventKind, id: *const [evt.event_id_size]u8) !bool {
    const DB = evt.EventDB(repo_hash);
    const kinds_cursor = try moment.getCursor(hash.hashInt(repo_hash, evt.event_index_key)) orelse return false;
    if (try evt.readEventKind(repo_hash, try DB.HashMap(.read_only).init(kinds_cursor), id) != kind) return false;
    const Removed = struct { removed: bool };
    const record = switch (kind) {
        .issue => try evt.readRecordSubset(evt.Issue, Removed, DB, repo_hash, moment, arena, id),
        .discuss => try evt.readRecordSubset(evt.Discussion, Removed, DB, repo_hash, moment, arena, id),
        .patch => try evt.readRecordSubset(evt.Patch, Removed, DB, repo_hash, moment, arena, id),
        else => return false,
    } orelse return false;
    return !record.removed;
}

/// a notif's position in the inbox's order, newest first. a cursor names one.
pub const OrderKey = [@sizeOf(u64) + evt.event_id_size]u8;

/// a notif the viewer may read, with where its thread is now
pub const Shown = struct {
    item: Item,
    place: Place,
    order_key: OrderKey,
};

/// one window of the notifs a viewer may read, with their counts
pub const Window = struct {
    items: []const Shown,
    // the first notif after the window, or null when it is the last
    next: ?OrderKey,
    // how many readable notifs the window's start skipped
    skipped: u64,
    // every readable notif, and the unread ones among them
    total: u64,
    unread: u64,
};

/// where a window starts among the readable notifs: after skipping a number of
/// them, or at the first whose order key is at or after a cursor's (a notif
/// bumped or dismissed since the cursor was given out doesn't move it)
pub const From = union(enum) {
    index: u64,
    key: OrderKey,
};

/// up to `count` of the notifs `readable`'s viewer may read (of threads still
/// there, in repos they may still read), from `from`,
/// newest first, with the counts of every readable notif, read or not.
/// `moment` is the viewer's user repo's latest. the TUI's inbox and the JSON
/// API both read through this, so neither shows a notif of a thread its
/// reader may no longer read, in a list or in a count.
pub fn readWindow(moment: UserDB.HashMap(.read_only), arena: *std.heap.ArenaAllocator, readable: *Readable, from: From, count: usize) !Window {
    var window: Window = .{ .items = &.{}, .next = null, .skipped = 0, .total = 0, .unread = 0 };
    var items: std.ArrayList(Shown) = .empty;
    const recent_cursor = try moment.getCursor(hash.hashInt(hash_kind, recent_notif_id_set_key)) orelse return window;
    const recent = try UserDB.SortedSet(.read_only).init(recent_cursor);

    // every notif, newest first, with the place of its thread if the viewer may read its repo
    var entries: std.ArrayList(Entry) = .empty;
    var iter = try recent.iteratorFromIndex(0);
    while (try iter.next()) |kv_cursor| {
        var cursor = kv_cursor;
        const kv_pair = try cursor.readKeyValuePair();
        var order_key: OrderKey = undefined;
        _ = try kv_pair.key_cursor.readBytes(&order_key);
        const id = order_key[@sizeOf(u64)..].*;
        const item = (try readItem(moment, arena, &id)) orelse return error.NotFound;
        try entries.append(arena.allocator(), .{ .item = item, .place = try readable.placeOf(item.notif), .order_key = order_key });
    }
    // then of those, the ones whose thread is gone, each repo opened once
    var checked: std.AutoHashMapUnmanaged([evt.event_id_size]u8, void) = .empty;
    for (entries.items, 0..) |entry, index| {
        if (entry.place == null) continue;
        if ((try checked.getOrPut(arena.allocator(), entry.item.notif.repo_id)).found_existing) continue;
        try readable.dropRemoved(entries.items[index..], &entry.item.notif.repo_id);
    }

    for (entries.items) |entry| {
        const item = entry.item;
        const order_key = entry.order_key;
        const place = entry.place orelse continue;

        const started = switch (from) {
            .index => |start| window.total >= start,
            .key => |key| std.mem.order(u8, &order_key, &key) != .lt,
        };
        window.total += 1;
        if (item.unread) window.unread += 1;
        if (!started) {
            window.skipped += 1;
        } else if (items.items.len < count) {
            try items.append(arena.allocator(), .{ .item = item, .place = place, .order_key = order_key });
        } else if (window.next == null) {
            window.next = order_key;
        }
    }
    window.items = items.items;
    return window;
}

// one change of a notify mode at a time in this process (the web, the API and
// the TUI over SSH all run in it): a subscription's place in its tier and its
// record land together, or neither does, before another change reads them, so
// no change answers on one still being made
var mode_mutex: std.Io.Mutex = .init;

/// what subscribing came to
pub const Subscribed = enum {
    // a tier holds the user: the subscribed one now, or one that already did
    subscribed,
    // the subscribed tier was at its cap, so nothing changed
    full,
};

// notify `user_id` of the thread `thread_id` in the repo at `location` by
// choice, unless a tier already holds them or the subscribed tier is full.
// the cap is checked and the user put in the tier in one transaction on the
// owner's index, so subscribers racing for the last place can't pass it.
pub fn subscribe(
    io: std.Io,
    allocator: std.mem.Allocator,
    users_dir: []const u8,
    user_id: *const [evt.event_id_size]u8,
    location: evt.RepoLocation,
    thread_id: *const [evt.event_id_size]u8,
    author: evt.CommitAuthor,
) !Subscribed {
    mode_mutex.lockUncancelable(io);
    defer mode_mutex.unlock(io);
    const Reserved = enum { already, full, reserved };
    const Ctx = struct {
        notif_id: [evt.event_id_size]u8,
        user_id: *const [evt.event_id_size]u8,
        out: *Reserved,

        pub fn run(ctx: @This(), cursor: *UserDB.Cursor(.read_write)) !void {
            const moment = try UserDB.HashMap(.read_write).init(cursor.*);
            if (try isNotified(moment.readOnly(), &ctx.notif_id, ctx.user_id)) {
                ctx.out.* = .already;
                return error.CancelTransaction;
            }
            if (try tierFull(moment.readOnly(), &ctx.notif_id, .subscribed)) {
                ctx.out.* = .full;
                return error.CancelTransaction;
            }
            const tier = comptime tierOf(.subscribed) orelse unreachable;
            const sets = try UserDB.HashMap(.read_write).init(try moment.putCursor(hash.hashInt(hash_kind, tier.map_key)));
            const users = try UserDB.SortedSet(.read_write).init(try sets.putCursor(hash.hashInt(hash_kind, &ctx.notif_id)));
            try users.put(ctx.user_id);
            ctx.out.* = .reserved;
        }
    };
    var reserved: Reserved = .already;
    try transact(io, allocator, users_dir, &location.owner_id, Ctx{ .notif_id = idOf(&location.repo_id, thread_id), .user_id = user_id, .out = &reserved });
    switch (reserved) {
        .already => return .subscribed,
        .full => return .full,
        .reserved => {},
    }
    // a record that can't be written gives the place back, so the index never
    // holds a subscriber whose own record says otherwise (or nothing), and a
    // retry reserves afresh
    errdefer unreserve(io, allocator, users_dir, &location, thread_id, user_id);
    try writeRecord(io, allocator, users_dir, user_id, &location, thread_id, .subscribed, author);
    return .subscribed;
}

// take `user_id` out of the subscribed tier `subscribe` reserved for them,
// logging rather than returning a failure
fn unreserve(
    io: std.Io,
    allocator: std.mem.Allocator,
    users_dir: []const u8,
    location: *const evt.RepoLocation,
    thread_id: *const [evt.event_id_size]u8,
    user_id: *const [evt.event_id_size]u8,
) void {
    const Ctx = struct {
        notif_id: [evt.event_id_size]u8,
        user_id: *const [evt.event_id_size]u8,

        pub fn run(ctx: @This(), cursor: *UserDB.Cursor(.read_write)) !void {
            const moment = try UserDB.HashMap(.read_write).init(cursor.*);
            const tier = comptime tierOf(.subscribed) orelse unreachable;
            const sets = try UserDB.HashMap(.read_write).init(try moment.putCursor(hash.hashInt(hash_kind, tier.map_key)));
            const users = try UserDB.SortedSet(.read_write).init(try sets.putCursor(hash.hashInt(hash_kind, &ctx.notif_id)));
            if (!try users.remove(ctx.user_id)) return error.CancelTransaction;
        }
    };
    transact(io, allocator, users_dir, &location.owner_id, Ctx{ .notif_id = idOf(&location.repo_id, thread_id), .user_id = user_id }) catch |err| {
        std.log.warn("failed to release a subscriber's place: {s}", .{@errorName(err)});
    };
}

// never notify `user_id` of the thread `thread_id` in the repo at `location`, dropping its notif
pub fn mute(
    io: std.Io,
    allocator: std.mem.Allocator,
    users_dir: []const u8,
    user_id: *const [evt.event_id_size]u8,
    location: evt.RepoLocation,
    thread_id: *const [evt.event_id_size]u8,
    author: evt.CommitAuthor,
) !void {
    mode_mutex.lockUncancelable(io);
    defer mode_mutex.unlock(io);
    try writeModeLocked(io, allocator, users_dir, user_id, &location, thread_id, .muted, author);
    try dismiss(io, allocator, users_dir, user_id, &idOf(&location.repo_id, thread_id));
}

// write the user's notify event for a thread, then move them to its tier in the owner's index
pub fn writeMode(
    io: std.Io,
    allocator: std.mem.Allocator,
    users_dir: []const u8,
    user_id: *const [evt.event_id_size]u8,
    location: *const evt.RepoLocation,
    thread_id: *const [evt.event_id_size]u8,
    mode: evt.Notify.Mode,
    author: evt.CommitAuthor,
) !void {
    mode_mutex.lockUncancelable(io);
    defer mode_mutex.unlock(io);
    try writeModeLocked(io, allocator, users_dir, user_id, location, thread_id, mode, author);
}

// `writeMode`, for a caller holding `mode_mutex`
fn writeModeLocked(
    io: std.Io,
    allocator: std.mem.Allocator,
    users_dir: []const u8,
    user_id: *const [evt.event_id_size]u8,
    location: *const evt.RepoLocation,
    thread_id: *const [evt.event_id_size]u8,
    mode: evt.Notify.Mode,
    author: evt.CommitAuthor,
) !void {
    try writeRecord(io, allocator, users_dir, user_id, location, thread_id, mode, author);
    indexMode(io, allocator, users_dir, location, thread_id, user_id, mode);
}

// write the user's notify event for a thread
fn writeRecord(
    io: std.Io,
    allocator: std.mem.Allocator,
    users_dir: []const u8,
    user_id: *const [evt.event_id_size]u8,
    location: *const evt.RepoLocation,
    thread_id: *const [evt.event_id_size]u8,
    mode: evt.Notify.Mode,
    author: evt.CommitAuthor,
) !void {
    {
        var user_repo = (try evt.openUserRepo(io, allocator, users_dir, user_id)) orelse return error.NotFound;
        defer user_repo.deinit(io, allocator);
        try evt.consume(.{ .server = .{ .users_dir = users_dir } }, .user, .xit, evt.user_repo_opts, io, allocator, &user_repo, evt.events_ref, &[_]evt.EventWithId{.{
            .id = std.fmt.bytesToHex(evt.Notify.idOf(&location.repo_id, thread_id), .lower),
            .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
            .author = author,
            .event = .{ .notify = .{
                .owner_id = std.fmt.bytesToHex(location.owner_id, .lower),
                .repo_id = std.fmt.bytesToHex(location.repo_id, .lower),
                .thread_id = std.fmt.bytesToHex(thread_id.*, .lower),
                .mode = mode,
            } },
        }});
    }
}

// move `user_id` to `mode`'s tier on the thread in its repo owner's index, or
// out of every tier for a mute, logging rather than returning a failure
fn indexMode(
    io: std.Io,
    allocator: std.mem.Allocator,
    users_dir: []const u8,
    location: *const evt.RepoLocation,
    thread_id: *const [evt.event_id_size]u8,
    user_id: *const [evt.event_id_size]u8,
    mode: evt.Notify.Mode,
) void {
    const Ctx = struct {
        notif_id: [evt.event_id_size]u8,
        user_id: *const [evt.event_id_size]u8,
        mode: evt.Notify.Mode,

        pub fn run(ctx: @This(), cursor: *UserDB.Cursor(.read_write)) !void {
            const moment = try UserDB.HashMap(.read_write).init(cursor.*);
            inline for (comptime std.enums.values(evt.Notify.Mode)) |tier_mode| {
                if (comptime tierOf(tier_mode)) |tier| {
                    const sets = try UserDB.HashMap(.read_write).init(try moment.putCursor(hash.hashInt(hash_kind, tier.map_key)));
                    const users = try UserDB.SortedSet(.read_write).init(try sets.putCursor(hash.hashInt(hash_kind, &ctx.notif_id)));
                    if (tier_mode == ctx.mode) try users.put(ctx.user_id) else _ = try users.remove(ctx.user_id);
                }
            }
        }
    };

    transact(io, allocator, users_dir, &location.owner_id, Ctx{
        .notif_id = idOf(&location.repo_id, thread_id),
        .user_id = user_id,
        .mode = mode,
    }) catch |err| {
        std.log.warn("failed to index thread notify mode: {s}", .{@errorName(err)});
    };
}

// put the users `events` show taking part in their threads in a tier, the
// threads' authors and the assignees as involved and the commenters as
// commented. logs rather than returning a failure.
pub fn subscribeParticipants(io: std.Io, allocator: std.mem.Allocator, server: evt.Host.Server, repo_path: []const u8, events: []const evt.EventWithId) void {
    const admin_repo_path = server.admin_repo_path orelse return;
    const location = evt.parseRepoPath(server.users_dir, repo_path) orelse return;
    subscribeEach(io, allocator, server.users_dir, admin_repo_path, location, events) catch |err| {
        std.log.warn("failed to subscribe thread participants: {s}", .{@errorName(err)});
    };
}

fn subscribeEach(io: std.Io, allocator: std.mem.Allocator, users_dir: []const u8, admin_repo_path: []const u8, location: evt.RepoLocation, events: []const evt.EventWithId) !void {
    var admin_repo = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = admin_repo_path });
    defer admin_repo.deinit(io, allocator);
    const admin_moment = try evt.currentMoment(evt.admin_repo_opts, &admin_repo);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for (events) |event| {
        const thread_hex: [evt.event_id_size * 2]u8, const email: []const u8, const mode: evt.Notify.Mode = switch (event.event) {
            inline .discuss, .issue, .patch => |thread| if (thread != null) .{ event.id, event.author.email, .involved } else continue,
            .comment => |comment_maybe| if (comment_maybe) |comment| .{ comment.thread_id, event.author.email, .commented } else continue,
            .assign => |assign_maybe| if (assign_maybe) |assign| .{ assign.thread_id, assign.email, .involved } else continue,
            else => continue,
        };
        const user_id = (try evt.User.readIdByEmail(evt.AdminDB, evt.admin_repo_opts.hash, admin_moment, email)) orelse continue;
        const thread_id = try evt.parseEventId(&thread_hex);
        // the check and the write it allows are one change of the user's mode
        mode_mutex.lockUncancelable(io);
        defer mode_mutex.unlock(io);
        // a mute stands, and a record only ever moves up to involved
        {
            var user_repo = (try evt.openUserRepo(io, allocator, users_dir, &user_id)) orelse continue;
            defer user_repo.deinit(io, allocator);
            if (try evt.userMoment(&user_repo)) |moment| {
                if (try evt.Notify.readMode(UserDB, hash_kind, moment, &arena, &location.repo_id, &thread_id)) |existing| {
                    if (mode != .involved or existing == .involved or existing == .muted) continue;
                }
            }
        }
        // a full commented tier takes nobody new, so a later comment checks again
        if (mode == .commented) {
            var owner_repo = (try evt.openUserRepo(io, allocator, users_dir, &location.owner_id)) orelse return error.NotFound;
            defer owner_repo.deinit(io, allocator);
            if (try tierFull(try owner_repo.core.latestMoment(), &idOf(&location.repo_id, &thread_id), .commented)) continue;
        }
        // the write's own author, which for an assignment is the assigner
        try writeModeLocked(io, allocator, users_dir, &user_id, &location, &thread_id, mode, event.author);
    }
}

// the thread `notif_id` names' set under a tier's `map_key`, or null before its
// first user. `moment` is its repo owner's user repo's latest.
fn tierSet(moment: UserDB.HashMap(.read_only), notif_id: *const [evt.event_id_size]u8, map_key: []const u8) !?UserDB.SortedSet(.read_only) {
    const sets_cursor = try moment.getCursor(hash.hashInt(hash_kind, map_key)) orelse return null;
    const users_cursor = try (try UserDB.HashMap(.read_only).init(sets_cursor)).getCursor(hash.hashInt(hash_kind, notif_id)) orelse return null;
    return try UserDB.SortedSet(.read_only).init(users_cursor);
}

// the users in the tiers of the thread `notif_id` names. `moment` is its repo owner's user repo's latest.
pub fn readNotified(moment: UserDB.HashMap(.read_only), arena: *std.heap.ArenaAllocator, notif_id: *const [evt.event_id_size]u8) ![]const [evt.event_id_size]u8 {
    var user_ids: std.ArrayList([evt.event_id_size]u8) = .empty;
    inline for (comptime std.enums.values(evt.Notify.Mode)) |mode| {
        if (comptime tierOf(mode)) |tier| {
            if (try tierSet(moment, notif_id, tier.map_key)) |users| {
                var iter = try users.iteratorFromIndex(0);
                while (try iter.next()) |kv_cursor| {
                    var cursor = kv_cursor;
                    const kv_pair = try cursor.readKeyValuePair();
                    var user_id: [evt.event_id_size]u8 = undefined;
                    _ = try kv_pair.key_cursor.readBytes(&user_id);
                    try user_ids.append(arena.allocator(), user_id);
                }
            }
        }
    }
    return user_ids.items;
}

// whether a tier of the thread `notif_id` names holds `user_id`. `moment` is its repo owner's user repo's latest.
pub fn isNotified(moment: UserDB.HashMap(.read_only), notif_id: *const [evt.event_id_size]u8, user_id: *const [evt.event_id_size]u8) !bool {
    inline for (comptime std.enums.values(evt.Notify.Mode)) |mode| {
        if (comptime tierOf(mode)) |tier| {
            if (try tierSet(moment, notif_id, tier.map_key)) |users| {
                if (try users.contains(user_id)) return true;
            }
        }
    }
    return false;
}

// whether `mode`'s tier on the thread `notif_id` names is at its cap. `moment` is its repo owner's user repo's latest.
pub fn tierFull(moment: UserDB.HashMap(.read_only), notif_id: *const [evt.event_id_size]u8, comptime mode: evt.Notify.Mode) !bool {
    const tier = comptime tierOf(mode) orelse @compileError("a mute has no tier");
    const cap = tier.cap orelse return false;
    const users = (try tierSet(moment, notif_id, tier.map_key)) orelse return false;
    return try users.count() >= cap;
}

// mark `user_id`'s notif on a thread read now that a page has shown the thread
// as `repo`'s current moment holds it: unless it was bumped past `seen` (the
// bump the page read, or null for whichever it names now) since, or names a
// child the page can't show. markRead checks the bump again in its transaction.
pub fn markViewed(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    users_dir: []const u8,
    user_id: *const [evt.event_id_size]u8,
    repo: *rp.Repo(.xit, repo_opts),
    repo_id: *const [evt.event_id_size]u8,
    thread_id: *const [evt.event_id_size]u8,
    seen: ?*const [evt.event_id_size]u8,
) !void {
    const notif_id = idOf(repo_id, thread_id);
    const item = blk: {
        var user_repo = (try evt.openUserRepo(io, allocator, users_dir, user_id)) orelse return;
        defer user_repo.deinit(io, allocator);
        const latest = (try latestMoment(&user_repo)) orelse return;
        break :blk (try readItem(latest, arena, &notif_id)) orelse return;
    };
    if (!item.unread) return;
    const last_child_id = seen orelse &item.notif.last_child_id;
    if (!std.mem.eql(u8, last_child_id, &item.notif.last_child_id)) return;
    // the page reads this moment or a newer one, so a child in it is shown
    const moment = try evt.currentMoment(repo_opts, repo);
    const kinds_cursor = try moment.getCursor(hash.hashInt(repo_opts.hash, evt.event_index_key)) orelse return error.CursorNotFound;
    const kinds = try evt.EventDB(repo_opts.hash).HashMap(.read_only).init(kinds_cursor);
    // a child the page can't show leaves it unread
    if (try evt.readEventKind(repo_opts.hash, kinds, last_child_id) == null) return;
    try markRead(io, allocator, users_dir, user_id, &notif_id, last_child_id);
}

//
// delivery
//

// deliver the notifs of the comments and assignments the repo transaction at
// `moment_index` created, logging rather than returning a failure.
// `pusher_id` is the user who pushed it, if a push did.
pub fn deliverTransaction(
    io: std.Io,
    allocator: std.mem.Allocator,
    server: evt.Host.Server,
    comptime repo_opts: rp.RepoOpts(.xit),
    repo: *rp.Repo(.xit, repo_opts),
    moment_index: u64,
    pusher_id: ?*const [evt.event_id_size]u8,
    progress_ctx_maybe: ?repo_opts.ProgressCtx,
) void {
    const admin_repo_path = server.admin_repo_path orelse return;
    const location = evt.parseRepoPath(server.users_dir, repo.core.work_path) orelse return;
    deliverEach(repo_opts, io, allocator, server.users_dir, admin_repo_path, location, repo, moment_index, pusher_id, progress_ctx_maybe) catch |err| {
        std.log.warn("failed to deliver notifications: {s}", .{@errorName(err)});
    };
}

// a transaction's notifs, coalesced per user and thread
const Inboxes = struct {
    arena: *std.heap.ArenaAllocator,
    admin_moment: evt.AdminDB.HashMap(.read_only),
    owner_moment: UserDB.HashMap(.read_only),
    repo: evt.Repo.Record,
    repo_id: *const [evt.event_id_size]u8,
    // each user's role in the repo, or null when they are inactive or hold none
    roles: std.AutoHashMapUnmanaged([evt.event_id_size]u8, ?evt.Repo.Role) = .empty,
    by_user: std.AutoArrayHashMapUnmanaged([evt.event_id_size]u8, std.ArrayList(Notif)) = .empty,

    fn add(self: *Inboxes, user_id: [evt.event_id_size]u8, notif: Notif) !void {
        if (!mayRead(self.repo.event, try self.roleOf(user_id), notif.thread_kind)) return;
        const entry = try self.by_user.getOrPut(self.arena.allocator(), user_id);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        // events arrive newest first, so a thread keeps its latest child
        for (entry.value_ptr.items) |existing| {
            if (std.mem.eql(u8, &existing.thread_id, &notif.thread_id)) return;
        }
        try entry.value_ptr.append(self.arena.allocator(), notif);
    }

    fn roleOf(self: *Inboxes, user_id: [evt.event_id_size]u8) !?evt.Repo.Role {
        if (self.roles.get(user_id)) |role| return role;
        const role = if (try evt.User.readById(evt.AdminDB, evt.admin_repo_opts.hash, self.admin_moment, self.arena, &user_id)) |user|
            (if (user.removed) null else try evt.Repo.roleOf(UserDB, hash_kind, self.owner_moment, self.arena, self.repo, self.repo_id, user_id))
        else
            null;
        try self.roles.put(self.arena.allocator(), user_id, role);
        return role;
    }
};

fn deliverEach(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    allocator: std.mem.Allocator,
    users_dir: []const u8,
    admin_repo_path: []const u8,
    location: evt.RepoLocation,
    repo: *rp.Repo(.xit, repo_opts),
    moment_index: u64,
    pusher_id: ?*const [evt.event_id_size]u8,
    progress_ctx_maybe: ?repo_opts.ProgressCtx,
) !void {
    const DB = evt.EventDB(repo_opts.hash);
    const haxy_moment = try evt.currentMoment(repo_opts, repo);
    // the transaction's events, newest first
    const ids = (try evt.momentEventIds(DB, repo_opts.hash, haxy_moment, moment_index)) orelse return;

    var owner_repo = (try evt.openUserRepo(io, allocator, users_dir, &location.owner_id)) orelse return;
    defer owner_repo.deinit(io, allocator);
    const owner_moment = (try evt.userMoment(&owner_repo)) orelse return;
    // the owner's plain data, which holds the tier index
    const owner_latest = try owner_repo.core.latestMoment();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const repo_record = (try evt.Repo.readById(UserDB, hash_kind, owner_moment, &arena, &location.repo_id)) orelse return;
    if (repo_record.removed) return;

    var admin_repo = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = admin_repo_path });
    defer admin_repo.deinit(io, allocator);

    const admin_moment = try evt.currentMoment(evt.admin_repo_opts, &admin_repo);
    const owner = (try evt.User.readById(evt.AdminDB, evt.admin_repo_opts.hash, admin_moment, &arena, &location.owner_id)) orelse return;

    var inboxes: Inboxes = .{
        .arena = &arena,
        .admin_moment = admin_moment,
        .owner_moment = owner_moment,
        .repo = repo_record,
        .repo_id = &location.repo_id,
    };

    const kinds_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, evt.event_index_key)) orelse return error.CursorNotFound;
    const kinds = try DB.HashMap(.read_only).init(kinds_cursor);

    var iter = try ids.iteratorFromIndex(0);
    while (try iter.next()) |kv_cursor| {
        var cursor = kv_cursor;
        const kv_pair = try cursor.readKeyValuePair();
        var order_key: [@sizeOf(u64) + evt.event_id_size]u8 = undefined;
        _ = try kv_pair.key_cursor.readBytes(&order_key);
        const id = order_key[@sizeOf(u64)..].*;
        const order = std.math.maxInt(u64) - std.mem.readInt(u64, order_key[0..@sizeOf(u64)], .big);

        // edits keep the created order, so only creations notify
        const Created = struct { thread_id: [evt.event_id_size * 2]u8, actor_email: ?[]const u8 };
        const created: Created = switch ((try evt.readEventKind(repo_opts.hash, kinds, &id)) orelse continue) {
            inline .comment, .assign => |kind| blk: {
                const Fields = struct { removed: bool, author_email: ?[]const u8, created_order: u64, event: struct { thread_id: [evt.event_id_size * 2]u8 } };
                const T = if (kind == .comment) evt.Comment else evt.Assignment;
                const record = (try evt.readRecordSubset(T, Fields, DB, repo_opts.hash, haxy_moment, &arena, &id)) orelse continue;
                if (record.removed or record.created_order != order) continue;
                break :blk .{ .thread_id = record.event.thread_id, .actor_email = record.author_email };
            },
            else => continue,
        };

        const thread_id = try evt.parseEventId(&created.thread_id);
        const Titled = struct { event: struct { title: []const u8 } };
        const thread_kind = (try evt.readEventKind(repo_opts.hash, kinds, &thread_id)) orelse continue;
        const thread = (switch (thread_kind) {
            .issue => try evt.readRecordSubset(evt.Issue, Titled, DB, repo_opts.hash, haxy_moment, &arena, &thread_id),
            .patch => try evt.readRecordSubset(evt.Patch, Titled, DB, repo_opts.hash, haxy_moment, &arena, &thread_id),
            .discuss => try evt.readRecordSubset(evt.Discussion, Titled, DB, repo_opts.hash, haxy_moment, &arena, &thread_id),
            else => null,
        }) orelse continue;

        const notif: Notif = .{
            .repo_id = location.repo_id,
            .owner_name = owner.event.name,
            .repo_name = repo_record.event.name,
            .thread_id = thread_id,
            .thread_kind = thread_kind,
            .title = thread.event.title,
            .last_child_id = id,
        };

        // a user hears of no comment or assignment they made or pushed
        const actor_id = if (created.actor_email) |email| try evt.User.readIdByEmail(evt.AdminDB, evt.admin_repo_opts.hash, admin_moment, email) else null;
        for (try readNotified(owner_latest, &arena, &idOf(&location.repo_id, &thread_id))) |user_id| {
            if (actor_id) |actor| if (std.mem.eql(u8, &actor, &user_id)) continue;
            if (pusher_id) |pusher| if (std.mem.eql(u8, pusher, &user_id)) continue;
            try inboxes.add(user_id, notif);
        }
    }

    if (inboxes.by_user.count() == 0) return;
    progress.report(repo_opts, io, progress_ctx_maybe, .{ .text = "Delivering notifications" });
    progress.report(repo_opts, io, progress_ctx_maybe, .{ .start = .{ .kind = .writing_patch, .estimated_total_items = inboxes.by_user.count() } });
    for (inboxes.by_user.keys(), inboxes.by_user.values()) |*user_id, notifs| {
        deliver(io, allocator, users_dir, user_id, notifs.items) catch |err| {
            std.log.warn("failed to deliver notifications: {s}", .{@errorName(err)});
        };
        progress.report(repo_opts, io, progress_ctx_maybe, .{ .complete_one = .writing_patch });
    }
    progress.report(repo_opts, io, progress_ctx_maybe, .{ .end = .writing_patch });
}
