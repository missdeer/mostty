# Dot-sourced after normal PowerShell profiles; do not replace their prompt or input behavior.
if (Get-Variable MosttyIntegrationLoaded -Scope Global -ValueOnly -ErrorAction Ignore) { return }
if (!(Get-Variable LASTEXITCODE -Scope Global -ErrorAction Ignore)) { $global:LASTEXITCODE = 0 }
$global:MosttyIntegrationLoaded = $true
$global:MosttyOriginalPrompt = $function:prompt
$global:MosttyCommandStarted = $false
if (Test-Path Function:\PSConsoleHostReadLine) {
    $global:MosttyOriginalReadLine = $function:PSConsoleHostReadLine
    function global:PSConsoleHostReadLine {
        $line = & $global:MosttyOriginalReadLine
        [Console]::Write("$([char]27)]133;C$([char]7)")
        $global:MosttyCommandStarted = $true
        return $line
    }
}
function global:prompt {
    param($succeeded = $?, $exitCode = $global:LASTEXITCODE)
    # Run the user's prompt before integration commands change its view of $?.
    $text = if ($global:MosttyOriginalPrompt) { & $global:MosttyOriginalPrompt } else { "PS $PWD> " }
    $esc = [char]27
    $bel = [char]7
    if ($global:MosttyCommandStarted) {
        $status = if ($succeeded) { 0 } elseif ($exitCode) { $exitCode } else { 1 }
        [Console]::Write("$esc]133;D;$status$bel")
        $global:MosttyCommandStarted = $false
    }
    if ($PWD.Provider.Name -eq 'FileSystem') {
        $uri = [Uri]::new($PWD.ProviderPath).AbsoluteUri
        [Console]::Write("$esc]7;$uri$bel")
    }
    $title = ($PWD.Path -replace '[\x00-\x1f\x7f]', '')
    [Console]::Write("$esc]2;$title$bel$esc]133;A$bel")
    $global:LASTEXITCODE = $exitCode
    return "$text$esc]133;B$bel"
}
