//! The contract between the backend-agnostic render layer and a graphics
//! backend.
//!
//! Terminal-to-cell translation, glyph cache policy, grid geometry and dirty
//! range detection are the same work regardless of graphics API. Duplicating
//! them per backend would let two renderers drift apart, and visual
//! equivalence against D3D11 is exactly what a second backend is judged by —
//! drift would destroy the yardstick. So those modules are written against
//! `anytype` and resolve to whichever backend is instantiated; D3D11 keeps
//! running the same source it always did.
//!
//! A backend must provide:
//!   * `glyph_handoff` — which form it takes glyph pixels in
//!   * `atlasEnsure(tex_pixel) bool` — (re)size the atlas, true if retained
//!   * `atlasWriteCpu(dst_coord, src_ptr, src_row_pitch)` — one slot from CPU bytes
//!   * `atlasCopyStaging(staging, src_left, dst_coord)` — one slot from a font
//!     service surface; only required when `glyph_handoff == .shared_surface`
//!   * `cellsResize(count) bool` — (re)allocate the cell buffer, true if recreated
//!   * `cellsUpload(first_cell, cells)` — write a contiguous cell range
//!   * `backgroundImageUpload(decoded)`
//!
//! plus the fields the shared layer reads directly: `common`, `font_service`,
//! `shadow_cells`, `glyph_cache`, `glyph_cache_allocator`, `glyph_cache_cell_size`,
//! `cache_gen`, `grid_force_full`, `background_image`, `kitty_images`.

/// Which form the font service hands rasterized glyph pixels to a backend in.
///
/// The font service owns rasterization for both backends — that common source
/// is what keeps text coverage compositing comparable. What differs is only
/// the handoff form, because the surface-sharing mechanism the font service
/// uses today is not openable by every graphics API.
pub const GlyphHandoff = enum {
    /// The backend opens the font service's GPU surface directly. Available
    /// only to a backend on the same graphics API as the font service.
    shared_surface,
    /// The font service rasterizes into ordinary memory and the backend copies
    /// those bytes into its own upload resource. The bytes are never read by
    /// the GPU, so the handoff ends when the copy returns — no completion
    /// signal is involved and the font service may immediately reuse them.
    cpu_pixels,
};
