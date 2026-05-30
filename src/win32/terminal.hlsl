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
    uint3 _pad;
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
    // Background gradient (per-pixel sin dither was removed — its
    // amplitude was ±1/510 and the gradient deltas are tiny, so the
    // banding it hid is barely perceptible after sRGB encode).
    float2 pos = sv_pos.xy / (cell_size * float2(col_count, row_count));
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

    // Cell grid
    uint col = sv_pos.x / cell_size.x;
    uint row = sv_pos.y / cell_size.y;
    uint cell_index = row * col_count + col;

    Cell cell = cells[cell_index];
    float4 bg = UnpackRgba(cell.bg);
    float4 fg = UnpackRgba(cell.fg);
    float3 linear_bg = to_linear(bg.rgb);
    bool invisible = (cell.attrs & (1u << 6)) != 0;

    if (invisible) {
        // Skip glyph sampling entirely; render bg as-is with its alpha so the
        // translucent default cell still lets DWM blur through.
        return float4(linear_bg * bg.a, bg.a);
    }

    uint2 glyph_cell_pos = uint2(
        cell.glyph_index % cells_per_row,
        cell.glyph_index / cells_per_row
    );
    uint2 cell_pixel = uint2(sv_pos.xy) % cell_size;
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
        float out_a = src_a + bg.a * (1.0 - src_a);
        float3 out_rgb = src_rgb + linear_bg * bg.a * (1.0 - src_a);
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

    float3 color = linear_bg * (1.0 - cov) + linear_fg * cov;
    float alpha = lerp(bg.a, 1.0, max(cov.r, max(cov.g, cov.b)));

    return float4(color * alpha, alpha);
}
