param(
    [string]$Executable = (Join-Path $PSScriptRoot '../zig-out/bin/Mostty.exe'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../tmp/d3d11-close-redraw'),
    [switch]$Probe
)
$ErrorActionPreference = 'Stop'

# A real ConPTY child: acknowledge input independently of the displayed pixels.
if ($Probe) {
    $esc = [char]27
    [Console]::Write("${esc}[48;2;0;0;0m${esc}[2J${esc}[Hready> ")
    while ($null -ne ($line = [Console]::ReadLine())) {
        if ($line -eq 'exit') { exit 0 }
        $parts = $line.Split(' ')
        $rgb = switch ($parts[0]) {
            'red' { '255;0;0' }
            'green' { '0;255;0' }
            'blue' { '0;0;255' }
            default { continue }
        }
        [Console]::Write("${esc}[48;2;${rgb}m${esc}[2J${esc}[Hready> ")
        [IO.File]::WriteAllText((Join-Path $OutputDirectory ($parts[1] + '.ack')), [string]$PID)
    }
    exit 0
}

Add-Type -AssemblyName System.Drawing
# Define only native entry points; the test and helper contain no C# source.
$assembly = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly(
    [Reflection.AssemblyName]::new('CloseRedrawNative'), [Reflection.Emit.AssemblyBuilderAccess]::Run)
$module = $assembly.DefineDynamicModule('Native')
$builder = $module.DefineType('CloseRedrawNative', [Reflection.TypeAttributes]'Public, Sealed, Abstract')
function Add-Native([string]$Name, [Type]$Return, [Type[]]$Parameters) {
    $method = $builder.DefinePInvokeMethod($Name, 'user32.dll',
        [Reflection.MethodAttributes]'Public, Static, PinvokeImpl', [Reflection.CallingConventions]::Standard,
        $Return, $Parameters, [Runtime.InteropServices.CallingConvention]::Winapi,
        [Runtime.InteropServices.CharSet]::Unicode)
    $method.SetImplementationFlags([Reflection.MethodImplAttributes]::PreserveSig)
}
Add-Native 'FindWindowExW' ([IntPtr]) @([IntPtr], [IntPtr], [string], [IntPtr])
Add-Native 'IsWindowVisible' ([bool]) @([IntPtr])
Add-Native 'GetWindowThreadProcessId' ([uint32]) @([IntPtr], [IntPtr])
Add-Native 'GetWindowRect' ([bool]) @([IntPtr], [IntPtr])
Add-Native 'GetClientRect' ([bool]) @([IntPtr], [IntPtr])
Add-Native 'SendMessageW' ([IntPtr]) @([IntPtr], [uint32], [UIntPtr], [IntPtr])
Add-Native 'SetWindowPos' ([bool]) @([IntPtr], [IntPtr], [int], [int], [int], [int], [uint32])
Add-Native 'ShowWindow' ([bool]) @([IntPtr], [int])
Add-Native 'SetForegroundWindow' ([bool]) @([IntPtr])
Add-Native 'SetThreadDpiAwarenessContext' ([IntPtr]) @([IntPtr])
$null = $builder.CreateType()

$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$Executable = [IO.Path]::GetFullPath($Executable)
$run = Join-Path $OutputDirectory ([Guid]::NewGuid().ToString('N'))
$profile = Join-Path $run 'profile/Mostty'
$null = New-Item -ItemType Directory -Force -Path $profile
$pwsh = (Get-Command pwsh).Source
@('renderer = d3d11', 'background-opacity = 1', 'background-blur = false', 'font-size = 14',
    ('launcher = probe | "{0}" -NoProfile -File "{1}" -Probe -OutputDirectory "{2}"' -f $pwsh, $PSCommandPath, $run)
) | Set-Content -LiteralPath (Join-Path $profile 'config') -Encoding utf8
$previousDpi = [CloseRedrawNative]::SetThreadDpiAwarenessContext([IntPtr](-4))
$results = [Collections.Generic.List[object]]::new()

function Get-TestWindow {
    $candidate = [IntPtr]::Zero
    $memory = [Runtime.InteropServices.Marshal]::AllocHGlobal(4)
    try {
        while (($candidate = [CloseRedrawNative]::FindWindowExW([IntPtr]::Zero, $candidate, 'MosttyWindow', [IntPtr]::Zero)) -ne [IntPtr]::Zero) {
            $null = [CloseRedrawNative]::GetWindowThreadProcessId($candidate, $memory)
            if ([Runtime.InteropServices.Marshal]::ReadInt32($memory) -eq $app.Id) { return $candidate }
        }
        return [IntPtr]::Zero
    } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($memory) }
}

function Get-Panes {
    $child = [IntPtr]::Zero
    while (($child = [CloseRedrawNative]::FindWindowExW($script:window, $child, 'MosttyPane', [IntPtr]::Zero)) -ne [IntPtr]::Zero) {
        if ([CloseRedrawNative]::IsWindowVisible($child)) { $child }
    }
}
function Wait-Panes([int]$Count, [IntPtr]$Absent = [IntPtr]::Zero) {
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    do {
        $panes = @(Get-Panes)
        if ($panes.Count -eq $Count -and $Absent -notin $panes) { Start-Sleep -Milliseconds 250; return $panes }
        if ($app.HasExited) { throw "Test application exited: $($app.ExitCode)" }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Expected $Count visible panes; got $($panes.Count)"
}
function Get-Box([IntPtr]$Handle, [switch]$Client) {
    $memory = [Runtime.InteropServices.Marshal]::AllocHGlobal(16)
    try {
        $ok = if ($Client) { [CloseRedrawNative]::GetClientRect($Handle, $memory) } else {
            [CloseRedrawNative]::GetWindowRect($Handle, $memory)
        }
        if (-not $ok) { throw 'Cannot read window rectangle' }
        $values = 0..3 | ForEach-Object { [Runtime.InteropServices.Marshal]::ReadInt32($memory, $_ * 4) }
        return [pscustomobject]@{ X=$values[0]; Y=$values[1]; W=$values[2]-$values[0]; H=$values[3]-$values[1] }
    } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($memory) }
}
function Send-Line([IntPtr]$Pane, [string]$Text) {
    foreach ($ch in ($Text + "`r").ToCharArray()) {
        $null = [CloseRedrawNative]::SendMessageW($Pane, 0x102, [UIntPtr][uint16]$ch, [IntPtr]::Zero)
    }
}
function Assert-Color([IntPtr]$Pane, [string]$Color, [string]$Label) {
    $tag = [Guid]::NewGuid().ToString('N')
    Send-Line $Pane "$Color $tag"
    $ack = Join-Path $run "$tag.ack"
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $ack)) {
        if ([DateTime]::UtcNow -gt $deadline) { throw "Input not received: $Label" }
        Start-Sleep -Milliseconds 100
    }
    $expected = [Drawing.Color]::FromName(@{red='Red';green='Lime';blue='Blue'}[$Color])
    $box = Get-Box $Pane
    $bitmap = [Drawing.Bitmap]::new($box.W, $box.H)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $passed = $false
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(3)
        do {
            Start-Sleep -Milliseconds 100
            $graphics.CopyFromScreen($box.X, $box.Y, 0, 0, $bitmap.Size)
            $passed = $true
            foreach ($x in @(0.2, 0.5, 0.8)) {
                foreach ($y in @(0.25, 0.5, 0.75)) {
                    $actual = $bitmap.GetPixel([int]($box.W*$x), [int]($box.H*$y))
                    if ([Math]::Abs([int]$actual.R-$expected.R) -gt 12 -or
                        [Math]::Abs([int]$actual.G-$expected.G) -gt 12 -or
                        [Math]::Abs([int]$actual.B-$expected.B) -gt 12) { $passed = $false }
                }
            }
        } while (-not $passed -and [DateTime]::UtcNow -lt $deadline)
        $bitmap.Save((Join-Path $run "$Label.png"))
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
    $results.Add([pscustomobject]@{case=$Label;input_received=$true;pixels_match=$passed})
    Write-Output "$Label : input received, pixels match = $passed"
}
function New-Tab {
    $box = Get-Box $window -Client
    # The plus button occupies the last four character columns of the tab band.
    $line = @(Select-String -LiteralPath (Join-Path $run 'tmp/mostty-diag.log') -Pattern 'cell=(\d+)x(\d+)')[-1]
    $cellWidth = [int]$line.Matches[0].Groups[1].Value
    $x = ([Math]::Floor($box.W/$cellWidth)-2)*$cellWidth
    $null = [CloseRedrawNative]::SendMessageW($window, 0x201, [UIntPtr]1, [IntPtr](8*65536+$x))
    $null = [CloseRedrawNative]::SendMessageW($window, 0x202, [UIntPtr]::Zero, [IntPtr](8*65536+$x))
}
function Split-Pane([int]$Command) {
    $null = [CloseRedrawNative]::SendMessageW($window, 0x112, [UIntPtr]$Command, [IntPtr]::Zero)
}

$start = [Diagnostics.ProcessStartInfo]::new($Executable)
$start.UseShellExecute = $false
$start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
$start.WorkingDirectory = $run
$start.Environment['LOCALAPPDATA'] = Split-Path $profile -Parent
$start.Environment['MOSTTY_DIAG'] = '1'
$app = [Diagnostics.Process]::Start($start)
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $app.Refresh()
        $script:window = Get-TestWindow
        if ($app.HasExited) { throw 'Application failed to start' }
        Start-Sleep -Milliseconds 100
    } while ($window -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
    if ($window -eq [IntPtr]::Zero) { throw 'No test window' }
    $null = [CloseRedrawNative]::ShowWindow($window, 9)
    $null = [CloseRedrawNative]::SetWindowPos($window, [IntPtr](-1), 60, 60, 960, 640, 0x40)
    $null = [CloseRedrawNative]::SetForegroundWindow($window)
    $first = @(Wait-Panes 1)[0]
    Assert-Color $first red 'initial'
    New-Tab
    $second = @(Wait-Panes 1)[0]
    if ($second -eq $first) { throw 'Second tab was not created' }
    Assert-Color $second green 'second-tab'
    New-Tab
    $third = @(Wait-Panes 1)[0]
    if ($third -eq $second) { throw 'Third tab was not created' }
    Assert-Color $third blue 'third-tab'
    Send-Line $third exit
    $survivor = @(Wait-Panes 1 $third)[0]
    if ($survivor -ne $second) { throw 'Last tab did not return to its neighbor' }
    Assert-Color $survivor red 'last-tab-exit'
    Send-Line $survivor exit
    $survivor = @(Wait-Panes 1 $second)[0]
    if ($survivor -ne $first) { throw 'Original pane HWND was replaced' }
    Assert-Color $survivor green 'second-tab-exit'

    Split-Pane 0x30
    $panes = @(Wait-Panes 2)
    $active = @($panes | Where-Object { $_ -ne $first })[0]
    Assert-Color $active blue 'split-active'
    Send-Line $active exit
    $survivor = @(Wait-Panes 1)[0]
    Assert-Color $survivor red 'active-pane-exit'

    Split-Pane 0x30
    $panes = @(Wait-Panes 2)
    $active = @($panes | Where-Object { $_ -ne $first })[0]
    Assert-Color $active green 'split-before-inactive-exit'
    Send-Line $first exit
    $survivor = @(Wait-Panes 1)[0]
    if ($survivor -ne $active) { throw 'Inactive exit replaced the active HWND' }
    Assert-Color $survivor blue 'inactive-pane-exit'

    # Three panes: close the new active leaf; the unrelated pane keeps its size
    # and retained back buffer, but shares the context cleared by the closed leaf.
    Split-Pane 0x30
    $two = @(Wait-Panes 2)
    $branch = @($two | Where-Object { $_ -ne $survivor })[0]
    Split-Pane 0x40
    $three = @(Wait-Panes 3)
    $leaf = @($three | Where-Object { $_ -notin $two })[0]
    Assert-Color $leaf red 'three-pane-leaf'
    Send-Line $leaf exit
    $null = Wait-Panes 2
    Assert-Color $survivor green 'three-pane-unchanged-sibling'
    Assert-Color $branch blue 'three-pane-expanded-sibling'

    # Closing a whole split tab destroys multiple surfaces in succession.
    New-Tab
    $neighbor = @(Wait-Panes 1)[0]
    Assert-Color $neighbor red 'neighbor-tab'
    $null = [CloseRedrawNative]::SendMessageW($window, 0x201, [UIntPtr]1, [IntPtr](8*65536+20))
    $null = Wait-Panes 2
    # This tab was originally created with first pane ID 1 (its original pane exited).
    $null = [CloseRedrawNative]::SendMessageW($window, 0x8001, [UIntPtr]1, [IntPtr]::Zero)
    $null = Wait-Panes 1
    Assert-Color $neighbor blue 'whole-split-tab-close'
    Send-Line $neighbor exit
    if (-not $app.WaitForExit(10000) -or $app.ExitCode -ne 0) { throw 'Final pane exit failed' }
    $failed = @($results | Where-Object { -not $_.pixels_match })
    if ($failed.Count -gt 0) { throw "Input arrived but redraw failed: $($failed.case -join ', ')" }
} finally {
    if (-not $app.HasExited) { $app.Kill($true); $app.WaitForExit() }
    [ordered]@{executable=$Executable;sha256=(Get-FileHash -LiteralPath $Executable).Hash;cases=$results.ToArray()} |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $run 'result.json') -Encoding utf8
    $null = [CloseRedrawNative]::SetThreadDpiAwarenessContext($previousDpi)
    Write-Output "Evidence: $run"
}
