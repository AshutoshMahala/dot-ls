//! Editor rules are explicit. Restrictions do not ban valid DOT constructs.
const dot = @import("dot_parser");
pub const dot_ls: dot.Policy = blk: {
    var p = dot.presets.standard;
    p.scanner = .block;
    p.execution = .{ .metering = true, .cancellation = true };
    p.limits.max_nesting = 256;
    p.validation.invalid_encoding = .err;
    p.validation.repeated_attribute = .warning;
    break :blk p;
};
// Bounds apply only to repeated-attribute checking, never syntax acceptance.
pub const max_attribute_keys = 256;
pub const max_key_bytes = 4096;
pub const max_key_probes = 16;
