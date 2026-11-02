//! Unit-test entry point. Not imported by the production executable.
test {
    _ = @import("main.zig");
    _ = @import("app.zig");
    _ = @import("analysis/pipeline.zig");
    _ = @import("runtime/worker.zig");
    _ = @import("runtime/snapshot.zig");
    _ = @import("runtime/server.zig");
    _ = @import("runtime/document.zig");
    _ = @import("runtime/job.zig");
    _ = @import("runtime/requests.zig");
    _ = @import("runtime/limits.zig");
    _ = @import("protocol/json_message.zig");
    _ = @import("protocol/framing.zig");
    _ = @import("protocol/output.zig");
    _ = @import("protocol/lsp.zig");
    _ = @import("protocol/requests.zig");
    _ = @import("protocol/responses.zig");
    _ = @import("analysis/dot.zig");
    _ = @import("analysis/parser_policy.zig");
    _ = @import("analysis/validation.zig");
    _ = @import("analysis/diagnostic_text.zig");
    _ = @import("features/labels.zig");
    _ = @import("features/attributes.zig");
    _ = @import("features/completion_context.zig");
    _ = @import("features/completion.zig");
    _ = @import("features/references.zig");
    _ = @import("features/outline.zig");
    _ = @import("features/code_actions.zig");
    _ = @import("text/types.zig");
    _ = @import("text/positions.zig");
    _ = @import("text/coordinates.zig");
    _ = @import("tests/parser_sessions.zig");
}
