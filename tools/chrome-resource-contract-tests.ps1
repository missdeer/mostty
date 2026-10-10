$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

function Function-Body([string]$source, [string]$name) {
    $match = [regex]::Match($source, "(?m)^(?:pub )?fn " + $name + "\(")
    if (-not $match.Success) { throw "Missing function $name" }
    $start = $source.IndexOf('{', $match.Index)
    $depth = 1
    $end = $start + 1
    while ($depth -gt 0 -and $end -lt $source.Length) {
        if ($source[$end] -eq '{') { $depth++ }
        if ($source[$end] -eq '}') { $depth-- }
        $end++
    }
    if ($depth -ne 0) { throw "Unbalanced function $name" }
    $source.Substring($start + 1, $end - $start - 2)
}

foreach ($path in @('src/win32/d3d11.zig', 'src/win32/d3d12/renderer.zig', 'src/win32/gl46.zig', 'src/win32/vulkan.zig')) {
    $source = Get-Content -Raw (Join-Path $root $path)
    $chrome = Function-Body $source 'renderChrome'
    $prepare = Function-Body $source 'prepareFrame'
    $pane = Function-Body $source 'render'
    $font = Function-Body $source 'onFontStateChanged'
    if ($chrome -notmatch 'prepareFrame\((self, )?hwnd, null, false\)') {
        throw "$path chrome must select preparation without terminal resources"
    }
    if ($pane -notmatch 'prepareFrame\((self, )?hwnd, term, mouse_in_scrollbar\)' -or $pane -notmatch 'prepared.atlas\.\?') {
        throw "$path panes must retain full terminal preparation"
    }
    $earlyReturn = $prepare.IndexOf('const term = terminal orelse return')
    $atlas = $prepare.IndexOf('glyph_mod.setupGlyphAtlas(self)')
    if ($earlyReturn -lt 0 -or $atlas -le $earlyReturn) {
        throw "$path chrome must return before allocating the glyph atlas/cache"
    }
    $chromeSetup = $prepare.Substring(0, $earlyReturn)
    if ($chromeSetup -notmatch 'font_service.cell_size_xy' -or $chromeSetup -notmatch 'common.tab_bar_height') {
        throw "$path chrome must retain current FontService metrics"
    }
    if ($chromeSetup -match 'setupGlyphAtlas|atlasEnsure|cellsResize') {
        throw "$path chrome must not allocate terminal resources"
    }
    if ($font -notmatch 'cache_gen \+%= 1' -or $source -notmatch 'tabbar_paint.signature\(tabbar, self.cache_gen,') {
        throw "$path font/DPI changes must still invalidate the tab band without an atlas"
    }
}
'PASS: 4 backend chrome/pane preparation and font epoch source contracts (offline; no GPU execution or memory measurement)'
