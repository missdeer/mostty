param([Parameter(Mandatory=$true)][ValidateSet('d3d12','opengl','pure-opengl','vulkan','native-vulkan')][string]$Renderer)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$outputRoot=Join-Path $root "tmp\pane-backend-$Renderer"
$profile=Join-Path $outputRoot 'profile\Mostty'
New-Item -ItemType Directory -Force -Path $profile | Out-Null
@("renderer = $Renderer",'background-opacity = 1','background-blur = false','font-size = 14') | Set-Content -LiteralPath (Join-Path $profile 'config') -Encoding utf8
if(-not ('PaneAcceptance' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'pane-test-native.cs')}
$start=[Diagnostics.ProcessStartInfo]::new((Join-Path $root 'zig-out\bin\Mostty.exe'))
$start.WorkingDirectory=$outputRoot
$start.UseShellExecute=$false
$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
$start.Environment['LOCALAPPDATA']=Split-Path $profile -Parent
$start.Environment['MOSTTY_DIAG']='1'
$app=[Diagnostics.Process]::Start($start)
$result=[ordered]@{renderer=$Renderer;process_id=$app.Id;status='running'}
try {
    $deadline=[DateTime]::UtcNow.AddSeconds(20)
    $window=[IntPtr]::Zero
    do {
        Start-Sleep -Milliseconds 100
        if($app.HasExited){throw "Backend exited during initialization: $($app.ExitCode)"}
        $window=[PaneAcceptance]::Root($app.Id)
        $dialog=[PaneAcceptance]::Dialog($app.Id)
        if($dialog -ne [IntPtr]::Zero){break}
    } while($window -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
    if($window -eq [IntPtr]::Zero){throw 'No backend window'}
    Start-Sleep -Seconds 2
    $dialog=[PaneAcceptance]::Dialog($app.Id)
    if($dialog -ne [IntPtr]::Zero){
        $text=[PaneAcceptance]::DialogText($dialog)
        if($text -notmatch 'D3D11'){throw "Unexpected startup dialog: $text"}
        $result.startup='unsupported on this driver; explicit fallback offered'
        $result.reason=$text
        [PaneAcceptance]::ClickDialogButton($dialog,7)
        if(-not $app.WaitForExit(8000)){throw 'Declining fallback did not exit'}
        $result.status='explicit startup limitation verified'
    } else {
        [void][PaneAcceptance]::SetWindowPos($window,[IntPtr](-1),60,40,950,650,0x40)
        [PaneAcceptance]::Activate($window,$app.Id)
        [PaneAcceptance]::Responsive($window)
        if([PaneAcceptance]::Panes($window).Count -ne 0){throw 'Research backend unexpectedly created a D3D11 pane'}
        [PaneAcceptance]::Chord($window,$app.Id,@(0x11,0x10,0x44))
        $deadline=[DateTime]::UtcNow.AddSeconds(5)
        do {Start-Sleep -Milliseconds 100;$dialog=[PaneAcceptance]::Dialog($app.Id)}while($dialog -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
        if($dialog -eq [IntPtr]::Zero){throw 'Split restriction was not surfaced'}
        $text=[PaneAcceptance]::DialogText($dialog)
        if($text -notmatch 'selected renderer has not been changed'){throw "Unexpected split dialog: $text"}
        $result.split_message=$text
        [PaneAcceptance]::ClickDialogButton($dialog,2)
        Start-Sleep -Milliseconds 300
        if([PaneAcceptance]::Dialog($app.Id) -ne [IntPtr]::Zero){throw 'Split dialog did not close'}
        if([PaneAcceptance]::Panes($window).Count -ne 0){throw 'Split command silently changed backend'}
        $result.startup='pass'
        $result.split='explicitly unavailable; renderer retained'
        foreach($c in 'exit'.ToCharArray()){[void][PaneAcceptance]::PostMessageW($window,0x102,[UIntPtr][int][char]$c,[IntPtr]::Zero)}
        [void][PaneAcceptance]::PostMessageW($window,0x102,[UIntPtr]13,[IntPtr]::Zero)
        if(-not $app.WaitForExit(8000)){throw 'Single session exit hung'}
        $result.exit_code=$app.ExitCode
        if($app.ExitCode -ne 0){throw 'Backend did not exit cleanly'}
        $result.status='single-surface compatibility and split restriction verified'
    }
 } catch {
    $result.status='fail';$result.error=$_.Exception.Message
    if($window -ne [IntPtr]::Zero -and -not $app.HasExited){
        Add-Type -AssemblyName System.Drawing
        $r=[PaneAcceptance]::Box($window)
        $bitmap=[Drawing.Bitmap]::new($r.Right-$r.Left,$r.Bottom-$r.Top)
        $graphics=[Drawing.Graphics]::FromImage($bitmap)
        try{$graphics.CopyFromScreen($r.Left,$r.Top,0,0,$bitmap.Size);$bitmap.Save((Join-Path $outputRoot 'failure.png'),[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}
    }
    throw
}
finally {
    if(-not $app.HasExited){$app.Kill();$app.WaitForExit()}
    $result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $outputRoot 'result.json') -Encoding utf8
    $result | ConvertTo-Json -Depth 4
}
