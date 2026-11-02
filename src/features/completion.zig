//! Static keyword lists selected by the compact lexical context index.
pub const Item = struct { label: []const u8, detail: []const u8 };
pub const items = [_]Item{
    .{ .label = "graph", .detail = "Undirected graph or graph attribute defaults" },
    .{ .label = "digraph", .detail = "Directed graph" },
    .{ .label = "strict", .detail = "Graph without parallel edges" },
    .{ .label = "subgraph", .detail = "Subgraph or attribute scope" },
    .{ .label = "node", .detail = "Default node attributes" },
    .{ .label = "edge", .detail = "Default edge attributes" },
};

const body = [_]Item{ items[0], items[3], items[4], items[5] };
pub fn forContext(kind: @import("completion_context.zig").Kind) []const Item {
    return switch (kind) {
        .none, .attr_graph, .attr_node, .attr_edge, .attr_subgraph, .attr_cluster => &.{},
        .header => items[0..3],
        .graph_kind => items[0..2],
        .body => &body,
        .endpoint => items[3..4],
    };
}
