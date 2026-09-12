param([switch]$KeepRunning, [switch]$ImeOnly, [switch]$CloseOnly, [ValidateSet('d3d11','d3d12','opengl','pure-opengl','vulkan','native-vulkan')][string]$Renderer='d3d11', [switch]$TestRecovery, [switch]$VulkanValidation)
$ErrorActionPreference = 'Stop'
$runId = [Guid]::NewGuid().ToString('N')
$projectRoot = Split-Path $PSScriptRoot -Parent
$outputRoot = Join-Path $projectRoot $(if($Renderer -eq 'd3d11'){'tmp\pane-acceptance'}else{"tmp\pane-acceptance-$Renderer"})
if($TestRecovery -and $Renderer -eq 'd3d11'){throw 'Diagnostic recovery requires a research renderer'}
$profile = Join-Path $outputRoot 'profile\Mostty'
New-Item -ItemType Directory -Force -Path $profile | Out-Null
@("renderer = $Renderer", 'font-size = 14', 'background-opacity = 1', 'background-blur = false') | Set-Content -LiteralPath (Join-Path $profile 'config') -Encoding utf8
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
if (-not ('PaneAcceptance' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'pane-test-native.cs')
}
$previousDpiContext=[PaneAcceptance]::SetThreadDpiAwarenessContext([IntPtr](-4))
function Get-PaneMetrics([IntPtr]$Pane){
    $pattern='pane size: id=(\d+) hwnd={0} vt=(\d+)x(\d+) cell=(\d+)x(\d+)' -f $Pane.ToInt64()
    $entries=@(Select-String -LiteralPath (Join-Path $outputRoot 'tmp/mostty-diag.log') -Pattern $pattern)
    if($entries.Count -eq 0){throw 'Missing current pane metrics'}
    $g=$entries[-1].Matches[0].Groups
    return [pscustomobject]@{Id=[int]$g[1].Value;Columns=[int]$g[2].Value;Rows=[int]$g[3].Value;CellWidth=[int]$g[4].Value;CellHeight=[int]$g[5].Value}
}
function Assert-PaneGeometry([IntPtr]$Pane){
    $m=Get-PaneMetrics $Pane
    $rect=[PaneAcceptance]::Box($Pane)
    $scrollbar=[Math]::Round(14*[PaneAcceptance]::GetDpiForWindow($Pane)/96,[MidpointRounding]::AwayFromZero)
    $columns=[Math]::Max(1,[Math]::Floor(($rect.Right-$rect.Left-$scrollbar)/$m.CellWidth))
    $rows=[Math]::Max(1,[Math]::Floor(($rect.Bottom-$rect.Top)/$m.CellHeight))
    if($m.Columns -ne $columns -or $m.Rows -ne $rows){throw 'Pane grid does not match its physical region'}
}
function Assert-PaneColor([IntPtr]$Pane,[Drawing.Color]$Expected){
    $rect=[PaneAcceptance]::Box($Pane)
    $sample=[Drawing.Bitmap]::new(1,1);$graphics=[Drawing.Graphics]::FromImage($sample)
    try{
        $graphics.CopyFromScreen($rect.Left+5,$rect.Top+5,0,0,$sample.Size)
        $actual=$sample.GetPixel(0,0)
        if([Math]::Abs([int]$actual.R-$Expected.R) -gt 12 -or [Math]::Abs([int]$actual.G-$Expected.G) -gt 12 -or [Math]::Abs([int]$actual.B-$Expected.B) -gt 12){throw 'Hidden output was not rendered in the correct pane'}
    }finally{$graphics.Dispose();$sample.Dispose()}
}
function Test-HiddenOutput([int]$Phase){
    $python=(Get-Command python).Source
    $probe=Join-Path $projectRoot 'tools/pane-output-probe.py'
    $outputs=@()
    for($i=0;$i -lt 4;$i++){
        $out=Join-Path $outputRoot "hidden-$runId-$Phase-$i.txt";$outputs+=$out
        Send-Command $panes[$i] ('"{0}" "{1}" hidden {2} "{3}" --phase {4}' -f $python,$probe,$i,$out,$Phase)
    }
    foreach($out in $outputs){Wait-File ([IO.Path]::ChangeExtension($out,'.ready'))}
    if($Phase -eq 0){Chord @(0x11,0x32)}else{Chord @(0x11,0x10,0x0D)}
    $null=Wait-Panes 1
    foreach($out in $outputs){[IO.File]::WriteAllText([IO.Path]::ChangeExtension($out,'.go'),'go')}
    foreach($out in $outputs){Wait-File $out}
    if($Phase -eq 0){Chord @(0x11,0x31)}else{Chord @(0x11,0x10,0x0D)}
    $restored=Wait-Panes 4
    if(@(Compare-Object @($panes | ForEach-Object ToInt64) @($restored | ForEach-Object ToInt64)).Count -ne 0){throw 'Visibility restoration rebuilt pane HWNDs'}
    Start-Sleep -Milliseconds 400
    $colors=@([Drawing.Color]::Red,[Drawing.Color]::Lime,[Drawing.Color]::Blue,[Drawing.Color]::Yellow)
    $pids=@()
    for($i=0;$i -lt 4;$i++){
        Assert-PaneColor $panes[$i] $colors[($i+$Phase)%4]
        $parts=[IO.File]::ReadAllText($outputs[$i]).Trim().Split(',')
        if($parts[1] -ne [IO.Path]::GetFileNameWithoutExtension($outputs[$i])){throw 'Stale hidden output probe'}
        $pids+=[int]$parts[0]
    }
    if(@($pids | Select-Object -Unique).Count -ne 4){throw 'Hidden panes did not retain independent shells'}
    if($Phase -eq 0){$result.hidden_shell_pids=$pids;$result.background_tab_output='pass'}else{
        if(@(Compare-Object $result.hidden_shell_pids $pids).Count -ne 0){throw 'Maximize restoration restarted a shell'}
        $result.maximized_hidden_output='pass'
    }
    Capture "hidden-output-$Phase"
}
function Test-UrlHover {
    $python=(Get-Command python).Source
    $probe=Join-Path $projectRoot 'tools/pane-output-probe.py'
    for($i=0;$i -lt 4;$i++){
        $out=Join-Path $outputRoot "url-$runId-$i.txt"
        Send-Command $panes[$i] ('"{0}" "{1}" url {2} "{3}"' -f $python,$probe,$i,$out)
        Wait-File $out
    }
    Start-Sleep -Milliseconds 400
    $focused=[PaneAcceptance]::Focus($window)
    for($i=0;$i -lt 4;$i++){
        $m=Get-PaneMetrics $panes[$i]
        if(-not [PaneAcceptance]::HoverIsLink($window,$app.Id,$panes[$i],(3*$m.CellWidth+2),(2*$i*$m.CellHeight+5))){throw "URL hover missed pane $i"}
        if([PaneAcceptance]::HoverIsLink($window,$app.Id,$panes[$i],(3*$m.CellWidth+2),((2*$i+1)*$m.CellHeight+5))){throw "URL hover leaked to non-link text in pane $i"}
        if([PaneAcceptance]::Focus($window) -ne $focused){throw 'URL hover changed keyboard focus'}
    }
    $result.url_hover='pass: pane-specific URL rows and non-link rows; focus retained'
    Capture 'url-hover'
}
function Test-RendererDpi {
    $original=[PaneAcceptance]::GetDpiForWindow($window)
    $target=if($original -eq 144){192}else{144}
    $before=@($panes | ForEach-Object {Get-PaneMetrics $_})
    $python=(Get-Command python).Source
    foreach($dpi in @($target,$original)){
        [void][PaneAcceptance]::PostMessageW($window,0x8009,[UIntPtr]$dpi,[IntPtr]::Zero)
        $deadline=[DateTime]::UtcNow.AddSeconds(8)
        do{Start-Sleep -Milliseconds 100;$changed=Select-String -LiteralPath (Join-Path $outputRoot 'tmp/mostty-diag.log') -SimpleMatch "diagnostic renderer DPI: $dpi"}while(-not $changed -and [DateTime]::UtcNow -lt $deadline)
        if(-not $changed){throw 'Renderer DPI diagnostic did not complete'}
        for($i=0;$i -lt 4;$i++){
            Send-Command $panes[$i] ('"{0}" -c "import os; s=os.get_terminal_size(2); print(s.columns,s.lines,os.getppid(),sep='','')" > dpi-{1}-{2}-{3}.txt & echo ready > dpi-{1}-{2}-{3}.txt.ready' -f $python,$runId,$dpi,$i)
        }
        for($i=0;$i -lt 4;$i++){
            $out=Join-Path $outputRoot "dpi-$runId-$dpi-$i.txt"
            Wait-File "$out.ready"
            $values=[IO.File]::ReadAllText($out).Trim().Split(',')
            $m=Get-PaneMetrics $panes[$i]
            Assert-PaneGeometry $panes[$i]
            if([int]$values[0] -ne $m.Columns -or [int]$values[1] -ne $m.Rows -or [int]$values[2] -ne $shellPids[$i]){throw 'Renderer DPI reflow changed a session or left mismatched PTY/VT sizes'}
            if($dpi -eq $original){if($m.CellWidth -ne $before[$i].CellWidth -or $m.CellHeight -ne $before[$i].CellHeight){throw 'Renderer DPI restore did not restore font metrics'}}
            elseif($m.CellWidth -eq $before[$i].CellWidth){throw 'Renderer DPI change did not update cell metrics'}
        }
        $phase=if($dpi -eq $original){1}else{0}
        for($i=0;$i -lt 4;$i++){
            $out=Join-Path $outputRoot "dpi-glyphs-$runId-$dpi-$i.txt"
            Send-Command $panes[$i] ('"{0}" "{1}" glyphs {2} "{3}" --phase {4}' -f $python,(Join-Path $projectRoot 'tools/pane-output-probe.py'),$i,$out,$phase)
        }
        for($i=0;$i -lt 4;$i++){Wait-File (Join-Path $outputRoot "dpi-glyphs-$runId-$dpi-$i.txt")}
        $deadline=[DateTime]::UtcNow.AddSeconds(8)
        do{
            $settled=$true
            for($i=0;$i -lt 4;$i++){
                $m=Get-PaneMetrics $panes[$i];$rect=[PaneAcceptance]::Box($panes[$i])
                $length=('DPI{0}_ABC123xyz' -f $i).Length
                $bitmap=[Drawing.Bitmap]::new($length*$m.CellWidth,$m.CellHeight)
                $graphics=[Drawing.Graphics]::FromImage($bitmap)
                try{
                    $graphics.CopyFromScreen($rect.Left,$rect.Top,0,0,$bitmap.Size)
                    $marker=$bitmap.GetPixel(0,0)
                    $marked=if($phase -eq 0){$marker.B -ge 100 -and $marker.B -le 170 -and $marker.R -lt 15 -and $marker.G -lt 15}else{$marker.R -ge 100 -and $marker.R -le 170 -and $marker.B -lt 15 -and $marker.G -lt 15}
                    if(-not $marked){$settled=$false;continue}
                    for($column=0;$column -lt $length;$column++){
                        $ink=$false
                        for($y=0;$y -lt $m.CellHeight -and -not $ink;$y++){
                            for($x=1;$x -lt $m.CellWidth-1;$x++){
                                $pixel=$bitmap.GetPixel($column*$m.CellWidth+$x,$y)
                                if([int]$pixel.R+[int]$pixel.G+[int]$pixel.B -gt 300){$ink=$true;break}
                            }
                        }
                        if(-not $ink){$settled=$false;break}
                    }
                }finally{$graphics.Dispose();$bitmap.Dispose()}
            }
            if(-not $settled){[PaneAcceptance]::Responsive($window);Start-Sleep -Milliseconds 100}
        }while(-not $settled -and [DateTime]::UtcNow -lt $deadline)
        if(-not $settled){throw 'DPI glyph rows did not settle in every pane'}
        Capture "renderer-dpi-$dpi"
    }
    $result.renderer_dpi_change="pass: renderer $original->$target->$original; cells, settled glyphs, PTY/VT geometry and PIDs verified"
}
function Wait-Panes([int]$Count) {
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    do {
        if ($script:app.HasExited) { throw "Test app exited: $($script:app.ExitCode)" }
        $dialog=[PaneAcceptance]::Dialog($script:app.Id)
        if($dialog -ne [IntPtr]::Zero -and [PaneAcceptance]::DialogText($dialog) -match 'Mostty Renderer Fallback'){
            $reason=[PaneAcceptance]::DialogText($dialog)
            [PaneAcceptance]::ClickDialogButton($dialog,7)
            if(-not $app.WaitForExit(8000)){throw 'Declining unsupported renderer fallback did not exit'}
            throw [NotSupportedException]::new($reason)
        }
        $panes = [PaneAcceptance]::Panes($script:window)
        if ($panes.Count -eq $Count) { return ,$panes }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Expected $Count visible panes; found $($panes.Count)"
}
function Send-Command([IntPtr]$Pane, [string]$Command) {
    foreach ($c in $Command.ToCharArray()) {
        if (-not [PaneAcceptance]::PostMessageW($Pane, 0x102, [UIntPtr][int][char]$c, [IntPtr]::Zero)) { throw 'WM_CHAR failed' }
    }
    [void][PaneAcceptance]::PostMessageW($Pane, 0x102, [UIntPtr]13, [IntPtr]::Zero)
}
function Chord([int[]]$Keys) {
    [PaneAcceptance]::Activate($script:window, $script:app.Id)
    [PaneAcceptance]::Chord($script:window, $script:app.Id, $Keys)
    Start-Sleep -Milliseconds 250
}
function Wait-File([string]$Path) {
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    while (-not (Test-Path -LiteralPath $Path)) {
        [PaneAcceptance]::Responsive($script:window)
        if ([DateTime]::UtcNow -gt $deadline) { throw "Probe did not produce $Path" }
        Start-Sleep -Milliseconds 100
    }
}
function Confirm-TestDialog([string]$Expected) {
    $deadline=[DateTime]::UtcNow.AddSeconds(5)
    do{Start-Sleep -Milliseconds 100;$dialog=[PaneAcceptance]::Dialog($app.Id)}while($dialog -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
    if($dialog -eq [IntPtr]::Zero){throw "Missing close confirmation: $Expected"}
    $message=[PaneAcceptance]::DialogText($dialog)
    if($message -notmatch [regex]::Escape($Expected)){throw "Wrong close action: $message"}
    [PaneAcceptance]::ClickDialogButton($dialog,6)
}
function Capture([string]$Name) {
    $r = [PaneAcceptance+RECT]::new()
    [void][PaneAcceptance]::GetWindowRect($script:window, [ref]$r)
    $bitmap = [Drawing.Bitmap]::new($r.Right-$r.Left, $r.Bottom-$r.Top)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($r.Left,$r.Top,0,0,$bitmap.Size)
        $bitmap.Save((Join-Path $outputRoot "$Name.png"), [Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
}
function Test-Ime {
    $python = (Get-Command python).Source
    $probe = Join-Path $projectRoot 'tools\pane-input-probe.py'
    [PaneAcceptance]::Activate($window,$app.Id)
    [PaneAcceptance]::ClickPane($window,$app.Id,$panes[3],25,30)
    $chineseLayout=[PaneAcceptance]::ChineseLayout()
    if($chineseLayout -eq [IntPtr]::Zero){
        $result.ime='unverified: no Simplified Chinese keyboard layout installed'
    } else {
        $previousLayout=[PaneAcceptance]::Layout($window)
        $imeOutputs=@()
        for($i=0;$i -lt 4;$i++){
            $out=Join-Path $outputRoot "ime-$runId-$i.txt"
            $imeOutputs+=$out
            Send-Command $panes[$i] ('"{0}" "{1}" ime "{2}" --seconds 6' -f $python,$probe,$out)
        }
        foreach($out in $imeOutputs){Wait-File ([IO.Path]::ChangeExtension($out,'.ready'))}
        $diagPath=Join-Path $outputRoot 'tmp\mostty-diag.log'
        $beforeImeLines=@(Get-Content -LiteralPath $diagPath).Count
        try {
            [void][PaneAcceptance]::PostMessageW($panes[3],0x50,[UIntPtr]::Zero,$chineseLayout)
            Start-Sleep -Milliseconds 400
            $result.ime_layout = [PaneAcceptance]::Layout($window).ToInt64().ToString('x')
            $null = [PaneAcceptance]::ImeControl($panes[3],6,1)
            # Only one letter, then Space to commit. Candidate content is
            # deliberately unspecified: IMEs and dictionaries differ.
            Chord @(0x41)
            Capture 'ime-candidate'
            Chord @(0x20)
            foreach($out in $imeOutputs){Wait-File $out}
            $imeText=[IO.File]::ReadAllText($imeOutputs[3])
            for($i=0;$i -lt 3;$i++){
                if([IO.File]::ReadAllText($imeOutputs[$i]).Length -ne 0){throw "IME input leaked to pane $i"}
            }
            $sizePattern='pane size: id=(\d+) hwnd={0} ' -f $panes[3].ToInt64()
            $paneEntry=@(Select-String -LiteralPath $diagPath -Pattern $sizePattern)[-1]
            $imePaneId=$paneEntry.Matches[0].Groups[1].Value
            $imeEvents=@(Get-Content -LiteralPath $diagPath | Select-Object -Skip $beforeImeLines)
            $commitPattern='IME commit: pane={0} utf16_units=([1-9]\d*)' -f $imePaneId
            $anchorPattern='IME composition anchor: pane={0} .*placed=1' -f $imePaneId
            $result.ime=if($imeText.Length -gt 0 -and ($imeEvents -match $commitPattern).Count -gt 0 -and ($imeEvents -match $anchorPattern).Count -gt 0){'pass'}else{'unverified: no completed IME composition observed'}
            $result.ime_input_units=$imeText.Length
            $result.ime_test_keys='one letter followed by Space; no candidate-text assertion'
        } finally {
            [void][PaneAcceptance]::PostMessageW($panes[3],0x50,[UIntPtr]::Zero,$previousLayout)
            Start-Sleep -Milliseconds 300
        }
    }

}
function Test-CloseActions {
    Send-Command $panes[0] 'exit'
    $remaining = Wait-Panes 3
    $result.individual_exit = 'pass'
    Capture 'closed-pane'
    # The first shell's exit must not invalidate the tab's retained ID.
    [PaneAcceptance]::ClickPane($window,$app.Id,$remaining[0],25,30)
    [PaneAcceptance]::MenuCommand($window,'Close pane')
    Confirm-TestDialog 'Close this pane?'
    $remaining=Wait-Panes 2
    $result.close_pane='pass'
    Chord @(0x11,0x54)
    $newTab=Wait-Panes 1
    Chord @(0x11,0x31)
    $null=Wait-Panes 2
    Chord @(0x11,0x57)
    Confirm-TestDialog 'Close this tab?'
    $survivor=Wait-Panes 1
    if($survivor[0] -ne $newTab[0]){throw 'Closing a tab removed the other tab'}
    $result.close_tab='pass'
    Chord @(0x11,0x10,0x44)
    $null=Wait-Panes 2
    Chord @(0x12,0x73)
    Confirm-TestDialog 'Close window and all tabs?'
    if (-not $app.WaitForExit(8000)) { throw 'Closing the window and all panes hung' }
    $result.close_window='pass'
    if ($app.ExitCode -ne 0) { throw "App exit code $($app.ExitCode)" }
}
$start = [Diagnostics.ProcessStartInfo]::new((Join-Path $projectRoot 'zig-out\bin\Mostty.exe'))
$start.WorkingDirectory = $outputRoot
$start.UseShellExecute = $false
$start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
$start.Environment['LOCALAPPDATA'] = Split-Path $profile -Parent
$start.Environment['MOSTTY_DIAG'] = '1'
if($VulkanValidation){
    if($Renderer -notin @('vulkan','native-vulkan')){throw 'Vulkan validation requires a Vulkan renderer'}
    $validationLog=Join-Path $outputRoot "validation-$runId.log"
    @('khronos_validation.validate_sync = true','khronos_validation.debug_action = VK_DBG_LAYER_ACTION_LOG_MSG','khronos_validation.log_filename = stdout','khronos_validation.report_flags = error,warn,info') | Set-Content -LiteralPath (Join-Path $outputRoot 'vk_layer_settings.txt') -Encoding utf8
    $start.Environment['VK_INSTANCE_LAYERS']='VK_LAYER_KHRONOS_validation'
    $start.Environment['VK_LAYER_SETTINGS_PATH']=$outputRoot
    $start.RedirectStandardOutput=$true
    $start.RedirectStandardError=$true
}
$script:app = [Diagnostics.Process]::Start($start)
if($VulkanValidation){$validationStdout=$app.StandardOutput.ReadToEndAsync();$validationStderr=$app.StandardError.ReadToEndAsync()}
$script:window = [IntPtr]::Zero
$result = [ordered]@{ executable_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $projectRoot 'zig-out/bin/Mostty.exe')).Hash; renderer = $Renderer; process_id = $app.Id; run_id = $runId; status = 'running' }
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 100
        if ($app.HasExited) { throw "Test app exited during startup: $($app.ExitCode)" }
        $script:window = [PaneAcceptance]::Root($app.Id)
    } while ($window -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
    if ($window -eq [IntPtr]::Zero) { throw 'No main window' }
    # Showing this owned test window is required for composition capture.
    [void][PaneAcceptance]::SetWindowPos($window,[IntPtr](-1),60,40,1100,760,0x40)
    [void][PaneAcceptance]::SetForegroundWindow($window)
    $null = Wait-Panes 1
    Start-Sleep -Seconds 1
    Capture 'one-pane'
    Chord @(0x11,0x10,0x44)
    $null = Wait-Panes 2
    Chord @(0x11,0x10,0x45)
    $null = Wait-Panes 3
    $rightFocus = [PaneAcceptance]::Box([PaneAcceptance]::Focus($window))
    Chord @(0x11,0x12,0x25)
    $leftFocus = [PaneAcceptance]::Box([PaneAcceptance]::Focus($window))
    if ($leftFocus.Left -ge $rightFocus.Left) { throw 'Directional focus did not move left' }
    $result.directional_focus = 'pass'
    Chord @(0x11,0x10,0x45)
    $panes = Wait-Panes 4
    if($Renderer -eq 'd3d11'){
        if(@(Select-String -LiteralPath (Join-Path $outputRoot 'tmp/mostty-diag.log') -SimpleMatch 'd3d: D3D11 device created:').Count -ne 1){throw 'Missing unique D3D11 renderer device evidence'}
        $result.backend_identity='D3D11 renderer with four native panes'
    }
    if($Renderer -eq 'd3d12'){
        $devices=@(Select-String -LiteralPath (Join-Path $outputRoot 'tmp\mostty-diag.log') -Pattern 'd3d12: pane created: id=(\d+) device=(0x[0-9a-f]+) queue=(0x[0-9a-f]+)')
        if($devices.Count -lt 4){throw 'Missing actual renderer pane creation evidence'}
        if(@($devices | ForEach-Object {$_.Matches[0].Groups[2].Value} | Select-Object -Unique).Count -ne 1){throw 'Panes did not share one D3D12 device'}
        if(@($devices | ForEach-Object {$_.Matches[0].Groups[3].Value} | Select-Object -Unique).Count -ne 1){throw 'Panes did not share one D3D12 command queue'}
        $result.backend_identity='four D3D12 surfaces sharing one device and queue'
    }
    if($Renderer -in @('opengl','pure-opengl')){
        $logPath=Join-Path $outputRoot 'tmp/mostty-diag.log'
        $surfaces=@(Select-String -LiteralPath $logPath -Pattern 'gl46: pane created: id=(\d+) context=(0x[0-9a-f]+) dc=(0x[0-9a-f]+) mode=(\w+)')
        if($surfaces.Count -lt 4){throw 'Missing actual OpenGL pane creation evidence'}
        if(@($surfaces | ForEach-Object {$_.Matches[0].Groups[2].Value} | Select-Object -Unique).Count -ne 1){throw 'Panes did not share one WGL context'}
        if(@($surfaces | ForEach-Object {$_.Matches[0].Groups[3].Value} | Select-Object -Unique).Count -ne 4){throw 'Panes did not have distinct DCs'}
        $expectedMode=if($Renderer -eq 'pure-opengl'){'pure_wgl'}else{'interop'}
        if(@($surfaces | Where-Object {$_.Matches[0].Groups[4].Value -ne $expectedMode}).Count -ne 0){throw 'OpenGL pane used the wrong presentation mode'}
        $bridges=@(Select-String -LiteralPath $logPath -Pattern 'bridge active: surface=(\d+) device=(0x[0-9a-f]+)')
        if($Renderer -eq 'pure-opengl'){
            if($bridges.Count -ne 0){throw 'Pure OpenGL created an interop bridge'}
            $result.presentation='pure WGL'
        }elseif($bridges.Count -ge 5){
            if(@($bridges | ForEach-Object {$_.Matches[0].Groups[2].Value} | Select-Object -Unique).Count -ne 1){throw 'OpenGL panes created multiple D3D11 presentation devices'}
            $result.presentation='WGL_NV_DX_interop2 with one shared D3D11 presentation device'
        }else{
            if(-not (Select-String -LiteralPath $logPath -SimpleMatch 'bridge unavailable')){throw 'OpenGL presentation identity is unknown'}
            $result.presentation='interop unavailable; baseline WGL exercised'
        }
        $result.backend_identity="four $Renderer panes sharing one context with distinct DCs"
    }
    if($Renderer -in @('vulkan','native-vulkan')){
        $logPath=Join-Path $outputRoot 'tmp/mostty-diag.log'
        $surfaces=@(Select-String -LiteralPath $logPath -Pattern 'vulkan: pane created: id=(\d+) device=(0x[0-9a-f]+) queue=(0x[0-9a-f]+) mode=(\w+)')
        if($surfaces.Count -lt 4){throw 'Missing actual Vulkan pane creation evidence'}
        if(@($surfaces | ForEach-Object {$_.Matches[0].Groups[2].Value} | Select-Object -Unique).Count -ne 1){throw 'Vulkan panes did not share one device'}
        if(@($surfaces | ForEach-Object {$_.Matches[0].Groups[3].Value} | Select-Object -Unique).Count -ne 1){throw 'Vulkan panes did not share one queue'}
        $mode=if($Renderer -eq 'native-vulkan'){'native_wsi'}else{'dcomp_bridge'}
        if(@($surfaces | Where-Object {$_.Matches[0].Groups[4].Value -ne $mode}).Count -ne 0){throw 'Vulkan presentation changed mode'}
        $bridges=@(Select-String -LiteralPath $logPath -Pattern 'vulkan: pane bridge: id=(\d+) d3d_device=(0x[0-9a-f]+)')
        if($Renderer -eq 'native-vulkan'){
            if($bridges.Count -ne 0){throw 'Native Vulkan created a D3D bridge'}
            $result.presentation='native Win32 WSI'
        }else{
            if($bridges.Count -lt 4 -or @($bridges | ForEach-Object {$_.Matches[0].Groups[2].Value} | Select-Object -Unique).Count -ne 1){throw 'Vulkan bridge panes did not share one D3D11 device'}
            $result.presentation='Vulkan/D3D11 bridge with a shared presentation device'
        }
        $result.backend_identity="four $Renderer panes sharing one Vulkan device and queue"
    }
    if($CloseOnly){
        Test-CloseActions
        $result.status='pass'
        return
    }
    if($ImeOnly){
        Test-Ime
        foreach($pane in $panes){Send-Command $pane 'exit'}
        if(-not $app.WaitForExit(8000)){throw 'IME-only test teardown hung'}
        $result.status=if($result.ime -eq 'pass'){'pass'}else{'partial'}
        return
    }
    for ($i=0; $i -lt $panes.Count; $i++) { Send-Command $panes[$i] "set MOSTTY_PANE_MARKER=PANE_${i}_$runId" }
    Start-Sleep -Milliseconds 500
    for ($i=0; $i -lt $panes.Count; $i++) {
        Send-Command $panes[$i] "echo %MOSTTY_PANE_MARKER% > marker-$i.txt"
        Send-Command $panes[$i] "echo VISIBLE_PANE_$i"
    }
    Start-Sleep -Seconds 1
    for ($i=0; $i -lt $panes.Count; $i++) {
        $value = (Get-Content -Raw -LiteralPath (Join-Path $outputRoot "marker-$i.txt")).Trim()
        if ($value -ne "PANE_${i}_$runId") { throw "Pane routing mismatch for $i : $value" }
    }
    $result.independent_input = 'pass'
    $result.pane_handles = @($panes | ForEach-Object { $_.ToInt64() })
    Capture 'four-panes'
    Chord @(0x11,0x10,0x0D)
    $null = Wait-Panes 1
    Capture 'maximized'
    Chord @(0x11,0x10,0x0D)
    $restored = Wait-Panes 4
    if (@(Compare-Object @($panes | ForEach-Object ToInt64) @($restored | ForEach-Object ToInt64)).Count -ne 0) { throw 'Maximize rebuilt a pane window' }
    $result.maximize_restore = 'pass'
    $beforeDrag = [PaneAcceptance]::Box($panes[0])
    $rightBox = [PaneAcceptance]::Box($panes[2])
    $focusBefore = [PaneAcceptance]::Focus($window)
    $dividerX = [int](($beforeDrag.Right + $rightBox.Left) / 2)
    [PaneAcceptance]::Drag($window,$app.Id,$dividerX,($beforeDrag.Top+50),($dividerX-100),($beforeDrag.Top+50))
    $afterDrag = [PaneAcceptance]::Box($panes[0])
    if ($afterDrag.Right -ge $beforeDrag.Right-50) { throw 'Divider drag did not resize the pane' }
    if ([PaneAcceptance]::Focus($window) -ne $focusBefore) { throw 'Divider drag stole pane focus' }
    $result.divider_drag = 'pass'
    Capture 'dragged-divider'
    $left=[PaneAcceptance]::Box($panes[0]);$right=[PaneAcceptance]::Box($panes[2])
    $startX=[int](($left.Right+$right.Left)/2)
    [PaneAcceptance]::Drag($window,$app.Id,$startX,($left.Top+50),($left.Left+10),($left.Top+50))
    foreach($paneHandle in $panes){Assert-PaneGeometry $paneHandle;$m=Get-PaneMetrics $paneHandle;if($m.Columns -lt 12 -or $m.Rows -lt 2){throw 'Divider violated pane minimum dimensions'}}
    $minimum=Get-PaneMetrics $panes[0]
    if($minimum.Columns -ne 12){throw 'Divider did not clamp to the expected minimum'}
    [PaneAcceptance]::ClickPane($window,$app.Id,$panes[0],25,30)
    $beforeRefusal=@(Get-Content -LiteralPath (Join-Path $outputRoot 'tmp/mostty-diag.log')).Count
    Chord @(0x11,0x10,0x44)
    $null=Wait-Panes 4
    $refusal=@(Get-Content -LiteralPath (Join-Path $outputRoot 'tmp/mostty-diag.log') | Select-Object -Skip $beforeRefusal | Select-String -SimpleMatch ("pane {0} is too small to split" -f $minimum.Id))
    if($refusal.Count -eq 0){throw 'Minimum-size split rejection was not observed'}
    $left=[PaneAcceptance]::Box($panes[0]);$right=[PaneAcceptance]::Box($panes[2])
    [PaneAcceptance]::Drag($window,$app.Id,([int](($left.Right+$right.Left)/2)),($left.Top+50),$startX,($left.Top+50))
    $result.minimum_size='pass: clamped to 12 columns and refused a further split'
    Chord @(0x11,0x54)
    $otherTab = Wait-Panes 1
    Chord @(0x11,0x31)
    $tabRestored = Wait-Panes 4
    if (@(Compare-Object @($panes | ForEach-Object ToInt64) @($tabRestored | ForEach-Object ToInt64)).Count -ne 0) { throw 'Tab switch rebuilt pane HWNDs' }
    $result.tab_retention = 'pass'
    Test-HiddenOutput 0
    Test-HiddenOutput 1
    Test-UrlHover
    # Probe actual ConPTY input bytes; posted shell setup targets each known HWND.
    $python = (Get-Command python).Source
    $probe = Join-Path $projectRoot 'tools\pane-input-probe.py'
    $mouseOutputs = @()
    for ($i=0;$i -lt 4;$i++) {
        $out = Join-Path $outputRoot "mouse-$runId-$i.txt"
        $mouseOutputs += $out
        Send-Command $panes[$i] ('"{0}" "{1}" mouse "{2}" --seconds 5' -f $python,$probe,$out)
    }
    foreach($out in $mouseOutputs){ Wait-File ([IO.Path]::ChangeExtension($out,'.ready')) }
    [PaneAcceptance]::Activate($window,$app.Id)
    [PaneAcceptance]::ClickPane($window,$app.Id,$panes[3],25,30)
    foreach($out in $mouseOutputs){ Wait-File $out }
    for($i=0;$i -lt 4;$i++) {
        $inputText = [IO.File]::ReadAllText($mouseOutputs[$i])
        if($i -eq 3) {if($inputText -notmatch '\x1b\[<0;\d+;\d+M' -or $inputText -notmatch '\x1b\[<0;\d+;\d+m'){throw 'Missing SGR press/release in clicked pane'}}
        elseif($inputText.Length -ne 0){throw "Mouse report leaked to pane $i"}
    }
    $result.mouse_reporting = 'pass'
    $result.click_focus = 'pass'
    $captureOut=Join-Path $outputRoot "capture-$runId.txt"
    Send-Command $panes[3] ('"{0}" "{1}" mouse "{2}" --seconds 4' -f $python,$probe,$captureOut)
    Wait-File ([IO.Path]::ChangeExtension($captureOut,'.ready'))
    [PaneAcceptance]::CapturedTabSwitch($window,$app.Id,$panes[3])
    $null=Wait-Panes 1
    Wait-File $captureOut
    $capturedBytes=[IO.File]::ReadAllText($captureOut)
    if($capturedBytes -notmatch '\x1b\[<0;\d+;\d+M' -or $capturedBytes -notmatch '\x1b\[<0;\d+;\d+m'){throw 'Mouse capture lost its release across tab switching'}
    Chord @(0x11,0x31)
    $null=Wait-Panes 4
    $result.mouse_capture_tab_switch='pass'

    Test-Ime

    $savedClipboard = [Windows.Forms.Clipboard]::GetDataObject()
    $clipboardCopy = [Windows.Forms.DataObject]::new()
    if($null -ne $savedClipboard){foreach($format in $savedClipboard.GetFormats($false)){$clipboardCopy.SetData($format,$false,$savedClipboard.GetData($format,$false))}}
    try {
        $pasteOutputs=@()
        for($i=0;$i -lt 4;$i++){
            $out=Join-Path $outputRoot "paste-$runId-$i.txt"
            $pasteOutputs+=$out
            Send-Command $panes[$i] ('"{0}" "{1}" paste "{2}" --seconds 5' -f $python,$probe,$out)
        }
        foreach($out in $pasteOutputs){Wait-File ([IO.Path]::ChangeExtension($out,'.ready'))}
        [Windows.Forms.Clipboard]::SetDataObject("PASTE_中文_$runId",$true)
        Chord @(0x11,0x56)
        foreach($out in $pasteOutputs){Wait-File $out}
        for($i=0;$i -lt 4;$i++){
            $inputText=[IO.File]::ReadAllText($pasteOutputs[$i])
            if($i -eq 3){if($inputText -ne ([char]27+"[200~PASTE_中文_$runId"+[char]27+'[201~')){throw 'Bracketed Unicode paste did not reach the focused pane'}}
            elseif($inputText.Length -ne 0){throw "Paste leaked to pane $i"}
        }
        $result.bracketed_unicode_paste='pass'
        $out=Join-Path $outputRoot "selection-$runId.txt"
        Send-Command $panes[0] ('"{0}" "{1}" selection "{2}" --seconds 4' -f $python,$probe,$out)
        Wait-File ([IO.Path]::ChangeExtension($out,'.ready'))
        $box=[PaneAcceptance]::Box($panes[0])
        $pattern='pane size: id=\d+ hwnd={0} vt=(\d+)x(\d+) cell=(\d+)x(\d+)' -f $panes[0].ToInt64()
        $entry=@(Select-String -LiteralPath (Join-Path $outputRoot 'tmp\mostty-diag.log') -Pattern $pattern)[-1]
        $cellWidth=[int]$entry.Matches[0].Groups[3].Value
        [PaneAcceptance]::Drag($window,$app.Id,($box.Left+1),($box.Top+8),($box.Left+13*$cellWidth+1),($box.Top+8))
        # EmptyClipboard notifies the previous OLE owner synchronously. Pump
        # this STA test thread before reading back, so the app can finish copy.
        $clipboardDeadline=[DateTime]::UtcNow.AddSeconds(5)
        $copied=$null
        do {
            [Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 50
            try {$copied=[Windows.Forms.Clipboard]::GetText()} catch {continue}
        } while($copied -ne 'SELECTION_PANE' -and [DateTime]::UtcNow -lt $clipboardDeadline)
        if($copied -ne 'SELECTION_PANE'){throw 'Selection used incorrect pane-local coordinates'}
        $result.selection_copy='pass'
        Wait-File $out
    } catch {
        $result.input_error=$_.Exception.Message
        throw
    } finally {
        $restoredClipboard=$false
        for($attempt=0;$attempt -lt 20 -and -not $restoredClipboard;$attempt++){
            [Windows.Forms.Application]::DoEvents()
            try {
                if($null -eq $savedClipboard){[Windows.Forms.Clipboard]::Clear()}else{[Windows.Forms.Clipboard]::SetDataObject($clipboardCopy,$true)}
                $restoredClipboard=$true
            } catch {Start-Sleep -Milliseconds 100}
        }
        $result.clipboard_restored=$restoredClipboard
        if(-not $restoredClipboard){throw 'Clipboard restoration failed after bounded retries; see input_error for any preceding assertion'}
    }


    Chord @(0x11,0x32)
    $null = Wait-Panes 1
    Send-Command $otherTab[0] 'exit'
    $null = Wait-Panes 4
    $streamOutputs=@()
    for($i=0;$i -lt 4;$i++){
        $out=Join-Path $outputRoot "stream-$runId-$i.txt";$streamOutputs+=$out
        Send-Command $panes[$i] ('"{0}" "{1}" stream {2} "{3}"' -f (Get-Command python).Source,(Join-Path $projectRoot 'tools/pane-output-probe.py'),$i,$out)
    }
    foreach($out in $streamOutputs){Wait-File ([IO.Path]::ChangeExtension($out,'.ready'))}
    foreach($out in $streamOutputs){[IO.File]::WriteAllText([IO.Path]::ChangeExtension($out,'.go'),'go')}
    foreach($out in $streamOutputs){Wait-File ([IO.Path]::ChangeExtension($out,'.started'));if(Test-Path -LiteralPath $out){throw 'Output completed before the resize exercise'}}
    $left=[PaneAcceptance]::Box($panes[0]);$right=[PaneAcceptance]::Box($panes[2]);$dragX=[int](($left.Right+$right.Left)/2)
    [PaneAcceptance]::Drag($window,$app.Id,$dragX,($left.Top+50),($dragX+40),($left.Top+50))
    $result.output_divider_responsiveness='pass'
    for ($step=0; $step -lt 12; $step++) {
        [void][PaneAcceptance]::SetWindowPos($window,[IntPtr]::Zero,60,40,(950+($step%3)*60),(650+($step%2)*80),0x14)
        [PaneAcceptance]::Responsive($window)
        Start-Sleep -Milliseconds 90
    }
    foreach($out in $streamOutputs){Wait-File $out}
    $result.output_resize_responsiveness = 'pass'
    $focusBeforeWheel=[PaneAcceptance]::Focus($window)
    [PaneAcceptance]::Wheel($window,$app.Id,$panes[2],600)
    if([PaneAcceptance]::Focus($window) -ne $focusBeforeWheel){throw 'Hover scrolling changed keyboard focus'}
    $scrollPattern='pane scroll: id=\d+ hwnd={0} before=(\d+) after=(\d+)' -f $panes[2].ToInt64()
    $scrollEntry=@(Select-String -LiteralPath (Join-Path $outputRoot 'tmp\mostty-diag.log') -Pattern $scrollPattern)
    if($scrollEntry.Count -eq 0){throw 'Wheel did not reach the hovered pane'}
    $scrollGroups=$scrollEntry[-1].Matches[0].Groups
    if([long]$scrollGroups[1].Value - [long]$scrollGroups[2].Value -ne 15){throw 'Wheel did not scroll exactly five three-line notches'}
    $result.hover_scroll='pass'
    Capture 'scrolled-pane'

    $python = (Get-Command python).Source
    for ($i=0;$i -lt $panes.Count;$i++) {
        $command = '"{0}" -c "import os; s=os.get_terminal_size(2); print(''{1}'',s.columns,s.lines,os.getppid(),sep='','')" > size-{2}.txt' -f $python,$runId,$i
        Send-Command $panes[$i] $command
    }
    Start-Sleep -Seconds 2
    $sizes = @()
    $shellPids = @()
    for ($i=0;$i -lt $panes.Count;$i++) {
        $parts = (Get-Content -Raw (Join-Path $outputRoot "size-$i.txt")).Trim().Split(',')
        if ($parts[0] -ne $runId) { throw 'Missing current ConPTY size probe' }
        $pattern = 'pane size: id=\d+ hwnd={0} vt=(\d+)x(\d+) cell=(\d+)x(\d+)' -f $panes[$i].ToInt64()
        $entry = @(Select-String -LiteralPath (Join-Path $outputRoot 'tmp\mostty-diag.log') -Pattern $pattern)[-1]
        if ($null -eq $entry) { throw 'Missing VT size evidence' }
        $groups = $entry.Matches[0].Groups
        if ([int]$parts[1] -ne [int]$groups[1].Value -or [int]$parts[2] -ne [int]$groups[2].Value) { throw "ConPTY/VT size mismatch in pane $i" }
        Assert-PaneGeometry $panes[$i]
        $shellPids += [int]$parts[3]
        $sizes += [ordered]@{ hwnd=$panes[$i].ToInt64(); columns=[int]$parts[1]; rows=[int]$parts[2] }
    }
    if (@($shellPids | Select-Object -Unique).Count -ne 4) { throw 'Panes did not report independent shell processes' }
    if(@(Compare-Object $result.hidden_shell_pids $shellPids).Count -ne 0){throw 'Layout/visibility operations restarted a shell'}
    $result.pty_region_match='pass'
    $result.pty_vt_sizes = $sizes
    $result.shell_process_ids = $shellPids
    Capture 'output-resize'
    if($TestRecovery){
        Start-Sleep -Milliseconds 1200
        Capture 'device-before'
        $diagPath=Join-Path $outputRoot 'tmp\mostty-diag.log'
        [void][PaneAcceptance]::PostMessageW($window,$(if($Renderer -eq 'd3d12'){0x8006}elseif($Renderer -in @('opengl','pure-opengl')){0x8007}else{0x8008}),[UIntPtr]::Zero,[IntPtr]::Zero)
        $deadline=[DateTime]::UtcNow.AddSeconds(20)
        do {
            Start-Sleep -Milliseconds 100
            if($app.HasExited){throw 'D3D12 process exited during recovery'}
            if([PaneAcceptance]::Dialog($app.Id) -ne [IntPtr]::Zero){throw 'Renderer recovery displayed a failure dialog'}
            $recovered=Select-String -LiteralPath $diagPath -Pattern '(D3D12|OpenGL|Vulkan) pane recovery complete'
        } while(-not $recovered -and [DateTime]::UtcNow -lt $deadline)
        if(-not $recovered){throw 'Renderer recovery did not complete'}
        $after=Wait-Panes 4
        if(@(Compare-Object @($panes | ForEach-Object ToInt64) @($after | ForEach-Object ToInt64)).Count -ne 0){throw 'Renderer recovery replaced pane HWNDs'}
        Start-Sleep -Milliseconds 1500
        Capture 'device-repaint'
        $beforeImage=[Drawing.Bitmap]::new((Join-Path $outputRoot 'device-before.png'))
        $afterImage=[Drawing.Bitmap]::new((Join-Path $outputRoot 'device-repaint.png'))
        $rootBox=[PaneAcceptance]::Box($window)
        $different=0;$compared=0
        try{
            foreach($paneHandle in $panes){
                $rect=[PaneAcceptance]::Box($paneHandle)
                # Exclude borders, scrollbar and the bottom two cursor rows.
                for($y=$rect.Top-$rootBox.Top+2;$y -lt $rect.Bottom-$rootBox.Top-2*[int]$groups[4].Value;$y++){
                    for($x=$rect.Left-$rootBox.Left+2;$x -lt $rect.Right-$rootBox.Left-18;$x++){
                        $a=$beforeImage.GetPixel($x,$y);$b=$afterImage.GetPixel($x,$y)
                        if([Math]::Abs([int]$a.R-$b.R) -gt 8 -or [Math]::Abs([int]$a.G-$b.G) -gt 8 -or [Math]::Abs([int]$a.B-$b.B) -gt 8){$different++}
                        $compared++
                    }
                }
            }
        }finally{$beforeImage.Dispose();$afterImage.Dispose()}
        $result.recovery_pixel_difference=$different
        $result.recovery_pixels_compared=$compared
        if($different -gt $compared*0.001){throw 'Settled renderer text pixels changed after recovery'}
        for($i=0;$i -lt 4;$i++){
            Send-Command $panes[$i] ('"{0}" -c "import os; print(os.getppid())" > recovery-{1}-{2}.txt & echo ready > recovery-{1}-{2}.txt.ready' -f $python,$runId,$i)
        }
        for($i=0;$i -lt 4;$i++){
            $out=Join-Path $outputRoot "recovery-$runId-$i.txt"
            Wait-File "$out.ready"
            if([int]([IO.File]::ReadAllText($out).Trim()) -ne $shellPids[$i]){throw 'Renderer recovery restarted a shell'}
        }
        if($Renderer -eq 'd3d12'){$result.device_removal_recovery='pass: original shell PIDs and pane HWNDs retained'}else{$result.presentation_failure_recovery='pass: original shell PIDs and pane HWNDs retained'}
        Capture 'device-recovered'
    }
    $previousCellWidth = [int]$groups[3].Value
    @("renderer = $Renderer", 'font-size = 18', 'foreground = #80e090', 'background-opacity = 0.65', 'background-blur = true') | Set-Content -LiteralPath (Join-Path $profile 'config') -Encoding utf8
    Start-Sleep -Seconds 2
    $null = Wait-Panes 4
    for ($i=0;$i -lt $panes.Count;$i++) {
        $command = '"{0}" -c "import os; s=os.get_terminal_size(2); print(''{1}'',s.columns,s.lines,sep='','')" > font-size-{2}.txt' -f $python,$runId,$i
        Send-Command $panes[$i] $command
        Send-Command $panes[$i] "echo 中文输入窗格_$i"
    }
    Start-Sleep -Seconds 2
    $fontSizes = @()
    for ($i=0;$i -lt $panes.Count;$i++) {
        $parts = (Get-Content -Raw (Join-Path $outputRoot "font-size-$i.txt")).Trim().Split(',')
        $pattern = 'pane size: id=\d+ hwnd={0} vt=(\d+)x(\d+) cell=(\d+)x(\d+)' -f $panes[$i].ToInt64()
        $entry = @(Select-String -LiteralPath (Join-Path $outputRoot 'tmp\mostty-diag.log') -Pattern $pattern)[-1]
        $groups = $entry.Matches[0].Groups
        if ($parts[0] -ne $runId -or [int]$parts[1] -ne [int]$groups[1].Value -or [int]$parts[2] -ne [int]$groups[2].Value) { throw "Font reload left mismatched sizes in pane $i" }
        if ([int]$groups[3].Value -eq $previousCellWidth) { throw 'Font reload did not update pane metrics' }
        $fontSizes += [ordered]@{ hwnd=$panes[$i].ToInt64(); columns=[int]$parts[1]; rows=[int]$parts[2]; cell_width=[int]$groups[3].Value; cell_height=[int]$groups[4].Value }
    }
    $result.font_reload_sizes = $fontSizes
    if($Renderer -eq 'native-vulkan' -and (Select-String -LiteralPath (Join-Path $outputRoot 'tmp/mostty-diag.log') -SimpleMatch 'cannot enable alpha composition')){
        $result.transparency_blur='unsupported: opaque native surface; request explicitly rejected'
    }else{$result.transparency_blur='pass'}
    Capture 'font-theme-transparency'
    & {
        $imageProbe=Join-Path $projectRoot 'tools/pane-image-probe.py'
        for($i=0;$i -lt 4;$i++){
            $ready=Join-Path $outputRoot "image-$runId-$i.ready"
            Send-Command $panes[$i] ('"{0}" "{1}" draw {2} "{3}"' -f $python,$imageProbe,$i,$ready)
        }
        for($i=0;$i -lt 4;$i++){Wait-File (Join-Path $outputRoot "image-$runId-$i.ready")}
        Start-Sleep -Milliseconds 700
        Capture 'kitty-four-panes'
        $colors=@([Drawing.Color]::Red,[Drawing.Color]::Lime,[Drawing.Color]::Blue,[Drawing.Color]::Yellow)
        function Assert-PaneImage([int]$Index){
            $box=[PaneAcceptance]::Box($panes[$Index])
            $sample=[Drawing.Bitmap]::new(1,1)
            $graphics=[Drawing.Graphics]::FromImage($sample)
            try{
                $graphics.CopyFromScreen($box.Left+10,$box.Top+[int]$groups[4].Value+10,0,0,$sample.Size)
                $actual=$sample.GetPixel(0,0);$expected=$colors[$Index]
                if([Math]::Abs([int]$actual.R-$expected.R) -gt 12 -or [Math]::Abs([int]$actual.G-$expected.G) -gt 12 -or [Math]::Abs([int]$actual.B-$expected.B) -gt 12){throw "Wrong Kitty image color in pane $Index : $actual"}
            }finally{$graphics.Dispose();$sample.Dispose()}
        }
        for($i=0;$i -lt 4;$i++){Assert-PaneImage $i}
        $ready=Join-Path $outputRoot "image-delete-$runId.ready"
        Send-Command $panes[0] ('"{0}" "{1}" delete 0 "{2}"' -f $python,$imageProbe,$ready)
        Wait-File $ready
        Start-Sleep -Milliseconds 500
        for($i=1;$i -lt 4;$i++){Assert-PaneImage $i}
        $result.kitty_isolation='pass: same ID shows four independent colors; deleting in one preserves the others'
        Capture 'kitty-deleted-pane'
        if($Renderer -eq 'native-vulkan' -and $result.transparency_blur -like 'unsupported*'){
            $result.wallpaper_reload='unverified: opaque native surface cannot reveal the wallpaper through cell backgrounds'
        }else{
        # A solid wallpaper with a transparent default cell background gives an exact pixel result.
        $wallpaper=Join-Path $outputRoot "wallpaper-$runId.bmp"
        $bitmap=[Drawing.Bitmap]::new(8,8)
        $graphics=[Drawing.Graphics]::FromImage($bitmap)
        try{$graphics.Clear([Drawing.Color]::Magenta);$bitmap.Save($wallpaper,[Drawing.Imaging.ImageFormat]::Bmp)}finally{$graphics.Dispose();$bitmap.Dispose()}
        foreach($paneHandle in $panes){Send-Command $paneHandle 'cls'}
        @("renderer = $Renderer",'font-size = 18','background-opacity = 0','background-blur = false',"background-image = $wallpaper",'background-image-opacity = 1','background-image-fit = stretch') | Set-Content -LiteralPath (Join-Path $profile 'config') -Encoding utf8
        $deadline=[DateTime]::UtcNow.AddSeconds(8)
        do{Start-Sleep -Milliseconds 100;$loaded=Select-String -LiteralPath (Join-Path $outputRoot 'tmp/mostty-diag.log') -SimpleMatch "loaded '$wallpaper'"}while(-not $loaded -and [DateTime]::UtcNow -lt $deadline)
        if(-not $loaded){throw 'Wallpaper update did not finish decoding'}
        Start-Sleep -Milliseconds 500
        foreach($paneHandle in $panes){
            $rect=[PaneAcceptance]::Box($paneHandle)
            $sample=[Drawing.Bitmap]::new(1,1);$graphics=[Drawing.Graphics]::FromImage($sample)
            try{
                $graphics.CopyFromScreen($rect.Right-40,$rect.Bottom-45,0,0,$sample.Size)
                $pixel=$sample.GetPixel(0,0)
                if($pixel.R -lt 243 -or $pixel.B -lt 243 -or $pixel.G -gt 12){throw 'Wallpaper update failed to reach a renderer pane'}
            }finally{$graphics.Dispose();$sample.Dispose()}
        }
        Capture 'wallpaper-updated'
        @("renderer = $Renderer",'font-size = 18','background-opacity = 1','background-blur = false','background-image =') | Set-Content -LiteralPath (Join-Path $profile 'config') -Encoding utf8
        Start-Sleep -Milliseconds 800
        foreach($paneHandle in $panes){
            $rect=[PaneAcceptance]::Box($paneHandle)
            $sample=[Drawing.Bitmap]::new(1,1);$graphics=[Drawing.Graphics]::FromImage($sample)
            try{
                $graphics.CopyFromScreen($rect.Right-40,$rect.Bottom-45,0,0,$sample.Size)
                $pixel=$sample.GetPixel(0,0)
                if($pixel.R -ge 243 -and $pixel.B -ge 243 -and $pixel.G -le 12){throw 'Wallpaper removal left a stale renderer texture'}
            }finally{$graphics.Dispose();$sample.Dispose()}
        }
        $result.wallpaper_reload='pass: all four panes displayed the new wallpaper and removed it'
        Capture 'wallpaper-removed'
        }
    }
    Test-RendererDpi
    $monitors=[PaneAcceptance]::Monitors()
    $result.monitor_dpi=@($monitors | ForEach-Object {$_.Dpi})
    foreach($monitor in $monitors){
        [void][PaneAcceptance]::SetWindowPos($window,[IntPtr]::Zero,($monitor.Left+60),($monitor.Top+40),1050,730,0x14)
        [PaneAcceptance]::Responsive($window)
        Start-Sleep -Milliseconds 200
        $movedPanes=Wait-Panes 4
        if(@(Compare-Object @($panes | ForEach-Object ToInt64) @($movedPanes | ForEach-Object ToInt64)).Count -ne 0){throw 'Monitor move rebuilt panes'}
    }
    [void][PaneAcceptance]::SetWindowPos($window,[IntPtr]::Zero,60,40,1050,730,0x14)
    $result.monitor_move='pass'
    $result.dpi_transition=if(@($monitors | ForEach-Object {$_.Dpi} | Select-Object -Unique).Count -gt 1){'observed mixed-DPI monitors; inspect per-transition evidence'}else{'unverified: both monitors have the same DPI'}



    $glyphDeliveries=@(Select-String -LiteralPath (Join-Path $outputRoot 'tmp/mostty-diag.log') -Pattern 'glyph upload: surface=(\d+) cache=')
    $glyphIds=@($glyphDeliveries | ForEach-Object {[int]$_.Matches[0].Groups[1].Value} | Select-Object -Unique)
    foreach($paneHandle in $panes){if($glyphIds -notcontains (Get-PaneMetrics $paneHandle).Id){throw 'No asynchronous glyph upload observed for a pane'}}
    $result.async_glyph_delivery='pass: uploads observed for every original pane'
    Test-CloseActions
    $result.status = if($result.ime -eq 'pass' -and $result.transparency_blur -notlike 'unsupported*'){'pass'}else{'partial'}
} catch {
    $result.status = if($_.Exception -is [NotSupportedException]){'unsupported'}else{'fail'}
    $result.error = $_.Exception.Message
    if ($window -ne [IntPtr]::Zero -and -not $app.HasExited) { Capture 'failure' }
    if($result.status -ne 'unsupported'){throw}
} finally {
    if (-not $KeepRunning -and -not $app.HasExited) { $app.Kill(); $app.WaitForExit() }
    $validationFailed=$false
    if($VulkanValidation -and $result.status -eq 'unsupported'){
        $result.vulkan_validation='unverified: backend startup unavailable'
    }elseif($VulkanValidation -and -not $app.HasExited){
        $result.vulkan_validation='unverified: process still running';$validationFailed=$true
    }elseif($VulkanValidation){
        $validationText=$validationStdout.GetAwaiter().GetResult()+[Environment]::NewLine+$validationStderr.GetAwaiter().GetResult()
        [IO.File]::WriteAllText($validationLog,$validationText)
        $result.vulkan_validation_instances=([regex]::Matches($validationText,'Khronos Validation Layer Active')).Count
        if($TestRecovery -and $result.vulkan_validation_instances -lt 2){$validationFailed=$true}
        if($validationText -notmatch 'Khronos Validation Layer Active' -or $validationText -notmatch 'SYNCHRONIZATION_VALIDATION'){
            $result.vulkan_validation='unverified: synchronization validation activation not captured';$validationFailed=$true
        }elseif(-not (Test-Path -LiteralPath $validationLog)){
            $result.vulkan_validation='unverified: validation layer log missing';$validationFailed=$true
        }else{
            $validationErrors=@(Select-String -LiteralPath $validationLog -Pattern 'Validation Error|SYNC-HAZARD')
            $result.vulkan_validation_errors=$validationErrors.Count
            $result.vulkan_validation_log=$validationLog
            $result.vulkan_validation=if($validationErrors.Count -eq 0){'no validation errors observed'}else{'failed'}
            $validationFailed=$validationFailed -or $validationErrors.Count -gt 0
        }
        if($validationFailed){$result.status='fail'}
    }
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $outputRoot 'result.json') -Encoding utf8
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $outputRoot "result-$runId.json") -Encoding utf8
    $result | ConvertTo-Json -Depth 6
    if($previousDpiContext -ne [IntPtr]::Zero){$null=[PaneAcceptance]::SetThreadDpiAwarenessContext($previousDpiContext)}
    if($validationFailed){throw "Vulkan validation did not pass; inspect $validationLog"}
}
