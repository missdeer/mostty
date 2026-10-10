param([switch]$Gui)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ci-result.ps1')
$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
$results = [Collections.Generic.List[object]]::new()
$folder = Join-Path $root 'tmp/ci-windows'
$null = New-Item -ItemType Directory -Force -Path $folder
function Invoke-Suite([string]$Name, [scriptblock]$Run, [string]$ResultDirectory = '', [string]$Renderer = '') {
    try {
        & $Run *> (Join-Path $folder "$Name.log")
        if (-not $?) { throw 'Suite returned failure' }
        $outcome = if ($ResultDirectory) { Read-VulkanBaselineOutcome $ResultDirectory $Renderer }
                   else { [ordered]@{status='pass';detail='See log and nested per-case results'} }
        $results.Add([ordered]@{suite=$Name;status=$outcome.status;detail=$outcome.detail})
    } catch {
        $results.Add([ordered]@{suite=$Name;status='fail';detail=$_.Exception.Message})
    }
}
try {
    Invoke-Suite 'shader-contract-tests' { & tools/shader-contract-tests.ps1 }
    Invoke-Suite 'pane-matrix-summary-test' { & tools/pane-matrix-summary-test.ps1 }
    Invoke-Suite 'vulkan-self-test' { & tools/vulkan-acceptance.ps1 self-test }
    Invoke-Suite 'ci-result-test' { & tools/ci-result-test.ps1 }
    if ($Gui) {
        Invoke-Suite 'startup-failure' { & tools/startup-failure.ps1 }
        Invoke-Suite 'pane-matrix-acceptance' { & tools/pane-matrix-acceptance.ps1 -SkipBuild }
        Invoke-Suite 'tabbar-acceptance' { & tools/tabbar-acceptance.ps1 }
        Invoke-Suite 'd3d11-close-redraw' { & tools/d3d11-close-redraw.ps1 }
        foreach ($renderer in @('d3d11','opengl','vulkan','native-vulkan')) {
            # A fresh directory prevents an old pass from masking missing output.
            $baseline = Join-Path $folder ("baseline-$renderer-" + [Guid]::NewGuid().ToString('N'))
            Invoke-Suite "vulkan-acceptance-$renderer" {
                & tools/vulkan-acceptance.ps1 run -Session local -Renderer $renderer -OutputDirectory $baseline
            } $baseline $renderer
        }
    } else {
        foreach ($suite in @('startup-failure','pane-acceptance','pane-backend-acceptance','pane-matrix-acceptance','tabbar-acceptance','d3d11-close-redraw','vulkan-acceptance-local')) {
            $results.Add([ordered]@{suite=$suite;status='blocked';detail='Requires an interactive desktop and renderer-capable GPU; dispatch GUI CI on an existing suitable runner'})
        }
    }
    foreach ($suite in @('ConPTY-pre-24H2-system-fallback','RDP-reconnect','session-switch','physical-mixed-DPI','real-device-removal')) {
        $results.Add([ordered]@{suite=$suite;status='blocked';detail='Dedicated operating system/hardware/operator validation required'})
    }
} finally {
    $results | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $folder 'results.json') -Encoding utf8
    $table = $results | ForEach-Object { [pscustomobject]$_ } | Format-Table -AutoSize | Out-String -Width 240
    Write-Host $table
    if ($env:GITHUB_STEP_SUMMARY) { Add-Content $env:GITHUB_STEP_SUMMARY "Windows test inventory (blocked is not passed):`n``````text`n$table`n```````n" }
    Pop-Location
}
if (@($results | Where-Object { $_.status -eq 'fail' }).Count) { throw 'One or more suites failed; inspect tmp/ci-windows' }
