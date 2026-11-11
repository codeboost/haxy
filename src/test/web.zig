//! the web ui over http, in process. these files import only modules that are
//! unchanged since 66c1ab6, so they also run against the handlers from before
//! the domain layer.

comptime {
    _ = @import("web/smoke.zig");
    _ = @import("web/repos.zig");
    _ = @import("web/members.zig");
    _ = @import("web/branches.zig");
    _ = @import("web/undo.zig");
    _ = @import("web/sync.zig");
    _ = @import("web/conflicts.zig");
    _ = @import("web/users.zig");
    _ = @import("web/keys.zig");
    _ = @import("web/delete.zig");
    _ = @import("web/notify.zig");
    _ = @import("web/threads.zig");
    _ = @import("web/comments.zig");
    _ = @import("web/assign.zig");
    _ = @import("web/patches.zig");
    _ = @import("web/merge.zig");
    _ = @import("web/attach.zig");
    _ = @import("web/connection.zig");
    _ = @import("web/patch_edit.zig");
    _ = @import("web/pages.zig");
}
