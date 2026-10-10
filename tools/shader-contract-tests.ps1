$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$shader = Get-Content -Raw (Join-Path $root 'src/win32/terminal.hlsl')
# Evaluate the shader's actual scalar color expression. Equal-channel coverage
# is sufficient to expose double-premultiplication; no GPU result is claimed.
$match = [regex]::Match($shader, 'float3 color = (back_rgb[^;]+);\s*float alpha = [^;]+;\s*return float4\(([^,]+), alpha\);')
if (-not $match.Success) { throw 'Cannot locate text composite expression' }
$expression = $match.Groups[1].Value
foreach ($name in @('back_rgb','back_a','linear_fg','cov')) { $expression = $expression -replace "\b$name\b", ('$' + $name) }
$returned = $match.Groups[2].Value -replace '\bcolor\b', '$color' -replace '\balpha\b', '$alpha'
$evaluate = [scriptblock]::Create('param($back_rgb,$back_a,$linear_fg,$cov,$alpha); $color = ' + $expression + '; ' + $returned)
foreach ($case in @(
    @{bg=0;ba=0;fg=1;cov=0.5;alpha=0.5;expected=0.5},
    @{bg=1;ba=0;fg=1;cov=0.5;alpha=0.5;expected=0.5},
    @{bg=0.2;ba=1;fg=0.8;cov=0.5;alpha=1;expected=0.5},
    @{bg=0.2;ba=0.5;fg=0.8;cov=0.25;alpha=0.625;expected=0.275}
)) {
    $actual = & $evaluate $case.bg $case.ba $case.fg $case.cov $case.alpha
    if ([Math]::Abs($actual - $case.expected) -gt 0.00001) { throw "Premultiplied RGB: expected $($case.expected), got $actual" }
}
$boundary = [regex]::Match($shader, 'if \(sv_pos.x >= ([^)]+)\)')
if (-not $boundary.Success) { throw 'Cannot locate scrollbar boundary expression' }
$expression = $boundary.Groups[1].Value -replace '\bscrollbar_x\b', '$scrollbar_x' -replace '\bgrid_pixel_width\b', '$grid_pixel_width' -replace '\(float\)', ''
$evaluate = [scriptblock]::Create('param($scrollbar_x,$grid_pixel_width); ' + $expression)
foreach ($width in @(398, 400, 401)) {
    $expected = $width - 14
    $rounded = [Math]::Ceiling($expected / 20) * 20
    $actual = & $evaluate $expected $rounded
    if ($actual -ne $expected) { throw "Scrollbar rendering misses hit area at pane width $width" }
}
foreach ($path in @('src/win32/d3d11.zig','src/win32/d3d12/renderer.zig','src/win32/gl46.zig','src/win32/vulkan.zig')) {
    $source = Get-Content -Raw (Join-Path $root $path)
    if ($source -notmatch 'var (sb_geom|scrollbar):[^\n]+\.x = @floatFromInt\(grid_w\)') {
        throw "$path must preserve the scrollbar boundary even when its thumb is hidden"
    }
}
'PASS: 4 text-composite cases, 3 scrollbar widths, 4 backend hidden-thumb boundaries (offline; no GPU execution)'
