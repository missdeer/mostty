param([string]$Executable = (Join-Path (Split-Path $PSScriptRoot -Parent) 'zig-out/bin/Mostty.exe'), [switch]$ConfirmationOnly)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$runRoot = Join-Path $root ('tmp/terminal-integration-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $runRoot
$client = Join-Path $root 'resources/mostty/Invoke-Mostty.ps1'
$results = [Collections.Generic.List[object]]::new()
$apps = [Collections.Generic.List[Diagnostics.Process]]::new()
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
function Assert($Condition, [string]$Rule) {
    if (!$Condition) { throw $Rule }
    $results.Add([pscustomobject]@{ rule = $Rule; status = 'pass' })
}
function Control([hashtable]$Request, [Diagnostics.Process]$App = $script:app) {
    & $client -Executable $Executable -TargetProcess $App.Id -Request $Request
}
function Expect-Error([hashtable]$Request, [string]$ErrorName) {
    try { $null = Control $Request } catch {
        Assert ($_.Exception.Message.Contains($ErrorName)) "Control rejects $ErrorName"
        return
    }
    throw "Expected $ErrorName"
}
function Check-PowerShell([string]$Shell, [string]$Directory) {
    $start = [Diagnostics.ProcessStartInfo]::new($Shell)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WindowStyle = 'Hidden'
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile','-File',(Join-Path $PSScriptRoot 'powershell-integration-probe.ps1'),'-Executable',$Executable,'-TargetProcess',[string]$app.Id,'-ExpectedDirectory',$Directory)) {
        $start.ArgumentList.Add($argument)
    }
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $output = $stdout.GetAwaiter().GetResult()
        $errors = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "PowerShell regression probe failed: $output $errors" }
        Assert ($output.Contains('PowerShell hook and control probes passed')) "StrictMode, prompt status and Unicode control work in $Shell"
    } finally { $process.Dispose() }
}
function Wait-Terminal([string]$Id, [string]$Directory, [bool]$Prompt = $true) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $terminal = (Control @{ action = 'get'; id = $Id }).terminal
        if ($terminal.directory -and $terminal.directory.Replace('/','\').TrimEnd('\') -eq $Directory.Replace('/','\').TrimEnd('\') -and (!$Prompt -or $terminal.at_prompt)) { return $terminal }
        Start-Sleep -Milliseconds 100
    } while ($watch.Elapsed.TotalSeconds -lt 20)
    throw "Terminal did not report directory/prompt: $($terminal | ConvertTo-Json -Compress)"
}
function Launch([string]$Name, [string]$Command, [bool]$Integration = $true) {
    $folder = Join-Path $runRoot $Name
    $profile = Join-Path $folder 'profile/Mostty'
    $null = New-Item -ItemType Directory -Force -Path $profile
    $enabled = $Integration.ToString().ToLowerInvariant()
    $confirmation = if ($Name -eq 'confirmation') { 'true' } else { 'false' }
    @('renderer = d3d11', "confirm-close-surface = $confirmation", "shell-integration = $enabled", "launcher = test | $Command") |
        Set-Content -LiteralPath (Join-Path $profile 'config') -Encoding utf8
    $start = [Diagnostics.ProcessStartInfo]::new($Executable)
    $start.UseShellExecute = $false
    $start.WorkingDirectory = $folder
    $start.WindowStyle = 'Hidden'
    $start.Environment['LOCALAPPDATA'] = (Split-Path $profile -Parent)
    $start.Environment['APPDATA'] = (Split-Path $profile -Parent)
    $start.Environment['HISTFILE'] = Join-Path $folder 'bash-history'
    $start.Environment['MOSTTY_DIAG'] = '1'
    $process = [Diagnostics.Process]::Start($start)
    $apps.Add($process)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        if ($process.HasExited) { throw "Mostty exited: $($process.ExitCode) ($folder)" }
        try { $list = Control @{action = 'list'} $process; if ($list.terminals.Count -gt 0) { return $process } } catch { }
        Start-Sleep -Milliseconds 100
    } while ($watch.Elapsed.TotalSeconds -lt 20)
    throw 'Mostty window did not become ready'
}
try {
    if (!$ConfirmationOnly) {
        $app = Launch 'powershell' ('"' + $pwsh + '" -NoLogo -NoProfile')
        $first = (Control @{ action = 'list' }).terminals[0]
        $startDirectory = Join-Path $runRoot 'powershell'
        $null = Wait-Terminal $first.id $startDirectory
        Assert $true 'PowerShell automatically reports the initial directory and prompt'
        $null = Control @{ action = 'input'; id = $first.id; text = "Start-Sleep -Seconds 2`r" }
        Start-Sleep -Milliseconds 300
        Assert (!(Control @{ action = 'get'; id = $first.id }).terminal.at_prompt) 'PowerShell marks command execution separately from its prompt'
        $null = Wait-Terminal $first.id $startDirectory
        $directory = Join-Path $runRoot "space ' percent% # 中文"
        $null = New-Item -ItemType Directory -Path $directory
        $escaped = $directory.Replace("'", "''")
        $null = Control @{ action = 'input'; id = $first.id; text = "Set-Location -LiteralPath '$escaped'`r" }
        $null = Wait-Terminal $first.id $directory
        Assert $true 'OSC 7 decodes spaces, quotes, percent, hash and Unicode paths'
        Check-PowerShell $pwsh $directory
        Check-PowerShell (Get-Command powershell -ErrorAction Stop).Source $directory
        $new = (Control @{ action = 'new_tab' }).terminal
        $null = Wait-Terminal $new.id $directory
        Assert ($new.id -ne $first.id) 'New tabs inherit the active shell directory and receive distinct stable IDs'
        $split = (Control @{ action = 'split'; id = $first.id; direction = 'down' }).terminal
        $null = Wait-Terminal $split.id $directory
        Assert $true 'Splitting a non-active terminal focuses it and inherits its directory'
        $null = Control @{ action = 'focus'; id = $new.id }
        Assert ((Control @{ action = 'get'; id = $new.id }).terminal.active) 'Focus resolves the requested tab and pane'
        $explicit = (Control @{ action = 'new_tab'; directory = $startDirectory }).terminal
        $null = Wait-Terminal $explicit.id $startDirectory
        Assert $true 'An explicit launcher directory takes precedence over inheritance'
        $marker = Join-Path $runRoot 'literal.txt'
        $literal = "[IO.File]::WriteAllText('$($marker.Replace("'","''"))','literal-input')"
        $null = Control @{ action = 'input'; id = $first.id; text = $literal }
        Start-Sleep -Milliseconds 300
        Assert (!(Test-Path -LiteralPath $marker)) 'Automation input remains literal until the caller supplies Enter'
        $null = Control @{ action = 'input'; id = $first.id; text = "`r" }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while (!(Test-Path -LiteralPath $marker) -and $watch.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 100 }
        Assert ((Get-Content -LiteralPath $marker -Raw) -eq 'literal-input') 'Input reaches the requested hidden pane without truncation'
        Expect-Error @{ action = 'get'; id = '0:0:1' } 'InvalidTerminal'
        Expect-Error @{ action = 'new_tab'; directory = 'Z:\mostty-missing-directory' } 'InvalidDirectory'
        Expect-Error @{ action = 'new_tab'; command = 'Z:\mostty-missing-shell.exe' } 'LaunchFailed'
        Expect-Error @{ action = 'split'; direction = 'diagonal' } 'InvalidRequest'
        $null = Control @{ action = 'close'; id = $split.id }
        Start-Sleep -Milliseconds 200
        Expect-Error @{ action = 'get'; id = $split.id } 'InvalidTerminal'
        Assert ((Control @{ action = 'list' }).terminals.Count -eq 3) 'Closing a pane preserves the other live sessions'
        foreach ($report in @('file://remote.invalid/C:/Windows', 'file://localhost/home/user', 'file://localhost/C:/bad%00path', 'file://localhost/C:/bad%xy')) {
            $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$([char]27)]7;$report$([char]7)"))
            $null = Control @{ action = 'input'; id = $first.id; text = "[Console]::Write([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$payload'))); Start-Sleep -Seconds 2`r" }
            Start-Sleep -Milliseconds 500
            Assert ($null -eq (Control @{ action = 'get'; id = $first.id }).terminal.directory) "Reject unsafe directory report $report"
            Start-Sleep -Seconds 2
        }
        $app = Launch 'cmd' 'C:\Windows\System32\cmd.exe'
        $cmdPane = (Control @{ action = 'list' }).terminals[0]
        $null = Wait-Terminal $cmdPane.id (Join-Path $runRoot 'cmd') $false
        $null = Control @{ action = 'input'; text = "cd /d `"$directory`"`r" }
        $null = Wait-Terminal $cmdPane.id $directory $false
        $cmdNew = (Control @{ action = 'new_tab' }).terminal
        $null = Wait-Terminal $cmdNew.id $directory $false
        Assert $true 'cmd reports raw Windows paths and new tabs inherit the directory'
        $bash = (Get-Command bash -ErrorAction Stop).Source
        $app = Launch 'bash' ('"' + $bash + '" --noprofile --norc')
        $bashPane = (Control @{ action = 'list' }).terminals[0]
        $null = Wait-Terminal $bashPane.id (Join-Path $runRoot 'bash')
        $bashNew = (Control @{ action = 'new_tab' }).terminal
        $null = Wait-Terminal $bashNew.id (Join-Path $runRoot 'bash')
        Assert $true 'Git Bash integration reports prompts and MSYS drive directories'
        $drive = $root.Substring(0,1).ToLowerInvariant()
        $null = Control @{action='input';id=$bashNew.id;text="cd /$drive`r"}
        $null = Wait-Terminal $bashNew.id ($drive + ':\')
        $drivePane = (Control @{action='new_tab'}).terminal
        $null = Wait-Terminal $drivePane.id ($drive + ':\')
        Assert $true 'Git Bash drive roots are inherited as absolute Windows drive roots'
        $pathOutput = Join-Path $runRoot 'bash-path.txt'
        $encodedPath = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pathOutput.Replace('\','/')))
        $pathCommand = 'cd "$(cygpath -u "$WINDIR")"; output=$(printf %s ' + "'$encodedPath'" + ' | base64 -d); PATH="/usr/bin:/bin:$MOSTTY_BIN_DIR" command -v Mostty > "$output"'
        $null = Control @{action='input';id=$bashNew.id;text=($pathCommand + "`r")}
        $null = Wait-Terminal $bashNew.id $env:WINDIR
        Assert ((Get-Content -LiteralPath $pathOutput -Raw).Trim().StartsWith('/')) 'Git Bash locates Mostty through an absolute POSIX PATH entry after changing drives'
        $app = Launch 'bash-login' ('"' + $bash + '" --noprofile --norc -l -i')
        $loginPane = (Control @{action='list'}).terminals[0]
        $null = Wait-Terminal $loginPane.id (Join-Path $runRoot 'bash-login')
        Assert $true 'Bash short login flags remain valid after automatic injection adds its long option'
        $legacy = (Get-Command powershell -ErrorAction Stop).Source
        $app = Launch 'windows-powershell' ('"' + $legacy + '" -NoLogo -NoProfile')
        $legacyPane = (Control @{ action = 'list' }).terminals[0]
        $null = Wait-Terminal $legacyPane.id (Join-Path $runRoot 'windows-powershell')
        Assert $true 'Windows PowerShell 5.1 receives automatic shell integration'
        $app = Launch 'disabled' ('"' + $pwsh + '" -NoProfile') $false
        Start-Sleep -Seconds 2
        $disabled = (Control @{ action = 'list' }).terminals[0]
        Assert (!$disabled.directory -and !$disabled.at_prompt) 'shell-integration=false disables automatic hooks'
        $app = Launch 'command' ('"' + $pwsh + '" -NoProfile -NoExit -Command "Write-Output noninteractive"')
        Start-Sleep -Seconds 2
        $command = (Control @{ action = 'list' }).terminals[0]
        Assert (!$command.directory -and !$command.at_prompt) 'Explicit PowerShell commands are preserved without injecting hooks'
    }
    $app = Launch 'confirmation' ('"' + $pwsh + '" -NoProfile')
    $confirmPane = (Control @{ action = 'list' }).terminals[0]
    $null = Wait-Terminal $confirmPane.id (Join-Path $runRoot 'confirmation')
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $job = Start-Job -ArgumentList $client,$Executable,$app.Id,$confirmPane.id -ScriptBlock {
        param($ClientPath,$ExePath,$Target,$PaneId)
        try { & $ClientPath -Executable $ExePath -TargetProcess $Target -Request @{action='close';id=$PaneId} } catch { $_.Exception.Message }
    }
    try {
        $condition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty, $app.Id)
        $no = $null
        $watch = [Diagnostics.Stopwatch]::StartNew()
        do {
            $windows = [Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children, $condition)
            foreach ($window in $windows) {
                $buttonId = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, '7')
                $no = $window.FindFirst([Windows.Automation.TreeScope]::Descendants, $buttonId)
                if ($no) {
                    $pattern = $null
                    if ($no.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) { break }
                    $no = $null
                }
            }
            if (!$no) { Start-Sleep -Milliseconds 100 }
        } while (!$no -and $watch.Elapsed.TotalSeconds -lt 15)
        if (!$no) { throw 'Close confirmation did not expose its No button' }
        $controls = foreach ($window in $windows) {
            foreach ($child in $window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)) {
                [pscustomobject]@{Name=$child.Current.Name;Id=$child.Current.AutomationId;Type=$child.Current.ControlType.ProgrammaticName;Patterns=($child.GetSupportedPatterns().ProgrammaticName -join ',')}
            }
        }
        $controls | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $runRoot 'close-controls.json') -Encoding utf8
        ([Windows.Automation.InvokePattern]$pattern).Invoke()
        $null = Wait-Job $job -Timeout 10
        $reply = Receive-Job $job | Out-String
        [IO.File]::WriteAllText((Join-Path $runRoot 'close-response.txt'), $reply)
        if (!$reply.Contains('CloseCancelled')) { throw "Expected CloseCancelled; received: $reply" }
        Assert $true 'Cancelling native close confirmation returns an automation error'
        Assert ((Control @{action='get';id=$confirmPane.id}).terminal.id -eq $confirmPane.id) 'Cancelling close preserves the same live session'
    } finally {
        Stop-Job $job
        Remove-Job $job
    }
} catch {
    $results.Add([pscustomobject]@{rule=$_.Exception.Message;status='fail'})
    throw
} finally {
    foreach ($process in $apps) {
        if (!$process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
    $results | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $runRoot 'results.json') -Encoding utf8
    Write-Host "$(@($results | Where-Object status -eq 'pass').Count) checks passed, $(@($results | Where-Object status -eq 'fail').Count) failed; evidence: $runRoot"
}
