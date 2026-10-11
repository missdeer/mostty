# Windows benchmark runner. Both executables are built before timing begins.
$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path
function GitValue([string[]]$Arguments) {
    $value = & git @Arguments
    if ($LASTEXITCODE -ne 0) { throw "git failed: $Arguments" }
    return "$value".Trim()
}
$base = GitValue @('rev-parse', "$($env:BENCH_BASE)^{commit}")
$headRef = if ($env:BENCH_HEAD) { $env:BENCH_HEAD } else { 'HEAD' }
$head = GitValue @('rev-parse', "$headRef^{commit}")
$out = Join-Path $root $(if ($env:BENCH_OUTPUT) { $env:BENCH_OUTPUT } else { 'tmp/runtime-bench' })
New-Item -ItemType Directory -Force $out | Out-Null
foreach ($side in @('base', 'head')) {
    $revision = if ($side -eq 'base') { $base } else { $head }
    $tree = Join-Path $out $side
    & git worktree add --detach $tree $revision
    if ($LASTEXITCODE -ne 0) { throw 'worktree creation failed' }
    if ((Get-FileHash "$root/build.zig.zon").Hash -ne (Get-FileHash "$tree/build.zig.zon").Hash) { throw 'Dependency manifests differ; comparison is not valid' }
    Copy-Item "$root/build.zig" "$tree/build.zig"
    Copy-Item "$root/src/runtime_bench*.zig" "$tree/src/"
    Copy-Item "$root/src/win32/d3d11/run_cache_fixture.zig" "$tree/src/win32/d3d11/"
    $cachePath = "$tree/src/win32/glyph_index_cache.zig"
    $cacheText = [IO.File]::ReadAllText($cachePath)
    if (-not $cacheText.Contains('pub var test_run_hash_calls: usize = 0;')) {
        $signature = 'pub fn initRun(text: []const u8, offset: u8, style: Style) Key {'
        if ([regex]::Matches($cacheText, [regex]::Escape($signature)).Count -ne 1) { throw 'Run hash instrumentation point changed' }
        $cacheText = $cacheText.Replace($signature, "$signature`n        if (@import(`"builtin`").is_test) test_run_hash_calls += 1;")
        $cacheText += "`npub var test_run_hash_calls: usize = 0;`n"
        [IO.File]::WriteAllText($cachePath, $cacheText)
    }
    $glyphPath = "$tree/src/win32/d3d11/glyph.zig"
    $glyphText = [IO.File]::ReadAllText($glyphPath)
    if (-not $glyphText.Contains('pub var test_blank_slot: ?u32 = null;')) {
        $signature = 'fn blankGlyphSlot(self: anytype, cache: *GlyphIndexCache, tex_cell_count: CellXY) u32 {'
        if ([regex]::Matches($glyphText, [regex]::Escape($signature)).Count -ne 1) { throw 'Blank glyph test boundary changed' }
        $glyphText = $glyphText.Replace($signature, "$signature`n    if (@import(`"builtin`").is_test) { if (test_blank_slot) |slot| return slot; }")
        $glyphText += "`npub var test_blank_slot: ?u32 = null;`n"
    }
    [IO.File]::WriteAllText($glyphPath, $glyphText + [IO.File]::ReadAllText("$root/tests/bench/windows-glyph.zig"))
    foreach ($part in @('mouse', 'misc')) {
        $path = "$tree/src/win32/wnd/$part.zig"
        $text = [IO.File]::ReadAllText($path)
        if ($part -eq 'mouse') {
            $needle = 'const new_hit = url_hover.detectAt(tab.term, cell.col, cell.row);'
            if ([regex]::Matches($text, [regex]::Escape($needle)).Count -ne 1) { throw 'Hover probe insertion point changed; update the shared harness' }
            $text = $text.Replace($needle, 'const new_hit = runtimeBenchDetect(tab.term, cell.col, cell.row);')
        }
        $text += [IO.File]::ReadAllText("$root/tests/bench/windows-$part.zig")
        [IO.File]::WriteAllText($path, $text)
    }
    $entry = [IO.File]::ReadAllText("$tree/src/mosttywindows.zig")
    $entry += "`ncomptime { _ = @import(`"runtime_bench.zig`"); }`n"
    $entry += "`npub fn runtimeBenchAllocator() @import(`"std`").mem.Allocator { return @import(`"win32/global.zig`").global.gpa.allocator(); }`n"
    [IO.File]::WriteAllText("$tree/src/mosttywindows.zig", $entry)
    Push-Location $tree
    try {
        & zig build runtime-bench -Druntime-bench -Doptimize=ReleaseFast -Dcpu=baseline --global-cache-dir "$root/.zig-cache" *> "$out/$side-build.log"
        if ($LASTEXITCODE -ne 0) { Get-Content "$out/$side-build.log" -Tail 100; throw "Benchmark build failed: $side" }
    } finally { Pop-Location }
}
$order = @('base', 'head', 'head', 'base', 'head', 'base', 'base', 'head')
@{ base=$base; head=$head; os=[Environment]::OSVersion.VersionString; cpu=(Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors); compiler=(& zig version); mode='ReleaseFast'; target_cpu='baseline'; warmup=3; samples_per_process=15; order=$order } | ConvertTo-Json -Depth 5 | Set-Content "$out/metadata.json"
for ($i = 0; $i -lt $order.Count; $i++) {
    $side = $order[$i]
    & "$out/$side/zig-out/bin/runtime-bench.exe" *> "$out/$side-$i.log"
    if ($LASTEXITCODE -ne 0) { Get-Content "$out/$side-$i.log" -Tail 100; throw "Benchmark assertion failed: $side trial $i" }
}
