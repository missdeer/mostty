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
$out = Join-Path $root 'tmp/runtime-bench'
New-Item -ItemType Directory -Force $out | Out-Null
foreach ($side in @('base', 'head')) {
    $revision = if ($side -eq 'base') { $base } else { $head }
    $tree = Join-Path $out $side
    & git worktree add --detach $tree $revision
    if ($LASTEXITCODE -ne 0) { throw 'worktree creation failed' }
    if ((Get-FileHash "$root/build.zig.zon").Hash -ne (Get-FileHash "$tree/build.zig.zon").Hash) { throw 'Dependency manifests differ; comparison is not valid' }
    Copy-Item "$root/build.zig" "$tree/build.zig"
    Copy-Item "$root/src/runtime_bench*.zig" "$tree/src/"
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
        if ($LASTEXITCODE -ne 0) { throw "Benchmark build failed: $side" }
    } finally { Pop-Location }
}
$order = @('base', 'head', 'head', 'base', 'head', 'base', 'base', 'head')
@{ base=$base; head=$head; os=[Environment]::OSVersion.VersionString; cpu=(Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors); compiler=(& zig version); mode='ReleaseFast'; target_cpu='baseline'; warmup=3; samples_per_process=15; order=$order } | ConvertTo-Json -Depth 5 | Set-Content "$out/metadata.json"
for ($i = 0; $i -lt $order.Count; $i++) {
    $side = $order[$i]
    & "$out/$side/zig-out/bin/runtime-bench.exe" *> "$out/$side-$i.log"
    if ($LASTEXITCODE -ne 0) { throw "Benchmark assertion failed: $side trial $i" }
}
