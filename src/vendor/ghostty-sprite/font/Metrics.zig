//! Subset of ghostty's font/Metrics.zig — fields only, no calc/apply/clamp.
//! The sprite drawing code in `draw/*` only reads these fields; the
//! computation routines pull in font face / config dependencies we don't
//! ship.

const Metrics = @This();

/// Recommended cell width and height for a monospace grid using this font.
cell_width: u32,
cell_height: u32,

/// Distance in pixels from the bottom of the cell to the text baseline.
cell_baseline: u32,

/// Distance in pixels from the top of the cell to the top of the underline.
underline_position: u32,
/// Thickness in pixels of the underline.
underline_thickness: u32,

/// Distance in pixels from the top of the cell to the top of the strikethrough.
strikethrough_position: u32,
/// Thickness in pixels of the strikethrough.
strikethrough_thickness: u32,

/// Distance in pixels from the top of the cell to the top of the overline.
/// Can be negative to adjust the position above the top of the cell.
overline_position: i32,
/// Thickness in pixels of the overline.
overline_thickness: u32,

/// Thickness in pixels of box drawing characters.
box_thickness: u32,

/// The thickness in pixels of the cursor sprite. This has a default value
/// because it is not determined by fonts but rather by user configuration.
cursor_thickness: u32 = 1,

/// The height in pixels of the cursor sprite.
cursor_height: u32,

/// The constraint height for nerd fonts icons (unused by sprite draw).
icon_height: f64 = 0,
icon_height_single: f64 = 0,

/// Unrounded face width/height (unused by sprite draw).
face_width: f64 = 0,
face_height: f64 = 0,
face_y: f64 = 0,
