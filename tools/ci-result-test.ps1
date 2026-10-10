$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ci-result.ps1')
$directory = Join-Path (Split-Path $PSScriptRoot -Parent) ('tmp/ci-result-test-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $directory
$path = Join-Path $directory 'local-vulkan-auto-baseline.json'
$record = [ordered]@{session='local';renderer='vulkan';scenario='baseline';requested_present_tier='auto';status='pass';reason='fixture'}
try {
    foreach ($case in @(@('pass','pass'), @('unavailable','blocked'), @('fail','fail'))) {
        $record.status = $case[0]
        $record | ConvertTo-Json | Set-Content -LiteralPath $path
        $outcome = Read-VulkanBaselineOutcome $directory 'vulkan'
        if ($outcome.status -ne $case[1]) { throw "Incorrect mapping for $($case[0])" }
    }
    foreach ($case in @('unknown', 'mismatch', 'missing')) {
        $record.status = if ($case -eq 'unknown') { 'unknown' } else { 'pass' }
        $record.renderer = if ($case -eq 'mismatch') { 'opengl' } else { 'vulkan' }
        $record | ConvertTo-Json | Set-Content -LiteralPath $path
        if ($case -eq 'missing') { Remove-Item -LiteralPath $path }
        $rejected = $false
        try { $null = Read-VulkanBaselineOutcome $directory 'vulkan' } catch { $rejected = $true }
        if (-not $rejected) { throw "Invalid $case evidence was accepted" }
    }
    'PASS: baseline pass/fail/unavailable remain distinct; unknown, mismatched and missing evidence are rejected'
} finally {
    Remove-Item -LiteralPath $directory -Recurse -Force
}
