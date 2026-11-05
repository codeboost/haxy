comptime {
    _ = @import("test/api.zig");
    _ = @import("test/api_account.zig");
    _ = @import("test/api_discovery.zig");
    _ = @import("test/api_events.zig");
    _ = @import("test/api_find.zig");
    _ = @import("test/api_issues.zig");
    _ = @import("test/api_refs.zig");
    _ = @import("test/api_repo.zig");
    _ = @import("test/api_repo_create.zig");
    _ = @import("test/api_session.zig");
    _ = @import("test/event.zig");
    _ = @import("test/event/admin.zig");
    _ = @import("test/event/notify.zig");
    _ = @import("test/event/patch.zig");
    _ = @import("test/origin.zig");
    _ = @import("test/serve.zig");
    _ = @import("test/ssh.zig");
    _ = @import("test/ui.zig");
    _ = @import("test/undo.zig");
}
