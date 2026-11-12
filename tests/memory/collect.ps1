# PowerShell 7. OS metrics are process-scoped; related processes stay separate.
param([int]$TargetPid = 0, [string]$Executable = '', [string]$Metadata = '',
      [Parameter(Mandatory)][string]$Output, [int]$Samples = 60, [int]$IntervalMs = 250, [switch]$Smoke)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Windows collector requires Windows' }
if ($Samples -lt 2 -or $IntervalMs -lt 10) { throw 'Need at least two samples and 10 ms cadence' }
if ($Smoke) {
    $TargetPid = $PID
    $meta = @{ scenario='collector-smoke'; phase='smoke'; side='head'; trial=0; run_group='smoke';
        commit=(& git rev-parse HEAD); compiler=(& zig version); mode='collector-smoke'; target_cpu=$env:PROCESSOR_ARCHITECTURE;
        backend='collector-self'; presentation=$null; font='not-applicable'; font_size_pt=0; dpi=0; window_pixels=@(0,0); panes=0;
        dependencies=(Get-FileHash build.zig.zon -Algorithm SHA256).Hash; conpty_version='not-applicable';
        input_sha256='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'; steady_samples=$Samples; warmup_seconds=0 }
} else {
    if ($TargetPid -le 0 -or -not $Executable -or -not $Metadata) { throw 'Specify TargetPid, Executable and Metadata' }
    $meta = Get-Content -Raw $Metadata | ConvertFrom-Json -AsHashtable
    $meta.binary_sha256 = (Get-FileHash $Executable -Algorithm SHA256).Hash
}
foreach ($key in @('commit','compiler','mode','target_cpu','backend','font','font_size_pt','dpi','window_pixels','panes','dependencies','conpty_version','input_sha256','scenario','side','trial','run_group','phase','steady_samples','warmup_seconds')) {
    if (-not $meta.ContainsKey($key)) { throw "Missing metadata: $key" }
}
$meta.kind='metadata'; $meta.schema=1; $meta.platform='Windows'; $meta.role=$(if ($Smoke) {'smoke'} else {'measurement'})
if (-not $meta.ContainsKey('presentation')) { throw 'Missing presentation metadata (null for D3D11/D3D12)' }
$meta.pid=$TargetPid; $meta.samples=$Samples; $meta.interval_ms=$IntervalMs
$meta.scope='Target PID only, including in-process conpty.dll; OpenConsole and shell excluded. related_pids are separate.'
try {
    $meta.hardware=@{ os=[Environment]::OSVersion.VersionString;
        cpu=@(Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors);
        gpu=@(Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion,PNPDeviceID) }
} catch { $meta.hardware=@{os=[Environment]::OSVersion.VersionString; status='blocked'; reason=$_.Exception.Message} }
$parent = Split-Path -Parent $Output
if ($parent) { $null=New-Item -ItemType Directory -Force $parent }
$meta | ConvertTo-Json -Depth 15 -Compress | Set-Content -Encoding utf8NoBOM $Output
function ProcessMemory([int]$Id) {
    try {
        $p=Get-Process -Id $Id
        return @{ pid=$Id; name=$p.ProcessName; private_bytes=$p.PrivateMemorySize64; working_set_bytes=$p.WorkingSet64;
            paged_memory_bytes=$p.PagedMemorySize64; cpu_ns=[long]($p.TotalProcessorTime.TotalMilliseconds*1000000); status='ok' }
    } catch { return @{ pid=$Id; status='exited-or-unavailable'; reason=$_.Exception.Message } }
}
function AppResources {
    if ($Smoke) { return @{ status='blocked'; reason='Collector smoke samples itself, not Mostty'; data=$null } }
    $start=[Diagnostics.ProcessStartInfo]::new($Executable)
    $start.UseShellExecute=$false; $start.RedirectStandardInput=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    foreach ($arg in @('+control','--target-process',"$TargetPid")) { $start.ArgumentList.Add($arg) }
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$start
    try {
        $null=$process.Start()
        $process.StandardInput.WriteLine('{"action":"resources"}'); $process.StandardInput.Close()
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) { $process.Kill(); throw 'Resource probe timed out' }
        $reply=$stdout.GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
        if ($process.ExitCode -ne 0 -or -not $reply.ok -or $reply.resources.schema -ne 1) { throw 'Mostty resource API unavailable' }
        return @{status='ok'; data=$reply.resources}
    } catch { return @{status='blocked'; reason=$_.Exception.Message; data=$null} }
    finally { $process.Dispose() }
}
Start-Sleep -Milliseconds ([int](1000*$meta.warmup_seconds))
$clock=[Diagnostics.Stopwatch]::StartNew()
for ($i=0; $i -lt $Samples; $i++) {
    $start=$clock.Elapsed.TotalMilliseconds
    $os=ProcessMemory $TargetPid
    $gpu=@{status='blocked'; dedicated_bytes=$null; shared_bytes=$null; reason='GPU Process Memory counters unavailable'}
    if (-not $Smoke) {
        try {
            $counters=Get-Counter '\GPU Process Memory(*)\Dedicated Usage','\GPU Process Memory(*)\Shared Usage' -ErrorAction Stop
            $matching=@($counters.CounterSamples | Where-Object { $_.InstanceName -match "^pid_$($TargetPid)_" })
            $dedicated=@($matching | Where-Object Path -Like '*\dedicated usage')
            $shared=@($matching | Where-Object Path -Like '*\shared usage')
            if ($dedicated.Count -eq 0 -or $shared.Count -eq 0) { throw 'Target dedicated/shared GPU counter unavailable' }
            $gpu=@{status='ok'; dedicated_bytes=[long](($dedicated | Measure-Object CookedValue -Sum).Sum);
                shared_bytes=[long](($shared | Measure-Object CookedValue -Sum).Sum);
                scope='Sum across target PID adapter instances; do not add to logical textures or process memory'}
        } catch { $gpu.reason=$_.Exception.Message }
    }
    $probe=[Diagnostics.Stopwatch]::StartNew()
    $app=AppResources
    $probe.Stop()
    $related=@(); if ($meta.ContainsKey('related_pids')) { foreach ($id in $meta.related_pids) { $related+=ProcessMemory $id } }
    @{kind='sample'; index=$i; elapsed_ns=[long]($clock.Elapsed.TotalMilliseconds*1000000); phase=$meta.phase;
        os=$os; gpu=$gpu; app=$app; related=$related; probe_ns=[long]($probe.Elapsed.TotalMilliseconds*1000000)} |
        ConvertTo-Json -Depth 25 -Compress | Add-Content -Encoding utf8NoBOM $Output
    $remaining=$IntervalMs-($clock.Elapsed.TotalMilliseconds-$start)
    if ($i+1 -lt $Samples -and $remaining -gt 0) { Start-Sleep -Milliseconds ([int]$remaining) }
}
