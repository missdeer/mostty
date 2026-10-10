param([string]$Executable = (Join-Path $PSScriptRoot '../zig-out/bin/Mostty.exe'))
$ErrorActionPreference = 'Stop'
$run = Join-Path (Split-Path $PSScriptRoot -Parent) ('tmp/startup-failure-' + [Guid]::NewGuid().ToString('N'))
$profile = Join-Path $run 'profile/Mostty'
$null = New-Item -ItemType Directory -Force -Path $profile
@('renderer = d3d11', 'launcher = missing | mostty-test-nonexistent-executable.exe') |
    Set-Content (Join-Path $profile 'config') -Encoding utf8
$start = [Diagnostics.ProcessStartInfo]::new([IO.Path]::GetFullPath($Executable))
$start.UseShellExecute = $false
$start.WorkingDirectory = $run
$start.Environment['LOCALAPPDATA'] = Split-Path $profile -Parent
$start.Environment['MOSTTY_DIAG'] = '1'
$app = [Diagnostics.Process]::Start($start)
try {
    if (-not $app.WaitForExit(15000)) { throw 'Failed launcher left a live empty window or blocked shutdown' }
    if ($app.ExitCode -ne 1) { throw "Expected controlled startup error 1, got $($app.ExitCode)" }
    $log = Get-Content -Raw (Join-Path $run 'tmp/mostty-diag.log')
    if ($log -notmatch "launcher 'missing' failed to start") { throw 'Launcher failure was not reported' }
    'PASS: failed first launcher exits without publishing an empty input window'
} finally {
    if (-not $app.HasExited) { $app.Kill(); $app.WaitForExit() }
    $app.Dispose()
}
