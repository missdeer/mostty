cbuffer GridConfig : register(b0)
{
    uint2 cell_size;
    uint col_count;
    uint row_count;
    float scrollbar_y;
    float scrollbar_height;
    float scrollbar_x;
    float scrollbar_width;
    // Glyph atlas geometry, supplied by CPU so the pixel shader skips a
    // per-pixel GetDimensions/divide just to recover the same constant.
    uint cells_per_row;
    // Pixel height of the tab-bar band at the top. The grid is drawn under a
    // viewport offset by this much, so SV_Position.y is RT-absolute and every
    // terminal-space calc subtracts tab_bar_height first.
    uint tab_bar_height;
    // Background image: bit0 = enabled, bit1 = repeat/tile. Both 0 disables all
    // image sampling below.
    uint bg_image_flags;
    // Multiplier applied to the sampled image alpha (background-image-opacity).
    float bg_image_opacity;
    // Fitted image rectangle in terminal-grid pixel space: offset.xy, size.xy.
    float4 bg_image_dest;
}

struct Cell
{
    uint glyph_index;
    uint bg;
    uint fg;
    uint attrs;
};
StructuredBuffer<Cell> cells : register(t0);
Texture2D<float4> glyph_texture : register(t1);
Texture2D<float4> bg_image : register(t2);
Texture2D<float4> inline_image : register(t3);
SamplerState bg_sampler : register(s0);

cbuffer ImageConfig : register(b0)
{
    float4 image_dest;
    float4 image_source;
    float2 image_size;
    float image_tab_bar_height;
    float image_pad;
}

float4 VertexMain(uint id : SV_VERTEXID) : SV_POSITION
{
    return float4(
        2.0 * (float(id & 1) - 0.5),
        -(float(id >> 1) - 0.5) * 2.0,
        0, 1
    );
}

float4 UnpackRgba(uint packed)
{
    float4 unpacked;
    unpacked.r = (float)((packed >> 24) & 0xFF) / 255.0f;
    unpacked.g = (float)((packed >> 16) & 0xFF) / 255.0f;
    unpacked.b = (float)((packed >> 8) & 0xFF) / 255.0f;
    unpacked.a = (float)(packed & 0xFF) / 255.0f;
    return unpacked;
}

// Fast gamma decode approximation. This avoids per-pixel pow() while staying
// much closer to DirectWrite's gamma 2.2 output than the older c*c path.
float3 to_linear(float3 c) {
    c = saturate(c);
    return c * (c * (c * 0.305306011 + 0.682171111) + 0.012522878);
}

float4 PixelMain(float4 sv_pos : SV_POSITION) : SV_TARGET {
    // Terminal-space y: SV_Position is RT-absolute, the grid starts at
    // tab_bar_height (viewport offset), so subtract it for every cell calc.
    float gy_f = sv_pos.y - (float)tab_bar_height;

    // Background gradient (per-pixel sin dither was removed — its
    // amplitude was ±1/510 and the gradient deltas are tiny, so the
    // banding it hid is barely perceptible after sRGB encode).
    float2 pos = float2(sv_pos.x, max(0.0, gy_f)) / (cell_size * float2(col_count, row_count));
    float3 purple_gradient = float3(
        lerp(0.08, 0.08, pos.x),
        lerp(0.06, 0.07, pos.y),
        lerp(0.10, 0.09, (pos.x + pos.y) * 0.5)
    );

    uint grid_pixel_width = col_count * cell_size.x;

    // Scrollbar area (beyond the cell grid)
    if (sv_pos.x >= (float)grid_pixel_width) {
        float3 color = to_linear(purple_gradient);
        float alpha = 0.94;

        // Scrollbar thumb
        if (scrollbar_width > 0 &&
            sv_pos.y >= scrollbar_y && sv_pos.y < scrollbar_y + scrollbar_height)
        {
            color = lerp(color, to_linear(float3(0.03, 0.018, 0.04)), 0.8);
        }

        return float4(color * alpha, alpha);
    }

    // Cell grid. Band pixels (gy_f < 0) shouldn't be rasterized thanks to the
    // viewport offset, but guard anyway so a stray pixel stays transparent.
    if (gy_f < 0.0) return float4(0.0, 0.0, 0.0, 0.0);
    uint gy = (uint)gy_f;
    uint col = sv_pos.x / cell_size.x;
    uint row = gy / cell_size.y;
    uint cell_index = row * col_count + col;

    Cell cell = cells[cell_index];
    float4 bg = UnpackRgba(cell.bg);
    float4 fg = UnpackRgba(cell.fg);
    float3 linear_bg = to_linear(bg.rgb);
    bool invisible = (cell.attrs & (1u << 6)) != 0;

    // Background image backdrop. The cell background color is composited OVER
    // the image (both premultiplied), so the image only shows through the
    // cell's translucent fraction (1 - bg.a): explicit opaque-bg cells hide it,
    // matching Ghostty. back_rgb/back_a are the un-premultiplied result the rest
    // of the shader uses in place of linear_bg / bg.a. When no image is
    // configured this is exactly the old (linear_bg, bg.a).
    float3 back_rgb = linear_bg;
    float back_a = bg.a;
    if ((bg_image_flags & 1u) != 0u && bg_image_dest.z > 0.0 && bg_image_dest.w > 0.0) {
        float2 uv = (float2(sv_pos.x, gy_f) - bg_image_dest.xy) / bg_image_dest.zw;
        bool inside;
        if ((bg_image_flags & 2u) != 0u) {
            uv = frac(uv);
            inside = true;
        } else {
            inside = all(uv >= 0.0) && all(uv < 1.0);
        }
        if (inside) {
            float4 img = bg_image.SampleLevel(bg_sampler, uv, 0);
            float img_a = saturate(img.a * bg_image_opacity);
            float3 img_lin = to_linear(img.rgb);
            float3 back_pm = linear_bg * bg.a + img_lin * img_a * (1.0 - bg.a);
            back_a = bg.a + img_a * (1.0 - bg.a);
            back_rgb = (back_a > 0.0) ? (back_pm / back_a) : float3(0.0, 0.0, 0.0);
        }
    }

    if (invisible) {
        // Skip glyph sampling entirely; render the backdrop as-is with its alpha
        // so the translucent default cell still lets DWM blur / the image show.
        return float4(back_rgb * back_a, back_a);
    }

    uint2 glyph_cell_pos = uint2(
        cell.glyph_index % cells_per_row,
        cell.glyph_index / cells_per_row
    );
    uint2 cell_pixel = uint2((uint)sv_pos.x, gy) % cell_size;
    uint2 texture_coord = glyph_cell_pos * cell_size + cell_pixel;
    float4 glyph_texel = glyph_texture.Load(int3(texture_coord, 0));

    bool color_glyph = (cell.attrs & (1u << 5)) != 0;
    if (color_glyph) {
        // Atlas was rendered into a PREMULTIPLIED D2D RT but D2D stored the
        // premultiplied value in sRGB-encoded space, so we must un-premultiply
        // before decoding gamma, then re-premultiply in linear space.
        // Composing without this step darkens emoji edges where alpha is
        // partial. Source-over with the cell's unpremultiplied bg produces a
        // premultiplied result for the sRGB RTV to re-encode on store.
        float src_a = glyph_texel.a;
        float3 src_rgb = (src_a > 0.0)
            ? to_linear(saturate(glyph_texel.rgb / src_a)) * src_a
            : float3(0.0, 0.0, 0.0);
        float out_a = src_a + back_a * (1.0 - src_a);
        float3 out_rgb = src_rgb + back_rgb * back_a * (1.0 - src_a);
        return float4(out_rgb, out_a);
    }

    // Linear-space blending. The sRGB-flavor RTV re-encodes on store.
    // Atlas RGB is gamma-encoded ClearType mask intensity; the same decode
    // approximates DirectWrite's gamma 2.2 mask back to linear coverage.
    float3 linear_fg = to_linear(fg.rgb);
    float3 cov = to_linear(glyph_texel.rgb) * fg.a;

    uint underline = cell.attrs & 7;
    bool strikethrough = (cell.attrs & (1u << 3)) != 0;
    bool overline = (cell.attrs & (1u << 4)) != 0;
    uint line_thickness = max(1u, cell_size.y / 14u);
    uint underline_y = cell_size.y - max(2u, cell_size.y / 8u);
    bool line_pixel = false;

    if (underline == 1) {
        line_pixel = line_pixel || (cell_pixel.y >= underline_y && cell_pixel.y < underline_y + line_thickness);
    } else if (underline == 2) {
        // Double underline: two `line_thickness`-tall bands with a one-thickness
        // gap. Anchor the lower band at `underline_y` and place the upper band
        // above the gap; shift the whole pair up if the lower line would
        // overflow the bottom of the cell at small sizes.
        uint gap = line_thickness;
        uint lower_top = underline_y;
        uint lower_bottom = lower_top + line_thickness;
        uint shift = (lower_bottom > cell_size.y) ? (lower_bottom - cell_size.y) : 0u;
        lower_top = (lower_top > shift) ? (lower_top - shift) : 0u;
        uint upper_top = (lower_top > line_thickness + gap) ? (lower_top - line_thickness - gap) : 0u;
        line_pixel = line_pixel ||
            (cell_pixel.y >= upper_top && cell_pixel.y < upper_top + line_thickness) ||
            (cell_pixel.y >= lower_top && cell_pixel.y < lower_top + line_thickness);
    } else if (underline == 3) {
        uint wave_y = underline_y + ((cell_pixel.x / 3u) & 1u);
        line_pixel = line_pixel || (cell_pixel.y >= wave_y && cell_pixel.y < wave_y + line_thickness);
    } else if (underline == 4) {
        line_pixel = line_pixel || ((cell_pixel.x % 4u) < 2u &&
            cell_pixel.y >= underline_y && cell_pixel.y < underline_y + line_thickness);
    } else if (underline == 5) {
        line_pixel = line_pixel || ((cell_pixel.x % 8u) < 5u &&
            cell_pixel.y >= underline_y && cell_pixel.y < underline_y + line_thickness);
    }
    if (strikethrough) {
        uint strike_y = cell_size.y / 2;
        line_pixel = line_pixel || (cell_pixel.y >= strike_y && cell_pixel.y < strike_y + line_thickness);
    }
    if (overline) {
        uint overline_y = max(1u, cell_size.y / 12u);
        line_pixel = line_pixel || (cell_pixel.y >= overline_y && cell_pixel.y < overline_y + line_thickness);
    }
    if (line_pixel) {
        cov = float3(1.0, 1.0, 1.0) * fg.a;
    }

    float3 color = back_rgb * (1.0 - cov) + linear_fg * cov;
    float alpha = lerp(back_a, 1.0, max(cov.r, max(cov.g, cov.b)));

    return float4(color * alpha, alpha);
}

float4 ImagePixelMain(float4 sv_pos : SV_POSITION) : SV_TARGET {
    float2 p = float2(sv_pos.x, sv_pos.y - image_tab_bar_height);
    float2 q = p - image_dest.xy;
    clip(q.x);
    clip(q.y);
    clip(image_dest.z - q.x);
    clip(image_dest.w - q.y);

    float2 uv = image_source.xy + (q / image_dest.zw) * image_source.zw;
    uv = uv / image_size;
    float4 img = inline_image.SampleLevel(bg_sampler, uv, 0);
    float alpha = saturate(img.a);
    return float4(to_linear(img.rgb) * alpha, alpha);
}
