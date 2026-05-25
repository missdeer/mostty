//! Minimal `font` module facade for the vendored sprite drawing code.
//!
//! The original ghostty `src/font/main.zig` re-exports a large surface
//! (Atlas, Face, discovery, shaper, etc.). The sprite draw functions only
//! reference `font.Metrics` and `font.sprite.Canvas`, so this adapter
//! exposes just those two.

pub const Metrics = @import("Metrics.zig");

pub const sprite = struct {
    pub const Canvas = @import("sprite/canvas.zig").Canvas;
    pub const Color = @import("sprite/canvas.zig").Color;
    pub const Point = @import("sprite/canvas.zig").Point;
    pub const Box = @import("sprite/canvas.zig").Box;
};
