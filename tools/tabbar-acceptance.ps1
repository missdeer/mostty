#Requires -Version 7
# Process.Kill(bool) is .NET Core only, so Windows PowerShell 5.1 fails at
# teardown after the whole run has already happened. Fail up front instead.
param(
    [ValidateSet('d3d11','d3d12','opengl','pure-opengl','vulkan','native-vulkan')]
    [string]$Renderer = 'd3d11',
    [string]$Executable = 'zig-out/bin/Mostty.exe'
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$outputRoot = Join-Path $projectRoot "tmp/tabbar-acceptance/$Renderer"
$profile = Join-Path $outputRoot 'profile'
$configPath = Join-Path $profile 'Mostty/config'
New-Item -ItemType Directory -Force -Path (Split-Path $configPath) | Out-Null
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Declare native entry points with PowerShell reflection, without embedded C#.
$assembly = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly([Reflection.AssemblyName]::new('TabbarAcceptance'), [Reflection.Emit.AssemblyBuilderAccess]::Run)
$module = $assembly.DefineDynamicModule('Native')
$builder = $module.DefineType('TabbarNative', 'Public, Sealed, Abstract')
function Add-Native([string]$Name, [type]$Return, [type[]]$Parameters, [string]$Dll = 'user32.dll') {
    $method = $builder.DefinePInvokeMethod($Name, $Dll, 'Public, Static, PinvokeImpl', [Reflection.CallingConventions]::Standard, $Return, $Parameters, [Runtime.InteropServices.CallingConvention]::Winapi, [Runtime.InteropServices.CharSet]::Unicode)
    $method.SetImplementationFlags($method.GetMethodImplementationFlags() -bor [Reflection.MethodImplAttributes]::PreserveSig)
}
Add-Native 'GetClientRect' ([bool]) @([IntPtr],[int[]])
Add-Native 'ClientToScreen' ([bool]) @([IntPtr],[int[]])
Add-Native 'GetWindowRect' ([bool]) @([IntPtr],[int[]])
Add-Native 'FindWindowExW' ([IntPtr]) @([IntPtr],[IntPtr],[string],[string])
Add-Native 'GetWindowThreadProcessId' ([uint32]) @([IntPtr],[int[]])
Add-Native 'MoveWindow' ([bool]) @([IntPtr],[int],[int],[int],[int],[bool])
Add-Native 'ShowWindow' ([bool]) @([IntPtr],[int])
Add-Native 'SetWindowPos' ([bool]) @([IntPtr],[IntPtr],[int],[int],[int],[int],[uint32])
Add-Native 'IsWindowVisible' ([bool]) @([IntPtr])
Add-Native 'IsIconic' ([bool]) @([IntPtr])
Add-Native 'SetForegroundWindow' ([bool]) @([IntPtr])
Add-Native 'PostMessageW' ([bool]) @([IntPtr],[uint32],[UIntPtr],[IntPtr])
Add-Native 'SetThreadDpiAwarenessContext' ([IntPtr]) @([IntPtr])
Add-Native 'GetDC' ([IntPtr]) @([IntPtr])
Add-Native 'ReleaseDC' ([int]) @([IntPtr],[IntPtr])
Add-Native 'BitBlt' ([bool]) @([IntPtr],[int],[int],[int],[int],[IntPtr],[int],[int],[uint32]) 'gdi32.dll'
$native = $builder.CreateType()
$oldDpi = $native::SetThreadDpiAwarenessContext([IntPtr](-4))

function Wait-Ui([int]$Milliseconds) {
    $until = [DateTime]::UtcNow.AddMilliseconds($Milliseconds)
    do { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 25 } while ([DateTime]::UtcNow -lt $until)
}
function Write-Config([string]$Background, [string]$Foreground, [double]$Opacity) {
    # Redirected WGL needs blur-behind enabled for per-pixel desktop alpha.
    $blur = if ($Renderer -eq 'pure-opengl') { 'true' } else { 'false' }
    @("renderer = $Renderer", 'font-size = 14', "background = #$Background", "foreground = #$Foreground", "background-opacity = $Opacity", "background-blur = $blur", 'confirm-close-surface = false') | Set-Content -LiteralPath $configPath -Encoding utf8
}
function Copy-Screen([Drawing.Bitmap]$Bitmap, [int]$X, [int]$Y) {
    $graphics = [Drawing.Graphics]::FromImage($Bitmap)
    $destination = $graphics.GetHdc()
    $source = $native::GetDC([IntPtr]::Zero)
    try {
        if (-not $native::BitBlt($destination, 0, 0, $Bitmap.Width, $Bitmap.Height, $source, $X, $Y, 0x40cc0020)) { throw 'Screen capture failed' }
    } finally {
        $null = $native::ReleaseDC([IntPtr]::Zero, $source)
        $graphics.ReleaseHdc($destination)
        $graphics.Dispose()
    }
}
function Get-Capture {
    # Do not move/invalidate windows here: that could hide a missing repaint
    # after an idle theme or opacity reload.
    foreach ($existingWindow in $minimizedWindows) {
        if (-not $native::IsIconic($existingWindow)) { $null = $native::ShowWindow($existingWindow, 6) }
    }
    Wait-Ui 100
    $rect = [int[]]::new(4)
    $origin = [int[]]::new(2)
    if (-not $native::GetClientRect($script:window, $rect) -or -not $native::ClientToScreen($script:window, $origin)) { throw 'Cannot read client geometry' }
    # Most cases run translucent, so anything that slips between the window and
    # the solid backdrop gets measured as terminal color. Probe the backdrop just
    # outside the window: if it is occluded, every delta below is meaningless —
    # including one that happens to look like a pass.
    # Sample the backdrop's top-left, not the strip beside the window: DWM's
    # drop shadow reaches ~20px out and reads as an occlusion.
    $probe = [Drawing.Bitmap]::new(1, 1)
    try {
        Copy-Screen $probe ($backdrop.Left + 10) ($backdrop.Top + 10)
        if ((Distance $probe.GetPixel(0, 0) $backdrop.BackColor) -gt 2) {
            throw 'Backdrop is occluded at capture time; run one renderer at a time with nothing else on screen'
        }
    } finally { $probe.Dispose() }
    $bitmap = [Drawing.Bitmap]::new($rect[2], $rect[3])
    Copy-Screen $bitmap $origin[0] $origin[1]
    return ,$bitmap
}
function Rgb([Drawing.Color]$Color) { return @([int]$Color.R, [int]$Color.G, [int]$Color.B) }
function Distance([Drawing.Color]$A, [Drawing.Color]$B) {
    return [Math]::Max([Math]::Abs([int]$A.R-$B.R), [Math]::Max([Math]::Abs([int]$A.G-$B.G), [Math]::Abs([int]$A.B-$B.B)))
}

$backdrop = [Windows.Forms.Form]::new()
$backdrop.FormBorderStyle = 'None'
$backdrop.StartPosition = 'Manual'
$backdrop.Bounds = [Drawing.Rectangle]::new(20, 20, 1150, 850)
$backdrop.BackColor = [Drawing.Color]::FromArgb(50, 80, 110)
$backdrop.TopMost = $true
$oldLocal = $env:LOCALAPPDATA
$app = $null
$minimizedWindows = [Collections.Generic.List[IntPtr]]::new()
$results = [Collections.Generic.List[object]]::new()
try {
    $existingWindow = [IntPtr]::Zero
    do {
        $existingWindow = $native::FindWindowExW([IntPtr]::Zero, $existingWindow, 'MosttyWindow', [NullString]::Value)
        if ($existingWindow -ne [IntPtr]::Zero -and $native::IsWindowVisible($existingWindow) -and -not $native::IsIconic($existingWindow)) {
            $minimizedWindows.Add($existingWindow)
            $null = $native::ShowWindow($existingWindow, 6)
        }
    } while ($existingWindow -ne [IntPtr]::Zero)
    $backdrop.Show()
    $null = $native::SetWindowPos($backdrop.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x53)
    if (-not $native::IsWindowVisible($backdrop.Handle)) { throw 'Solid backdrop is not visible' }
    $backdrop.Refresh()
    Wait-Ui 200
    Write-Config '202830' 'e8e0d8' 1
    $env:LOCALAPPDATA = $profile
    $app = Start-Process -FilePath (Join-Path $projectRoot $Executable) -WorkingDirectory $outputRoot -WindowStyle Hidden -PassThru
    $env:LOCALAPPDATA = $oldLocal
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        Wait-Ui 100
        $app.Refresh()
        if ($app.HasExited) { throw "Mostty exited with $($app.ExitCode)" }
        $script:window = $app.MainWindowHandle
        if ($script:window -eq [IntPtr]::Zero) {
            $candidate = [IntPtr]::Zero
            do {
                $candidate = $native::FindWindowExW([IntPtr]::Zero, $candidate, 'MosttyWindow', [NullString]::Value)
                $owner = [int[]]::new(1)
                $null = $native::GetWindowThreadProcessId($candidate, $owner)
                if ($owner[0] -eq $app.Id) { $script:window = $candidate; break }
            } while ($candidate -ne [IntPtr]::Zero)
        }
    } while ($script:window -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
    if ($script:window -eq [IntPtr]::Zero) { throw 'No Mostty window' }
    $null = $native::ShowWindow($script:window, 9)
    $null = $native::MoveWindow($script:window, 100, 100, 960, 650, $true)
    $null = $native::SetWindowPos($script:window, [IntPtr](-1), 100, 100, 960, 650, 0x40)
    $null = $native::SetForegroundWindow($script:window)
    if (-not $native::IsWindowVisible($script:window)) { throw 'Test window is not visible' }
    Wait-Ui 500
    [Windows.Forms.Cursor]::Position = [Drawing.Point]::new(25,25)
    $pane = $native::FindWindowExW($script:window, [IntPtr]::Zero, 'MosttyPane', [NullString]::Value)
    if ($pane -eq [IntPtr]::Zero) { throw 'No pane window' }
    $paneRect = [int[]]::new(4)
    $origin = [int[]]::new(2)
    $null = $native::GetWindowRect($pane, $paneRect)
    $null = $native::ClientToScreen($script:window, $origin)
    $bandHeight = $paneRect[1] - $origin[1]
    if ($bandHeight -le 0) { throw 'Tab band has no height' }
    $client = [int[]]::new(4)
    $null = $native::GetClientRect($script:window, $client)
    $buttonPoint = [IntPtr](($client[2]-20) -bor ([int]($bandHeight/2) -shl 16))
    $null = $native::PostMessageW($script:window, 0x201, [UIntPtr]1, $buttonPoint)
    $null = $native::PostMessageW($script:window, 0x202, [UIntPtr]::Zero, $buttonPoint)
    Wait-Ui 500
    if ($native::FindWindowExW($script:window, $pane, 'MosttyPane', [NullString]::Value) -eq [IntPtr]::Zero -and $native::FindWindowExW($script:window, [IntPtr]::Zero, 'MosttyPane', [NullString]::Value) -eq $pane) { throw 'New-tab click did not create a second pane' }
    $cases = @(
        @{Name='dark-opaque'; Background='202830'; Foreground='e8e0d8'; Opacity=1},
        @{Name='light-opaque'; Background='e8e0d8'; Foreground='202830'; Opacity=1},
        @{Name='dark-translucent'; Background='202830'; Foreground='e8e0d8'; Opacity=0.5},
        @{Name='light-translucent'; Background='e8e0d8'; Foreground='202830'; Opacity=0.5},
        @{Name='transparent'; Background='e8e0d8'; Foreground='202830'; Opacity=0},
        @{Name='dark-restored'; Background='202830'; Foreground='e8e0d8'; Opacity=1},
        @{Name='foreground-only'; Background='202830'; Foreground='70e090'; Opacity=1}
    )
    $previousBand = $null
    foreach ($case in $cases) {
        Write-Config $case.Background $case.Foreground $case.Opacity
        Wait-Ui 1200
        $bitmap = Get-Capture
        try {
            $bitmap.Save((Join-Path $outputRoot "$($case.Name).png"))
            $x = $bitmap.Width - 80
            $band = $bitmap.GetPixel($x, $bandHeight-1)
            $grid = $bitmap.GetPixel($x, $bandHeight+50)
            $delta = Distance $band $grid
            # Blank regions and the full transition must share a continuous surface.
            $seamDelta = 0
            for ($y=$bandHeight-3; $y -le $bandHeight+3; $y++) {
                $seamDelta = [Math]::Max($seamDelta, (Distance ($bitmap.GetPixel($x,$y)) $grid))
            }
            $entry = [ordered]@{case=$case.Name; band=(Rgb $band); grid=(Rgb $grid); delta=$delta; seam_delta=$seamDelta; band_height=$bandHeight}
            $results.Add($entry)
            if ($delta -gt 2 -or $seamDelta -gt 2) { throw "Band/grid seam in $($case.Name): $($entry | ConvertTo-Json -Compress)" }
            # Existing backend gamma conversions can shift dark colors slightly;
            # band/grid equality above stays strict regardless of that shift.
            if ($case.Opacity -eq 1 -and (Distance $band ([Drawing.ColorTranslator]::FromHtml("#$($case.Background)"))) -gt 6) { throw 'Theme reload did not apply the requested background' }
            if ($case.Opacity -eq 0 -and (Distance $band $backdrop.BackColor) -gt 2) { throw 'Opacity-only reload did not reveal the solid backdrop' }
            if ($case.Name -eq 'foreground-only') {
                $different = 0
                for ($y=0; $y -lt $bandHeight; $y++) {
                    for ($xx=0; $xx -lt [Math]::Min(600,$bitmap.Width); $xx++) {
                        if ((Distance ($bitmap.GetPixel($xx,$y)) ($previousBand.GetPixel($xx,$y))) -gt 10) { $different++ }
                    }
                }
                if ($different -lt 100) { throw 'Foreground-only reload did not repaint titles and selected pill' }
                $entry.foreground_changed_pixels = $different
            }
            if ($previousBand) { $previousBand.Dispose() }
            $previousBand = $bitmap.Clone()
            $entry | ConvertTo-Json -Compress | Write-Output
        } finally { $bitmap.Dispose() }
    }
} finally {
    $results | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $outputRoot 'results.json') -Encoding utf8
    if ($previousBand) { $previousBand.Dispose() }
    if ($app -and -not $app.HasExited) {
        $null = $native::PostMessageW($script:window, 0x10, [UIntPtr]::Zero, [IntPtr]::Zero)
        if (-not $app.WaitForExit(5000)) { $app.Kill($true) }
    }
    $env:LOCALAPPDATA = $oldLocal
    $backdrop.Close()
    $backdrop.Dispose()
    foreach ($existingWindow in $minimizedWindows) { $null = $native::ShowWindow($existingWindow, 9) }
    $null = $native::SetThreadDpiAwarenessContext($oldDpi)
}
