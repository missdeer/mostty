cbuffer GridConfig : register(b0)
{
    uint2 cell_size;
    uint col_count;
    uint row_count;
    float scrollbar_y;
    float scrollbar_height;
    float scrollbar_x;
    float scrollbar_width;
}

struct Cell
{
    uint glyph_index;
    uint bg;
    uint fg;
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

// gamma 2.2 approximation. Matches DirectWrite's CreateCustomRenderingParams
// gamma so glyph coverage decoded with the same curve cancels the encode
// applied by D2D when rendering white-on-black ClearType.
float3 to_linear(float3 c) { return pow(max(c, 0.0), 2.2); }

float4 PixelMain(float4 sv_pos : SV_POSITION) : SV_TARGET {
    // Background gradient + dither (shared by grid and scrollbar)
    float2 pos = sv_pos.xy / (cell_size * float2(col_count, row_count));
    float3 purple_gradient = float3(
        lerp(0.08, 0.08, pos.x),
        lerp(0.06, 0.07, pos.y),
        lerp(0.10, 0.09, (pos.x + pos.y) * 0.5)
    );
    float noise = frac(sin(dot(sv_pos.xy, float2(12.9898, 78.233))) * 43758.5453);
    noise = (noise - 0.5) / 255.0;
    purple_gradient += noise;

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

    uint texture_width, texture_height;
    glyph_texture.GetDimensions(texture_width, texture_height);
    uint cells_per_row = texture_width / cell_size.x;

    uint2 glyph_cell_pos = uint2(
        cell.glyph_index % cells_per_row,
        cell.glyph_index / cells_per_row
    );
    uint2 cell_pixel = uint2(sv_pos.xy) % cell_size;
    uint2 texture_coord = glyph_cell_pos * cell_size + cell_pixel;
    float4 glyph_texel = glyph_texture.Load(int3(texture_coord, 0));

    // Linear-space blending. The sRGB-flavor RTV re-encodes on store.
    // Atlas RGB is gamma-encoded ClearType mask intensity; pow(2.2) decode
    // pairs with CreateCustomRenderingParams(gamma=2.2) to recover linear
    // per-subpixel coverage.
    float3 linear_gradient = to_linear(purple_gradient);
    float3 linear_fg = to_linear(fg.rgb);
    float3 linear_bg = lerp(linear_gradient, to_linear(bg.rgb), bg.a);
    float3 cov = to_linear(glyph_texel.rgb) * fg.a;
    float3 color = linear_bg * (1.0 - cov) + linear_fg * cov;
    // Conservative scalar alpha for premultiplied output on a translucent
    // window. `max(cov.rgb)` over-occludes uncovered subpixels slightly but
    // keeps text legible against the desktop showthrough.
    float alpha = lerp(0.94, 1.0, max(cov.r, max(cov.g, cov.b)));

    return float4(color * alpha, alpha);
}
