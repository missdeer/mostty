param(
    [string]$Executable = (Join-Path (Split-Path $PSScriptRoot -Parent) 'zig-out/bin/Mostty.exe'),
    [string]$EmitFile,
    [int]$ChunkSize = 256
)
$ErrorActionPreference = 'Stop'
if ($EmitFile) {
    $bytes = [IO.File]::ReadAllBytes($EmitFile)
    $output = [Console]::OpenStandardOutput()
    for ($offset = 0; $offset -lt $bytes.Length; $offset += $ChunkSize) {
        $output.Write($bytes, $offset, [Math]::Min($ChunkSize, $bytes.Length - $offset))
        $output.Flush()
        Start-Sleep -Milliseconds 5
    }
    [IO.File]::WriteAllText($EmitFile + '.done', 'done')
    return
}

Add-Type -AssemblyName System.Windows.Forms
$savedClipboard = [Windows.Forms.DataObject]::new()
$original = [Windows.Forms.Clipboard]::GetDataObject()
if ($original) {
    foreach ($format in $original.GetFormats($false)) {
        $data = $original.GetData($format, $false)
        if ($null -ne $data) { $savedClipboard.SetData($format, $false, $data) }
    }
}
$root = Split-Path $PSScriptRoot -Parent
$runRoot = Join-Path $root ('tmp/clipboard-' + [Guid]::NewGuid().ToString('N'))
$profile = Join-Path $runRoot 'profile/Mostty'
$null = New-Item -ItemType Directory -Force -Path $profile
$client = Join-Path $root 'resources/mostty/Invoke-Mostty.ps1'
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$results = [Collections.Generic.List[object]]::new()
$app = $null
$sequenceNumber = 0
function Control([hashtable]$Request) {
    & $client -Executable $Executable -TargetProcess $app.Id -Request $Request
}
function Assert($Condition, [string]$Rule) {
    if (!$Condition) { throw $Rule }
    $results.Add([pscustomobject]@{ rule = $Rule; status = 'pass' })
}
function Emit([string]$Sequence, [int]$Chunk = 256) {
    $script:sequenceNumber++
    $path = Join-Path $runRoot ("sequence-$sequenceNumber.bin")
    [IO.File]::WriteAllBytes($path, [Text.Encoding]::UTF8.GetBytes($Sequence))
    $scriptPath = $PSCommandPath.Replace("'", "''")
    $quotedPath = $path.Replace("'", "''")
    $null = Control @{ action = 'input'; text = "& '$scriptPath' -EmitFile '$quotedPath' -ChunkSize $Chunk`r" }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (!(Test-Path -LiteralPath ($path + '.done'))) {
        if ($app.HasExited -or $watch.Elapsed.TotalSeconds -gt 20) { throw 'PTY emitter did not finish' }
        Start-Sleep -Milliseconds 50
    }
    Start-Sleep -Milliseconds 300
}
function Expect-Clipboard([string]$Expected, [string]$Rule) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $actual = [Windows.Forms.Clipboard]::GetText()
        if ($actual -ceq $Expected) { Assert $true $Rule; return }
        Start-Sleep -Milliseconds 50
    } while ($watch.Elapsed.TotalSeconds -lt 5)
    throw "$Rule (expected $($Expected.Length) chars, got $($actual.Length))"
}
function Osc52([string]$Text, [string]$Destination = 'c', [string]$Terminator = "`a") {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
    return "$([char]27)]52;$Destination;$encoded$Terminator"
}
try {
    @('renderer = d3d11', 'confirm-close-surface = false', "launcher = test | `"$pwsh`" -NoLogo -NoProfile") |
        Set-Content -LiteralPath (Join-Path $profile 'config') -Encoding utf8
    $start = [Diagnostics.ProcessStartInfo]::new($Executable)
    $start.UseShellExecute = $false
    $start.WindowStyle = 'Hidden'
    $start.WorkingDirectory = $runRoot
    $start.Environment['LOCALAPPDATA'] = (Split-Path $profile -Parent)
    $start.Environment['APPDATA'] = (Split-Path $profile -Parent)
    $app = [Diagnostics.Process]::Start($start)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        if ($app.HasExited) { throw "Mostty exited: $($app.ExitCode)" }
        try { $ready = (Control @{ action = 'list' }).terminals.Count -gt 0 } catch { $ready = $false }
        if (!$ready) { Start-Sleep -Milliseconds 100 }
    } while (!$ready -and $watch.Elapsed.TotalSeconds -lt 20)
    if (!$ready) { throw 'Mostty control did not become ready' }

    $text = "SSH Codex 中文 👩‍💻`nsecond line"
    Emit (Osc52 $text) 1
    Expect-Clipboard $text 'Fragmented OSC 52 BEL writes exact Unicode and multiline text to the local clipboard'
    Emit (Osc52 'ST terminator' '' "$([char]27)\")
    Expect-Clipboard 'ST terminator' 'OSC 52 with the default destination and ST terminator writes the local clipboard'
    $long = ('remote selection 中文 ' * 2000)
    Emit (Osc52 $long) 173
    Expect-Clipboard $long 'Large remote selections survive PTY drain boundaries without truncation'

    Emit "$([char]27)]52;c;%%%`a"
    Expect-Clipboard $long 'Invalid base64 preserves the previous local clipboard'
    foreach ($invalid in @([byte[]]@(255), [Text.Encoding]::UTF8.GetBytes("prefix`0suffix"))) {
        Emit ("$([char]27)]52;c;" + [Convert]::ToBase64String($invalid) + "`a")
        Expect-Clipboard $long 'Invalid UTF-8 and embedded NUL cannot replace the clipboard with truncated text'
    }
    Emit "$([char]27)]52;c;?`a"
    Expect-Clipboard $long 'Clipboard read queries do not modify the local clipboard'
    Emit (Osc52 'primary selection' 'p')
    Expect-Clipboard $long 'Unsupported primary selections do not overwrite the Windows clipboard'
    Emit (Osc52 '')
    Expect-Clipboard '' 'An empty OSC 52 write clears the local text clipboard'
} catch {
    $results.Add([pscustomobject]@{ rule = $_.Exception.Message; status = 'fail' })
    throw
} finally {
    if ($app) {
        if (!$app.HasExited) { $app.Kill(); $app.WaitForExit() }
        $app.Dispose()
    }
    if ($savedClipboard.GetFormats($false).Count -gt 0) {
        [Windows.Forms.Clipboard]::SetDataObject($savedClipboard, $true)
    } else { [Windows.Forms.Clipboard]::Clear() }
    $results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $runRoot 'results.json') -Encoding utf8
    Write-Host "$($results.Count) checks recorded; evidence: $runRoot"
}
