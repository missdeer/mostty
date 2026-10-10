function Read-VulkanBaselineOutcome([string]$Directory, [string]$Renderer) {
    $path = Join-Path $Directory "local-$Renderer-auto-baseline.json"
    $record = Get-Content -Raw -LiteralPath $path -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($record.session -ne 'local' -or $record.renderer -ne $Renderer -or
        $record.scenario -ne 'baseline' -or $record.requested_present_tier -ne 'auto') {
        throw 'Baseline evidence does not match the requested case'
    }
    $status = switch ($record.status) {
        'pass' { 'pass' }
        'unavailable' { 'blocked' }
        'fail' { 'fail' }
        default { throw "Unknown baseline result: $($record.status)" }
    }
    return [ordered]@{status=$status;detail="$($record.reason); evidence: $path"}
}
