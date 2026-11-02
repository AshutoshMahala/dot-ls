//! Shared editor coordinates. No feature or protocol dependencies.
pub const Encoding = enum { utf8, utf16, utf32 };
pub const Position = struct { line: usize, character: usize };
pub const Range = struct { start: Position, end: Position };
